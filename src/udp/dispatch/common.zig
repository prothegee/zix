//! zix udp raw-bytes dispatch helpers (ADR-049), shared by the per-model run files.
//!
//! What:
//! - The recvmmsg worker loop and the two run shapes the models map to: `runSingle` (one worker on
//!   the calling thread) and `runPerCore` (one SO_REUSEPORT worker per CPU). The non-Linux fallback
//!   lives here too. Each `dispatch/<model>.zig` is a thin wrapper over one of these.

const std = @import("std");
const builtin = @import("builtin");

const Config = @import("../config.zig");
const UdpServerConfig = Config.UdpServerConfig;
const core = @import("../core.zig");
const datagram = @import("../datagram.zig");
const Logger = @import("../../logger/logger.zig").Logger;

const posix = std.posix;
const IpAddress = std.Io.net.IpAddress;

// --------------------------------------------------------- //

pub fn logSystem(config: UdpServerConfig, comptime fmt: []const u8, args: anytype) void {
    if (config.logger) |lg| {
        lg.system(.INFO, "udp", fmt, args);
        return;
    }

    if (comptime builtin.mode == .Debug) std.debug.print("zix udp: " ++ fmt ++ "\n", args);
}

/// Effective worker count: the configured value, or one per CPU when 0.
pub fn effectiveWorkers(config: UdpServerConfig) usize {
    if (config.workers != 0) return config.workers;

    return std.Thread.getCpuCount() catch 1;
}

/// One worker: a recvmmsg batch in, handler per datagram, sendmmsg out. `reuse` sets SO_REUSEPORT
/// (required when several workers bind the same port).
pub fn workerLoop(comptime handler: core.HandlerFn, config: UdpServerConfig, reuse: bool) void {
    const fd = datagram.open(config.ip, config.port, reuse) catch |err| {
        if (config.logger) |lg| lg.system(.ERROR, "udp", "raw bind error: {}", .{err});
        return;
    };
    defer datagram.close(fd);

    var rx = datagram.RecvBatch.init(config.allocator, config.recv_batch, config.max_recv_buf) catch return;
    defer rx.deinit();

    var tx = datagram.SendBatch.init(config.allocator, config.send_batch, config.send_batch * config.max_recv_buf) catch return;
    defer tx.deinit();

    while (true) {
        const count = rx.recv(fd) catch |err| {
            if (config.logger) |lg| lg.system(.WARN, "udp", "raw recv error: {}", .{err});
            continue;
        };

        for (0..count) |i| {
            const dg = rx.get(i);
            const peer = datagram.sockaddrToIp4(dg.from);
            var sink = core.Sink{ .batch = &tx, .fd = fd, .sender = dg.from };
            handler(dg.data, &peer, &sink);
        }

        tx.flush(fd) catch |err| {
            if (config.logger) |lg| lg.system(.WARN, "udp", "raw send error: {}", .{err});
            tx.reset();
        };
    }
}

/// Single worker on the calling thread. Used by the ASYNC / POOL / MIXED models.
pub fn runSingle(comptime handler: core.HandlerFn, config: UdpServerConfig) !void {
    if (!datagram.is_linux) return runFallback(handler, config);

    logSystem(config, "raw listening on {s}:{d} (single worker)", .{ config.ip, config.port });
    workerLoop(handler, config, config.reuse_address);
}

/// One SO_REUSEPORT worker per CPU. Used by the EPOLL / URING models. Per-core workers each bind the
/// same port, so SO_REUSEPORT is forced on regardless of the reuse_address flag.
pub fn runPerCore(comptime handler: core.HandlerFn, config: UdpServerConfig) !void {
    if (!datagram.is_linux) return runFallback(handler, config);

    const want = effectiveWorkers(config);
    logSystem(config, "raw listening on {s}:{d} ({d} workers)", .{ config.ip, config.port, want });

    const threads = try config.allocator.alloc(std.Thread, want);
    defer config.allocator.free(threads);

    var spawned: usize = 0;
    for (0..want) |i| {
        threads[i] = std.Thread.spawn(.{}, workerLoop, .{ handler, config, true }) catch break;
        spawned += 1;
    }

    for (threads[0..spawned]) |t| t.join();
}

/// Portable single-socket fallback for non-Linux targets: one datagram per receive, replies sent
/// individually through std.Io.net (no recvmmsg / sendmmsg batching).
pub fn runFallback(comptime handler: core.HandlerFn, config: UdpServerConfig) !void {
    const io = config.io;

    const addr = try IpAddress.parse(config.ip, config.port);
    const socket = try addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(io);

    logSystem(config, "raw listening on {s}:{d} (fallback)", .{ config.ip, config.port });

    const buf = try config.allocator.alloc(u8, config.max_recv_buf);
    defer config.allocator.free(buf);

    var tx = try datagram.SendBatch.init(config.allocator, config.send_batch, config.send_batch * config.max_recv_buf);
    defer tx.deinit();

    while (true) {
        const msg = socket.receive(io, buf) catch continue;

        const sender = datagram.ip4ToSockaddr(msg.from);
        const peer = msg.from;
        var sink = core.Sink{ .batch = &tx, .fd = undefined, .sender = sender };
        handler(msg.data, &peer, &sink);

        for (0..tx.count) |i| {
            const dest = datagram.sockaddrToIp4(tx.names[i]);
            socket.send(io, &dest, tx.iovs[i].base[0..tx.iovs[i].len]) catch {};
        }
        tx.reset();
    }
}
