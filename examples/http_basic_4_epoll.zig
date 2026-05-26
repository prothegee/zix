const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9100;
const DISPATCH_MODEL: zix.Tcp.DispatchModel = .EPOLL;
const MAX_KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_CLIENT_REQUEST: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;
const WORKERS: usize = 0; // ignored by .EPOLL (single epoll event loop accepts)
const POOL_SIZE: usize = 0; // 0 = auto (max(10, cpu_count * 2) worker threads)

// Logger config — uncomment this section to add logger
// const LOG_DIR: []const u8  = "./logs";
// const LOG_FILE: []const u8 = "app";

// --------------------------------------------------------- //

// Note:
// .EPOLL is Linux-only. A single epoll event loop accepts connections and hands
// each readable socket to a worker pool. Each worker serves one request then
// re-arms the socket (EPOLLONESHOT), so idle keep-alive connections hold no thread.
// Best for very high connection counts and slow/idle clients. On other platforms
// the server returns error.EpollUnsupported — use .POOL there.

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9100/"
pub fn homeHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    // res.setContentType(.TEXT_PLAIN); // need apple to apple?
    try res.send("Hello, World!");
}

// curl usage: curl -X GET "http://localhost:9100/echo"
pub fn echoHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    res.setContentType(.APPLICATION_JSON);
    res.setKeepAlive(true);
    try res.addHeader("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'");
    try res.addHeader("X-Content-Type-Options", "nosniff");
    try res.addHeader("X-Frame-Options", "DENY");
    try res.addHeader("Referrer-Policy", "strict-origin-when-cross-origin");
    try res.send("{\"status\":\"ok\"}");
}

// curl usage: curl -X GET "http://localhost:9100/about"
pub fn aboutHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    try res.send("zix basic server example");
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/", .handler = homeHandler },
        .{ .path = "/echo", .handler = echoHandler },
        .{ .path = "/about", .handler = aboutHandler },
    }, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .max_kernel_backlog = MAX_KERNEL_BACKLOG,
        .max_client_request = MAX_CLIENT_REQUEST,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
