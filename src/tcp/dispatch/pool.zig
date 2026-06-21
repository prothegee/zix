//! zix tcp .POOL dispatch model.

const std = @import("std");
const Config = @import("../config.zig");
const TcpServerConfig = Config.TcpServerConfig;
const Logger = @import("../../logger/logger.zig").Logger;
const common = @import("common.zig");
const logSystem = common.logSystem;
const HandlerFn = common.HandlerFn;
const getPeerAddr = common.getPeerAddr;
const getMonotonicMs = common.getMonotonicMs;
const applyConnTimeout = common.applyConnTimeout;

// --------------------------------------------------------- //

// Work queue shared between accept threads (producers) and pool threads (consumers).
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

// Accept thread for POOL dispatch: pushes accepted connections to the shared queue.
fn workerEntry(cfg: TcpServerConfig, queue: *ConnQueue, io: std.Io) void {
    const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
        if (cfg.logger) |lg| lg.system(.ERROR, "tcp", "resolve error: {}", .{err});
        return;
    };
    var net_server = addr.listen(io, .{
        .mode = .stream,
        .protocol = .tcp,
        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
        .kernel_backlog = cfg.kernel_backlog,
    }) catch |err| {
        if (cfg.logger) |lg| lg.system(.ERROR, "tcp", "listen error: {}", .{err});
        return;
    };
    defer net_server.deinit(io);

    while (true) {
        const stream = net_server.accept(io) catch |err| {
            if (err != error.ConnectionAborted) {
                if (cfg.logger) |lg| lg.system(.WARN, "tcp", "accept error: {}", .{err});
                break;
            }
            continue;
        };
        applyConnTimeout(stream.socket.handle, cfg.recv_timeout_ms, cfg.send_timeout_ms);

        queue.push(stream, io);
    }
}

// Pool thread: pops connections from the shared queue and dispatches each to handler.
fn poolEntry(queue: *ConnQueue, io: std.Io, handler: HandlerFn, logger: ?*Logger) void {
    while (queue.pop(io)) |stream| {
        var peer_buf: [64]u8 = undefined;
        const peer = getPeerAddr(stream.socket.handle, &peer_buf);
        const start = getMonotonicMs();
        handler(stream, io);
        if (logger) |lg| lg.conn(peer, getMonotonicMs() - start, null);
    }
}

// --------------------------------------------------------- //
// POOL model

pub fn runPool(cfg: TcpServerConfig, handler: HandlerFn) !void {
    const io = cfg.io;
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;
    const pool_count = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

    logSystem(cfg, "listening on {s}:{d} (pool/{d}x{d})", .{ cfg.ip, cfg.port, worker_count, pool_count });

    var queue = ConnQueue{};
    defer queue.deinit();

    const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_count);
    defer std.heap.smp_allocator.free(pool_threads);
    for (pool_threads) |*t| {
        t.* = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, poolEntry, .{ &queue, io, handler, cfg.logger });
    }

    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(acc_threads);
    for (acc_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, workerEntry, .{ cfg, &queue, io });
    }

    for (acc_threads) |t| t.join();
    queue.close(io);
    for (pool_threads) |t| t.join();
}
