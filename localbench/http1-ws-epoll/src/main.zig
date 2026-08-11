//! localbench: zix-ws
//!
//! zix.Http1 WebSocket (.EPOLL), Router-only: one handler module per route
//! (src/handlers/). GET /ws upgrades, then the engine drives the echo loop:
//! frames are echoed on readiness and a pipelined burst is coalesced into one
//! write.

const std = @import("std");
const zix = @import("zix");

const ws = @import("handlers/ws.zig");

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = ws.PATH, .handler = ws.RESPONSE },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = "::",
        .port = 8080,
        .workers = 0,
        .dispatch_model = .EPOLL,
        //
        .send_date_header = false,
        //
        .kernel_backlog = 16 * 1024,
        .max_recv_buf = 4 * 1024,
        .ws_recv_buf = 32 * 1024,
    });
    defer server.deinit();

    try server.run();
}
