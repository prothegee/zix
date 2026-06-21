//! gRPC h2c server example: EPOLL dispatch model. Linux-only.
//! Port: 9035
//!
//! EPOLL for gRPC uses a single epoll event loop to accept connections and
//! hands each fd to a worker pool. Workers run the full gRPC connection loop
//! (HTTP/2 is stateful: HPACK table, stream state, flow control), so idle
//! keep-alive connections still hold a thread. The benefit over POOL is a
//! single-threaded accept loop rather than N accept threads.
//! Use POOL or ASYNC on non-Linux platforms.
//!
//! Run:
//! zig build example-grpc_server_4_epoll
//! ./zig-out/bin/example-grpc_server_4_epoll
//!
//! Test with grpcurl (requires grpcurl installed):
//! grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//! -d '{"name":"world"}' 127.0.0.1:9035 helloworld.Greeter/SayHello
//!
//! Benchmark with h2load (requires nghttp2):
//! h2load -n 999999 -c 256 -t 4 -D 10 \
//!   --header 'content-type: application/grpc+proto' \
//!   --header 'te: trailers' \
//!   --data examples/grpc_hello_req.bin \
//!   http://127.0.0.1:9035/helloworld.Greeter/SayHello
//!
//! Benchmark with ghz (requires ghz):
//! ghz --insecure \
//!   --proto examples/protobuf/helloworld.proto \
//!   --call helloworld.Greeter/SayHello \
//!   -d '{"name":"world"}' -c 64 -z 10s \
//!   127.0.0.1:9035

const std = @import("std");
const zix = @import("zix");

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

fn echoHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;
    while (ctx.recvMessage()) |msg| {
        ctx.sendMessage("application/grpc+proto", msg);
    }

    ctx.finish(zix.Grpc.Status.OK, "");
}

const Routes = [_]zix.Grpc.Route{
    .{ .path = "/helloworld.Greeter/SayHello", .handler = sayHelloHandler },
    .{ .path = "/helloworld.Greeter/Echo", .handler = echoHandler, .is_server_streaming = true },
};

pub fn main(process: std.process.Init) !void {
    var server = try zix.Grpc.Server.init(
        &Routes,
        .{
            .io = process.io,
            .ip = "127.0.0.1",
            .port = 9035,
            .dispatch_model = .EPOLL,
            .pool_size = 0,
        },
    );
    defer server.deinit();

    try server.run();
}
