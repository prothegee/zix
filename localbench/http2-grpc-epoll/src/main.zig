//! localbench: zix-grpc
//!
//! zix.Grpc (.EPOLL) over h2c, one handler module per RPC (src/handlers/).
//! Shared-nothing: each worker owns its SO_REUSEPORT listener, its epoll set,
//! and its connections, multiplexing h2 streams per connection. Nothing is
//! cached.

const std = @import("std");
const zix = @import("zix");

const getsum = @import("handlers/getsum.zig");
const streamsum = @import("handlers/streamsum.zig");

// --------------------------------------------------------- //

// The engine reads is_server_streaming off the route table before any handler
// runs, to pick sync-inline against task-spawn dispatch, so init takes the
// router TYPE rather than a handler pointer.
const Routes = zix.Grpc.Router(&[_]zix.Grpc.Route{
    .{ .path = getsum.PATH, .handler = getsum.RESPONSE },
    .{ .path = streamsum.PATH, .handler = streamsum.RESPONSE, .is_server_streaming = true },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Grpc.Server.init(Routes, .{
        .io = process.io,
        .ip = "::",
        .port = 8080,
        .workers = 0,
        .dispatch_model = .EPOLL,
        //
        .kernel_backlog = 16 * 1024,
        //
        // Wide enough that a client opening many parallel streams is never
        // refused: h2load drives 100 at a time. Per-stream buffers are small,
        // so a wide table stays cheap.
        .max_streams = 128,
        .max_body = 4 * 1024,
    });
    defer server.deinit();

    try server.run();
}
