// channel_worker_pool.zig: fan-out: 1 producer, N workers sharing one channel
//
// Producer pushes task IDs 0..19 into a buffered channel.
// Four worker threads compete to pull from the same channel.
// Each worker squares the task ID and records the result.
//
// Demonstrates fan-out: work is distributed across workers based on
// who is ready first, no fixed assignment.
//
// Run:
// zig build example-channel_worker_pool && ./zig-out/bin/example-channel_worker_pool

const std = @import("std");
const zix = @import("zix");

const TASK_COUNT: u32 = 20;
const WORKER_COUNT: usize = 4;

const TaskChan = zix.Channel(u32);

// Logger config — uncomment this section to add logger
// const LOG_DIR: []const u8  = "./logs";
// const LOG_FILE: []const u8 = "channel";

// fn createLogDir(io: std.Io) void {
//     std.Io.Dir.cwd().createDirPath(io, LOG_DIR) catch {};
// }

// --------------------------------------------------------- //

const ProducerCap = struct {
    ch: *TaskChan,
    io: std.Io,
};

fn producer(cap: ProducerCap) void {
    defer cap.ch.close(cap.io);
    for (0..TASK_COUNT) |i| {
        cap.ch.send(cap.io, @intCast(i)) catch |err| {
            std.debug.print("producer: send error: {}\n", .{err});
            return;
        };
        std.debug.print("producer: queued task {d}\n", .{i});
    }
}

// --------------------------------------------------------- //

const WorkerCap = struct {
    id: usize,
    ch: *TaskChan,
    io: std.Io,
};

fn worker(cap: WorkerCap) void {
    var processed: u32 = 0;
    while (true) {
        const task_id = cap.ch.recv(cap.io) catch |err| {
            if (err != error.Closed) std.debug.print("worker {d}: recv error: {}\n", .{ cap.id, err });
            break;
        };
        const result = task_id * task_id;
        std.debug.print("worker {d}: task {d} -> {d}\n", .{ cap.id, task_id, result });
        processed += 1;
    }
    std.debug.print("worker {d}: done, processed {d} tasks\n", .{ cap.id, processed });
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    // Uncomment this to add logger (console only — no save_path means no file output):
    // var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    //     .console           = .ALWAYS,
    //     .console_min_level = .INFO,
    // });
    // defer logger.deinit();

    // Uncomment this to add logger with file output (createLogDir must run first):
    // createLogDir(process.io);
    // var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    //     .save_path      = LOG_DIR,
    //     .save_file      = LOG_FILE,
    //     .save_min_level = .INFO,
    //     .console        = .ALWAYS,
    // });
    // defer logger.deinit();

    // logger.system(.INFO, "channel", "main started", .{});

    _ = process;

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Buffer capacity = WORKER_COUNT: producer can stay ahead of workers.
    var ch = try TaskChan.init(std.heap.smp_allocator, WORKER_COUNT);
    defer ch.deinit();

    // Start workers first so they are ready to pull when producer begins.
    var worker_threads: [WORKER_COUNT]std.Thread = undefined;
    for (&worker_threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, worker, .{WorkerCap{ .id = i, .ch = &ch, .io = io }});
    }

    const producer_thread = try std.Thread.spawn(.{}, producer, .{ProducerCap{ .ch = &ch, .io = io }});

    producer_thread.join();
    for (worker_threads) |t| t.join();

    std.debug.print("all {d} tasks done\n", .{TASK_COUNT});
}
