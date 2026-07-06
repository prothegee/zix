const std = @import("std");
const zix = @import("zix");

// HTTP/2 over TLS (h2, RFC 7540 + 8446). The Http2 server serves h2c by default; attaching a
// Tls.Context (config.tls) opts into the gated TLS path (zix.Tls): the handshake negotiates ALPN
// h2, then a terminator runs the unchanged h2c engine over the decrypted stream. The cleartext
// dispatch models stay untouched, https is on its own perf band.

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9061;
// Demo fixtures. For a real domain, point CERT / KEY at your certbot files:
// CERT: /etc/letsencrypt/live/sub.domain.tld/fullchain.pem
// KEY: /etc/letsencrypt/live/sub.domain.tld/privkey.pem
const CERT: []const u8 = "examples/tls/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/tls/certs/ecdsa_p256_key.pem";

// --------------------------------------------------------- //

fn handler(_: []const u8, _: []const zix.Http2.Header, _: []const u8, fd: std.posix.fd_t, sid: u31) void {
    zix.Http2.sendResponseFD(fd, sid, 200, "text/plain", "hello over h2 tls 1.3\n") catch {};
}

const Routes = [_]zix.Http2.Route{
    .{ .path = "/", .handler = handler },
};

pub fn main(process: std.process.Init) !void {
    var tls = try zix.Tls.Context.init(std.heap.smp_allocator, process.io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.H2},
    });
    defer tls.deinit();

    var server = zix.Http2.Server.init(&Routes, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .tls = &tls,
        .dispatch_model = .EPOLL,
    });
    defer server.deinit();

    try server.run();
}
