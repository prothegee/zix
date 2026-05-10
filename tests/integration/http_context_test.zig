//! Integration tests: zix.Http.Context timeout methods (Layer B).
//! Covers gaps not testable in the unit test in src/tcp/http/context.zig:
//!   - withTimeout(large) -> timedOut() false immediately (within budget)
//!   - withDeadline()     -> timedOut() false when deadline is in the future
//!   - withTimeout(tiny) + sleep past deadline -> timedOut() true (budget exceeded)
//!
//! io-dependent tests run on a std.Thread.spawn thread backed by std.Io.Threaded,
//! matching the same io pattern used by pool threads in model 2.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix integration: Context.timedOut -- null deadline always false" {
    // io is undefined: timedOut() must short-circuit without touching io.
    const ctx = zix.Http.Context{ .io = undefined, .allocator = std.testing.allocator };
    try std.testing.expect(!ctx.timedOut());
}

// --------------------------------------------------------- //
// Timing tests -- require a real io backed by std.Io.Threaded.
// Run inside a spawned thread so io operations resolve against the thread pool.

const TimingResult = struct {
    within_budget: bool = false,
    with_deadline: bool = false,
    budget_exceeded: bool = false,
};

fn timingTestFn(result: *TimingResult, io: std.Io) void {
    const base = zix.Http.Context{ .io = io, .allocator = std.heap.smp_allocator };

    // Large budget (60s): timedOut() must be false immediately.
    const ctx_large = base.withTimeout(60_000);
    result.within_budget = !ctx_large.timedOut();

    // withDeadline: reuse the same far-future timestamp from ctx_large.
    // timedOut() must also be false.
    const ctx_deadline = base.withDeadline(ctx_large.deadline.?);
    result.with_deadline = !ctx_deadline.timedOut();

    // Tiny budget (10ms): sleep 50ms past it, timedOut() must be true.
    const ctx_tiny = base.withTimeout(10);
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .real) catch {};
    result.budget_exceeded = ctx_tiny.timedOut();
}

test "zix integration: Context.withTimeout and withDeadline -- timing behavior" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{
        .stack_size = 512 * 1024,
    });
    defer threaded.deinit();

    var result = TimingResult{};
    const t = try std.Thread.spawn(.{}, timingTestFn, .{ &result, threaded.io() });
    t.join();

    try std.testing.expect(result.within_budget); // 60s budget: not expired yet
    try std.testing.expect(result.with_deadline); // same future deadline: not expired
    try std.testing.expect(result.budget_exceeded); // 10ms budget, 50ms elapsed: expired
}
