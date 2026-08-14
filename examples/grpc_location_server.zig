//! gRPC h2c location service.
//! Service: location.Location / SendLocationAndSave
//! Port: 9038
//!
//! The dispatch model is picked per target at comptime (ADR-065): .URING on Linux,
//! .ASYNC everywhere else. .EPOLL and .URING are Linux-only, and run() returns
//! error.ZixDispatchModelUnsupported rather than silently serving a different model.
//!
//! .URING and .EPOLL are shared-nothing: one SO_REUSEPORT listener plus one ring or epoll
//! instance per worker, each multiplexing the full gRPC connection lifetime (HTTP/2 is
//! stateful: HPACK table, stream state, flow control). .ASYNC dispatches each connection
//! through io.async().
//!
//! Proto schema: examples/protobuf/location.proto
//! message LocationReq  { double long = 1; double lat = 2; string message = 3; }
//! message LocationResp { string message = 1; bool ok = 2; }
//!
//! Run:
//! zig build example-grpc_location_server
//! ./zig-out/bin/zix-example-grpc_location_server
//!
//! Test with the location client:
//! ./zig-out/bin/zix-example-grpc_location_client
//!
//! Benchmark with h2load (requires nghttp2):
//! h2load -n 999999 -c 256 -t 4 -D 10 \
//!   --header 'content-type: application/grpc+proto' \
//!   --header 'te: trailers' \
//!   --data examples/grpc_location_req.bin \
//!   http://127.0.0.1:9038/location.Location/SendLocationAndSave
//!
//! Benchmark with ghz (requires ghz):
//! ghz --insecure \
//!   --proto examples/protobuf/location.proto \
//!   --call location.Location/SendLocationAndSave \
//!   -d '{"long":106.8,"lat":-6.2,"message":"test"}' -c 64 -z 10s \
//!   127.0.0.1:9038

const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

const DISPATCH_MODEL: zix.Grpc.DispatchModel = if (builtin.os.tag == .linux) .URING else .ASYNC;

fn sendLocationAndSave(req: *zix.Grpc.Request, res: *zix.Grpc.Response, ctx: *zix.Grpc.Context) !void {
    _ = ctx;

    const msg = req.recvMessage() orelse {
        try res.finish(zix.Grpc.Status.INVALID_ARGUMENT, "empty request");
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

    // std.debug.print("recv location: long={d:.4} lat={d:.4} msg=\"{s}\"\n", .{ lon, lat, message });

    var resp: [128]u8 = undefined;
    var rpos: usize = 0;
    rpos += zix.Grpc.encodeString(1, "saved", resp[rpos..]);
    rpos += zix.Grpc.encodeInt32(2, 1, resp[rpos..]);

    try res.sendMessage("application/grpc+proto", resp[0..rpos]);
    try res.finish(zix.Grpc.Status.OK, "");
}

// --------------------------------------------------------- //

const Routes = [_]zix.Grpc.Route{
    .{ .path = "/location.Location/SendLocationAndSave", .handler = sendLocationAndSave },
};

pub fn main(process: std.process.Init) !void {
    var server = zix.Grpc.Server.init(
        zix.Grpc.Router(&Routes),
        .{
            .io = process.io,
            .ip = "127.0.0.1",
            .port = 9038,
            .dispatch_model = DISPATCH_MODEL,
        },
    );
    defer server.deinit();

    try server.run();
}
