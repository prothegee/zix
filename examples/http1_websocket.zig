const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9028;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .EPOLL;
const KERNEL_BACKLOG: u31 = 1024;
// Comptime per-deployment tuning profile (ADR-041): .lean uses a small recv
// buffer for memory-bound hosts, .throughput a larger one for RAM-abundant hosts.
const Profile = enum { lean, throughput };
const PROFILE: Profile = .throughput;
const MAX_RECV_BUF: usize = switch (PROFILE) {
    .lean => 4 * 1024,
    .throughput => 16 * 1024,
};
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
const MAX_HEADERS: u8 = 16;
const WORKERS: usize = 0;

// Room registry bounds. Each member is tracked in a fixed slot so the demo
// never allocates on the frame path.
const ROOM_ID_MAX: usize = 64;
const NAME_MAX: usize = 64;
const MAX_MEMBERS: usize = 512;
const MSG_MAX: usize = 4096;

// --------------------------------------------------------- //

/// One connection tracked in a room: its fd, the room it joined, and the
/// display name to prefix its messages with. Strings are owned copies in fixed
/// buffers so a slot never points into a request buffer that gets freed once
/// the handler returns.
const Member = struct {
    fd: std.posix.fd_t = -1,
    active: bool = false,
    room_len: usize = 0,
    name_len: usize = 0,
    room_buf: [ROOM_ID_MAX]u8 = undefined,
    name_buf: [NAME_MAX]u8 = undefined,
};

/// What one broadcast pass resolved for a sender: its display name and the live
/// fds of every member sharing its room. Filled into caller-owned buffers so
/// the frame path allocates nothing.
const Fanout = struct {
    name: []const u8,
    count: usize,
};

/// Process-lifetime room registry keyed by fd.
///
/// The http1 engine-owned WebSocket model hands the connection to the EPOLL
/// loop and then calls a stateless per-frame callback (fd, opcode, payload)
/// with no per-connection context and no disconnect hook. So the demo keeps its
/// own fd -> (room, name) map here, joins on upgrade, and prunes descriptors the
/// kernel has since closed lazily (there is no leave() callback to hook).
///
/// Note:
/// - Guarded by an atomic spinlock, not std.Io.Mutex: the frame callback runs
///   without an std.Io handle, and the EPOLL engine is multi-worker so a room
///   can span worker threads.
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

    /// Index of the active member on fd, or null. Caller holds the lock.
    fn slotForFd(self: *Rooms, fd: std.posix.fd_t) ?usize {
        for (&self.members, 0..) |*member, i| {
            if (member.active and member.fd == fd) return i;
        }

        return null;
    }

    /// Index of the first free slot, or null when the table is full. Caller
    /// holds the lock.
    fn freeSlot(self: *Rooms) ?usize {
        for (&self.members, 0..) |*member, i| {
            if (!member.active) return i;
        }

        return null;
    }

    /// Drop every slot whose descriptor the kernel has closed. Probes with
    /// fcntl(F_GETFD): a closed fd returns EBADF. Caller holds the lock.
    fn pruneDeadLocked(self: *Rooms) void {
        for (&self.members) |*member| {
            if (!member.active) continue;

            const rc = std.os.linux.fcntl(member.fd, std.posix.F.GETFD, 0);
            if (std.posix.errno(rc) != .SUCCESS) member.active = false;
        }
    }

    /// Add (or refresh) the member on fd. A slot already holding fd is reused,
    /// so a reused descriptor overwrites its stale entry. When the table is full
    /// the dead-descriptor prune runs once before giving up.
    fn join(self: *Rooms, fd: std.posix.fd_t, room_id: []const u8, display_name: []const u8) void {
        self.lock();
        defer self.unlock();

        const slot = self.slotForFd(fd) orelse self.freeSlot() orelse blk: {
            self.pruneDeadLocked();
            break :blk self.freeSlot() orelse return;
        };

        const member = &self.members[slot];
        const room_len = @min(room_id.len, ROOM_ID_MAX);
        const name_len = @min(display_name.len, NAME_MAX);

        @memcpy(member.room_buf[0..room_len], room_id[0..room_len]);
        @memcpy(member.name_buf[0..name_len], display_name[0..name_len]);
        member.room_len = room_len;
        member.name_len = name_len;
        member.fd = fd;
        member.active = true;
    }

    /// Resolve the sender on fd: copy its display name into name_out and fill
    /// fds_out with the live members of its room. Descriptors the kernel has
    /// closed are dropped in passing, so an active room self-heals one message
    /// after a member leaves. Returns null if fd is not a tracked member.
    ///
    /// Note:
    /// - The sender is included in the fan-out, so a client sees its own message
    ///   echoed back with the name prefix (matching the ergonomic-engine demo).
    fn fanout(self: *Rooms, fd: std.posix.fd_t, name_out: []u8, fds_out: []std.posix.fd_t) ?Fanout {
        self.lock();
        defer self.unlock();

        const idx = self.slotForFd(fd) orelse return null;
        const sender = self.members[idx];

        const name_len = @min(sender.name_len, name_out.len);
        @memcpy(name_out[0..name_len], sender.name_buf[0..name_len]);

        const room_id = sender.room_buf[0..sender.room_len];
        var count: usize = 0;

        for (&self.members) |*member| {
            if (!member.active) continue;
            if (!std.mem.eql(u8, member.room_buf[0..member.room_len], room_id)) continue;

            const rc = std.os.linux.fcntl(member.fd, std.posix.F.GETFD, 0);
            if (std.posix.errno(rc) != .SUCCESS) {
                member.active = false;
                continue;
            }
            if (count >= fds_out.len) break;

            fds_out[count] = member.fd;
            count += 1;
        }

        return .{ .name = name_out[0..name_len], .count = count };
    }
};

