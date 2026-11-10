//! ZIX example http1 websocket
//!
//! ### file: examples/http1_websocket.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example with two WebSocket routes: an echo route and a room
//! broadcast route.
//!
//! ### note:
//!
//! The engine runs the frame loop on every model: .URING and .EPOLL from their
//! event loop, .ASYNC with the blocking loop. The frame callback has no
//! per-connection context and no leave hook, so the room registry is keyed by
//! fd and drops closed descriptors lazily.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const zix = @import("zix");

const builtin = @import("builtin");

// --------------------------------------------------------- //

const IP:[]const u8 = "127.0.0.1";
const PORT:u16 = 9028;
const WORKERS:usize = 0;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;
const KERNEL_BACKLOG:u31 = 1024;
/// Largest WebSocket frame, apart from the HTTP max_recv_buf.
const WS_RECV_BUF:usize = 16 * 1024;

// Room registry bounds. Each member has a fixed slot, so the frame path never
// allocates.
const ROOM_ID_MAX:usize = 64;
const NAME_MAX:usize = 64;
const MAX_MEMBERS:usize = 512;
const MSG_MAX:usize = 4096;

/// "No member fd". Windows descriptors are opaque pointers, POSIX are ints.
const NO_FD:std.posix.fd_t =
    if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else -1;

// --------------------------------------------------------- //

/// Whether fd is still an open descriptor. fcntl(F_GETFD) on a closed fd
/// fails with EBADF. Windows has no cheap probe, so a member stays until a
/// send to it fails.
fn fdAlive(fd: std.posix.fd_t) bool {
    if (comptime builtin.os.tag == .windows) return true;

    if (comptime builtin.os.tag == .linux) {
        const rc = std.os.linux.fcntl(fd, std.posix.F.GETFD, 0);

        return std.posix.errno(rc) == .SUCCESS;
    }

    return std.c.fcntl(fd, std.posix.F.GETFD, @as(c_int, 0)) != -1;
}

/// One connection in a room: its fd, the room, and the display name. Strings
/// are copied, because the request buffer is gone once the handler returns.
const Member = struct {
    fd: std.posix.fd_t = NO_FD,
    active: bool = false,
    room_len: usize = 0,
    name_len: usize = 0,
    room_buf: [ROOM_ID_MAX]u8 = undefined,
    name_buf: [NAME_MAX]u8 = undefined,
};

/// What one broadcast pass found for a sender: its name and how many live
/// room fds were written to the caller buffer.
const Fanout = struct {
    name: []const u8,
    count: usize,
};

/// Process-wide room registry keyed by fd.
///
/// Note:
/// - Guarded by an atomic spinlock, not std.Io.Mutex: the frame callback has
///   no std.Io handle, and a room can span worker threads.
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

    /// Index of the active member on fd. The caller holds the lock.
    fn slotForFd(self: *Rooms, fd: std.posix.fd_t) ?usize {
        for (&self.members, 0..) |*member, index| {
            if (member.active and member.fd == fd) return index;
        }

        return null;
    }

    /// Index of the first free slot. The caller holds the lock.
    fn freeSlot(self: *Rooms) ?usize {
        for (&self.members, 0..) |*member, index| {
            if (!member.active) return index;
        }

        return null;
    }

    /// Drop every member whose fd is closed. The caller holds the lock.
    fn pruneDeadLocked(self: *Rooms) void {
        for (&self.members) |*member| {
            if (!member.active) continue;

            if (!fdAlive(member.fd)) member.active = false;
        }
    }

    /// Add or refresh the member on fd. A reused fd overwrites its old entry.
    /// A full table prunes closed fds once before it gives up.
    fn join(self: *Rooms, fd: std.posix.fd_t, room_id: []const u8, name: []const u8) void {
        self.lock();
        defer self.unlock();

        const slot = self.slotForFd(fd) orelse self.freeSlot() orelse blk: {
            self.pruneDeadLocked();

            break :blk self.freeSlot() orelse return;
        };

        const member = &self.members[slot];
        const room_len = @min(room_id.len, ROOM_ID_MAX);
        const name_len = @min(name.len, NAME_MAX);

        @memcpy(member.room_buf[0..room_len], room_id[0..room_len]);
        @memcpy(member.name_buf[0..name_len], name[0..name_len]);
        member.room_len = room_len;
        member.name_len = name_len;
        member.fd = fd;
        member.active = true;
    }

    /// Copy the sender name into name_out and fill fds_out with the live fds
    /// of its room, the sender included. Closed fds are dropped on the way.
    fn fanout(
        self: *Rooms,
        fd: std.posix.fd_t,
        name_out: []u8,
        fds_out: []std.posix.fd_t,
    ) ?Fanout {
        self.lock();
        defer self.unlock();

        const sender_index = self.slotForFd(fd) orelse return null;
        const sender = self.members[sender_index];
        const name_len = @min(sender.name_len, name_out.len);
        @memcpy(name_out[0..name_len], sender.name_buf[0..name_len]);

        const room_id = sender.room_buf[0..sender.room_len];
        var count: usize = 0;

        for (&self.members) |*member| {
            if (!member.active) continue;
            if (!std.mem.eql(u8, member.room_buf[0..member.room_len], room_id)) continue;

            if (!fdAlive(member.fd)) {
                member.active = false;
                continue;
            }
            if (count >= fds_out.len) break;

            fds_out[count] = member.fd;
            count += 1;
        }

        return .{
            .name = name_out[0..name_len],
            .count = count,
        };
    }
};

