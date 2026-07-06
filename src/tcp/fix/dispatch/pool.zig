//! zix fix .POOL dispatch model.

const std = @import("std");
const core = @import("../core.zig");
const FixServerConfig = @import("../config.zig").FixServerConfig;
const FixServeOpts = core.FixServeOpts;
const common = @import("common.zig");
const logSystem = common.logSystem;
const dispatchConn = common.dispatchConn;

/// Stack size for the accept worker threads. These only run the accept loop and
/// hand connections to the pool, so they need far less stack than the pool
/// workers (which use cfg.worker_stack_size_bytes for the handler frames).
const ACCEPT_WORKER_STACK_BYTES: usize = 256 * 1024;

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

const WorkerCtx = struct {
    queue: *ConnQueue,
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    opts: FixServeOpts,
};

fn workerEntry(ctx: WorkerCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch |err| {
        if (ctx.opts.logger) |lg| lg.system(.ERROR, "fix", "resolve error: {}", .{err});
        return;
    };
    var listener = addr.listen(ctx.io, .{
        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
        .kernel_backlog = ctx.kernel_backlog,
    }) catch |err| {
        if (ctx.opts.logger) |lg| lg.system(.ERROR, "fix", "listen error: {}", .{err});
        return;
    };
    defer listener.deinit(ctx.io);

    while (true) {
        const stream = listener.accept(ctx.io) catch |err| {
            if (err != error.ConnectionAborted) {
                if (ctx.opts.logger) |lg| lg.system(.WARN, "fix", "accept error: {}", .{err});
                break;
            }
            continue;
        };
        ctx.queue.push(stream, ctx.io);
    }
}

const PoolCtx = struct {
    queue: *ConnQueue,
    io: std.Io,
    comp_id: []const u8,
    opts: FixServeOpts,
};

fn poolEntry(ctx: PoolCtx) void {
    while (ctx.queue.pop(ctx.io)) |stream| {
        dispatchConn(.{ .stream = stream, .io = ctx.io, .comp_id = ctx.comp_id, .opts = ctx.opts });
    }
}

// --------------------------------------------------------- //
// POOL model

pub fn runPool(cfg: FixServerConfig, conn_opts: FixServeOpts) !void {
    const io = cfg.io;
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;
    const pool_count = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

    logSystem(cfg, "listening on {s}:{d} (pool/{d}x{d})", .{ cfg.ip, cfg.port, worker_count, pool_count });

    var queue = ConnQueue{};
    defer queue.deinit();

    const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_count);
    defer std.heap.smp_allocator.free(pool_threads);
    for (pool_threads) |*t|
        t.* = try std.Thread.spawn(
            .{ .stack_size = cfg.pool_stack_size_bytes },
            poolEntry,
            .{PoolCtx{ .queue = &queue, .io = io, .comp_id = cfg.comp_id, .opts = conn_opts }},
        );

    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(acc_threads);
    for (acc_threads) |*t|
        t.* = try std.Thread.spawn(
            .{ .stack_size = ACCEPT_WORKER_STACK_BYTES },
            workerEntry,
            .{WorkerCtx{
                .queue = &queue,
                .io = io,
                .ip = cfg.ip,
                .port = cfg.port,
                .kernel_backlog = cfg.kernel_backlog,
                .opts = conn_opts,
            }},
        );

    for (acc_threads) |t| t.join();
    queue.close(io);
    for (pool_threads) |t| t.join();
}
