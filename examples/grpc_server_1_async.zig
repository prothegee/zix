//! gRPC h2c server example: ASYNC dispatch model.
//! Demonstrates unary and streaming RPC patterns.
//! Port: 8083
//!
//! Run:
//! zig build example-grpc_server_1_async
//! ./zig-out/bin/example-grpc_server_1_async
//!
//! Test with the gRPC client:
//! ./zig-out/bin/example-grpc_client
//!
//! Test with grpcurl (requires grpcurl installed):
//! grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//! -d '{"name":"world"}' 127.0.0.1:8083 helloworld.Greeter/SayHello

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

pub fn main(process: std.process.Init) !void {
    var server = try zix.Grpc.Server.init(
        &[_]zix.Grpc.Route{
            .{ .path = "/helloworld.Greeter/SayHello", .handler = sayHelloHandler },
            .{ .path = "/helloworld.Greeter/Echo", .handler = echoHandler },
        },
        .{
            .io = process.io,
            .ip = "127.0.0.1",
            .port = 8083,
            .dispatch_model = .ASYNC,
        },
    );
    defer server.deinit();

    try server.run();
}
