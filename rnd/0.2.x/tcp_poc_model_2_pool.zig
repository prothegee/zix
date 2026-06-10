//! PoC: TCP Model 2 — POOL — N accept threads + ConnQueue + M pool threads.
//!
//! Concurrency: N accept threads (SO_REUSEPORT) push accepted connections to a
//! shared ConnQueue. M pool threads block on ConnQueue.pop() and handle each
//! connection synchronously. Pool is fixed at startup — all threads pre-warmed.
//!
//! Protocol: length-prefix framing — [4 bytes u32 big-endian][N bytes payload].
//! Server echoes each message back verbatim.
//!
//! Self-contained: no imports from zix src.
//!
//! Run:  zig run rnd/tcp_poc_model_2_pool.zig
//! Test: zig run rnd/tcp_poc_client.zig  (PORT = 9201)

const std = @import("std");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9201;
const MAX_MSG: usize = 4096;
const RESPONSE: []const u8 = "Hi from TCP Server";
const WORKERS: usize = 0; // 0 = cpu_count accept threads
const POOL_SIZE: usize = 0; // 0 = @max(10, cpu_count * 2) pool threads

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

const ConnQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    items: std.ArrayListUnmanaged(std.Io.net.Stream) = .empty,
    closed: bool = false,

    fn push(self: *ConnQueue, stream: std.Io.net.Stream, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.items.append(std.heap.smp_allocator, stream) catch {
            self.mutex.unlock(io);
            stream.close(io);
            return;
        };
        self.mutex.unlock(io);
        self.ready.signal(io);
    }

    fn pop(self: *ConnQueue, io: std.Io) ?std.Io.net.Stream {
        self.mutex.lockUncancelable(io);
        while (self.items.items.len == 0) {
            if (self.closed) {
                self.mutex.unlock(io);
                return null;
            }
            self.ready.waitUncancelable(io, &self.mutex);
        }
        const stream = self.items.orderedRemove(0);
        self.mutex.unlock(io);
        return stream;
    }

    fn close(self: *ConnQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.mutex.unlock(io);
        self.ready.broadcast(io);
    }

    fn deinit(self: *ConnQueue) void {
        self.items.deinit(std.heap.smp_allocator);
    }
};

// --------------------------------------------------------- //

const PoolCtx = struct { queue: *ConnQueue, io: std.Io };
const AcceptCtx = struct { queue: *ConnQueue, io: std.Io };

fn poolEntry(ctx: PoolCtx) void {
    while (ctx.queue.pop(ctx.io)) |stream| handleConnection(stream, ctx.io);
}

fn acceptEntry(ctx: AcceptCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, IP, PORT) catch return;
    var net_server = addr.listen(ctx.io, .{
        .mode = .stream,
        .protocol = .tcp,
        .reuse_address = true,
        .kernel_backlog = 4096,
    }) catch return;
    defer net_server.deinit(ctx.io);

    while (true) {
        const stream = net_server.accept(ctx.io) catch continue;
        ctx.queue.push(stream, ctx.io);
    }
}

// --------------------------------------------------------- //

pub fn main() !void {
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (WORKERS == 0) cpu else WORKERS;
    const pool_count = if (POOL_SIZE == 0) @max(10, cpu * 2) else POOL_SIZE;

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var queue = ConnQueue{};
    defer queue.deinit();

    std.debug.print("zix tcp server (pool): {s}:{d} ({d} accept, {d} pool)\n", .{
        IP, PORT, worker_count, pool_count,
    });

    const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_count);
    defer std.heap.smp_allocator.free(pool_threads);
    for (pool_threads) |*t|
        t.* = try std.Thread.spawn(
            .{ .stack_size = 512 * 1024 },
            poolEntry,
            .{PoolCtx{ .queue = &queue, .io = io }},
        );

    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(acc_threads);
    for (acc_threads) |*t|
        t.* = try std.Thread.spawn(.{}, acceptEntry, .{AcceptCtx{ .queue = &queue, .io = io }});

    for (acc_threads) |t| t.join();
    queue.close(io);
    for (pool_threads) |t| t.join();
}
