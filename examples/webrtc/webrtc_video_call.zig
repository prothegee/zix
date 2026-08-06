// Usage:
// zig build example-webrtc_video_call
// ./zig-out/bin/zix-example-webrtc_video_call
// browser: http://localhost:9088/ in two or more tabs, and read the note about that address below
//
// A camera and microphone call between everyone in one room. zix carries the offer, the answer,
// and the candidates, and then steps out: every picture and every sound goes straight from one tab
// to another, and no frame of any of it ever reaches this process.
//
// The relay itself is the same one webrtc_signaling runs, because a signalling relay reads nothing
// it carries. What makes this a call rather than a chat is entirely in the page: getUserMedia for
// the camera and the microphone, addTrack to put them on the connection, ontrack to show what
// arrives, and one connection per other person. Watch the terminal, it says nothing at all once
// the room has found itself.
//
// The room is a mesh, so each pair of tabs holds its own connection and the count grows with the
// square of the members. That is what makes an SFU a different thing: there one peer holds one
// connection to the server and the server does the forwarding. This example is the shape that
// needs no engine at all.
//
// Note:
// - Load the page at http://localhost:9088/, NOT at this machine's network address. A browser
//   hands out getUserMedia in a secure context only, and a plain http page on a network address is
//   not one, so navigator.mediaDevices is undefined there and no camera can be opened. localhost
//   and 127.0.0.1 do count as secure, which is what lets two tabs on one machine call each other
//   with no certificate anywhere. A call between two machines needs the page served over TLS, and
//   examples/tls/ carries that shape.
// - That is the opposite of what webrtc_datachannel_chat and webrtc_file_transfer ask for. In
//   those zix IS the peer, so it has to publish a candidate a browser will pair with, and a
//   loopback one is not. Here the two tabs pair with each other and zix is never a peer at all.
// - Tabs of one browser is the case this was measured on. Different browsers, or different
//   machines over TLS, work the same way as far as this process is concerned.
//
// Pair it with:
//   webrtc_signaling, the same relay carrying a data channel instead of a call
//   webrtc_datachannel_chat, for the other shape, where zix IS the peer

const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

// --------------------------------------------------------- //

// 0.0.0.0 so the page is reachable when it is served over TLS from somewhere else. Over plain
// http only the localhost address can open a camera, see the note above.
const IP: []const u8 = "0.0.0.0";
const PORT: u16 = 9088;

// Served page. Loaded per request so editing the file shows up on a browser refresh with no
// rebuild. The path is relative, so run this example from the repository root.
const PAGE_PATH: []const u8 = "templates/html/webrtc_video_call.html";
const MAX_PAGE_BYTES: usize = 64 * 1024;

// Engine-owned WebSocket runs under every model: the event loops drive their own frame pump and
// .ASYNC drives the blocking one. So this takes the per-target idiom.
const DISPATCH_MODEL: zix.Http1.DispatchModel = if (builtin.os.tag == .linux) .URING else .ASYNC;
const KERNEL_BACKLOG: u31 = 128;

// A call offer is the largest thing this relay carries: an audio section and a video section, each
// listing every codec the browser knows, plus the candidates that follow. Measured at around 6 KB
// from Firefox, so the buffer is sized well clear of it.
const MAX_RECV_BUF: usize = 32 * 1024;

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
// an offer describing two cameras is carried by the same line that carries a data channel.
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

    std.log.info("webrtc video call on http://localhost:{d}/ (open it in two tabs)", .{PORT});

    try server.run();
}
