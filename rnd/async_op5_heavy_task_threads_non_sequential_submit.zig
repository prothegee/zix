const std = @import("std");

const TaskHeavyResult = @typeInfo(@TypeOf(taskHeavy)).@"fn".return_type.?;

fn taskHeavy(io: std.Io, task_id: usize) !void {
    const src: std.Random.IoSource = .{ .io = io };
    const rand = src.interface();
    const delay = rand.intRangeAtMost(i64, 2000, 4000);

    std.debug.print("Task #{d} start\n", .{task_id});
    try io.sleep(std.Io.Duration.fromMilliseconds(delay), .awake);
    std.debug.print("Task #{d} finished for {d}ms\n", .{ task_id, delay });
}

fn taskSubmit(task_id: usize) !void {
    std.debug.print("Submitting task #{d}\n", .{task_id});
}

fn awaitAndSubmit(io: std.Io, future: *std.Io.Future(TaskHeavyResult), id: usize) !void {
    _ = try future.await(io);
    try taskSubmit(id);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const MAX_OP = 1_000_000;

    const allocator = std.heap.page_allocator;
    const heavy_futures = try allocator.alloc(std.Io.Future(TaskHeavyResult), MAX_OP);
    defer allocator.free(heavy_futures);

    var spawned: usize = 0;
    defer {
        for (heavy_futures[0..spawned]) |*f| {
            _ = f.cancel(io) catch {};
        }
    }
    for (0..MAX_OP) |id| {
        heavy_futures[id] = io.concurrent(taskHeavy, .{ io, id }) catch
            io.async(taskHeavy, .{ io, id });
        spawned += 1;
    }

    var group: std.Io.Group = .init;
    for (0..MAX_OP) |id| {
        group.concurrent(io, awaitAndSubmit, .{ io, &heavy_futures[id], id }) catch
            group.async(io, awaitAndSubmit, .{ io, &heavy_futures[id], id });
    }

    try group.await(io);
}
