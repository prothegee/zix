//! ZIX example channel basic
//!
//! ### file: examples/channel_basic.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Producer and consumer on two OS threads, sharing one `zix.Channel` of u32.
//! The producer sends task IDs 1 to 10, the consumer prints each ID squared.
//!
//! ### note:
//!
//! Run: `zig build zix-example-channel_basic`, then the binary in `zig-out/bin`.
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

const TASK_COUNT: u32 = 10;
const CHANNEL_CAPACITY: usize = 4;

const ThreadArgs = struct {
    channel: *zix.Channel,
    io: std.Io,
};

// --------------------------------------------------------- //

fn producer(args: ThreadArgs) void {
    defer args.channel.close(args.io);

    for (1..TASK_COUNT + 1) |task_id| {
        args.channel.send(args.io, u32, @intCast(task_id)) catch |err| {
            std.debug.print("producer: send error: {}\n", .{err});
            return;
        };

        std.debug.print("producer: sent task {d}\n", .{task_id});
    }
}

fn consumer(args: ThreadArgs) void {
    var total: u32 = 0;
    while (true) {
        const task_id = args.channel.recv(args.io, u32) catch |err| switch (err) {
            error.ZixChannel_Channel_Closed => break,
            error.ZixChannel_Channel_OutOfMemory,
            error.ZixChannel_Channel_TypeMismatch,
            => {
                std.debug.print("consumer: recv error: {}\n", .{err});
                break;
            },
        };

        std.debug.print("consumer: task {d} -> {d}\n", .{ task_id, task_id * task_id });
        total += 1;
    }

    std.debug.print("consumer: processed {d} tasks\n", .{total});
}

// --------------------------------------------------------- //

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var channel: zix.Channel = try .init(std.heap.smp_allocator, u32, CHANNEL_CAPACITY);
    defer channel.deinit();
    const args: ThreadArgs = .{
        .channel = &channel,
        .io = io,
    };

    const producer_thread = try std.Thread.spawn(.{}, producer, .{args});
    const consumer_thread = try std.Thread.spawn(.{}, consumer, .{args});

    producer_thread.join();
    consumer_thread.join();
}

