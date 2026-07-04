//! tls_http_ws.zig: WebSocket over TLS (wss) on the zix.Http (arena) engine (ADR-055).
//!
//! GET /ws - WebSocket echo endpoint over TLS.
//!
//! WebSocket over TLS rides the thread-per-connection path (.ASYNC / .POOL / .MIXED), so this
//! example uses .ASYNC. The handler validates the upgrade then calls WebSocket.serveTls, which
//! completes the handshake (the 101 encrypted through the ADR-054 stream sink) and hands the
//! connection to the https thread: from then on wsOnFrame runs per frame over the TLS session
//! (ping auto-ponged, close auto-echoed). Rooms / broadcast are not served over TLS (each
//! connection has its own session), so this echoes per connection (the cleartext
//! examples/http_websocket.zig keeps the room model).
//!
//! Connect:
//! websocat --insecure "wss://localhost:9075/ws"

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9075;
// Demo fixtures. For a real domain, point CERT / KEY at your certbot files:
// CERT: /etc/letsencrypt/live/sub.domain.tld/fullchain.pem
// KEY: /etc/letsencrypt/live/sub.domain.tld/privkey.pem
const CERT: []const u8 = "examples/tls/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/tls/certs/ecdsa_p256_key.pem";

// --------------------------------------------------------- //

// Per-frame callback: the engine parses each client frame and calls this for text / binary only,
// so this echoes the payload straight back. send() routes through the stream sink (encrypted).
fn wsOnFrame(fd: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    zix.Http.WebSocket.sendFD(fd, @enumFromInt(opcode), payload) catch {};
}

// GET /ws: validate the upgrade, then hand the connection to the https thread over TLS.
fn wsHandler(req: *zix.Http.Request, res: *zix.Http.Response, _: *zix.Http.Context) !void {
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

    zix.Http.WebSocket.serveTls(req.fd, ws_key.?, wsOnFrame) catch {};
}

// --------------------------------------------------------- //

const Routes = [_]zix.Http.Route{
    .{ .path = "/ws", .handler = wsHandler },
};

pub fn main(process: std.process.Init) !void {
    var tls = try zix.Tls.Context.init(std.heap.smp_allocator, process.io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.HTTP_1_1},
    });
    defer tls.deinit();

    var server = try zix.Http.Server.init(4096, &Routes, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .tls = &tls,
        // .ASYNC (thread per connection) is the WebSocket-over-TLS path: the connection thread runs
        // the inline frame loop. .EPOLL / .URING terminate TLS multiplexed (request / response only).
        .dispatch_model = .ASYNC,
    });
    defer server.deinit();

    try server.run();
}
