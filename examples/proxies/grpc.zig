//! grpc.zig: the upstream behind the zixer grpc proxy demo. Port: 9109
//!
//! A gRPC server on h2c. The edge in front of it relays h2 frames to h2, never
//! an http1 hop, because a gRPC reply carries its status in the trailing
//! header block and http1 has nowhere to put it.
//!
//! Two routes, both with a proto file already in the repository:
//! - helloworld.Greeter/SayHello: unary, one reply then the trailers.
//! - benchmark.BenchmarkService/StreamSum: server-streaming, `count` replies
//!   before the trailers, so a multi-message stream crosses the relay.
//!
//! Site file: examples/proxies/sites/grpc.cfg (edge port 9108)
//!
//! Run:
//! zig build zixer-example-grpc
//! ./zig-out/bin/zixer-example-grpc-<arch>-<os>-<optimize>
//!
//! Through the proxy, with grpcurl:
//! grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//!     -d '{"name":"world"}' 127.0.0.1:9108 helloworld.Greeter/SayHello
//! grpcurl -proto examples/protobuf/benchmark.proto -plaintext \
//!     -d '{"a":1,"b":2,"count":3}' 127.0.0.1:9108 benchmark.BenchmarkService/StreamSum

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9109;
const DISPATCH_MODEL: zix.Grpc.DispatchModel = .ASYNC;

/// Longest reply this demo builds, protobuf framing included.
const REPLY_MAX: usize = 256;
/// Ceiling on StreamSum replies, so one request cannot ask for an endless stream.
const STREAM_COUNT_MAX: i32 = 1000;

// --------------------------------------------------------- //

/// The string in field `field_number` of a protobuf message, or null when the
/// message does not carry it.
fn stringField(message: []const u8, field_number: u32) ?[]const u8 {
    var reader = zix.Grpc.MessageReader.init(message);
    while (reader.next() catch null) |field| {
        if (field.field_number == field_number and field.wire_type == zix.Grpc.WT_LEN) return field.payload;
    }

    return null;
}

/// Unary SayHello: read HelloReq.name, answer HelloResp.message, then OK in
/// the trailers.
fn sayHelloHandler(req: *zix.Grpc.Request, res: *zix.Grpc.Response, _: *zix.Grpc.Context) !void {
    const message = req.recvMessage() orelse {
        try res.finish(zix.Grpc.Status.INVALID_ARGUMENT, "empty request");
        return;
    };

    const name = stringField(message, 1) orelse {
        try res.finish(zix.Grpc.Status.INVALID_ARGUMENT, "HelloReq.name is missing");
        return;
    };

    var text_buf: [REPLY_MAX]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "Hello, {s}! (from proxies/grpc on {s}:{d})", .{ name, IP, PORT }) catch "Hello!";

    var reply_buf: [REPLY_MAX]u8 = undefined;
    const reply_len = zix.Grpc.encodeString(1, text, &reply_buf);

    try res.sendMessage("application/grpc+proto", reply_buf[0..reply_len]);
    try res.finish(zix.Grpc.Status.OK, "");
}

/// Server-streaming StreamSum: read StreamRequest{a, b, count}, emit `count`
/// SumReply messages carrying a + b + i, then OK in the trailers. Several
/// messages ahead of the trailing block is what an http1 hop could not carry.
fn streamSumHandler(req: *zix.Grpc.Request, res: *zix.Grpc.Response, _: *zix.Grpc.Context) !void {
    const message = req.recvMessage() orelse {
        try res.finish(zix.Grpc.Status.INVALID_ARGUMENT, "empty request");
        return;
    };

    var first: i32 = 0;
    var second: i32 = 0;
    var count: i32 = 1;

    var reader = zix.Grpc.MessageReader.init(message);
    while (reader.next() catch null) |field| {
        switch (field.field_number) {
            1 => first = @bitCast(@as(u32, @truncate(field.value_u64))),
            2 => second = @bitCast(@as(u32, @truncate(field.value_u64))),
            3 => count = @bitCast(@as(u32, @truncate(field.value_u64))),
            else => {},
        }
    }

    if (count <= 0) count = 1;
    if (count > STREAM_COUNT_MAX) count = STREAM_COUNT_MAX;

    const sum = first + second;
    var reply_buf: [REPLY_MAX]u8 = undefined;

    var sent: i32 = 0;
    while (sent < count) : (sent += 1) {
        const reply_len = zix.Grpc.encodeInt32(1, sum + sent, &reply_buf);
        try res.sendMessage("application/grpc+proto", reply_buf[0..reply_len]);
    }

    try res.finish(zix.Grpc.Status.OK, "");
}

// --------------------------------------------------------- //

const Routes = [_]zix.Grpc.Route{
    .{ .path = "/helloworld.Greeter/SayHello", .handler = sayHelloHandler },
    .{ .path = "/benchmark.BenchmarkService/StreamSum", .handler = streamSumHandler, .is_server_streaming = true },
};

pub fn main(process: std.process.Init) !void {
    var server = zix.Grpc.Server.init(zix.Grpc.Router(&Routes), .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
    });
    defer server.deinit();

    try server.run();
}
