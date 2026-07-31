const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9000;
// Pick the model per target at comptime (ADR-065): .URING is the Linux shared-nothing
// completion loop, .ASYNC the portable model. .EPOLL and .URING are Linux-only, and run()
// returns error.DispatchModelUnsupported rather than silently serving a different model.
const DISPATCH_MODEL: zix.Tcp.DispatchModel = if (builtin.os.tag == .linux) .URING else .ASYNC;
const KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_RECV_BUF: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const WORKERS: usize = 0; // 0 = cpu_count workers under .EPOLL / .URING, ignored by .ASYNC

// --------------------------------------------------------- //

// Note:
// Under .URING (Linux) the engine is shared-nothing: each worker owns one SO_REUSEPORT
// listener and one io_uring ring. The kernel distributes new connections across workers with
// no shared queue. Each readable batch recvs into the connection buffer, runs one request, and
// submits one coalesced send. One request per buffer (no pipelined drain), matching .EPOLL.
//
// Under .ASYNC a single accept thread dispatches each connection through io.async(), which is
// the only model available on every platform.

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9000/"
pub fn homeHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    try res.send("Hello, World!");
}

// curl usage: curl -X GET "http://localhost:9000/echo"
pub fn echoHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    res.setContentType(.APPLICATION_JSON);
    res.setKeepAlive(true);
    try res.send("{\"status\":\"ok\"}");
}

// curl usage: curl -X GET "http://localhost:9000/about"
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

    const router = zix.Http.Router(&Routes);
    var server = zix.Http.Server.init(router.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .workers = WORKERS,
    });
    defer server.deinit();

    try server.run();
}