var rooms: Rooms = .{};

/// Answer a JSON error with status.
fn sendError(
    res: *zix.Http1.Response,
    status: zix.Http1.Status.Code,
    body: []const u8,
) !void {
    res.setStatus(status);

    try res.sendJson(body);
}

/// The Sec-WebSocket-Key of a GET upgrade request, or null after answering
/// 405 or 400.
fn upgradeKey(req: *zix.Http1.Request, res: *zix.Http1.Response) !?[]const u8 {
    if (req.method() != .GET) {
        try sendError(res, .METHOD_NOT_ALLOWED, "{\"error\":\"method not allowed\"}");

        return null;
    }

    const upgrade = req.header("upgrade") orelse "";
    const key = req.header("sec-websocket-key") orelse "";

    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket") or key.len == 0) {
        try sendError(res, .BAD_REQUEST, "{\"error\":\"not a websocket upgrade request\"}");

        return null;
    }

    return key;
}

/// Complete the handshake, or answer 500 when it fails.
fn serveOrFail(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    key: []const u8,
    on_frame: zix.Http1.WebSocket.WsFrameFn,
) !bool {
    zix.Http1.WebSocket.serve(req.fd, key, on_frame) catch |err| switch (err) {
        error.ZixHttp1_WebSocket_KeyTooLong,
        error.ZixHttp1_WebSocket_NoSpaceLeft,
        error.ZixHttp1_WebSocket_BrokenPipe,
        error.ZixHttp1_WebSocket_HeadBuild,
        => {
            try sendError(res, .INTERNAL_SERVER_ERROR, "{\"error\":\"handshake failed\"}");

            return false;
        },
    };

    return true;
}

/// Frame callback for /ws: send the payload back to its sender. Ping and
/// close never reach here, the engine answers them.
fn echoOnFrame(fd: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    zix.Http1.WebSocket.sendFD(fd, @enumFromInt(opcode), payload) catch |err| switch (err) {
        // The peer is gone. The engine closes the connection.
        error.ZixHttp1_WebSocketSend_BrokenPipe,
        error.ZixHttp1_WebSocketSend_HeadBuild,
        => {},
    };
}

/// Frame callback for /ws/:room-id: prefix the payload with the sender name
/// and send it to every member of the sender room.
fn roomOnFrame(fd: std.posix.fd_t, _: u8, payload: []const u8) void {
    var name_buf: [NAME_MAX]u8 = undefined;
    var fds: [MAX_MEMBERS]std.posix.fd_t = undefined;

    const view = rooms.fanout(fd, &name_buf, &fds) orelse return;

    const capped = payload[0..@min(payload.len, MSG_MAX)];
    var msg_buf: [NAME_MAX + MSG_MAX + 8]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "[{s}] {s}",
        .{
            view.name,
            capped,
        },
    ) catch |err| switch (err) {
        // msg_buf is sized for the capped name and payload.
        error.NoSpaceLeft => capped,
    };

    zix.Http1.WebSocket.broadcast(fds[0..view.count], .text, msg);
}

// GET /ws
// Echo every frame back to its sender. Read this route first.
// wscat usage:    wscat -c "ws://localhost:9028/ws"
// websocat usage: websocat "ws://localhost:9028/ws"
fn echoHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const key = try upgradeKey(req, res) orelse return;

    _ = try serveOrFail(req, res, key, echoOnFrame);
}

// GET /ws/:room-id?name=alice
// Every message goes to every member of the same room, prefixed with the
// sender name. Read the path and query params before serve: after the
// handler returns, the connection is a raw WebSocket stream.
// wscat usage:    wscat -c "ws://localhost:9028/ws/lobby?name=alice"
// websocat usage: websocat "ws://localhost:9028/ws/lobby?name=alice"
fn roomHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const room_id = req.pathParam("room-id") orelse {
        try sendError(res, .BAD_REQUEST, "{\"error\":\"missing room-id\"}");

        return;
    };
    const name = req.queryParam("name") orelse "anonymous";
    const key = try upgradeKey(req, res) orelse return;

    if (!try serveOrFail(req, res, key, roomOnFrame)) return;

    rooms.join(req.fd, room_id, name);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{
        .path = "/ws",
        .handler = echoHandler,
    },
    .{
        .path = "/ws/:room-id",
        .handler = roomHandler,
        .kind = .PARAM,
    },
});

pub fn main(init: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .ws_recv_buf = WS_RECV_BUF,
    });
    defer server.deinit();

    try server.run();
}

