//! http1_ws.zig: the upstream behind the zixer websocket proxy demo. Port: 9105
//!
//! An rfc 6455 echo server. Once the upgrade completes, zixer is a raw tunnel
//! between the client and this backend, and the upstream that answered the
//! upgrade stays pinned for the life of the connection.
//!
//! The webrtc signaling demo (sites/rtc_signal.cfg) reuses this same server
//! behind a TLS site, because signaling is an ordinary websocket site.
//!
//! Site files: examples/proxies/sites/http1_ws.cfg (edge port 9104)
//!             examples/proxies/sites/rtc_signal.cfg (edge port 9122, wss)
//!
//! Run:
//! zig build zixer-example-http1_ws
//! ./zig-out/bin/zixer-example-http1_ws-<arch>-<os>
//!
//! Through the proxy:
//! websocat ws://127.0.0.1:9104/ws
//! wscat -c ws://127.0.0.1:9104/ws

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9105;
// Engine-owned WebSocket runs under every dispatch model. .ASYNC drives the
// blocking frame loop, which keeps this demo the same on every platform.
const DISPATCH_MODEL: zix.Http1.DispatchModel = .ASYNC;
const MAX_RECV_BUF: usize = 16 * 1024;

// --------------------------------------------------------- //

/// Per-frame callback: send the payload back to whoever sent it. The engine
/// has already answered any ping and echoed any close, so only text and
/// binary frames arrive here.
fn onFrame(fd: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    zix.Http1.WebSocket.sendFD(fd, @enumFromInt(opcode), payload) catch {};
}

// GET /ws : the websocket endpoint.
// Path and header reads must happen before serve(): after it the connection is
// a raw frame stream and the request is gone.
fn wsHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const upgrade_value = req.header("upgrade") orelse "";
    const ws_key = req.header("sec-websocket-key");

    if (!std.ascii.eqlIgnoreCase(upgrade_value, "websocket") or ws_key == null) {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"not a websocket upgrade request\"}");
        return;
    }

    zix.Http1.WebSocket.serve(req.fd, ws_key.?, onFrame) catch {
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
        .max_recv_buf = MAX_RECV_BUF,
    });
    defer server.deinit();

    try server.run();
}
