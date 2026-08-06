// Usage:
// zig build example-webrtc_signaling
// ./zig-out/bin/zix-example-webrtc_signaling
// browser: http://127.0.0.1:9081/ in two tabs
//
// The signalling half of WebRTC, and nothing else. Two browser tabs need to hand each other an
// offer, an answer, and their candidates before they can talk directly, and none of that has a
// transport of its own: WebRTC leaves it to the application (RFC 8829 3.4). This carries it over a
// WebSocket room.
//
// zix is not a peer here. Once the two tabs have swapped descriptions they open a data channel
// straight to each other, and every message on it goes browser to browser without touching this
// process. Watch the terminal: it goes quiet the moment the channel opens.
//
// Everything it relays is opaque to it. A frame arriving from one member goes to the others in the
// same room unchanged and unread, which is what makes this the same 40 lines whether the tabs are
// negotiating a data channel, a camera, or something not written yet.
//
// Pair it with:
//   webrtc_datachannel_chat, for the other shape, where zix IS the peer

const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

// --------------------------------------------------------- //

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9081;

// Served page. Loaded per request so editing the file shows up on a browser refresh with no
// rebuild. The path is relative, so run this example from the repository root.
const PAGE_PATH: []const u8 = "templates/html/webrtc_signaling.html";
const MAX_PAGE_BYTES: usize = 64 * 1024;

// Engine-owned WebSocket runs under every model: the event loops drive their own frame pump and
// .ASYNC drives the blocking one. So this takes the per-target idiom.
const DISPATCH_MODEL: zix.Http1.DispatchModel = if (builtin.os.tag == .linux) .URING else .ASYNC;
const KERNEL_BACKLOG: u31 = 128;

// An offer with a video section and a dozen candidates is a few kilobytes, so the receive buffer
// has to hold more than a chat line.
const MAX_RECV_BUF: usize = 16 * 1024;

// Room registry bounds. Every member sits in a fixed slot, so relaying allocates nothing.
const ROOM_ID_MAX: usize = 64;
const MAX_MEMBERS: usize = 64;

/// Sentinel for "no member". Windows descriptors are opaque pointers, POSIX are ints.
const NO_FD: std.posix.fd_t = if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else -1;

/// Whether fd still refers to an open descriptor. Probes with fcntl(F_GETFD), a closed one answers
/// EBADF. Windows has no cheap probe here, so members are assumed live and a write that fails is
/// what reports them gone.
///
/// Note:
/// - fcntl has no portable wrapper in std here: the Linux form returns the raw syscall convention
///   (a negative errno packed into a usize) and the libc form returns c_int with -1 on failure, so
///   each branch checks its own return.
fn fdAlive(fd: std.posix.fd_t) bool {
    if (comptime builtin.os.tag == .windows) return true;

    if (comptime builtin.os.tag == .linux) {
        const rc = std.os.linux.fcntl(fd, std.posix.F.GETFD, 0);

        return std.posix.errno(rc) == .SUCCESS;
    }

    return std.c.fcntl(fd, std.posix.F.GETFD, @as(c_int, 0)) != -1;
}

// --------------------------------------------------------- //

/// One tab in a room: the connection it arrived on, and which room that was.
const Member = struct {
    fd: std.posix.fd_t = NO_FD,
    active: bool = false,
    room_len: usize = 0,
    room_buf: [ROOM_ID_MAX]u8 = undefined,
};

