const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9030;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
const MAX_HEADERS: u8 = 16;

// 0 means unlimited concurrent tasks (auto from CPU count).
// Any other value pins the max concurrent task limit.
const CONCURRENT_LIMIT: usize = 4;

// .ASYNC uses the caller's io directly (the Io.Threaded created below).
// concurrent_limit on that io controls how many connections run concurrently.
const DISPATCH_MODEL: zix.Http1.DispatchModel = .ASYNC;
const WORKERS: usize = 0; // ignored by .ASYNC

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9030/"
fn homeHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.writeSimple(fd, 200, "text/plain", "hello from zix http1 (manual concurrent)") catch {};
}

// curl usage: curl -X GET "http://localhost:9030/info"
fn infoHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{{\"concurrent_limit\":{d}}}", .{CONCURRENT_LIMIT}) catch return;
    zix.Http1.writeJson(fd, 200, msg) catch {};
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/info", .handler = infoHandler },
});

// main does not take std.process.Init because the I/O backend is created here manually.
// This gives explicit control over the concurrency limit. The .ASYNC model dispatches
// each accepted connection through this io via io.async(), so concurrent_limit caps how
// many connections are served at once.
pub fn main() !void {
    const limit: std.Io.Limit = if (CONCURRENT_LIMIT == 0)
        .unlimited
    else
        std.Io.Limit.limited(CONCURRENT_LIMIT);

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{
        .concurrent_limit = limit,
    });
    defer threaded.deinit();

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = threaded.io(),
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .compression_max_out = COMPRESSION_MAX_OUT,
        .max_headers = MAX_HEADERS,
        .workers = WORKERS,
    });
    defer server.deinit();

    try server.run();
}
