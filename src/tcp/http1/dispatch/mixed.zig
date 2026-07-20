//! zix http1 .MIXED dispatch model.

const std = @import("std");
const Config = @import("../config.zig").Http1ServerConfig;
const core = @import("../core.zig");
const HandlerFn = core.HandlerFn;
const common = @import("common.zig");
const logSystem = common.logSystem;
const ConnArgs = common.ConnArgs;
const connEntry = common.connEntry;

// --------------------------------------------------------- //
// MIXED model

const MixedAcceptCtx = struct {
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    handler: HandlerFn,
    handler_timeout_ms: u32 = 0,
    conn_timeout_ms: u32 = 0,
    registry: ?*common.ConnRegistry = null,
    send_date_header: bool = true,
    large_body_rcvbuf: usize = 0,
    public_dir: []const u8 = "",
    max_response_headers: usize = 16,
};

fn mixedAcceptEntry(ctx: MixedAcceptCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
    var srv = addr.listen(ctx.io, .{
        .mode = .stream,
        .kernel_backlog = ctx.kernel_backlog,
        .reuse_address = true,
    }) catch return;
    defer srv.deinit(ctx.io);

    while (true) {
        const stream = srv.accept(ctx.io) catch continue;
        _ = ctx.io.async(connEntry, .{ConnArgs{ .stream = stream, .io = ctx.io, .handler = ctx.handler, .handler_timeout_ms = ctx.handler_timeout_ms, .conn_timeout_ms = ctx.conn_timeout_ms, .registry = ctx.registry, .send_date_header = ctx.send_date_header, .large_body_rcvbuf = ctx.large_body_rcvbuf, .public_dir = ctx.public_dir, .max_response_headers = ctx.max_response_headers }});
    }
}

// --------------------------------------------------------- //

pub fn runMixed(config: Config, handler: HandlerFn) !void {
    const io = config.io;
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (config.workers == 0) cpu else config.workers;

    var conn_registry = common.ConnRegistry{};
    const registry: ?*common.ConnRegistry = if (config.conn_timeout_ms > 0) &conn_registry else null;
    if (config.conn_timeout_ms > 0) {
        const sweeper = try std.Thread.spawn(.{}, common.connTimerLoop, .{ io, &conn_registry });
        sweeper.detach();
    }

    logSystem(config, "listening on {s}:{d} ({d} accept, io.async)", .{ config.ip, config.port, worker_count });

    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(acc_threads);

    for (acc_threads) |*t| {
        // Use default stack size (.{}), serveConn uses ~128KB stack via io.async scheduler.
        // Explicit 256KB here overflows when io.async falls back to inline dispatch.
        t.* = try std.Thread.spawn(
            .{},
            mixedAcceptEntry,
            .{MixedAcceptCtx{ .io = io, .ip = config.ip, .port = config.port, .kernel_backlog = config.kernel_backlog, .handler = handler, .handler_timeout_ms = config.handler_timeout_ms, .conn_timeout_ms = config.conn_timeout_ms, .registry = registry, .send_date_header = config.send_date_header, .large_body_rcvbuf = config.large_body_rcvbuf, .public_dir = config.public_dir, .max_response_headers = config.max_response_headers.value() }},
        );
    }

    for (acc_threads) |t| t.join();
}
