const std = @import("std");
const zix = @import("zix");

// https/1.1 over TLS. The Http1 server serves cleartext by default; attaching a Tls.Context
// (config.tls) opts into the gated TLS path (zix.Tls), on its own perf band, leaving the
// cleartext EPOLL / URING engine untouched. The context carries the cert / key / alpn / version
// / curve / cipher / HSTS policy, loaded and validated once at startup.

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9060;
// Demo fixtures. For a real domain, point CERT / KEY at your certbot files:
// CERT: /etc/letsencrypt/live/sub.domain.tld/fullchain.pem
// KEY: /etc/letsencrypt/live/sub.domain.tld/privkey.pem
const CERT: []const u8 = "examples/tls/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/tls/certs/ecdsa_p256_key.pem";

// HSTS max-age in SECONDS (RFC 6797). 1 year, well above the common 180-day minimum.
const HSTS_MAX_AGE_S: u32 = 31536000;

// --------------------------------------------------------- //

fn handler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const body = "hello over tls 1.3\n";

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    writer.print(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nStrict-Transport-Security: max-age={d}; includeSubDomains\r\n\r\n{s}",
        .{ body.len, HSTS_MAX_AGE_S, body },
    ) catch return;

    try res.sendRaw(writer.buffered());
}

pub fn main(process: std.process.Init) !void {
    var tls = try zix.Tls.Context.init(std.heap.smp_allocator, process.io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.HTTP_1_1},
        .hsts_max_age_s = HSTS_MAX_AGE_S,
    });
    defer tls.deinit();

    var server = zix.Http1.Server.init(handler, .{
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