var rooms: Rooms = .{};

// --------------------------------------------------------- //

// Per-frame callback for the engine-owned WebSocket. The engine parses each
// client frame and calls this for text/binary only (ping is auto-ponged, close
// is auto-echoed). This resolves the sender's room and name, prefixes the
// payload, and fans it out to every member of the room via the engine's
// broadcast primitive (which writes each fd directly, bypassing the per-frame
// send sink).
fn wsOnFrame(fd: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    _ = opcode;

    var name_buf: [NAME_MAX]u8 = undefined;
    var fds: [MAX_MEMBERS]std.posix.fd_t = undefined;

    const view = rooms.fanout(fd, &name_buf, &fds) orelse return;

    const capped = payload[0..@min(payload.len, MSG_MAX)];
    var msg_buf: [NAME_MAX + MSG_MAX + 8]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "[{s}] {s}", .{ view.name, capped }) catch capped;

    zix.Http1.WebSocket.broadcast(fds[0..view.count], .text, msg);
}

// GET /ws/:room-id?name=alice
// WebSocket room broadcast endpoint.
//
// The handler reads the room-id path param and the name query param, validates
// the upgrade, then calls WebSocket.serve, which completes the handshake and
// hands the connection to the engine's epoll loop. Path and query params MUST
// be read here: after serve the connection is a raw WebSocket stream and the
// request context is gone. join() copies both into the registry before the
// handler returns. From then on wsOnFrame runs per frame and no worker is
// parked on the connection.
//
// Engine-owned WebSocket (serve + broadcast) requires dispatch_model .EPOLL.
//
// Connect (name defaults to "anonymous" when ?name is omitted):
// wscat    -c "ws://localhost:9028/ws/lobby?name=alice"
// websocat    "ws://localhost:9028/ws/lobby?name=alice"
//
// After connecting, any message is broadcast to every client in the same room,
// prefixed with the sender's display name.
fn wsHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;

    if (!std.mem.eql(u8, head.method, "GET")) {
        zix.Http1.sendJsonFD(fd, 405, "{\"error\":\"method not allowed\"}") catch {};
        return;
    }

    const room_id = zix.Http1.pathParam("room-id") orelse {
        zix.Http1.sendJsonFD(fd, 400, "{\"error\":\"missing room-id\"}") catch {};
        return;
    };

    // Read the display name NOW: it is unavailable after the upgrade.
    const display_name = zix.Http1.queryParam(head, "name") orelse "anonymous";

    const upgrade_val = zix.Http1.getHeader(head, "upgrade") orelse "";
    const ws_key = zix.Http1.getHeader(head, "sec-websocket-key");

    if (!std.ascii.eqlIgnoreCase(upgrade_val, "websocket") or ws_key == null) {
        zix.Http1.sendJsonFD(fd, 400, "{\"error\":\"not a websocket upgrade request\"}") catch {};
        return;
    }

    zix.Http1.WebSocket.serve(fd, ws_key.?, wsOnFrame) catch {
        zix.Http1.sendJsonFD(fd, 500, "{\"error\":\"handshake failed\"}") catch {};
        return;
    };

    rooms.join(fd, room_id, display_name);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/ws/:room-id", .handler = wsHandler, .kind = .PARAM },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .compression_max_out = COMPRESSION_MAX_OUT,
        .max_headers = MAX_HEADERS,
        .workers = WORKERS,
    });
    defer server.deinit();

    try server.run();
}
