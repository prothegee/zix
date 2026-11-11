//! ZIX example grpc server
//!
//! ### file: examples/grpc_server.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! gRPC h2c server example with three routes: SayHello (unary), Echo
//! (server-streaming), and StreamSum (server-streaming).
//!
//! ### note:
//!
//! A large StreamSum count packs many reply messages into each DATA frame,
//! so it is a quick way to load the streaming path.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const zix = @import("zix");

const builtin = @import("builtin");

// --------------------------------------------------------- //

const IP:[]const u8 = "127.0.0.1";
const PORT:u16 = 9036;
const WORKERS:usize = 0;
const DISPATCH_MODEL:zix.Grpc.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;

const CONTENT_TYPE:[]const u8 = "application/grpc+proto";

// --------------------------------------------------------- //

// grpcurl usage:
// grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//   -d '{"name":"world"}' 127.0.0.1:9036 helloworld.Greeter/SayHello
fn sayHelloHandler(req: *zix.Grpc.Request, res: *zix.Grpc.Response, _: *zix.Grpc.Context) !void {
    const msg = req.recvMessage() orelse {
        try res.finish(.INVALID_ARGUMENT, "empty request");
        return;
    };

    // HelloReq fields: 1 - name (string)
    var name: []const u8 = "stranger";
    var reader = zix.Grpc.MessageReader.init(msg);
    while (true) {
        const field = reader.next() catch {
            try res.finish(.INVALID_ARGUMENT, "malformed request");
            return;
        } orelse break;

        if (field.field_number == 1) name = field.payload;
    }

    var text_buf: [256]u8 = undefined;
    const greeting = std.fmt.bufPrint(&text_buf, "Hello, {s}!", .{name}) catch "Hello!";

    // HelloResp fields: 1 - message (string)
    var resp_buf: [300]u8 = undefined;
    const resp_len = try zix.Grpc.encodeString(1, greeting, &resp_buf);

    try res.sendMessage(CONTENT_TYPE, resp_buf[0..resp_len]);
    try res.finish(.OK, "");
}

// Echoes each request message back as is.
fn echoHandler(req: *zix.Grpc.Request, res: *zix.Grpc.Response, _: *zix.Grpc.Context) !void {
    while (req.recvMessage()) |msg| {
        try res.sendMessage(CONTENT_TYPE, msg);
    }

    try res.finish(.OK, "");
}

// Reads one StreamRequest { a, b, count }, then sends `count` SumReply
// messages carrying a + b + i.
//
// ghz usage:
// ghz --insecure --proto examples/protobuf/benchmark.proto \
//   --call benchmark.BenchmarkService/StreamSum \
//   -d '{"a":1,"b":2,"count":5000}' --connections 8 -c 32 -z 6s \
//   127.0.0.1:9036
fn streamSumHandler(
    req: *zix.Grpc.Request,
    res: *zix.Grpc.Response,
    _: *zix.Grpc.Context,
) !void {
    const msg = req.recvMessage() orelse {
        try res.finish(.INVALID_ARGUMENT, "empty request");
        return;
    };

    var num_a: i32 = 0;
    var num_b: i32 = 0;
    var count: i32 = 1;
    var reader = zix.Grpc.MessageReader.init(msg);
    while (true) {
        const field = reader.next() catch {
            try res.finish(.INVALID_ARGUMENT, "malformed request");
            return;
        } orelse break;

        const value: i32 = @bitCast(@as(u32, @truncate(field.value_u64)));
        switch (field.field_number) {
            1 => num_a = value,
            2 => num_b = value,
            3 => count = value,
            else => {},
        }
    }

    if (count <= 0) count = 1;

    const sum = num_a +% num_b;
    var reply_buf: [16]u8 = undefined;

    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const reply_len = try zix.Grpc.encodeInt32(1, sum +% i, &reply_buf);
        try res.sendMessage(CONTENT_TYPE, reply_buf[0..reply_len]);
    }

    try res.finish(.OK, "");
}

// --------------------------------------------------------- //

const Routes = zix.Grpc.Router(&[_]zix.Grpc.Route{
    .{
        .path = "/helloworld.Greeter/SayHello",
        .handler = sayHelloHandler,
    },
    .{
        .path = "/helloworld.Greeter/Echo",
        .handler = echoHandler,
        .is_server_streaming = true,
    },
    .{
        .path = "/benchmark.BenchmarkService/StreamSum",
        .handler = streamSumHandler,
        .is_server_streaming = true,
    },
});

pub fn main(init: std.process.Init) !void {
    var server = zix.Grpc.Server.init(Routes, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .dispatch_model = DISPATCH_MODEL,
    });
    defer server.deinit();

    try server.run();
}

