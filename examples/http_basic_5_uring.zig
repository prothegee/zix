const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9114;
const DISPATCH_MODEL: zix.Tcp.DispatchModel = .URING;
const KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_RECV_BUF: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;
const WORKERS: usize = 0; // 0 = auto (cpu_count ring workers). Used by .URING as the worker count.
const POOL_SIZE: usize = 0; // 0 = auto. Not used by .URING.

// --------------------------------------------------------- //

// Note:
// .URING is Linux-only (ADR-037). Shared-nothing: each worker owns one
// SO_REUSEPORT listener and one io_uring ring. The kernel distributes new
// connections across workers with no shared queue. Each readable batch recvs into
// the connection buffer, runs one request, and submits one coalesced send.
// One request per buffer (no pipelined drain), matching the .EPOLL path. On other
// platforms the server falls back to .POOL.

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9114/"
pub fn homeHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    try res.send("Hello, World!");
}

// curl usage: curl -X GET "http://localhost:9114/echo"
pub fn echoHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    res.setContentType(.APPLICATION_JSON);
    res.setKeepAlive(true);
    try res.send("{\"status\":\"ok\"}");
}

// curl usage: curl -X GET "http://localhost:9114/about"
pub fn aboutHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    try res.send("zix basic server example");
}

// --------------------------------------------------------- //

const Routes = [_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/echo", .handler = echoHandler },
    .{ .path = "/about", .handler = aboutHandler },
};

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var server = try zix.Http.Server.init(4096, &Routes, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
