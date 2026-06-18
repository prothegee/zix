const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9100;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .URING;
const KERNEL_BACKLOG: u31 = 1024;
// Comptime per-deployment tuning profile (ADR-041): .lean uses a small recv
// buffer for memory-bound hosts, .throughput a larger one for RAM-abundant hosts.
const Profile = enum { lean, throughput };
const PROFILE: Profile = .throughput;
const MAX_RECV_BUF: usize = switch (PROFILE) {
    .lean => 4 * 1024,
    .throughput => 16 * 1024,
};
const MAX_GZIP_OUT: usize = 256 * 1024;
const MAX_HEADERS: u8 = 16;
const WORKERS: usize = 0; // 0 = cpu_count ring workers (shared-nothing, one listener + ring each)
const POOL_SIZE: usize = 0; // ignored by .URING (used only on the non-Linux POOL fallback)

// --------------------------------------------------------- //

// Note:
// .URING is Linux-only (ADR-037). Each worker owns a private SO_REUSEPORT listener and
// one io_uring completion ring. The kernel load-balances new connections across the
// per-worker listeners, so there is no accept thread and no cross-thread fd handoff.
// It is the completion-based twin of .EPOLL: same shared-nothing topology, but most
// syscall transitions are batched away. On non-Linux targets the server falls back to .POOL.
//
// Ring core status: chunked request bodies (fully present), bodies larger than max_recv_buf
// (answered then drained off the socket), and WebSocket upgrades are all served on the ring path.

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9100/"
fn homeHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.writeSimple(fd, 200, "text/plain", "Hello, World!") catch {};
}

// curl usage: curl -X GET "http://localhost:9100/echo"
fn echoHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.writeJson(fd, 200, "{\"status\":\"ok\"}") catch {};
}

// curl usage: curl -X GET "http://localhost:9100/about"
fn aboutHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.writeSimple(fd, 200, "text/plain", "zix http1 basic server example") catch {};
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
        .max_gzip_out = MAX_GZIP_OUT,
        .max_headers = MAX_HEADERS,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
