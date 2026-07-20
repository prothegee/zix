const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9029;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .URING;
const KERNEL_BACKLOG: u31 = 1024;
// Comptime per-deployment tuning profile (ADR-041): .lean uses a small recv
// buffer for memory-bound hosts, .throughput a larger one for RAM-abundant hosts.
const Profile = enum { lean, throughput };
const PROFILE: Profile = .throughput;
const MAX_RECV_BUF: usize = switch (PROFILE) {
    .lean => 4 * 1024,
    .throughput => 16 * 1024,
};
const WORKERS: usize = 0;

// --------------------------------------------------------- //

// Per-frame callback for the engine-owned WebSocket. The engine parses each
// client frame and calls this for text/binary only (ping is auto-ponged, close
// is auto-echoed), so this just echoes the payload straight back.
fn wsOnFrame(fd: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    zix.Http1.WebSocket.sendFD(fd, @enumFromInt(opcode), payload) catch {};
}

// GET /ws
// WebSocket echo endpoint on the io_uring (.URING) dispatch model.
//
// The handler validates the upgrade then calls WebSocket.serve, which completes
// the handshake and hands the connection to the engine's ring loop. From then
// on wsOnFrame runs per frame and no worker is parked on the connection. Engine
// owned WebSocket is served on both .EPOLL and .URING.
//
// Connect:
// wscat    -c "ws://localhost:9029/ws"
// websocat    "ws://localhost:9029/ws"
fn wsHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const upgrade_val = req.header("upgrade") orelse "";
    const ws_key = req.header("sec-websocket-key");

    if (!std.ascii.eqlIgnoreCase(upgrade_val, "websocket") or ws_key == null) {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"not a websocket upgrade request\"}");
        return;
    }

    zix.Http1.WebSocket.serve(req.fd, ws_key.?, wsOnFrame) catch {
        res.setStatus(.INTERNAL_SERVER_ERROR);

        try res.sendJson("{\"error\":\"handshake failed\"}");
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
        .workers = WORKERS,
    });
    defer server.deinit();

    try server.run();
}
