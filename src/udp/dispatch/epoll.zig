//! zix udp raw-bytes EPOLL dispatch (ADR-049 / ADR-050): one SO_REUSEPORT worker per CPU, each waiting
//! in epoll_wait and draining the socket to EAGAIN on every readiness wake before sleeping again.
//! Shared-nothing: its own socket, epoll fd, and send / recv batches, so the hot path takes no lock. The
//! per-datagram serve and the worker helpers live in the common module (common.zig).

const std = @import("std");
const linux = std.os.linux;

const Config = @import("../config.zig");
const UdpServerConfig = Config.UdpServerConfig;
const core = @import("../core.zig");
const datagram = @import("../datagram.zig");
const common = @import("common.zig");

/// Max datagrams drained per epoll wake before returning to epoll_wait, bounding one drain-to-EAGAIN
/// pass so a sustained flood still re-enters the wait. EAGAIN normally ends the drain first.
const max_drain_per_wake: usize = 4096;

/// One raw-UDP EPOLL worker: bind a per-core SO_REUSEPORT socket, watch it with epoll, and drain the
/// receive queue to EAGAIN on each readiness wake. Pub so the io_uring worker can fall back to it when
/// io_uring is unavailable.
pub fn workerLoopEpoll(comptime handler: core.HandlerFn, config: UdpServerConfig, worker_id: usize) void {
    common.pinToCpu(worker_id);

    const fd = datagram.open(config.ip, config.port, true) catch |err| {
        common.logSystem(config, "raw bind error: {}", .{err});
        return;
    };
    defer datagram.close(fd);

    common.setBusyPoll(fd, config.busy_poll_us);

    const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (std.posix.errno(epfd_rc) != .SUCCESS) {
        common.logSystem(config, "raw epoll_create1 failed", .{});
        return;
    }
    const epfd: i32 = @intCast(epfd_rc);
    defer _ = linux.close(epfd);

    var watch = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = fd } };
    if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &watch)) != .SUCCESS) {
        common.logSystem(config, "raw epoll_ctl ADD failed", .{});
        return;
    }

    var rx = datagram.RecvBatch.init(config.allocator, config.recv_batch, config.max_recv_buf) catch return;
    defer rx.deinit();

    var tx = datagram.SendBatch.init(config.allocator, config.send_batch, config.send_batch * config.max_recv_buf) catch return;
    defer tx.deinit();

    tx.gso = config.gso_enabled and datagram.probeGso(fd);

    var events: [1]linux.epoll_event = undefined;

    while (true) {
        const ready = linux.epoll_wait(epfd, &events, 1, -1);
        if (std.posix.errno(ready) != .SUCCESS) continue; // EINTR and friends: re-arm the wait

        // Drain the receive queue to EAGAIN so nothing waits a whole cycle. recvNow is the non-blocking
        // recvmmsg, 0 means empty. The cap bounds one drain so a sustained flood still re-enters the wait.
        var drained: usize = 0;
        while (drained < max_drain_per_wake) {
            const count = rx.recvNow(fd) catch break;
            if (count == 0) break;

            drained += count;
            for (0..count) |i| common.serveDatagram(handler, rx.get(i), &tx, fd);

            tx.flush(fd) catch tx.reset();
        }
    }
}

/// Run the raw server with one SO_REUSEPORT epoll worker per CPU. Non-Linux falls back to the portable
/// single-socket loop.
pub fn runEpoll(comptime handler: core.HandlerFn, config: UdpServerConfig) !void {
    if (!datagram.is_linux) return common.runFallback(handler, config);

    const want = common.effectiveWorkers(config);
    common.logSystem(config, "raw listening on {s}:{d} ({d} workers, SO_REUSEPORT + epoll)", .{ config.ip, config.port, want });

    const threads = try config.allocator.alloc(std.Thread, want);
    defer config.allocator.free(threads);

    var spawned: usize = 0;
    for (0..want) |i| {
        threads[i] = std.Thread.spawn(.{ .stack_size = config.worker_stack_size_bytes }, workerLoopEpoll, .{ handler, config, i }) catch break;
        spawned += 1;
    }

    for (threads[0..spawned]) |t| t.join();
}
