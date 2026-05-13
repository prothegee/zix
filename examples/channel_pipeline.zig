// channel_pipeline.zig -- 3-stage data pipeline via chained channels
//
// Stage A generates raw values and sends to ch1.
// Stage B reads from ch1, doubles each value, sends to ch2.
// Stage C reads from ch2, formats and prints the final result.
//
// Each stage runs as an independent thread. Channels decouple the stages:
// each runs at its own pace -- backpressure flows upstream when a stage is slow.
//
//   stage_a  -->  Channel(u32)  -->  stage_b  -->  Channel(u64)  -->  stage_c
//                   (ch1)                            (ch2)
//
// Run:
//   zig build example-channel_pipeline && ./zig-out/bin/example-channel_pipeline

const std = @import("std");
const zix = @import("zix");

const ITEM_COUNT: u32 = 10;

const RawChan = zix.Channel(u32);
const ResultChan = zix.Channel(u64);

// --------------------------------------------------------- //

// Stage A: generate raw values 1..ITEM_COUNT
const StageACap = struct {
    ch: *RawChan,
    io: std.Io,
};

fn stageA(cap: StageACap) void {
    defer cap.ch.close(cap.io);
    for (1..ITEM_COUNT + 1) |i| {
        cap.ch.send(cap.io, @intCast(i)) catch |err| {
            std.debug.print("stage_a: send error: {}\n", .{err});
            return;
        };
        std.debug.print("stage_a: produced {d}\n", .{i});
    }
}

// --------------------------------------------------------- //

// Stage B: read raw values, double them, forward
const StageBCap = struct {
    in: *RawChan,
    out: *ResultChan,
    io: std.Io,
};

fn stageB(cap: StageBCap) void {
    defer cap.out.close(cap.io);
    while (true) {
        const raw = cap.in.recv(cap.io) catch |err| {
            if (err != error.Closed) std.debug.print("stage_b: recv error: {}\n", .{err});
            break;
        };
        const doubled: u64 = @as(u64, raw) * 2;
        cap.out.send(cap.io, doubled) catch |err| {
            std.debug.print("stage_b: send error: {}\n", .{err});
            return;
        };
        std.debug.print("stage_b: {d} -> {d}\n", .{ raw, doubled });
    }
}

// --------------------------------------------------------- //

// Stage C: read results and print final output
const StageCCap = struct {
    in: *ResultChan,
    io: std.Io,
};

fn stageC(cap: StageCCap) void {
    var total: u64 = 0;
    while (true) {
        const result = cap.in.recv(cap.io) catch |err| {
            if (err != error.Closed) std.debug.print("stage_c: recv error: {}\n", .{err});
            break;
        };
        total += result;
        std.debug.print("stage_c: result={d}  running_sum={d}\n", .{ result, total });
    }
    std.debug.print("stage_c: pipeline done, total={d}\n", .{total});
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    _ = process;

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ch1 = try RawChan.init(std.heap.smp_allocator, 4);
    defer ch1.deinit();
    var ch2 = try ResultChan.init(std.heap.smp_allocator, 4);
    defer ch2.deinit();

    const ta = try std.Thread.spawn(.{}, stageA, .{StageACap{ .ch = &ch1, .io = io }});
    const tb = try std.Thread.spawn(.{}, stageB, .{StageBCap{ .in = &ch1, .out = &ch2, .io = io }});
    const tc = try std.Thread.spawn(.{}, stageC, .{StageCCap{ .in = &ch2, .io = io }});

    ta.join();
    tb.join();
    tc.join();
}
