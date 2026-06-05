//! gRPC h2c location service: EPOLL dispatch model. Linux-only.
//! Service: location.Location / SendLocationAndSave
//! Port: 10101
//!
//! EPOLL uses a single epoll accept loop to accept connections and hands each
//! fd to a worker pool. Workers hold the full gRPC connection lifetime (HTTP/2
//! is stateful: HPACK table, stream state, flow control). On non-Linux targets
//! the server falls back to .POOL automatically.
//!
//! Proto schema: examples/protobuf/location.proto
//! message LocationReq  { double long = 1; double lat = 2; string message = 3; }
//! message LocationResp { string message = 1; bool ok = 2; }
//!
//! Run:
//! zig build example-grpc_location_server_4_epoll
//! ./zig-out/bin/example-grpc_location_server_4_epoll
//!
//! Test with the location client:
//! ./zig-out/bin/example-grpc_location_client

const std = @import("std");
const zix = @import("zix");

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

pub fn main(process: std.process.Init) !void {
    var server = try zix.Grpc.Server.init(
        &[_]zix.Grpc.Route{
            .{ .path = "/location.Location/SendLocationAndSave", .handler = sendLocationAndSave },
        },
        .{
            .io = process.io,
            .ip = "127.0.0.1",
            .port = 10101,
            .dispatch_model = .EPOLL,
            .pool_size = 0,
        },
    );
    defer server.deinit();

    try server.run();
}
