//! zix http .POOL dispatch model: accept threads enqueue connections, a pool of
//! worker threads pop and handle each one synchronously with blocking I/O.

const std = @import("std");
const common = @import("common.zig");
const logSystem = common.logSystem;
const handleConnection = common.handleConnection;
const conn_queue_initial_cap = common.conn_queue_initial_cap;

// --------------------------------------------------------- //

// Work queue shared between accept threads (producers) and pool threads (consumers).
// Accept threads push accepted streams immediately and never block on handling.
// Pool threads pop and handle each connection synchronously (blocking I/O, no scheduler).
// Implemented as a heap-backed ring buffer: push and pop are both O(1).
// The backing buffer doubles on overflow (initial capacity conn_queue_initial_cap), allocated via smp_allocator.
pub const ConnQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    buf: []std.Io.net.Stream = &.{},
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,

    // Push a new connection. Grows the ring buffer on overflow.
    // On OOM (Out Of Memory) the stream is closed and the connection dropped.
    fn push(self: *ConnQueue, stream: std.Io.net.Stream, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        if (self.len == self.buf.len) {
            const new_cap = if (self.buf.len == 0) conn_queue_initial_cap else self.buf.len * 2;
            const new_buf = std.heap.smp_allocator.alloc(std.Io.net.Stream, new_cap) catch {
                self.mutex.unlock(io);
                stream.close(io);
                return;
            };
            if (self.buf.len > 0) {
                for (0..self.len) |i| new_buf[i] = self.buf[(self.head + i) % self.buf.len];
                std.heap.smp_allocator.free(self.buf);
            }
            self.buf = new_buf;
            self.head = 0;
        }
        self.buf[(self.head + self.len) % self.buf.len] = stream;
        self.len += 1;
        self.mutex.unlock(io);
        self.ready.signal(io);
    }

    // Pop the next connection, blocking until one arrives.
    // Returns null only after close() has been called and the queue is empty.
    fn pop(self: *ConnQueue, io: std.Io) ?std.Io.net.Stream {
        self.mutex.lockUncancelable(io);
        while (self.len == 0) {
            if (self.closed) {
                self.mutex.unlock(io);
                return null;
            }
            self.ready.waitUncancelable(io, &self.mutex);
        }
        const stream = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        self.len -= 1;
        self.mutex.unlock(io);
        return stream;
    }

    // Signal all waiting pool threads to drain and exit.
    fn close(self: *ConnQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.mutex.unlock(io);
        self.ready.broadcast(io);
    }

    fn deinit(self: *ConnQueue) void {
        if (self.buf.len > 0) std.heap.smp_allocator.free(self.buf);
    }
};

// --------------------------------------------------------- //

/// Accept thread: accepts connections and enqueues them immediately.
/// Stays in the accept loop at all times. Does not handle I/O.
///
/// Note:
/// - reuse_address = true sets SO_REUSEADDR + SO_REUSEPORT on POSIX,
///   allowing all accept threads to listen on the same port in parallel
fn workerEntry(server: anytype, queue: *ConnQueue, io: std.Io) void {
    const cfg = server.config;

    const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
        logSystem(cfg, "worker resolve error: {}", .{err});
        return;
    };
    var net_server = addr.listen(io, .{
        .mode = .stream,
        .kernel_backlog = @intCast(cfg.kernel_backlog),
        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
    }) catch |err| {
        logSystem(cfg, "worker listen error: {}", .{err});
        return;
    };
    defer net_server.deinit(io);

    while (true) {
        const stream = net_server.accept(io) catch |err| {
            if (err != error.ConnectionAborted) {
                logSystem(cfg, "worker accept error: {}", .{err});
                break;
            }
            continue;
        };
        queue.push(stream, io);
    }
}

/// Pool thread: pops connections from the queue and handles each one
/// synchronously with blocking I/O (no scheduler, no fiber overhead).
/// Exits when the queue is closed and drained.
fn poolEntry(server: anytype, queue: *ConnQueue, io: std.Io) void {
    while (queue.pop(io)) |stream| {
        handleConnection(stream, io, server);
    }
}

// --------------------------------------------------------- //
// POOL model

pub fn runPool(server: anytype, io: std.Io, cpu: usize) !void {
    const cfg = server.config;
    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;
    const pool_size = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

    logSystem(cfg, "listening on {s}:{d} ({d} accept, {d} pool)", .{ cfg.ip, cfg.port, worker_count, pool_size });

    var queue = ConnQueue{};
    defer queue.deinit();

    const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_size);
    defer std.heap.smp_allocator.free(pool_threads);
    for (pool_threads) |*t| {
        t.* = try std.Thread.spawn(
            .{ .stack_size = 512 * 1024 },
            poolEntry,
            .{ server, &queue, io },
        );
    }

    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(acc_threads);
    for (acc_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, workerEntry, .{ server, &queue, io });
    }

    for (acc_threads) |t| t.join();
    queue.close(io);
    for (pool_threads) |t| t.join();
}
