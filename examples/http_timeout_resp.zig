const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "0.0.0.0";
const PORT: u16 = 9007;
const MAX_KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_CLIENT_REQUEST: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;

const HANDLER_TIMEOUT_MS: u64 = 5_000;
const DELAY_MIN_MS: u64 = 3_000;
const DELAY_MAX_MS: u64 = 6_000;

// --------------------------------------------------------- //

// Simulates a handler that takes a random amount of time (3-6 seconds),
// if the simulated duration exceeds HANDLER_TIMEOUT_MS, responds with 408.
// curl usage: curl -X GET "http://localhost:9007/slow"
pub fn slowHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;

    // Seed PRNG from the current wall-clock second (std.Io.Timestamp, like rnd examples).
    const seed: u64 = @intCast(std.Io.Timestamp.now(ctx.io, .real).toSeconds());
    var prng = std.Random.DefaultPrng.init(seed);

    // Pick a random simulated work duration between DELAY_MIN_MS and DELAY_MAX_MS.
    const work_ms = prng.random().intRangeAtMost(u64, DELAY_MIN_MS, DELAY_MAX_MS);

    // Sleep to simulate async work in progress (non-blocking: other connections still served).
    std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(@intCast(work_ms)), .real) catch {};

    if (work_ms > HANDLER_TIMEOUT_MS) {
        res.setStatus(.REQUEST_TIMEOUT);
        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(
            &buf,
            "{{\"error\":\"timeout\",\"elapsed_ms\":{d},\"limit_ms\":{d}}}",
            .{ work_ms, HANDLER_TIMEOUT_MS },
        );
        try res.sendJson(msg);
    } else {
        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(
            &buf,
            "{{\"result\":\"ok\",\"elapsed_ms\":{d}}}",
            .{work_ms},
        );
        try res.sendJson(msg);
    }
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var server = try zix.Http.Server.init(.{
        .io = process.io,
        .allocator = arena.allocator(),
        .ip = IP,
        .port = PORT,
        .max_kernel_backlog = MAX_KERNEL_BACKLOG,
        .max_client_request = MAX_CLIENT_REQUEST,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
    });
    defer server.deinit();

    server.registerHandler("/slow", slowHandler);

    try server.run();
}
