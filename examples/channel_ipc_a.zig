// channel_ipc_a.zig -- bidirectional IPC via UDS (Process A, server side)
//
// Process A listens on /tmp/zix_ipc.sock and accepts one connection from Process B.
// After connecting, both sides send and receive independently at different rates.
//
// Two threads per process:
//   writer: sends "A:N" every 600 ms
//   reader: prints whatever B sends
//
// Either side can be stopped (Ctrl-C) -- the other side detects the closed
// connection and exits cleanly.
//
// Run Process A first:
//   zig build example-channel_ipc_a && ./zig-out/bin/example-channel_ipc_a
//
// Then Process B in a second terminal:
//   zig build example-channel_ipc_b && ./zig-out/bin/example-channel_ipc_b

const std = @import("std");

const SOCK_PATH: []const u8 = "/tmp/zix_ipc.sock";
const SEND_INTERVAL_MS: i64 = 600;

// --------------------------------------------------------- //

const WriterCap = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
};

fn writer(cap: WriterCap) void {
    var wbuf: [256]u8 = undefined;
    var wtr = cap.stream.writer(cap.io, &wbuf);
    var counter: u64 = 0;
    while (true) {
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "A:{d}", .{counter}) catch return;

        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(msg.len), .little);
        wtr.interface.writeAll(&hdr) catch return;
        wtr.interface.writeAll(msg) catch return;
        wtr.interface.flush() catch return;

        std.debug.print("A -> B  {s}\n", .{msg});
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
    var rbuf: [4096]u8 = undefined;
    var payload: [4096]u8 = undefined;
    var rdr = cap.stream.reader(cap.io, &rbuf);

    while (true) {
        var hdr: [4]u8 = undefined;
        var n: usize = 0;
        while (n < 4) {
            const got = rdr.interface.readSliceShort(hdr[n..]) catch return;
            if (got == 0) return;
            n += got;
        }

        const len = std.mem.readInt(u32, &hdr, .little);
        if (len > payload.len) return;

        n = 0;
        while (n < len) {
            const got = rdr.interface.readSliceShort(payload[n..len]) catch return;
            if (got == 0) return;
            n += got;
        }

        std.debug.print("B -> A  {s}\n", .{payload[0..len]});
    }
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    std.Io.Dir.deleteFileAbsolute(io, SOCK_PATH) catch {};
    const ua = try std.Io.net.UnixAddress.init(SOCK_PATH);
    var net_server = try ua.listen(io, .{ .kernel_backlog = 1 });
    defer {
        net_server.deinit(io);
        std.Io.Dir.deleteFileAbsolute(io, SOCK_PATH) catch {};
    }

    std.debug.print("A: listening on {s} -- start Process B\n", .{SOCK_PATH});
    const stream = try net_server.accept(io);

    std.debug.print("A: B connected -- starting bidirectional exchange\n", .{});

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const thread_io = threaded.io();

    const wt = try std.Thread.spawn(.{}, writer, .{WriterCap{ .stream = stream, .io = thread_io }});
    const rt = try std.Thread.spawn(.{}, reader, .{ReaderCap{ .stream = stream, .io = thread_io }});

    wt.join();
    rt.join();

    stream.close(io);
    std.debug.print("A: connection closed\n", .{});
}
