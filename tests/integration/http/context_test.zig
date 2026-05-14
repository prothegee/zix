//! Integration tests: zix.Http.Context timeout, wired with real std.Io.Threaded.
//! Verifies withTimeout and withDeadline resolve correctly against a live clock.

const std = @import("std");
const zix = @import("zix");

const TimingResult = struct {
    within_budget: bool = false,
    with_deadline: bool = false,
    budget_exceeded: bool = false,
};

fn timingTestFn(result: *TimingResult, io: std.Io) void {
    const base = zix.Http.Context{ .io = io, .allocator = std.heap.smp_allocator };

    const ctx_large = base.withTimeout(60_000);
    result.within_budget = !ctx_large.timedOut();

    const ctx_deadline = base.withDeadline(ctx_large.deadline.?);
    result.with_deadline = !ctx_deadline.timedOut();

    const ctx_tiny = base.withTimeout(10);
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .real) catch {};
    result.budget_exceeded = ctx_tiny.timedOut();
}

test "zix integration: Context.withTimeout and withDeadline, timing behavior" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();

    var result = TimingResult{};
    const t = try std.Thread.spawn(.{}, timingTestFn, .{ &result, threaded.io() });
    t.join();

    try std.testing.expect(result.within_budget);
    try std.testing.expect(result.with_deadline);
    try std.testing.expect(result.budget_exceeded);
}
