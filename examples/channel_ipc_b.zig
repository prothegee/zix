// channel_ipc_b.zig: bidirectional IPC via UDS (Process B, client side)
//
// Process B connects to /tmp/zix_ipc.sock opened by Process A.
// After connecting, both sides send and receive independently at different rates.
//
// Two threads per process:
// writer: sends "B:N" every 400 ms (different rate from A to show independence)
// reader: prints whatever A sends
//
// Either side can be stopped (Ctrl-C), the other side detects the closed
// connection and exits cleanly.
//
// Start Process A first, then run this:
// zig build example-channel_ipc_b && ./zig-out/bin/example-channel_ipc_b

const std = @import("std");
const zix = @import("zix");

const SOCK_PATH: []const u8 = "/tmp/zix_ipc.sock";
const SEND_INTERVAL_MS: i64 = 400;

// Logger config: uncomment this section to add logger
// const LOG_DIR: []const u8  = "./logs";
// const LOG_FILE: []const u8 = "channel_ipc";

// fn createLogDir(io: std.Io) void {
//     std.Io.Dir.cwd().createDirPath(io, LOG_DIR) catch {};
// }

// --------------------------------------------------------- //

const WriterCap = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
};

fn writer(cap: WriterCap) void {
    var write_buf: [256]u8 = undefined;
    var stream_writer = cap.stream.writer(cap.io, &write_buf);
    var counter: u64 = 0;
    while (true) {
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "B:{d}", .{counter}) catch return;

        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(msg.len), .little);
        stream_writer.interface.writeAll(&hdr) catch return;
        stream_writer.interface.writeAll(msg) catch return;
        stream_writer.interface.flush() catch return;

        std.debug.print("B -> A  {s}\n", .{msg});
        counter += 1;

        std.Io.sleep(cap.io, std.Io.Duration.fromMilliseconds(SEND_INTERVAL_MS), .awake) catch return;
    }
}

// --------------------------------------------------------- //

const ReaderCap = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
};

fn reader(cap: ReaderCap) void {
    var read_buf: [4096]u8 = undefined;
    var payload: [4096]u8 = undefined;
    var stream_reader = cap.stream.reader(cap.io, &read_buf);

    while (true) {
        var hdr: [4]u8 = undefined;
        var n: usize = 0;
        while (n < 4) {
            const got = stream_reader.interface.readSliceShort(hdr[n..]) catch return;
            if (got == 0) return;
            n += got;
        }

        const len = std.mem.readInt(u32, &hdr, .little);
        if (len > payload.len) return;

        n = 0;
        while (n < len) {
            const got = stream_reader.interface.readSliceShort(payload[n..len]) catch return;
            if (got == 0) return;
            n += got;
        }

        std.debug.print("A -> B  {s}\n", .{payload[0..len]});
    }
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    // Uncomment this to add logger (console only, no save_path means no file output):
    // var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    //     .console           = .ALWAYS,
    //     .console_min_level = .INFO,
    // });
    // defer logger.deinit();

    // Uncomment this to add logger with file output (createLogDir must run first):
    // createLogDir(io);
    // var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    //     .save_path      = LOG_DIR,
    //     .save_file      = LOG_FILE,
    //     .save_min_level = .INFO,
    //     .console        = .ALWAYS,
    // });
    // defer logger.deinit();

    // logger.system(.INFO, "ipc", "B: connecting to " ++ SOCK_PATH, .{});

    std.debug.print("B: connecting to {s}\n", .{SOCK_PATH});
    const unix_addr = try std.Io.net.UnixAddress.init(SOCK_PATH);
    const stream = try unix_addr.connect(io);

    std.debug.print("B: connected, starting bidirectional exchange\n", .{});

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const thread_io = threaded.io();

    const writer_thread = try std.Thread.spawn(.{}, writer, .{WriterCap{ .stream = stream, .io = thread_io }});
    const reader_thread = try std.Thread.spawn(.{}, reader, .{ReaderCap{ .stream = stream, .io = thread_io }});

    writer_thread.join();
    reader_thread.join();

    stream.close(io);
    std.debug.print("B: connection closed\n", .{});
}
