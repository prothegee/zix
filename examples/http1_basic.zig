const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9015;
// Pick the model per target at comptime (ADR-065): .URING is the Linux shared-nothing
// completion loop, .ASYNC the portable model. .EPOLL and .URING are Linux-only, and run()
// returns error.DispatchModelUnsupported rather than silently serving a different model.
const DISPATCH_MODEL: zix.Http1.DispatchModel = if (builtin.os.tag == .linux) .URING else .ASYNC;
const KERNEL_BACKLOG: u31 = 1024;
// Comptime per-deployment tuning profile (ADR-041): .lean uses a small recv
// buffer for memory-bound hosts, .throughput a larger one for RAM-abundant hosts.
const Profile = enum { lean, throughput };
const PROFILE: Profile = .throughput;
const MAX_RECV_BUF: usize = switch (PROFILE) {
    .lean => 4 * 1024,
    .throughput => 16 * 1024,
};
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
const WORKERS: usize = 0; // 0 = cpu_count workers under .EPOLL / .URING, ignored by .ASYNC

// --------------------------------------------------------- //

// Note:
// Under .URING (Linux) each worker owns a private SO_REUSEPORT listener and one io_uring
// completion ring. The kernel load-balances new connections across the per-worker listeners,
// so there is no accept thread and no cross-thread fd handoff. It is the completion-based twin
// of .EPOLL: same shared-nothing topology, but most syscall transitions are batched away.
//
// Ring core status: chunked request bodies (fully present), bodies larger than max_recv_buf
// (answered then drained off the socket), and WebSocket upgrades are all served on the ring path.
//
// Under .ASYNC a single accept thread dispatches each connection through io.async(), which is
// the only model available on every platform.

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9015/"
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("Hello, World!");
}

// curl usage: curl -X GET "http://localhost:9015/echo"
fn echoHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    try res.sendJson("{\"status\":\"ok\"}");
}

// curl usage: curl -X GET "http://localhost:9015/about"
fn aboutHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("zix http1 basic server example");
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/echo", .handler = echoHandler },
    .{ .path = "/about", .handler = aboutHandler },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .compression_max_out = COMPRESSION_MAX_OUT,
        .workers = WORKERS,
    });
    defer server.deinit();

    try server.run();
}
