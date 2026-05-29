//! zix fix server — all 3 dispatch models for FIX 4.x session protocol.

const std = @import("std");
const core = @import("core.zig");
const FixServerConfig = @import("config.zig").FixServerConfig;
const DispatchModel = @import("../config.zig").DispatchModel;
const FixServeOpts = core.FixServeOpts;
const Logger = @import("../../logger/logger.zig").Logger;

// --------------------------------------------------------- //

const ConnTask = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    comp_id: []const u8,
    opts: FixServeOpts,
};

fn dispatchConn(task: ConnTask) void {
    core.serveConn(task.stream, task.io, task.comp_id, task.opts) catch {};
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
    var srv = addr.listen(ctx.io, .{
        .reuse_address = true,
        .kernel_backlog = ctx.kernel_backlog,
    }) catch |err| {
        if (ctx.opts.logger) |lg| lg.system(.ERROR, "fix", "listen error: {}", .{err});
        return;
    };
    defer srv.deinit(ctx.io);
    while (true) {
        const stream = srv.accept(ctx.io) catch |err| {
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

const AsyncWorkerCtx = struct {
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    comp_id: []const u8,
    opts: FixServeOpts,
};

fn asyncWorkerEntry(ctx: AsyncWorkerCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
    var srv = addr.listen(ctx.io, .{
        .reuse_address = true,
        .kernel_backlog = ctx.kernel_backlog,
    }) catch return;
    defer srv.deinit(ctx.io);
    while (true) {
        const stream = srv.accept(ctx.io) catch |err| {
            if (err != error.ConnectionAborted) break;
            continue;
        };
        _ = ctx.io.async(dispatchConn, .{ConnTask{
            .stream = stream,
            .io = ctx.io,
            .comp_id = ctx.comp_id,
            .opts = ctx.opts,
        }});
    }
}

// --------------------------------------------------------- //

/// FIX 4.x session server. Dispatches connections via POOL, ASYNC, or MIXED.
/// Session logic (Logon, Logout, Heartbeat, echo) is handled by Fix.serveConn.
///
/// Usage:
///   var server = try FixServer.init(.{ .io = io, .ip = "0.0.0.0", .port = 9500, .comp_id = "SRV" });
///   defer server.deinit();
///   try server.run();
pub const FixServer = struct {
    const Self = @This();

    config: FixServerConfig,

    // --------------------------------------------------------- //

    /// Initialize. Returns error.PortNotConfigured if config.port is 0.
    pub fn init(config: FixServerConfig) !Self {
        if (config.port == 0) return error.PortNotConfigured;
        return .{ .config = config };
    }

    /// No-op: resources released inside run via defer.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Listen and serve FIX sessions using the server's comp_id.
    pub fn run(self: *Self) !void {
        const cfg = self.config;
        const io = cfg.io;
        const cpu = try std.Thread.getCpuCount();
        const conn_opts = FixServeOpts{
            .logger = cfg.logger,
            .heartbeat_timeout_ms = cfg.heartbeat_timeout_ms,
        };

        switch (cfg.dispatch_model) {
            .ASYNC => {
                if (cfg.logger) |lg| lg.system(.INFO, "fix", "listening on {s}:{d} (async)", .{ cfg.ip, cfg.port });

                const addr = try std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port);
                var srv = try addr.listen(io, .{
                    .reuse_address = true,
                    .kernel_backlog = cfg.kernel_backlog,
                });
                defer srv.deinit(io);

                while (true) {
                    const stream = srv.accept(io) catch |err| {
                        if (err != error.ConnectionAborted) break;
                        continue;
                    };
                    _ = io.async(dispatchConn, .{ConnTask{
                        .stream = stream,
                        .io = io,
                        .comp_id = cfg.comp_id,
                        .opts = conn_opts,
                    }});
                }
            },

            // EPOLL is HTTP-only. The FIX server falls back to the POOL model.
            .POOL, .EPOLL => {
                const worker_count = if (cfg.workers == 0) cpu else cfg.workers;
                const pool_count = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

                if (cfg.logger) |lg| lg.system(.INFO, "fix", "listening on {s}:{d} (pool/{d}x{d})", .{ cfg.ip, cfg.port, worker_count, pool_count });

                var queue = ConnQueue{};
                defer queue.deinit();

                const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_count);
                defer std.heap.smp_allocator.free(pool_threads);
                for (pool_threads) |*t|
                    t.* = try std.Thread.spawn(
                        .{ .stack_size = 256 * 1024 },
                        poolEntry,
                        .{PoolCtx{ .queue = &queue, .io = io, .comp_id = cfg.comp_id, .opts = conn_opts }},
                    );

                const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
                defer std.heap.smp_allocator.free(acc_threads);
                for (acc_threads) |*t|
                    t.* = try std.Thread.spawn(
                        .{ .stack_size = 256 * 1024 },
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
            },

            .MIXED => {
                const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

                if (cfg.logger) |lg| lg.system(.INFO, "fix", "listening on {s}:{d} (mixed/{d})", .{ cfg.ip, cfg.port, worker_count });

                const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
                defer std.heap.smp_allocator.free(acc_threads);
                for (acc_threads) |*t|
                    t.* = try std.Thread.spawn(
                        .{},
                        asyncWorkerEntry,
                        .{AsyncWorkerCtx{
                            .io = io,
                            .ip = cfg.ip,
                            .port = cfg.port,
                            .kernel_backlog = cfg.kernel_backlog,
                            .comp_id = cfg.comp_id,
                            .opts = conn_opts,
                        }},
                    );

                for (acc_threads) |t| t.join();
            },
        }
    }
};

// --------------------------------------------------------- //

test "zix fix: FixServer.init, port zero returns PortNotConfigured" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(
        error.PortNotConfigured,
        FixServer.init(.{ .io = io, .ip = "127.0.0.1", .port = 0, .comp_id = "SERVER" }),
    );
}

test "zix fix: FixServer.init, valid config succeeds and deinit is safe" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try FixServer.init(.{ .io = io, .ip = "127.0.0.1", .port = 9500, .comp_id = "SERVER" });
    server.deinit();
}
