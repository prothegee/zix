const std = @import("std");
const zix = @import("zix");

// https/1.1 over TLS on the zix.Http (arena) engine. The server serves cleartext by default;
// attaching a Tls.Context (config.tls) opts into the gated TLS path (zix.Tls), leaving the cleartext
// engine untouched. Each connection is handed to its own worker thread for the handshake and the
// keep-alive request loop. The router response is captured and encrypted, so handlers write a normal
// Response. Buffered responses only (SSE / streaming and WebSocket are not served over TLS yet).

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9071;
// Demo fixtures. For a real domain, point CERT / KEY at your certbot files:
// CERT: /etc/letsencrypt/live/sub.domain.tld/fullchain.pem
// KEY: /etc/letsencrypt/live/sub.domain.tld/privkey.pem
const CERT: []const u8 = "examples/tls/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/tls/certs/ecdsa_p256_key.pem";

// HSTS max-age in SECONDS (RFC 6797). 1 year, well above the common 180-day minimum.
const HSTS_MAX_AGE_S: u32 = 31536000;

// --------------------------------------------------------- //

fn rootHandler(req: *zix.Http.Request, res: *zix.Http.Response, _: *zix.Http.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try res.send("method not allowed");

        return;
    }

    res.setContentType(.TEXT_PLAIN);
    try res.addHeader("Strict-Transport-Security", std.fmt.comptimePrint("max-age={d}; includeSubDomains", .{HSTS_MAX_AGE_S}));
    try res.send("hello over tls 1.3 (http engine)\n");
}

const Routes = [_]zix.Http.Route{
    .{ .path = "/", .handler = rootHandler },
};

pub fn main(process: std.process.Init) !void {
    var tls = try zix.Tls.Context.init(std.heap.smp_allocator, process.io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.HTTP_1_1},
        .hsts_max_age_s = HSTS_MAX_AGE_S,
    });
    defer tls.deinit();

    var server = zix.Http.Server.init(&Routes, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .tls = &tls,
        // .EPOLL / .URING terminate TLS in the event-driven epoll-mux worker (keep-alive, many
        // connections per worker); .ASYNC / .POOL / .MIXED use the thread-per-connection path.
        .dispatch_model = .EPOLL,
        .workers = 1,
    });
    defer server.deinit();

    try server.run();
}
