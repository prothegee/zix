//! zix tcp .MIXED dispatch model.

const std = @import("std");
const Config = @import("../config.zig");
const TcpServerConfig = Config.TcpServerConfig;
const common = @import("common.zig");
const logSystem = common.logSystem;
const HandlerFn = common.HandlerFn;
const ConnTask = common.ConnTask;
const dispatchConn = common.dispatchConn;
const applyConnTimeout = common.applyConnTimeout;

// --------------------------------------------------------- //

// Accept thread for MIXED dispatch: dispatches each accepted connection via io.async().
fn asyncWorkerEntry(cfg: TcpServerConfig, io: std.Io, handler: HandlerFn) void {
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

        _ = io.async(dispatchConn, .{ConnTask{ .stream = stream, .io = io, .handler = handler, .logger = cfg.logger }});
    }
}

// --------------------------------------------------------- //
// MIXED model

pub fn runMixed(cfg: TcpServerConfig, handler: HandlerFn) !void {
    const io = cfg.io;
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

    logSystem(cfg, "listening on {s}:{d} (mixed/{d})", .{ cfg.ip, cfg.port, worker_count });

    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(acc_threads);
    for (acc_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, asyncWorkerEntry, .{ cfg, io, handler });
    }

    for (acc_threads) |t| t.join();
}
