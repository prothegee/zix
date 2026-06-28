// Usage:
// zig run examples/http2_basic_1_async.zig
//
// h2c (cleartext HTTP/2) over the .ASYNC dispatch model: one accept thread, io.async() per
// connection. Cross-platform.
//
// Test it with a prior-knowledge h2c client:
//   curl --http2-prior-knowledge http://127.0.0.1:9065/

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

const SERVER_IP: []const u8 = "127.0.0.1";
const SERVER_PORT: u16 = 9065;

// --------------------------------------------------------- //

fn home(_: []const u8, _: []const zix.Http2.Header, _: []const u8, fd: std.posix.fd_t, sid: u31) void {
    zix.Http2.sendResponse(fd, sid, 200, "text/plain", "hello from zix h2c (async)\n") catch {};
}

const Routes = [_]zix.Http2.Route{
    .{ .path = "/", .handler = home },
};

pub fn main(process: std.process.Init) !void {
    var server = try zix.Http2.Server.init(&Routes, .{
        .io = process.io,
        .ip = SERVER_IP,
        .port = SERVER_PORT,
        .dispatch_model = .ASYNC,
    });
    defer server.deinit();

    try server.run();
}
