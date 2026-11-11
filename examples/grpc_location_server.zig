//! ZIX example grpc location server
//!
//! ### file: examples/grpc_location_server.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! gRPC h2c location service (location.Location/SendLocationAndSave)
//! that reads double and string fields from the request.
//!
//! ### note:
//!
//! Proto schema: examples/protobuf/location.proto.
//! The h2load body file examples/grpc_location_req.bin is one framed LocationReq.
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
const PORT:u16 = 9038;
const WORKERS:usize = 0;
const DISPATCH_MODEL:zix.Grpc.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;

const CONTENT_TYPE:[]const u8 = "application/grpc+proto";

// --------------------------------------------------------- //

// grpcurl usage:
// grpcurl -proto examples/protobuf/location.proto -plaintext \
//   -d '{"long":106.8,"lat":-6.2,"message":"test"}' \
//   127.0.0.1:9038 location.Location/SendLocationAndSave
//
// h2load usage:
// h2load -n 100000 -c 64 -t 4 \
//   --header 'content-type: application/grpc+proto' \
//   --header 'te: trailers' \
//   --data examples/grpc_location_req.bin \
//   http://127.0.0.1:9038/location.Location/SendLocationAndSave
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

    // A real service stores longitude, latitude, and message here.

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
        .path = "/location.Location/SendLocationAndSave",
        .handler = sendLocationAndSave,
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

