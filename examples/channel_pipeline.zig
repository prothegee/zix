// channel_pipeline.zig: 3-stage data pipeline via chained channels
//
// Stage A generates raw values and sends to ch1.
// Stage B reads from ch1, doubles each value, sends to ch2.
// Stage C reads from ch2, formats and prints the final result.
//
// Each stage runs as an independent thread. Channels decouple the stages:
// each runs at its own pace, backpressure flows upstream when a stage is slow.
//
// ```mermaid
// flowchart LR
//     stage_a --> ch1["Channel(u32) ch1"]
//     ch1 --> stage_b
//     stage_b --> ch2["Channel(u64) ch2"]
//     ch2 --> stage_c
// ```
//
// Run:
// zig build example-channel_pipeline && ./zig-out/bin/example-channel_pipeline

const std = @import("std");
const zix = @import("zix");

const ITEM_COUNT: u32 = 10;

const RawChan = zix.Channel(u32);
const ResultChan = zix.Channel(u64);

// Logger config — uncomment this section to add logger
// const LOG_DIR: []const u8  = "./logs";
// const LOG_FILE: []const u8 = "channel";

// fn createLogDir(io: std.Io) void {
//     std.Io.Dir.cwd().createDirPath(io, LOG_DIR) catch {};
// }

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

    var ch1 = try RawChan.init(std.heap.smp_allocator, 4);
    defer ch1.deinit();
    var ch2 = try ResultChan.init(std.heap.smp_allocator, 4);
    defer ch2.deinit();

    const thread_a = try std.Thread.spawn(.{}, stageA, .{StageACap{ .ch = &ch1, .io = io }});
    const thread_b = try std.Thread.spawn(.{}, stageB, .{StageBCap{ .in = &ch1, .out = &ch2, .io = io }});
    const thread_c = try std.Thread.spawn(.{}, stageC, .{StageCCap{ .in = &ch2, .io = io }});

    thread_a.join();
    thread_b.join();
    thread_c.join();
}
