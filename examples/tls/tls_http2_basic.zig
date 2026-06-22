const std = @import("std");
const zix = @import("zix");

// HTTP/2 over TLS 1.3 (h2, RFC 7540 + 8446). The Http2 server serves h2c by default, setting
// tls_cert_path / tls_key_path opts into the gated TLS path (zix.Tls): the handshake negotiates
// ALPN h2, then a terminator runs the unchanged h2c engine over the decrypted stream. The
// cleartext dispatch models stay untouched, https is on its own perf band.

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9061;
const CERT: []const u8 = "examples/tls/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/tls/certs/ecdsa_p256_key.pem";

// --------------------------------------------------------- //

fn handler(_: []const u8, _: []const zix.Http2.Header, _: []const u8, fd: std.posix.fd_t, sid: u31) void {
    zix.Http2.sendResponse(fd, sid, 200, "text/plain", "hello over h2 tls 1.3\n") catch {};
}

pub fn main(process: std.process.Init) !void {
    var server = try zix.Http2.Server.init(&[_]zix.Http2.Route{
        .{ .path = "/", .handler = handler },
    }, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .tls_cert_path = CERT,
        .tls_key_path = KEY,
        .tls_alpn = &.{.H2},
    });
    defer server.deinit();

    try server.run();
}