/// Who is in which room, for the process lifetime.
///
/// Note:
/// - Guarded by an atomic spinlock rather than std.Io.Mutex: the frame callback runs without an
///   std.Io handle, and the per-core models put two members of one room on different worker
///   threads.
/// - There is no leave callback to hook, so a departed tab is noticed on the next relay: the write
///   to its descriptor fails and its slot is freed then.
const Rooms = struct {
    locked: std.atomic.Value(bool) = .init(false),
    members: [MAX_MEMBERS]Member = @splat(.{}),

    fn lock(self: *Rooms) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Rooms) void {
        self.locked.store(false, .release);
    }

    /// Put a connection in a room, reusing its slot when the descriptor is already known.
    fn join(self: *Rooms, fd: std.posix.fd_t, room_id: []const u8) void {
        self.lock();
        defer self.unlock();

        const slot = self.slotForFd(fd) orelse self.freeSlot() orelse return;
        const member = &self.members[slot];
        const room_len = @min(room_id.len, ROOM_ID_MAX);

        @memcpy(member.room_buf[0..room_len], room_id[0..room_len]);
        member.room_len = room_len;
        member.fd = fd;
        member.active = true;
    }

    /// Fill `out` with everyone in the sender's room except the sender, and say how many that was.
    ///
    /// Note:
    /// - The sender is left out on purpose. A relay that echoes hands a tab back its own offer,
    ///   and the browser answers it as if a second peer had appeared.
    /// - A descriptor the kernel has closed is dropped in passing, so a room heals one frame after
    ///   a tab goes. There is no leave callback to hook, which is why it is noticed here.
    fn others(self: *Rooms, fd: std.posix.fd_t, out: []std.posix.fd_t) usize {
        self.lock();
        defer self.unlock();

        const sender = self.slotForFd(fd) orelse return 0;
        const room_id = self.members[sender].room_buf[0..self.members[sender].room_len];

        var count: usize = 0;

        for (&self.members) |*member| {
            if (!member.active or member.fd == fd) continue;
            if (!std.mem.eql(u8, member.room_buf[0..member.room_len], room_id)) continue;

            if (!fdAlive(member.fd)) {
                member.active = false;

                continue;
            }

            if (count == out.len) break;

            out[count] = member.fd;
            count += 1;
        }

        return count;
    }

    /// The slot holding a descriptor, or null. Caller holds the lock.
    fn slotForFd(self: *Rooms, fd: std.posix.fd_t) ?usize {
        for (&self.members, 0..) |*member, i| {
            if (member.active and member.fd == fd) return i;
        }

        return null;
    }

    /// The first free slot, or null when the table is full. Caller holds the lock.
    fn freeSlot(self: *Rooms) ?usize {
        for (&self.members, 0..) |*member, i| {
            if (!member.active) return i;
        }

        return null;
    }
};

var rooms: Rooms = .{};

// --------------------------------------------------------- //

// Every frame goes to the rest of the room, byte for byte. Nothing here reads the JSON inside, so
// what the two tabs put in it is between them.
//
// broadcast, not sendFD. sendFD answers the connection whose frame is being handled: it appends to
// that connection's send sink, so aiming it at another member sends that member's bytes back to
// the sender instead. broadcast builds the frame once and writes it to each descriptor directly,
// which is what reaching somebody else takes.
fn onFrame(fd: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    var peers: [MAX_MEMBERS]std.posix.fd_t = undefined;
    const count = rooms.others(fd, &peers);

    if (count == 0) return;

    zix.Http1.WebSocket.broadcast(peers[0..count], @enumFromInt(opcode), payload);
}

// GET /ws/:room-id
// The relay. Two tabs opening this on the same room id can reach each other, and nobody else can.
fn signalHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    // Read the room id NOW. After the upgrade the connection is a raw WebSocket stream and the
    // request context is gone.
    const room_id = req.pathParam("room-id") orelse {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"missing room-id\"}");
        return;
    };

    const upgrade = req.header("upgrade") orelse "";
    const key = req.header("sec-websocket-key");

    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket") or key == null) {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"not a websocket upgrade request\"}");
        return;
    }

    zix.Http1.WebSocket.serve(req.fd, key.?, onFrame) catch {
        res.setStatus(.INTERNAL_SERVER_ERROR);

        try res.sendJson("{\"error\":\"handshake failed\"}");
        return;
    };

    rooms.join(req.fd, room_id);
}

// GET /
// The page both tabs load.
fn pageHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    const page = try zix.utils.file.load(ctx.io, ctx.allocator, PAGE_PATH, MAX_PAGE_BYTES);
    defer ctx.allocator.free(page);

    res.setContentType(.TEXT_HTML);

    try res.send(page);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/ws/:room-id", .handler = signalHandler, .kind = .PARAM },
    .{ .path = "/", .handler = pageHandler },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
    });
    defer server.deinit();

    std.log.info("webrtc signalling relay on http://{s}:{d}/ (open it in two tabs)", .{ IP, PORT });

    try server.run();
}
