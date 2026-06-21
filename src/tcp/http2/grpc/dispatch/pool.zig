//! zix grpc .POOL dispatch model.

const std = @import("std");
const core = @import("../core.zig");
const GrpcServerConfig = @import("../config.zig").GrpcServerConfig;
const Route = core.Route;
const common = @import("common.zig");
const logSystem = common.logSystem;
const ConnQueue = common.ConnQueue;
const WorkerCtx = common.WorkerCtx;
const workerEntry = common.workerEntry;

// --------------------------------------------------------- //
// POOL model

pub fn runPool(comptime routes: []const Route, cfg: GrpcServerConfig) !void {
    const D = common.Dispatch(routes);
    const io = cfg.io;
    const cpu = try std.Thread.getCpuCount();
    const opts = common.serveOpts(cfg);
    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;
    const pool_count = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

    logSystem(cfg, "listening on {s}:{d} (pool/{d}x{d})", .{ cfg.ip, cfg.port, worker_count, pool_count });

    var queue = ConnQueue{};
    defer queue.deinit();

    const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_count);
    defer std.heap.smp_allocator.free(pool_threads);
    for (pool_threads) |*t|
        t.* = try std.Thread.spawn(
            .{ .stack_size = 512 * 1024 },
            D.poolEntry,
            .{D.PoolCtx{ .queue = &queue, .io = io, .opts = opts }},
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
            }},
        );

    for (acc_threads) |t| t.join();
    queue.close(io);
    for (pool_threads) |t| t.join();
}
