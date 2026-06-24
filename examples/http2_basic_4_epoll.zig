// Usage:
// zig run examples/http2_basic_4_epoll.zig
//
// h2c (cleartext HTTP/2) over the .EPOLL dispatch model: a shared-nothing per-core multiplexed
// event loop (one SO_REUSEPORT listener + epoll per CPU), driving many non-blocking connections
// through the resumable h2 state machine. Linux-only, folds to .POOL elsewhere.
//
// Test it with a prior-knowledge h2c client:
//   curl --http2-prior-knowledge http://127.0.0.1:9068/

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

const SERVER_IP: []const u8 = "127.0.0.1";
const SERVER_PORT: u16 = 9068;

// --------------------------------------------------------- //

fn home(_: []const u8, _: []const zix.Http2.Header, _: []const u8, fd: std.posix.fd_t, sid: u31) void {
    zix.Http2.sendResponse(fd, sid, 200, "text/plain", "hello from zix h2c (epoll)\n") catch {};
}

pub fn main(process: std.process.Init) !void {
    var server = try zix.Http2.Server.init(&[_]zix.Http2.Route{
        .{ .path = "/", .handler = home },
    }, .{
        .io = process.io,
        .ip = SERVER_IP,
        .port = SERVER_PORT,

        // The shared-nothing multiplexed event loop. pool_size = 0 means one worker per CPU.
        .dispatch_model = .EPOLL,
    });
    defer server.deinit();

    try server.run();
}
