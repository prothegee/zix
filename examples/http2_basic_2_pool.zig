// Usage:
// zig run examples/http2_basic_2_pool.zig
//
// h2c (cleartext HTTP/2) over the .POOL dispatch model: a fixed thread pool, one connection per
// pool thread for its lifetime. Cross-platform.
//
// Test it with a prior-knowledge h2c client:
//   curl --http2-prior-knowledge http://127.0.0.1:9066/

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

const SERVER_IP: []const u8 = "127.0.0.1";
const SERVER_PORT: u16 = 9066;

// --------------------------------------------------------- //

fn home(_: *zix.Http2.Request, res: *zix.Http2.Response, _: *zix.Http2.Context) anyerror!void {
    try res.sendText("hello from zix h2c (pool)\n");
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
        .dispatch_model = .POOL,
    });
    defer server.deinit();

    try server.run();
}
