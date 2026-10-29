const std = @import("std");

fn taskHeavy(io: std.Io, task_id: usize) !void {
    const src: std.Random.IoSource = .{ .io = io };
    const rand = src.interface();
    const delay = rand.intRangeAtMost(i64, 2000, 4000);

    std.debug.print("Task #{d} start\n", .{task_id});

    // Simulate heavy task
    try io.sleep(std.Io.Duration.fromMilliseconds(delay), .awake);
    std.debug.print("Task #{d} finished for {d}ms\n", .{ task_id, delay });
}

fn taskSubmit(task_id: usize) !void {
    std.debug.print("Submitting task #{d}\n", .{task_id});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const MAX_OP = 1_000;

    const TaskHeavyResult = @typeInfo(@TypeOf(taskHeavy)).@"fn".return_type.?;
    var heavy_futures: [MAX_OP]std.Io.Future(TaskHeavyResult) = undefined;
    var spawned: usize = 0;

    defer {
        for (heavy_futures[0..spawned]) |*f| {
            _ = f.cancel(io) catch {};
        }
    }

    for (0..MAX_OP) |id| {
        heavy_futures[id] = io.async(taskHeavy, .{ io, id });
        spawned += 1;
    }

    for (0..MAX_OP) |id| {
        _ = try heavy_futures[id].await(io);

        var future_submit = io.async(taskSubmit, .{id});
        try future_submit.await(io);
    }
}
