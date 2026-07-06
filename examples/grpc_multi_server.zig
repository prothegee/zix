//! gRPC h2c multi-service server example: ASYNC dispatch model.
//! One server, one port, two services: each method has its own handler.
//! Port: 9042
//!
//! Services:
//! helloworld.Greeter / SayHello            (examples/protobuf/helloworld.proto)
//! location.Location  / SendLocationAndSave (examples/protobuf/location.proto)
//!
//! Run:
//! zig build example-grpc_multi_server
//! ./zig-out/bin/example-grpc_multi_server
//!
//! Test with the multi client:
//! ./zig-out/bin/example-grpc_multi_client
//!
//! Test with grpcurl (requires grpcurl installed):
//! grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//! -d '{"name":"world"}' localhost:9042 helloworld.Greeter/SayHello
//!
//! grpcurl -proto examples/protobuf/location.proto -plaintext \
//! -d '{"long":106.8,"lat":-6.2,"message":"good"}' \
//! localhost:9042 location.Location/SendLocationAndSave

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

fn sayHelloHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;

    const msg = ctx.recvMessage() orelse {
        ctx.finish(zix.Grpc.Status.INVALID_ARGUMENT, "empty request");
        return;
    };

    var name: []const u8 = "stranger";
    var reader = zix.Grpc.MessageReader.init(msg);
    while (reader.next() catch null) |field| {
        if (field.field_number == 1) name = field.payload;
    }

    var out: [256]u8 = undefined;
    const greeting = std.fmt.bufPrint(&out, "Hello, {s}!", .{name}) catch "Hello!";

    var resp: [128]u8 = undefined;
    var rpos: usize = 0;
    rpos += zix.Grpc.encodeString(1, greeting, resp[rpos..]);

    ctx.sendMessage("application/grpc+proto", resp[0..rpos]);
    ctx.finish(zix.Grpc.Status.OK, "");
}

fn sendLocationAndSave(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;

    const msg = ctx.recvMessage() orelse {
        ctx.finish(zix.Grpc.Status.INVALID_ARGUMENT, "empty request");
        return;
    };

    var lon: f64 = 0;
    var lat: f64 = 0;
    var message: []const u8 = "";

    var reader = zix.Grpc.MessageReader.init(msg);
    while (reader.next() catch null) |field| {
        switch (field.field_number) {
            1 => if (field.payload.len == 8) {
                lon = zix.Grpc.decodeDouble(field.payload[0..8]);
            },
            2 => if (field.payload.len == 8) {
                lat = zix.Grpc.decodeDouble(field.payload[0..8]);
            },
            3 => message = field.payload,
            else => {},
        }
    }

    std.debug.print("recv location: long={d:.4} lat={d:.4} msg=\"{s}\"\n", .{ lon, lat, message });

    var resp: [128]u8 = undefined;
    var rpos: usize = 0;
    rpos += zix.Grpc.encodeString(1, "saved", resp[rpos..]);
    rpos += zix.Grpc.encodeInt32(2, 1, resp[rpos..]);

    ctx.sendMessage("application/grpc+proto", resp[0..rpos]);
    ctx.finish(zix.Grpc.Status.OK, "");
}

// --------------------------------------------------------- //

const Routes = [_]zix.Grpc.Route{
    .{ .path = "/helloworld.Greeter/SayHello", .handler = sayHelloHandler },
    .{ .path = "/location.Location/SendLocationAndSave", .handler = sendLocationAndSave },
};

pub fn main(process: std.process.Init) !void {
    var logger = try zix.Logger.init(std.heap.smp_allocator, .{
        .console = .ALWAYS,
        .console_min_level = .INFO,
    });
    defer logger.deinit();

    var server = zix.Grpc.Server.init(
        &Routes,
        .{
            .io = process.io,
            .ip = "127.0.0.1",
            .port = 9042,
            .dispatch_model = .ASYNC,
            .logger = &logger,
        },
    );
    defer server.deinit();

    try server.run();
}
