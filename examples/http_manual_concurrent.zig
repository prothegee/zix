const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9002;
const MAX_KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_CLIENT_REQUEST: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;

// 0 means unlimited concurrent tasks (auto from CPU count).
// Any other value pins the max concurrent task limit.
const CONCURRENT_LIMIT: usize = 4;

// .ASYNC uses the caller's io directly (the Io.Threaded created below).
// concurrent_limit on that io controls how many connections run concurrently.
const DISPATCH_MODEL: zix.Http.DispatchModel = .ASYNC;
const WORKERS: usize = 0; // ignored by .ASYNC

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9002/"
pub fn homeHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    try res.send("hello from zix (manual concurrent)");
}

// curl usage: curl -X GET "http://localhost:9002/info"
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
//     var server = try zix.Http.Server.init(4096, &routes, .{ .io = process.io, ... });
//     // ...
// }
//
// Manual (this example):
// pub fn main() !void {
//     var threaded = std.Io.Threaded.init(allocator, .{ .concurrent_limit = ... });
//     var server = try zix.Http.Server.init(4096, &routes, .{ .io = threaded.io(), ... });
//     // ...
// }
pub fn main() !void {
    const limit: std.Io.Limit = if (CONCURRENT_LIMIT == 0)
        .unlimited
    else
        std.Io.Limit.limited(CONCURRENT_LIMIT);

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{
        .concurrent_limit = limit,
    });
    defer threaded.deinit();

    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/", .handler = homeHandler },
        .{ .path = "/info", .handler = infoHandler },
    }, .{
        .io = threaded.io(),
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .max_kernel_backlog = MAX_KERNEL_BACKLOG,
        .max_client_request = MAX_CLIENT_REQUEST,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
        .workers = WORKERS,
    });
    defer server.deinit();

    try server.run();
}
