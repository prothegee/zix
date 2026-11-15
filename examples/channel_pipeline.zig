//! ZIX example channel pipeline
//!
//! ### file: examples/channel_pipeline.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Three-stage pipeline on three OS threads, linked by two `zix.Channel` values.
//! Stage A makes values, stage B doubles them, stage C prints a running sum.
//!
//! ### note:
//!
//! A slow stage makes the channel before it fill up, so the stage before it waits
//! (backpressure flows upstream).
//! Run: `zig build zix-example-channel_pipeline`, then the binary in `zig-out/bin`.
//!
//! ```mermaid
//! flowchart LR
//!     stage_a --> raw_channel["raw_channel (u32)"]
//!     raw_channel --> stage_b
//!     stage_b --> result_channel["result_channel (u64)"]
//!     result_channel --> stage_c
//! ```
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

const ITEM_COUNT: u32 = 10;
const CHANNEL_CAPACITY: usize = 4;

const StageAArgs = struct {
    output: *zix.Channel,
    io: std.Io,
};

const StageBArgs = struct {
    input: *zix.Channel,
    output: *zix.Channel,
    io: std.Io,
};

const StageCArgs = struct {
    input: *zix.Channel,
    io: std.Io,
};

// --------------------------------------------------------- //

/// Stage A: send raw values 1 to ITEM_COUNT.
fn stageA(args: StageAArgs) void {
    defer args.output.close(args.io);

    for (1..ITEM_COUNT + 1) |raw| {
        args.output.send(args.io, u32, @intCast(raw)) catch |err| {
            std.debug.print("stage_a: send error: {}\n", .{err});
            return;
        };

        std.debug.print("stage_a: produced {d}\n", .{raw});
    }
}

/// Stage B: read raw values, double them, forward them.
fn stageB(args: StageBArgs) void {
    defer args.output.close(args.io);

    while (true) {
        const raw = args.input.recv(args.io, u32) catch |err| switch (err) {
            error.ZixChannel_Channel_Closed => break,
            error.ZixChannel_Channel_OutOfMemory,
            error.ZixChannel_Channel_TypeMismatch,
            => {
                std.debug.print("stage_b: recv error: {}\n", .{err});
                break;
            },
        };

        const doubled: u64 = @as(u64, raw) * 2;

        args.output.send(args.io, u64, doubled) catch |err| {
            std.debug.print("stage_b: send error: {}\n", .{err});
            return;
        };

        std.debug.print("stage_b: {d} -> {d}\n", .{ raw, doubled });
    }
}

/// Stage C: read results and print the running sum.
fn stageC(args: StageCArgs) void {
    var total: u64 = 0;
    while (true) {
        const result = args.input.recv(args.io, u64) catch |err| switch (err) {
            error.ZixChannel_Channel_Closed => break,
            error.ZixChannel_Channel_OutOfMemory,
            error.ZixChannel_Channel_TypeMismatch,
            => {
                std.debug.print("stage_c: recv error: {}\n", .{err});
                break;
            },
        };

        total += result;
        std.debug.print("stage_c: result={d} running_sum={d}\n", .{ result, total });
    }

    std.debug.print("stage_c: pipeline done, total={d}\n", .{total});
}

// --------------------------------------------------------- //

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw_channel: zix.Channel = try .init(std.heap.smp_allocator, u32, CHANNEL_CAPACITY);
    defer raw_channel.deinit();
    var result_channel: zix.Channel = try .init(std.heap.smp_allocator, u64, CHANNEL_CAPACITY);
    defer result_channel.deinit();

    const thread_a = try std.Thread.spawn(.{}, stageA, .{StageAArgs{
        .output = &raw_channel,
        .io = io,
    }});
    const thread_b = try std.Thread.spawn(.{}, stageB, .{StageBArgs{
        .input = &raw_channel,
        .output = &result_channel,
        .io = io,
    }});
    const thread_c = try std.Thread.spawn(.{}, stageC, .{StageCArgs{
        .input = &result_channel,
        .io = io,
    }});

    thread_a.join();
    thread_b.join();
    thread_c.join();
}

