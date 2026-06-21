//! zix fix .MIXED dispatch model.

const std = @import("std");
const core = @import("../core.zig");
const FixServerConfig = @import("../config.zig").FixServerConfig;
const FixServeOpts = core.FixServeOpts;
const common = @import("common.zig");
const logSystem = common.logSystem;
const ConnTask = common.ConnTask;
const dispatchConn = common.dispatchConn;

// --------------------------------------------------------- //

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
    var listener = addr.listen(ctx.io, .{
        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
        .kernel_backlog = ctx.kernel_backlog,
    }) catch return;
    defer listener.deinit(ctx.io);

    while (true) {
        const stream = listener.accept(ctx.io) catch |err| {
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
// MIXED model

pub fn runMixed(cfg: FixServerConfig, conn_opts: FixServeOpts) !void {
    const io = cfg.io;
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

    logSystem(cfg, "listening on {s}:{d} (mixed/{d})", .{ cfg.ip, cfg.port, worker_count });

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
}
