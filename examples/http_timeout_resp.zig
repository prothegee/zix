const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9010;
const DISPATCH_MODEL: zix.Http.DispatchModel = .ASYNC;
const KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_RECV_BUF: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const WORKERS: usize = 0; // ignored by .ASYNC

// Layer D: network-level connection guard.
// Connections idle or stalled beyond this are shut down by the timer thread.
// Should be >= HANDLER_TIMEOUT_MS.
const CONN_TIMEOUT_MS: u32 = 30_000;

// Layer B: per-handler execution budget.
// ctx.deadline is set before each dispatch. Handlers opt in by calling
// ctx.isExpired() between expensive steps and responding with 408 early.
const HANDLER_TIMEOUT_MS: u32 = 5_000;

// --------------------------------------------------------- //

// Simulates a slow two-step handler (3s + 3s = 6s total).
// With HANDLER_TIMEOUT_MS = 5s, step 2 triggers the timeout check.
//
// curl usage: curl http://localhost:9010/slow
pub fn slowHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;

    // Step 1: 3s of simulated work.
    std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(3_000), .real) catch {};
    if (ctx.isExpired()) {
        res.setStatus(.REQUEST_TIMEOUT);
        return res.sendJson("{\"error\":\"timeout\",\"step\":1}");
    }

    // Step 2: 3s more (total 6s > 5s budget).
    std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(3_000), .real) catch {};
    if (ctx.isExpired()) {
        res.setStatus(.REQUEST_TIMEOUT);
        return res.sendJson("{\"error\":\"timeout\",\"step\":2}");
    }

    try res.sendJson("{\"result\":\"ok\"}");
}

// Demonstrates ctx.setTimeout(): the handler overrides the server-wide deadline
// to give itself a shorter window. Useful when one route is slower than others
// but the global HANDLER_TIMEOUT_MS is set for the fast path.
//
// curl usage: curl http://localhost:9010/custom
pub fn customTimeoutHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;

    // Override: this handler caps itself to 2s regardless of the global 5s budget.
    ctx.setTimeout(2_000);

    std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(1_500), .real) catch {};
    if (ctx.isExpired()) {
        res.setStatus(.REQUEST_TIMEOUT);
        return res.sendJson("{\"error\":\"timeout\",\"handler\":\"custom\"}");
    }

    try res.sendJson("{\"result\":\"ok\",\"handler\":\"custom\"}");
}

// Fast handler to confirm unrelated requests are served normally.
//
// curl usage: curl http://localhost:9010/ping
pub fn pingHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    try res.sendJson("{\"result\":\"pong\"}");
}

// --------------------------------------------------------- //

const Routes = [_]zix.Http.Route{
    .{ .path = "/slow", .handler = slowHandler },
    .{ .path = "/custom", .handler = customTimeoutHandler },
    .{ .path = "/ping", .handler = pingHandler },
};

pub fn main(process: std.process.Init) !void {
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
        .conn_timeout_ms = CONN_TIMEOUT_MS,
        .handler_timeout_ms = HANDLER_TIMEOUT_MS,
    });
    defer server.deinit();

    try server.run();
}
