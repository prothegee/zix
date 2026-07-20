const std = @import("std");
const zix = @import("zix");

// Dual listener (config.tls_port): ONE server serves cleartext http/1.1 on PORT and https/1.1 on
// TLS_PORT from the same worker fleet. No second launch, no second fd table, no duplicate caches:
// the TLS side rides the same .EPOLL / .URING loop as cleartext (ADR-060). The thread models
// (.ASYNC / .POOL / .MIXED) serve the TLS side with one extra accept thread instead.

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9076;
const TLS_PORT: u16 = 9077;
// Demo fixtures. For a real domain, point CERT / KEY at your certbot files:
// CERT: /etc/letsencrypt/live/sub.domain.tld/fullchain.pem
// KEY: /etc/letsencrypt/live/sub.domain.tld/privkey.pem
const CERT: []const u8 = "examples/tls/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/tls/certs/ecdsa_p256_key.pem";

// --------------------------------------------------------- //

// curl http://localhost:9076/
// curl -k https://localhost:9077/
fn handler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const body = "hello from the dual listener\n";

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    writer.print(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    ) catch return;

    try res.sendRaw(writer.buffered());
}

pub fn main(process: std.process.Init) !void {
    var tls = try zix.Tls.Context.init(std.heap.smp_allocator, process.io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.HTTP_1_1},
    });
    defer tls.deinit();

    var server = zix.Http1.Server.init(handler, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .tls = &tls,
        .tls_port = TLS_PORT,
        .dispatch_model = .EPOLL,
        .workers = 1,
    });
    defer server.deinit();

    try server.run();
}
