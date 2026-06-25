const std = @import("std");
const zix = @import("zix");

// gRPC over TLS (grpc, RFC 8446 + 7540). The Grpc server serves h2c by default; attaching a
// Tls.Context (config.tls) opts into the gated TLS path (zix.Tls): the handshake negotiates ALPN
// h2, then the unchanged gRPC h2 mux runs over the decrypted stream. For the event-loop models
// (EPOLL / URING) one epoll worker per core terminates TLS in place and multiplexes many
// connections, so high concurrency does not spawn a thread per connection.

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9070;
const CERT: []const u8 = "examples/tls/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/tls/certs/ecdsa_p256_key.pem";

// --------------------------------------------------------- //

fn sayHelloHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;
    const msg = ctx.recvMessage() orelse {
        ctx.finish(zix.Grpc.Status.INVALID_ARGUMENT, "empty request");
        return;
    };

    var out: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&out, "Hello, {s}!", .{msg}) catch "Hello!";

    ctx.sendMessage("application/grpc+proto", resp);
    ctx.finish(zix.Grpc.Status.OK, "");
}

const Routes = [_]zix.Grpc.Route{
    .{ .path = "/helloworld.Greeter/SayHello", .handler = sayHelloHandler },
};

pub fn main(process: std.process.Init) !void {
    var tls = try zix.Tls.Context.init(std.heap.smp_allocator, process.io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.H2},
    });
    defer tls.deinit();

    var server = try zix.Grpc.Server.init(&Routes, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = .EPOLL,
        .tls = &tls,
    });
    defer server.deinit();

    try server.run();
}
