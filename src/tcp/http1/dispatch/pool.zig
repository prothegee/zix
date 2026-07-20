//! zix http1 .POOL dispatch model.

const std = @import("std");
const Config = @import("../config.zig").Http1ServerConfig;
const core = @import("../core.zig");
const HandlerFn = core.HandlerFn;
const common = @import("common.zig");
const logSystem = common.logSystem;

/// Initial slot count of the connection handoff queue before it doubles.
const CONN_QUEUE_INIT_CAP: usize = 16;

/// Auto pool sizing when config.pool_size is 0: max(floor, cpu * multiplier).
const POOL_SIZE_FLOOR: usize = 10;
const POOL_CPU_MULTIPLIER: usize = 2;

// --------------------------------------------------------- //
// POOL model

const ConnQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    buf: []std.Io.net.Stream = &.{},
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,

    fn push(self: *ConnQueue, stream: std.Io.net.Stream, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        if (self.len == self.buf.len) {
            const new_cap = if (self.buf.len == 0) CONN_QUEUE_INIT_CAP else self.buf.len * 2;
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

const PoolCtx = struct { queue: *ConnQueue, io: std.Io, handler: HandlerFn, handler_timeout_ms: u32 = 0, conn_timeout_ms: u32 = 0, registry: ?*common.ConnRegistry = null, send_date_header: bool = true, large_body_rcvbuf: usize = 0, public_dir: []const u8 = "", max_response_headers: usize = 16 };

const AcceptCtx = struct {
    queue: *ConnQueue,
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
};

fn poolEntry(ctx: PoolCtx) void {
    core.setDateHeader(ctx.send_date_header);
    core.setStatic(ctx.public_dir, ctx.io);
    core.setMaxResponseHeaders(ctx.max_response_headers);

    while (ctx.queue.pop(ctx.io)) |stream| {
        defer stream.close(ctx.io);
        const fd = stream.socket.handle;

        var guard: ?common.ConnEntry = null;
        if (ctx.registry) |registry| {
            guard = common.ConnEntry{ .fd = fd, .deadline = common.connDeadline(ctx.io, ctx.conn_timeout_ms) };
            registry.register(&guard.?, ctx.io);
        }
        defer if (ctx.registry) |registry| registry.deregister(&guard.?, ctx.io);

        core.serveConn(fd, ctx.handler, .{ .handler_timeout_ms = ctx.handler_timeout_ms, .large_body_rcvbuf = ctx.large_body_rcvbuf }, ctx.io);
    }
}

fn acceptEntry(ctx: AcceptCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
    var srv = addr.listen(ctx.io, .{
        .mode = .stream,
        .kernel_backlog = ctx.kernel_backlog,
        .reuse_address = true,
    }) catch return;
    defer srv.deinit(ctx.io);

    while (true) {
        const stream = srv.accept(ctx.io) catch continue;
        ctx.queue.push(stream, ctx.io);
    }
}

pub fn runPool(config: Config, handler: HandlerFn) !void {
    const io = config.io;
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (config.workers == 0) cpu else config.workers;
    const pool_count = if (config.pool_size == 0) @max(POOL_SIZE_FLOOR, cpu * POOL_CPU_MULTIPLIER) else config.pool_size;

    logSystem(config, "listening on {s}:{d} ({d} accept, {d} pool)", .{ config.ip, config.port, worker_count, pool_count });

    var queue = ConnQueue{};
    defer queue.deinit();

    var conn_registry = common.ConnRegistry{};
    const registry: ?*common.ConnRegistry = if (config.conn_timeout_ms > 0) &conn_registry else null;
    if (config.conn_timeout_ms > 0) {
        const sweeper = try std.Thread.spawn(.{}, common.connTimerLoop, .{ io, &conn_registry });
        sweeper.detach();
    }

    const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_count);
    defer std.heap.smp_allocator.free(pool_threads);
    for (pool_threads) |*t| {
        t.* = try std.Thread.spawn(
            .{ .stack_size = config.worker_stack_size_bytes },
            poolEntry,
            .{PoolCtx{ .queue = &queue, .io = io, .handler = handler, .handler_timeout_ms = config.handler_timeout_ms, .conn_timeout_ms = config.conn_timeout_ms, .registry = registry, .send_date_header = config.send_date_header, .large_body_rcvbuf = config.large_body_rcvbuf, .public_dir = config.public_dir, .max_response_headers = config.max_response_headers.value() }},
        );
    }

    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(acc_threads);
    for (acc_threads) |*t| {
        t.* = try std.Thread.spawn(
            .{ .stack_size = common.ACCEPT_STACK },
            acceptEntry,
            .{AcceptCtx{ .queue = &queue, .io = io, .ip = config.ip, .port = config.port, .kernel_backlog = config.kernel_backlog }},
        );
    }

    for (acc_threads) |t| t.join();
    queue.close(io);
    for (pool_threads) |t| t.join();
}
