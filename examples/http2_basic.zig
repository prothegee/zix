// Usage:
// zig build example-http2_basic
//
// h2c (cleartext HTTP/2). On Linux the .URING dispatch model runs a shared-nothing per-core
// io_uring loop (one SO_REUSEPORT listener + ring per CPU) driving connections through the
// resumable h2 state machine, probing the ring at startup and folding to .EPOLL when io_uring
// is unavailable. Off Linux the model is .ASYNC, the portable one.
//
// Test it with a prior-knowledge h2c client:
//   curl --http2-prior-knowledge http://127.0.0.1:9065/

const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

// --------------------------------------------------------- //

const SERVER_IP: []const u8 = "127.0.0.1";
const SERVER_PORT: u16 = 9065;
// Pick the model per target at comptime (ADR-065). .EPOLL and .URING are Linux-only, and run()
// returns error.DispatchModelUnsupported rather than silently serving a different model.
const DISPATCH_MODEL: zix.Http2.DispatchModel = if (builtin.os.tag == .linux) .URING else .ASYNC;

// --------------------------------------------------------- //

fn home(_: *zix.Http2.Request, res: *zix.Http2.Response, _: *zix.Http2.Context) anyerror!void {
    try res.sendText("hello from zix h2c\n");
}

const Routes = [_]zix.Http2.Route{
    .{ .path = "/", .handler = home },
};
const router = zix.Http2.Router(&Routes);

pub fn main(process: std.process.Init) !void {
    var server = zix.Http2.Server.init(router.dispatch, .{
        .io = process.io,
        .ip = SERVER_IP,
        .port = SERVER_PORT,
        .dispatch_model = DISPATCH_MODEL,
    });
    defer server.deinit();

    try server.run();
}
