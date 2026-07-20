const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9025;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .POOL;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
const WORKERS: usize = 0; // 0 = cpu_count accept threads
const POOL_SIZE: usize = 0; // 0 = max(10, cpu_count * 2) pool threads

// Per-handler execution budget. The server arms a thread-local deadline before
// each dispatch. Handlers opt in by calling zix.Http1.isExpired() between steps
// and responding with 408 early.
const HANDLER_TIMEOUT_MS: u32 = 5_000;

// --------------------------------------------------------- //

// Simulates a slow two-step handler (3s + 3s = 6s total).
// With HANDLER_TIMEOUT_MS = 5s, step 2 trips the server-armed deadline check
// (zix.Http1.isExpired reads the budget the engine set before this dispatch).
// The sleep runs on ctx.io, the worker io the trio carries.
//
// curl usage: curl http://localhost:9025/slow
fn slowHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    // Step 1: 3s of simulated work.
    std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(3_000), .awake) catch {};
    if (zix.Http1.isExpired()) {
        res.setStatus(.REQUEST_TIMEOUT);

        try res.sendJson("{\"error\":\"timeout\",\"step\":1}");
        return;
    }

    // Step 2: 3s more (total 6s > 5s budget).
    std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(3_000), .awake) catch {};
    if (zix.Http1.isExpired()) {
        res.setStatus(.REQUEST_TIMEOUT);

        try res.sendJson("{\"error\":\"timeout\",\"step\":2}");
        return;
    }

    try res.sendJson("{\"result\":\"ok\"}");
}

// Demonstrates ctx.setTimeout(): the handler gives itself a shorter 2s window on
// the context deadline, independent of the server-wide 5s budget.
//
// curl usage: curl http://localhost:9025/custom
fn customTimeoutHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    ctx.setTimeout(2_000);

    std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(1_500), .awake) catch {};
    if (ctx.timedOut()) {
        res.setStatus(.REQUEST_TIMEOUT);

        try res.sendJson("{\"error\":\"timeout\",\"handler\":\"custom\"}");
        return;
    }

    try res.sendJson("{\"result\":\"ok\",\"handler\":\"custom\"}");
}

// Fast handler to confirm unrelated requests are served normally.
//
// curl usage: curl http://localhost:9025/ping
fn pingHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    try res.sendJson("{\"result\":\"pong\"}");
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/slow", .handler = slowHandler },
    .{ .path = "/custom", .handler = customTimeoutHandler },
    .{ .path = "/ping", .handler = pingHandler },
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
        .pool_size = POOL_SIZE,
        .handler_timeout_ms = HANDLER_TIMEOUT_MS,
    });
    defer server.deinit();

    try server.run();
}
