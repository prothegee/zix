const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9007;
const DISPATCH_MODEL: zix.Http.DispatchModel = .POOL;
const MAX_KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_CLIENT_REQUEST: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;
const WORKERS: usize = 0; // 0 = auto (cpu_count accept threads)
const POOL_SIZE: usize = 0; // 0 = auto (max(10, cpu_count * 2) pool threads)

// Layer D: network-level connection guard.
// Connections idle or stalled beyond this are shut down by the timer thread.
// Requires model 2 (workers != 1). Should be >= HANDLER_TIMEOUT_MS.
const CONN_TIMEOUT_MS: u32 = 30_000;

// Layer B: per-handler execution budget.
// ctx.deadline is set before each dispatch. Handlers opt in by calling
// ctx.timedOut() between expensive steps and responding with 408 early.
const HANDLER_TIMEOUT_MS: u32 = 5_000;

// --------------------------------------------------------- //

// Simulates a slow two-step handler (3s + 3s = 6s total).
// With HANDLER_TIMEOUT_MS = 5s, step 2 triggers the timeout check.
//
// curl usage: curl http://localhost:9007/slow
pub fn slowHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;

    // Step 1 -- 3s of simulated work.
    std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(3_000), .real) catch {};
    if (ctx.timedOut()) {
        res.setStatus(.REQUEST_TIMEOUT);
        return res.sendJson("{\"error\":\"timeout\",\"step\":1}");
    }

    // Step 2 -- 3s more (total 6s > 5s budget).
    std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(3_000), .real) catch {};
    if (ctx.timedOut()) {
        res.setStatus(.REQUEST_TIMEOUT);
        return res.sendJson("{\"error\":\"timeout\",\"step\":2}");
    }

    try res.sendJson("{\"result\":\"ok\"}");
}

// Fast handler to confirm unrelated requests are served normally.
//
// curl usage: curl http://localhost:9007/ping
pub fn pingHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    try res.sendJson("{\"result\":\"pong\"}");
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var server = try zix.Http.Server.init(4096, .{
        .io = process.io,
        .allocator = arena.allocator(),
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .max_kernel_backlog = MAX_KERNEL_BACKLOG,
        .max_client_request = MAX_CLIENT_REQUEST,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
        .conn_timeout_ms = CONN_TIMEOUT_MS,
        .handler_timeout_ms = HANDLER_TIMEOUT_MS,
    });
    defer server.deinit();

    server.registerHandler("/slow", slowHandler);
    server.registerHandler("/ping", pingHandler);

    try server.run();
}
