// channel_basic.zig: producer/consumer pipeline via Channel(u32)
//
// Producer sends task IDs 1..10 into a buffered channel.
// Consumer reads each ID, computes ID * ID, and prints the result.
// Both run as OS threads sharing the same Channel.
//
// Channel uses std.Io.Mutex + std.Io.Condition for fiber-aware blocking.
// std.Io.Threaded provides the IO backend for spawned OS threads.
//
// Run:
// zig build example-channel_basic && ./zig-out/bin/example-channel_basic

const std = @import("std");
const zix = @import("zix");

const MyChan = zix.Channel(u32);

// Logger config — uncomment this section to add logger
// const LOG_DIR: []const u8  = "./logs";
// const LOG_FILE: []const u8 = "channel";

// fn createLogDir(io: std.Io) void {
//     std.Io.Dir.cwd().createDirPath(io, LOG_DIR) catch {};
// }

// --------------------------------------------------------- //

const ProducerCap = struct {
    ch: *MyChan,
    io: std.Io,
};

fn producer(cap: ProducerCap) void {
    defer cap.ch.close(cap.io);
    for (1..11) |i| {
        cap.ch.send(cap.io, @intCast(i)) catch |err| {
            std.debug.print("producer: send error: {}\n", .{err});
            return;
        };
        std.debug.print("producer: sent task {d}\n", .{i});
    }
}

// --------------------------------------------------------- //

const ConsumerCap = struct {
    ch: *MyChan,
    io: std.Io,
};

fn consumer(cap: ConsumerCap) void {
    var total: u32 = 0;
    while (true) {
        const id = cap.ch.recv(cap.io) catch |err| {
            if (err != error.Closed) std.debug.print("consumer: recv error: {}\n", .{err});
            break;
        };
        const result = id * id;
        std.debug.print("consumer: task {d} -> {d}\n", .{ id, result });
        total += 1;
    }
    std.debug.print("consumer: processed {d} tasks\n", .{total});
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

    // std.Io.Threaded provides the fiber-aware IO backend for OS threads.
    // Channel.send() and recv() call lockUncancelable(io) which requires
    // an IO that is valid on the calling thread.
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try MyChan.init(std.heap.smp_allocator, 4);
    defer ch.deinit();

    const producer_thread = try std.Thread.spawn(.{}, producer, .{ProducerCap{ .ch = &ch, .io = io }});
    const consumer_thread = try std.Thread.spawn(.{}, consumer, .{ConsumerCap{ .ch = &ch, .io = io }});

    producer_thread.join();
    consumer_thread.join();
}
