const std = @import("std");
const zix = @import("zix");

// https/1.1 over TLS 1.3 with an Ed25519 server certificate (RFC 8410 / 8446 4.4.3, scheme
// ed25519 = 0x0807). Same gated TLS path as tls_http1_basic, but the cert + key are Ed25519:
// the engine detects the key type from the certificate and signs CertificateVerify accordingly.
// Ed25519 is TLS 1.3 only here (the 1.2 ServerKeyExchange path is ECDSA-signed).

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9062;
const CERT: []const u8 = "examples/tls/certs/ed25519_cert.pem";
const KEY: []const u8 = "examples/tls/certs/ed25519_key.pem";

// HSTS max-age in SECONDS (RFC 6797). 1 year, well above the common 180-day minimum.
const HSTS_MAX_AGE_S: u32 = 31536000;

// --------------------------------------------------------- //

fn handler(_: *const zix.Http1.ParsedHead, _: []const u8, fd: std.posix.fd_t) void {
    const body = "hello over tls 1.3 (ed25519)\n";

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
