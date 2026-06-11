//! PoC: TCP Model 3: MIXED: N accept threads (SO_REUSEPORT) + io.async() per connection.
//!
//! Concurrency: N accept threads each dispatch via io.async() directly, no ConnQueue.
//! io.async() from N threads is safe (mutex-protected inside Threaded).
//! Falls back to inline on the stalled accept thread when async_limit is reached.
//!
//! Protocol: length-prefix framing, [4 bytes u32 big-endian][N bytes payload].
//! Server echoes each message back verbatim.
//!
//! Self-contained: no imports from zix src.
//!
//! Run:  zig run rnd/tcp_poc_model_3_mixed.zig
//! Test: zig run rnd/tcp_poc_client.zig  (PORT = 9202)

const std = @import("std");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9202;
const MAX_MSG: usize = 4096;
const RESPONSE: []const u8 = "Hi from TCP Server";
const WORKERS: usize = 0; // 0 = cpu_count accept threads

// --------------------------------------------------------- //

fn handleConnection(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);

    var rd_buf: [MAX_MSG + 4]u8 = undefined;
    var wr_buf: [MAX_MSG + 4]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    while (true) {
        const len = rd.interface.takeVarInt(u32, .big, 4) catch break;
        if (len == 0 or len > MAX_MSG) break;

        var body: [MAX_MSG]u8 = undefined;
        rd.interface.readSliceAll(body[0..len]) catch break;

        std.debug.print("recv ({d} bytes): {s}\n", .{ len, body[0..len] });

        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(RESPONSE.len), .big);
        wr.interface.writeAll(&hdr) catch break;
        wr.interface.writeAll(RESPONSE) catch break;
        wr.interface.flush() catch break;
    }
}

// --------------------------------------------------------- //

fn acceptEntry(io: std.Io) void {
    const addr = std.Io.net.IpAddress.resolve(io, IP, PORT) catch return;
    var net_server = addr.listen(io, .{
        .mode = .stream,
        .protocol = .tcp,
        .reuse_address = true,
        .kernel_backlog = 4096,
    }) catch return;
    defer net_server.deinit(io);

    while (true) {
        const stream = net_server.accept(io) catch continue;
        _ = io.async(handleConnection, .{ stream, io });
    }
}

// --------------------------------------------------------- //

pub fn main() !void {
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (WORKERS == 0) cpu else WORKERS;

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("zix tcp server (mixed): {s}:{d} ({d} accept)\n", .{ IP, PORT, worker_count });

    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(acc_threads);
    for (acc_threads) |*t|
        t.* = try std.Thread.spawn(.{}, acceptEntry, .{io});

    for (acc_threads) |t| t.join();
}
