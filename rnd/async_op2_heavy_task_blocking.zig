const std = @import("std");

fn taskHeavy(io: std.Io, task_id: usize) !void {
    const src: std.Random.IoSource = .{ .io = io };
    const rand = src.interface();
    const delay = rand.intRangeAtMost(i64, 2000, 4000);

    std.debug.print("Task #{d} start\n", .{task_id});

    // Simulate heavy task
    try io.sleep(std.Io.Duration.fromMilliseconds(delay), .awake);
    std.debug.print("Task #{d} finished for {d}ms\n", .{task_id, delay});
}

fn taskSubmit(task_id: usize) !void {
    std.debug.print("Submitting task #{d}\n", .{task_id});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const MAX_OP = 10;

    for (0..MAX_OP) |id| {
        var buf: [128]u8 = undefined;

        const msg = std.fmt.bufPrint(&buf, "Error task #{d}\n", .{id}) catch "Error too long";

        var future_heavy = io.async(taskHeavy, .{ io, id });
        defer _ = future_heavy.cancel(io) catch msg;
        _ = try future_heavy.await(io);

        var future_submit = io.async(taskSubmit, .{ id });
        defer _ = future_submit.cancel(io) catch |err| {
            std.debug.print("Fail to submit task #{d}: {s}\n", .{@errorName(err)});
        };
    }
}
