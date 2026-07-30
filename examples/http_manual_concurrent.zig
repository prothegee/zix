const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9014;
const KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_RECV_BUF: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;

// 0 means leave std's own default in place (one less than the CPU count).
// Any other value pins how many connections may run at once.
const CONCURRENT_LIMIT: usize = 4;

// .ASYNC uses the caller's io directly (the Io.Threaded created below) and hands each accepted
// connection to io.async, so async_limit is the field that decides how many run at once.
// concurrent_limit is set to match only because io.concurrent is the other way a caller can reach
// this pool. Setting concurrent_limit alone would do nothing here.
//
// Two things are worth knowing before changing the limit:
// std.Io.Threaded defaults async_limit to one less than the CPU count, so a single-core host
// defaults to 0, and when the limit is reached io.async does not queue or block: it runs the task
// inline on the caller. For an accept loop that means the connection is served on the accept thread
// and nothing new is accepted until it finishes, so too low a limit turns the server serial.
const DISPATCH_MODEL: zix.Http.DispatchModel = .ASYNC;
const WORKERS: usize = 0; // ignored by .ASYNC

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9014/"
pub fn homeHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    try res.send("hello from zix (manual concurrent)");
}

// curl usage: curl -X GET "http://localhost:9014/info"
pub fn infoHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    var buf: [128]u8 = undefined;
    const msg = try std.fmt.bufPrint(
        &buf,
        "{{\"concurrent_limit\":{d}}}",
        .{CONCURRENT_LIMIT},
    );
    try res.sendJson(msg);
}

// --------------------------------------------------------- //

// main does not take std.process.Init because the I/O backend is created here manually.
// This gives explicit control over the concurrency limit.
//
// Comparison:
// Auto (default in other examples):
// pub fn main(process: std.process.Init) !void {
//     const router = zix.Http.Router(&Routes);
//     var server = zix.Http.Server.init(router.dispatch, .{ .io = process.io, ... });
//     // ...
// }
//
// Manual (this example):
// pub fn main() !void {
//     var threaded = std.Io.Threaded.init(allocator, .{ .concurrent_limit = ... });
//     const router = zix.Http.Router(&Routes);
//     var server = zix.Http.Server.init(router.dispatch, .{ .io = threaded.io(), ... });
//     // ...
// }

const Routes = [_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/info", .handler = infoHandler },
};

pub fn main() !void {
    // null leaves each field at std's own default rather than forcing .unlimited, which for
    // async_limit would mean an unbounded thread pool.
    const limit: ?std.Io.Limit = if (CONCURRENT_LIMIT == 0)
        null
    else
        std.Io.Limit.limited(CONCURRENT_LIMIT);

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{
        .async_limit = limit,
        .concurrent_limit = limit orelse .unlimited,
    });
    defer threaded.deinit();

    const router = zix.Http.Router(&Routes);
    var server = zix.Http.Server.init(router.dispatch, .{
        .io = threaded.io(),
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
