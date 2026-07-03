//! gRPC h2c server example: URING dispatch model (io_uring). Linux-only.
//! Port: 9036
//!
//! URING for gRPC runs a shared-nothing io_uring ring per worker: one
//! SO_REUSEPORT listener and one completion loop per worker thread, each
//! multiplexing many connections through the resumable HTTP/2 state machine
//! (HPACK table, stream state, flow control) and sending one coalesced reply
//! per readable batch. Falls back to POOL on non-Linux platforms.
//!
//! Three routes:
//! - SayHello: unary, one reply.
//! - Echo: server-streaming, echoes each request message back.
//! - StreamSum: server-streaming, emits `count` replies of a + b + i. A large count exercises
//!   DATA-frame coalescing: consecutive messages pack into fewer h2 DATA frames instead of one tiny
//!   frame per message, cutting frame-header overhead and client-side frame parses.
//!
//! Run:
//! zig build example-grpc_server_5_uring
//! ./zig-out/bin/example-grpc_server_5_uring
//!
//! Test with grpcurl (requires grpcurl installed):
//! grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//! -d '{"name":"world"}' 127.0.0.1:9036 helloworld.Greeter/SayHello
//!
//! Benchmark the server-streaming path with ghz (requires ghz) against the HttpArena benchmark
//! proto, which defines StreamSum(a, b, count) -> stream of sums:
//! ghz --insecure \
//!   --proto examples/protobuf/benchmark.proto \
//!   --call benchmark.BenchmarkService/StreamSum \
//!   -d '{"a":1,"b":2,"count":5000}' --connections 8 -c 32 -z 6s \
//!   127.0.0.1:9036

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

/// Server-streaming StreamSum: read one SumRequest{a, b, count}, then emit `count` reply messages
/// carrying a + b + i. A large `count` exercises the streaming path's DATA-frame coalescing, which
/// packs many messages into each h2 DATA frame instead of one frame per message.
fn streamSumHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;
    const msg = ctx.recvMessage() orelse {
        ctx.finish(zix.Grpc.Status.INVALID_ARGUMENT, "empty request");
        return;
    };

    var reader = zix.Grpc.MessageReader.init(msg);
    var req_a: i32 = 0;
    var req_b: i32 = 0;
    var req_count: i32 = 1;

    while (reader.next() catch null) |field| {
        switch (field.field_number) {
            1 => req_a = @bitCast(@as(u32, @truncate(field.value_u64))),
            2 => req_b = @bitCast(@as(u32, @truncate(field.value_u64))),
            3 => req_count = @bitCast(@as(u32, @truncate(field.value_u64))),
            else => {},
        }
    }

    if (req_count <= 0) req_count = 1;

    const sum = req_a + req_b;
    var reply_buf: [16]u8 = undefined;

    var i: i32 = 0;
    while (i < req_count) : (i += 1) {
        const reply_len = zix.Grpc.encodeInt32(1, sum + i, &reply_buf);
        ctx.sendMessage("application/grpc+proto", reply_buf[0..reply_len]);
    }

    ctx.finish(zix.Grpc.Status.OK, "");
}

const Routes = [_]zix.Grpc.Route{
    .{ .path = "/helloworld.Greeter/SayHello", .handler = sayHelloHandler },
    .{ .path = "/helloworld.Greeter/Echo", .handler = echoHandler, .is_server_streaming = true },
    .{ .path = "/benchmark.BenchmarkService/StreamSum", .handler = streamSumHandler, .is_server_streaming = true },
};

pub fn main(process: std.process.Init) !void {
    var server = try zix.Grpc.Server.init(
        &Routes,
        .{
            .io = process.io,
            .ip = "127.0.0.1",
            .port = 9036,
            .dispatch_model = .URING,
            .pool_size = 0,
        },
    );
    defer server.deinit();

    try server.run();
}
