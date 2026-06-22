const std = @import("std");
const zix = @import("zix");

// https/1.1 over TLS 1.3. The Http1 server serves cleartext by default, setting
// tls_cert_path / tls_key_path opts into the gated TLS path (zix.Tls), on its own
// perf band, leaving the cleartext EPOLL / URING engine untouched.

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9060;
const CERT: []const u8 = "examples/tls/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/tls/certs/ecdsa_p256_key.pem";

// HSTS max-age in SECONDS (RFC 6797). 1 year, above the SSL Labs A+ minimum of 180 days.
const HSTS_MAX_AGE_S: u32 = 31536000;

// --------------------------------------------------------- //

fn handler(_: *const zix.Http1.ParsedHead, _: []const u8, fd: std.posix.fd_t) void {
    const body = "hello over tls 1.3\n";

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nStrict-Transport-Security: max-age={d}; includeSubDomains\r\n\r\n{s}",
        .{ body.len, HSTS_MAX_AGE_S, body },
    ) catch return;

    zix.Http1.fdWriteAll(fd, w.buffered()) catch {};
}

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(handler, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .tls_cert_path = CERT,
        .tls_key_path = KEY,
        .tls_alpn = &.{.HTTP_1_1},
        .hsts_max_age_s = HSTS_MAX_AGE_S,
    });
    defer server.deinit();

    try server.run();
}
