//! zix http2 .MIXED dispatch model.

const std = @import("std");
const core = @import("../core.zig");
const Http2ServerConfig = @import("../config.zig").Http2ServerConfig;
const common = @import("common.zig");
const logSystem = common.logSystem;

// --------------------------------------------------------- //
// MIXED model

pub fn runMixed(handler: core.HandlerFn, cfg: Http2ServerConfig) !void {
    const io = cfg.io;
    const cpu = try std.Thread.getCpuCount();
    const opts = common.serveOpts(cfg);
    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

    logSystem(cfg, "listening on {s}:{d} (mixed/{d})", .{ cfg.ip, cfg.port, worker_count });

    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(acc_threads);
    for (acc_threads) |*t|
        t.* = try std.Thread.spawn(
            .{},
            common.asyncWorkerEntry,
            .{common.AsyncWorkerCtx{
                .io = io,
                .ip = cfg.ip,
                .port = cfg.port,
                .kernel_backlog = cfg.kernel_backlog,
                .opts = opts,
                .handler = handler,
            }},
        );

    for (acc_threads) |t| t.join();
}
