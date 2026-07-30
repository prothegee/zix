//! gRPC h2c server example. Port: 9032
//!
//! The dispatch model is picked per target at comptime (ADR-065): .URING on Linux,
//! .ASYNC everywhere else. .EPOLL and .URING are Linux-only, and run() returns
//! error.DispatchModelUnsupported rather than silently serving a different model.
//!
//! .URING for gRPC runs a shared-nothing io_uring ring per worker: one
//! SO_REUSEPORT listener and one completion loop per worker thread, each
//! multiplexing many connections through the resumable HTTP/2 state machine
//! (HPACK table, stream state, flow control) and sending one coalesced reply
//! per readable batch. .ASYNC dispatches each connection through io.async().
//!
//! Three routes:
//! - SayHello: unary, one reply.
//! - Echo: server-streaming, echoes each request message back.
//! - StreamSum: server-streaming, emits `count` replies of a + b + i. A large count exercises
//!   DATA-frame coalescing: consecutive messages pack into fewer h2 DATA frames instead of one tiny
//!   frame per message, cutting frame-header overhead and client-side frame parses.
//!
//! Run:
//! zig build example-grpc_server
//! ./zig-out/bin/example-grpc_server
//!
//! Test with grpcurl (requires grpcurl installed):
//! grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//! -d '{"name":"world"}' 127.0.0.1:9032 helloworld.Greeter/SayHello
//!
//! Benchmark the server-streaming path with ghz (requires ghz) against the HttpArena benchmark
//! proto, which defines StreamSum(a, b, count) -> stream of sums:
//! ghz --insecure \
//!   --proto examples/protobuf/benchmark.proto \
//!   --call benchmark.BenchmarkService/StreamSum \
//!   -d '{"a":1,"b":2,"count":5000}' --connections 8 -c 32 -z 6s \
//!   127.0.0.1:9032

const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

const DISPATCH_MODEL: zix.Grpc.DispatchModel = if (builtin.os.tag == .linux) .URING else .ASYNC;

fn sayHelloHandler(req: *zix.Grpc.Request, res: *zix.Grpc.Response, ctx: *zix.Grpc.Context) !void {
    _ = ctx;
    const msg = req.recvMessage() orelse {
        res.finish(zix.Grpc.Status.INVALID_ARGUMENT, "empty request");
        return;
    };

    var out: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&out, "Hello, {s}!", .{msg}) catch "Hello!";

    res.sendMessage("application/grpc+proto", resp);
    res.finish(zix.Grpc.Status.OK, "");
}

fn echoHandler(req: *zix.Grpc.Request, res: *zix.Grpc.Response, ctx: *zix.Grpc.Context) !void {
    _ = ctx;
    while (req.recvMessage()) |msg| {
        res.sendMessage("application/grpc+proto", msg);
    }

    res.finish(zix.Grpc.Status.OK, "");
}

/// Server-streaming StreamSum: read one SumRequest{a, b, count}, then emit `count` reply messages
/// carrying a + b + i. A large `count` exercises the streaming path's DATA-frame coalescing, which
/// packs many messages into each h2 DATA frame instead of one frame per message.
fn streamSumHandler(req: *zix.Grpc.Request, res: *zix.Grpc.Response, ctx: *zix.Grpc.Context) !void {
    _ = ctx;
    const msg = req.recvMessage() orelse {
        res.finish(zix.Grpc.Status.INVALID_ARGUMENT, "empty request");
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
        res.sendMessage("application/grpc+proto", reply_buf[0..reply_len]);
    }

    res.finish(zix.Grpc.Status.OK, "");
}

const Routes = [_]zix.Grpc.Route{
    .{ .path = "/helloworld.Greeter/SayHello", .handler = sayHelloHandler },
    .{ .path = "/helloworld.Greeter/Echo", .handler = echoHandler, .is_server_streaming = true },
    .{ .path = "/benchmark.BenchmarkService/StreamSum", .handler = streamSumHandler, .is_server_streaming = true },
};

pub fn main(process: std.process.Init) !void {
    var server = zix.Grpc.Server.init(
        zix.Grpc.Router(&Routes),
        .{
            .io = process.io,
            .ip = "127.0.0.1",
            .port = 9032,
            .dispatch_model = DISPATCH_MODEL,
        },
    );
    defer server.deinit();

    try server.run();
}
