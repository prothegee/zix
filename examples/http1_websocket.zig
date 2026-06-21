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

// --------------------------------------------------------- //

// Per-frame callback for the engine-owned WebSocket. The engine parses each
// client frame and calls this for text/binary only (ping is auto-ponged, close
// is auto-echoed), so this just echoes the payload straight back.
fn wsOnFrame(fd: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    zix.Http1.WebSocket.send(fd, @enumFromInt(opcode), payload) catch {};
}

// GET /ws
// WebSocket echo endpoint.
//
// The handler validates the upgrade then calls WebSocket.serve, which completes
// the handshake and hands the connection to the engine's epoll loop. From then
// on wsOnFrame runs per frame and no worker is parked on the connection. Engine
// owned WebSocket requires dispatch_model .EPOLL.
//
// Connect:
// wscat    -c "ws://localhost:9028/ws"
// websocat    "ws://localhost:9028/ws"
fn wsHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;

    if (!std.mem.eql(u8, head.method, "GET")) {
        zix.Http1.writeJson(fd, 405, "{\"error\":\"method not allowed\"}") catch {};
        return;
    }

    const upgrade_val = zix.Http1.getHeader(head, "upgrade") orelse "";
    const ws_key = zix.Http1.getHeader(head, "sec-websocket-key");

    if (!std.ascii.eqlIgnoreCase(upgrade_val, "websocket") or ws_key == null) {
        zix.Http1.writeJson(fd, 400, "{\"error\":\"not a websocket upgrade request\"}") catch {};
        return;
    }

    zix.Http1.WebSocket.serve(fd, ws_key.?, wsOnFrame) catch {
        zix.Http1.writeJson(fd, 500, "{\"error\":\"handshake failed\"}") catch {};
        return;
    };
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/ws", .handler = wsHandler },
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
