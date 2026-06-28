// Usage:
// zig run examples/http2_basic_5_uring.zig
//
// h2c (cleartext HTTP/2) over the .URING dispatch model: a shared-nothing per-core io_uring loop
// (one SO_REUSEPORT listener + ring per CPU) driving connections through the resumable h2 state
// machine. Linux-only: probes the ring at startup and falls back to .EPOLL when io_uring is
// unavailable, or to .POOL off Linux.
//
// Test it with a prior-knowledge h2c client:
//   curl --http2-prior-knowledge http://127.0.0.1:9069/

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

const SERVER_IP: []const u8 = "127.0.0.1";
const SERVER_PORT: u16 = 9069;

// --------------------------------------------------------- //

fn home(_: []const u8, _: []const zix.Http2.Header, _: []const u8, fd: std.posix.fd_t, sid: u31) void {
    zix.Http2.sendResponse(fd, sid, 200, "text/plain", "hello from zix h2c (uring)\n") catch {};
}

const Routes = [_]zix.Http2.Route{
    .{ .path = "/", .handler = home },
};

pub fn main(process: std.process.Init) !void {
    var server = try zix.Http2.Server.init(&Routes, .{
        .io = process.io,
        .ip = SERVER_IP,
        .port = SERVER_PORT,
        .dispatch_model = .URING,
    });
    defer server.deinit();

    try server.run();
}
