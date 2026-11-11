//! ZIX example grpc multi server
//!
//! ### file: examples/grpc_multi_server.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! gRPC h2c server with two services on one router and one port:
//! helloworld.Greeter/SayHello and location.Location/SendLocationAndSave.
//!
//! ### note:
//!
//! Proto schemas: examples/protobuf/helloworld.proto and
//! examples/protobuf/location.proto.
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

// --------------------------------------------------------- //

const IP:[]const u8 = "127.0.0.1";
const PORT:u16 = 9042;
const WORKERS:usize = 0;
const DISPATCH_MODEL:zix.Grpc.DispatchModel = .ASYNC;

const CONTENT_TYPE:[]const u8 = "application/grpc+proto";

// --------------------------------------------------------- //

// grpcurl usage:
// grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//   -d '{"name":"world"}' 127.0.0.1:9042 helloworld.Greeter/SayHello
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

// grpcurl usage:
// grpcurl -proto examples/protobuf/location.proto -plaintext \
//   -d '{"long":106.8,"lat":-6.2,"message":"good"}' \
//   127.0.0.1:9042 location.Location/SendLocationAndSave
fn sendLocationAndSave(
    req: *zix.Grpc.Request,
    res: *zix.Grpc.Response,
    _: *zix.Grpc.Context,
) !void {
    const msg = req.recvMessage() orelse {
        try res.finish(.INVALID_ARGUMENT, "empty request");
        return;
    };

    // LocationReq fields: 1 - long (double), 2 - lat (double), 3 - message (string)
    var longitude: f64 = 0;
    var latitude: f64 = 0;
    var message: []const u8 = "";
    var reader = zix.Grpc.MessageReader.init(msg);
    while (true) {
        const field = reader.next() catch {
            try res.finish(.INVALID_ARGUMENT, "malformed request");
            return;
        } orelse break;

        switch (field.field_number) {
            1 => if (field.payload.len == 8) {
                longitude = zix.Grpc.decodeDouble(field.payload[0..8]);
            },
            2 => if (field.payload.len == 8) {
                latitude = zix.Grpc.decodeDouble(field.payload[0..8]);
            },
            3 => message = field.payload,
            else => {},
        }
    }

    std.debug.print(
        "recv location: long={d:.4} lat={d:.4} msg=\"{s}\"\n",
        .{
            longitude,
            latitude,
            message,
        },
    );

    // LocationResp fields: 1 - message (string), 2 - ok (bool)
    var resp_buf: [128]u8 = undefined;
    var resp_len: usize = 0;
    resp_len += try zix.Grpc.encodeString(1, "saved", resp_buf[resp_len..]);
    resp_len += try zix.Grpc.encodeInt32(2, 1, resp_buf[resp_len..]);

    try res.sendMessage(CONTENT_TYPE, resp_buf[0..resp_len]);
    try res.finish(.OK, "");
}

// --------------------------------------------------------- //

const Routes = zix.Grpc.Router(&[_]zix.Grpc.Route{
    .{
        .path = "/helloworld.Greeter/SayHello",
        .handler = sayHelloHandler,
    },
    .{
        .path = "/location.Location/SendLocationAndSave",
        .handler = sendLocationAndSave,
    },
});

pub fn main(init: std.process.Init) !void {
    var logger = try zix.Logger.init(std.heap.smp_allocator, .{
        .console = .ALWAYS,
        .console_min_level = .INFO,
    });
    defer {
        logger.flush();
        logger.deinit();
    }

    var server = zix.Grpc.Server.init(Routes, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .dispatch_model = DISPATCH_MODEL,
        .logger = &logger,
    });
    defer server.deinit();

    try server.run();
}

