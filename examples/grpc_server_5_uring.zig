//! gRPC h2c server example: URING dispatch model (io_uring). Linux-only.
//! Port: 9115
//!
//! URING for gRPC runs a shared-nothing io_uring ring per worker: one
//! SO_REUSEPORT listener and one completion loop per worker thread, each
//! multiplexing many connections through the resumable HTTP/2 state machine
//! (HPACK table, stream state, flow control) and sending one coalesced reply
//! per readable batch. Falls back to POOL on non-Linux platforms.
//!
//! Run:
//! zig build example-grpc_server_5_uring
//! ./zig-out/bin/example-grpc_server_5_uring
//!
//! Test with grpcurl (requires grpcurl installed):
//! grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//! -d '{"name":"world"}' 127.0.0.1:9115 helloworld.Greeter/SayHello
//!
//! Benchmark with ghz (requires ghz):
//! ghz --insecure \
//!   --proto examples/protobuf/helloworld.proto \
//!   --call helloworld.Greeter/SayHello \
//!   -d '{"name":"world"}' -c 64 -z 10s \
//!   127.0.0.1:9115

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
            .port = 9115,
            .dispatch_model = .URING,
            .pool_size = 0,
        },
    );
    defer server.deinit();

    try server.run();
}
