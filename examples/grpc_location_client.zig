//! gRPC h2c location client example.
//! Sends a SendLocationAndSave request to the location server on port 9038.
//!
//! Proto schema: examples/protobuf/location.proto
//! message LocationReq  { double long = 1; double lat = 2; string message = 3; }
//! message LocationResp { string message = 1; bool ok = 2; }
//!
//! Run (server must be running on port 9038):
//! zig build example-grpc_location_client
//! ./zig-out/bin/example-grpc_location_client

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    std.debug.print("connecting to location server at 127.0.0.1:9038\n", .{});

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = 9038 }, io);
    defer client.deinit();

    std.debug.print("connected\n", .{});

    // Encode LocationReq: long=106.8 (field 1), lat=-6.2 (field 2), message="good" (field 3)
    var req: [256]u8 = undefined;
    var pos: usize = 0;
    pos += zix.Grpc.encodeDouble(1, 106.8, req[pos..]);
    pos += zix.Grpc.encodeDouble(2, -6.2, req[pos..]);
    pos += zix.Grpc.encodeString(3, "good", req[pos..]);

    var buf: [512]u8 = undefined;
    const resp = client.unary(
        "/location.Location/SendLocationAndSave",
        "application/grpc+proto",
        req[0..pos],
        &buf,
    ) catch |e| {
        std.debug.print("rpc error: {}\n", .{e});
        return;
    };

    // Decode LocationResp: message (field 1), ok/bool (field 2)
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

    std.debug.print("response: message=\"{s}\" ok={}\n", .{ message, ok });
}
