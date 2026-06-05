//! gRPC h2c multi-service client example.
//! Calls two services on the same server (port 10102), one connection.
//!
//! Run (grpc_multi_server must be running on port 10102):
//! zig build example-grpc_multi_client
//! ./zig-out/bin/example-grpc_multi_client

const std = @import("std");
const zix = @import("zix");

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    std.debug.print("connecting to multi-service server at 127.0.0.1:10102\n", .{});

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = 10102 }, io);
    defer client.deinit();

    std.debug.print("connected\n", .{});

    // helloworld.Greeter / SayHello
    {
        var req: [64]u8 = undefined;
        var pos: usize = 0;
        pos += zix.Grpc.encodeString(1, "world", req[pos..]);

        var buf: [256]u8 = undefined;
        const resp = client.unary(
            "/helloworld.Greeter/SayHello",
            "application/grpc+proto",
            req[0..pos],
            &buf,
        ) catch |e| {
            std.debug.print("SayHello error: {}\n", .{e});
            return;
        };

        var message: []const u8 = "";
        var reader = zix.Grpc.MessageReader.init(resp);
        while (reader.next() catch null) |field| {
            if (field.field_number == 1) message = field.payload;
        }

        std.debug.print("SayHello response: \"{s}\"\n", .{message});
    }

    // location.Location / SendLocationAndSave
    {
        var req: [256]u8 = undefined;
        var pos: usize = 0;
        pos += zix.Grpc.encodeDouble(1, 106.8, req[pos..]);
        pos += zix.Grpc.encodeDouble(2, -6.2, req[pos..]);
        pos += zix.Grpc.encodeString(3, "good", req[pos..]);

        var buf: [256]u8 = undefined;
        const resp = client.unary(
            "/location.Location/SendLocationAndSave",
            "application/grpc+proto",
            req[0..pos],
            &buf,
        ) catch |e| {
            std.debug.print("SendLocationAndSave error: {}\n", .{e});
            return;
        };

        var message: []const u8 = "";
        var ok: bool = false;
        var reader = zix.Grpc.MessageReader.init(resp);
        while (reader.next() catch null) |field| {
            switch (field.field_number) {
                1 => message = field.payload,
                2 => ok = field.value_u64 != 0,
                else => {},
            }
        }

        std.debug.print("SendLocationAndSave response: message=\"{s}\" ok={}\n", .{ message, ok });
    }
}
