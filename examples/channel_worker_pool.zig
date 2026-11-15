//! ZIX example channel worker pool
//!
//! ### file: examples/channel_worker_pool.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Fan-out: one producer and four workers share one `zix.Channel` of u32.
//! Each task goes to whichever worker is ready first, there is no fixed assignment.
//!
//! ### note:
//!
//! Run: `zig build zix-example-channel_worker_pool`, then the binary in `zig-out/bin`.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

const TASK_COUNT: u32 = 20;
const WORKER_COUNT: usize = 4;

const ProducerArgs = struct {
    channel: *zix.Channel,
    io: std.Io,
};

const WorkerArgs = struct {
    worker_id: usize,
    channel: *zix.Channel,
    io: std.Io,
};

// --------------------------------------------------------- //

fn producer(args: ProducerArgs) void {
    defer args.channel.close(args.io);

    for (0..TASK_COUNT) |task_id| {
        args.channel.send(args.io, u32, @intCast(task_id)) catch |err| {
            std.debug.print("producer: send error: {}\n", .{err});
            return;
        };

        std.debug.print("producer: queued task {d}\n", .{task_id});
    }
}

fn worker(args: WorkerArgs) void {
    var processed: u32 = 0;
    while (true) {
        const task_id = args.channel.recv(args.io, u32) catch |err| switch (err) {
            error.ZixChannel_Channel_Closed => break,
            error.ZixChannel_Channel_OutOfMemory,
            error.ZixChannel_Channel_TypeMismatch,
            => {
                std.debug.print("worker {d}: recv error: {}\n", .{ args.worker_id, err });
                break;
            },
        };

        std.debug.print("worker {d}: task {d} -> {d}\n", .{
            args.worker_id,
            task_id,
            task_id * task_id,
        });
        processed += 1;
    }

    std.debug.print("worker {d}: done, processed {d} tasks\n", .{
        args.worker_id,
        processed,
    });
}

// --------------------------------------------------------- //

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Capacity = WORKER_COUNT, so the producer can stay ahead of the workers.
    var channel: zix.Channel = try .init(std.heap.smp_allocator, u32, WORKER_COUNT);
    defer channel.deinit();

    // Workers start first, so they are ready when the producer begins.
    var worker_threads: [WORKER_COUNT]std.Thread = undefined;
    for (&worker_threads, 0..) |*worker_thread, worker_id| {
        worker_thread.* = try std.Thread.spawn(.{}, worker, .{WorkerArgs{
            .worker_id = worker_id,
            .channel = &channel,
            .io = io,
        }});
    }
    const producer_thread = try std.Thread.spawn(.{}, producer, .{ProducerArgs{
        .channel = &channel,
        .io = io,
    }});

    producer_thread.join();
    for (worker_threads) |worker_thread| worker_thread.join();

    std.debug.print("all {d} tasks done\n", .{TASK_COUNT});
}

