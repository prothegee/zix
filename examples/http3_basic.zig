const std = @import("std");
const zix = @import("zix");

// HTTP/3 (QUIC) over the zix.Udp datagram substrate. QUIC requires TLS 1.3, so a Tls.Context
// (cert + key) is mandatory: the server rejects a null context at init. The v1 engine runs a
// single-worker recv with internal connection-id demux (ADR-049 / ADR-050), so connection
// migration needs no cross-core routing. EPOLL / URING fold to the v1 worker with a logged
// notice until per-core CID steering lands (ADR-049 phase 3).

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9063;
const CERT: []const u8 = "examples/tls/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/tls/certs/ecdsa_p256_key.pem";

// --------------------------------------------------------- //

fn handler(_: *const zix.Http3.Request, res: *zix.Http3.Response) void {
    res.setStatus(200);
    res.send("hello over http/3\n");
}

pub fn main(process: std.process.Init) !void {
    var tls = try zix.Tls.Context.init(std.heap.smp_allocator, process.io, .{
        .cert_path = CERT,
        .key_path = KEY,
    });
    defer tls.deinit();

    const Server = zix.Http3.Http3(handler);
    var server = try Server.init(.{
        .io = process.io,
        .allocator = std.heap.smp_allocator,
        .ip = IP,
        .port = PORT,
        .dispatch_model = .ASYNC,
        .tls = &tls,
    });
    defer server.deinit();

    try server.run();
}
