//! zix udp raw-bytes URING dispatch (ADR-049 / ADR-050): one SO_REUSEPORT worker per CPU, each driving a
//! real io_uring completion loop. A pool of recvmsg submissions stays in flight and the kernel hands back
//! datagrams (with peer address) as CQEs. A worker whose host lacks io_uring (old kernel, seccomp,
//! RLIMIT_MEMLOCK) falls back to the epoll loop, so selecting .URING never strands a core. The
//! per-datagram serve and the worker helpers live in the common module (common.zig).

const std = @import("std");
const linux = std.os.linux;
const IoUring = std.os.linux.IoUring;

const Config = @import("../config.zig");
const UdpServerConfig = Config.UdpServerConfig;
const core = @import("../core.zig");
const datagram = @import("../datagram.zig");
const common = @import("common.zig");
const epoll = @import("epoll.zig");

/// io_uring submission-queue depth for a raw-UDP .URING worker. The ring carries only recvmsg SQEs
/// (replies go out through the sendmmsg SendBatch), so this bounds the outstanding receives. A power of
/// two, at least uring_recv_slots.
const uring_entries: u16 = 256;

/// In-flight recvmsg submissions per worker: how many datagrams the kernel can fill at once, at
/// slots * max_recv_buf bytes of receive buffer per worker. Kept at or below uring_entries.
const uring_recv_slots: usize = 192;

/// Completions reaped per copy_cqes call.
const uring_cqe_batch: usize = 256;

/// One dual-stack sockaddr_in6 length, for a recvmsg msghdr name field.
const sockaddr_in6_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in6);

/// Initialize one io_uring for a raw-UDP worker. Each per-core worker is shared-nothing: one thread owns
/// the ring, submits, and reaps, so SINGLE_ISSUER (only this thread submits, kernel skips submitter
/// locking) + DEFER_TASKRUN (completion task work runs at submit_and_wait, not on every IRQ) apply. They
/// pair (DEFER_TASKRUN requires SINGLE_ISSUER) and need a recent kernel, so the init steps down to
/// COOP_TASKRUN then to plain flags. A kernel without io_uring errors out and the caller falls back to
/// the epoll worker. No SQPOLL: it needs privilege and a dedicated kernel poll thread per ring.
fn initUringRing() !IoUring {
    const single_defer = linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN;
    if (IoUring.init(uring_entries, single_defer)) |ring| return ring else |_| {}

    if (IoUring.init(uring_entries, linux.IORING_SETUP_COOP_TASKRUN)) |ring| return ring else |_| {}

    return IoUring.init(uring_entries, 0);
}

/// Get a submission-queue entry, submitting the backlog and retrying once when the SQ is momentarily
/// full. Null when the ring cannot accept a submission.
fn uringGetSqe(ring: *IoUring) ?*linux.io_uring_sqe {
    return ring.get_sqe() catch {
        _ = ring.submit() catch return null;

        return ring.get_sqe() catch null;
    };
}

/// Arm (or re-arm) a recvmsg on `slot`: reset the msghdr name length (recvmsg shrinks it to the actual
/// peer), queue a recvmsg SQE on the worker socket, and tag it with the slot index so the completion
/// recovers which buffer and peer address it filled.
fn armUringRecv(ring: *IoUring, msg: *linux.msghdr, slot: usize, fd: std.posix.socket_t) void {
    msg.namelen = sockaddr_in6_len;

    const sqe = uringGetSqe(ring) orelse return;
    sqe.prep_recvmsg(fd, msg, 0);
    sqe.user_data = @intCast(slot);
}

/// One raw-UDP io_uring worker: bind a per-core SO_REUSEPORT socket and drive a real io_uring completion
/// loop. A pool of recvmsg submissions stays in flight (one buffer + sockaddr + msghdr per slot), so the
/// kernel fills many datagrams in parallel and each completion hands back the bytes and peer address by
/// slot index. Replies go out through the same coalescing SendBatch, flushed once per completion batch.
/// Shared-nothing: its own ring, socket, and batches, no lock on the hot path. Falls back to the epoll
/// loop when io_uring is unavailable.
fn workerLoopUring(comptime handler: core.HandlerFn, config: UdpServerConfig, worker_id: usize) void {
    common.pinToCpu(worker_id);

    var ring = initUringRing() catch |err| {
        common.logSystem(config, "io_uring unavailable ({s}): raw worker {d} falls back to epoll", .{ @errorName(err), worker_id });

        return epoll.workerLoopEpoll(handler, config, worker_id);
    };
    defer ring.deinit();

    const fd = datagram.open(config.ip, config.port, true) catch |err| {
        common.logSystem(config, "raw bind error: {}", .{err});
        return;
    };
    defer datagram.close(fd);

    common.setBusyPoll(fd, config.busy_poll_us);

    // Receive-slot pool: one buffer + sockaddr + iovec + msghdr per in-flight recvmsg. Each msghdr points
    // at its slot's sockaddr and iovec (heap slices, stable for the worker's life), so the kernel writes
    // the datagram into the buffer and the peer address into the sockaddr, recovered by the CQE slot index.
    const bufs = config.allocator.alloc(u8, uring_recv_slots * config.max_recv_buf) catch return;
    defer config.allocator.free(bufs);
    const names = config.allocator.alloc(std.posix.sockaddr.in6, uring_recv_slots) catch return;
    defer config.allocator.free(names);
    const iovs = config.allocator.alloc(std.posix.iovec, uring_recv_slots) catch return;
    defer config.allocator.free(iovs);
    const msgs = config.allocator.alloc(linux.msghdr, uring_recv_slots) catch return;
    defer config.allocator.free(msgs);

    for (0..uring_recv_slots) |slot| {
        iovs[slot] = .{ .base = bufs.ptr + slot * config.max_recv_buf, .len = config.max_recv_buf };
        msgs[slot] = .{
            .name = @ptrCast(&names[slot]),
            .namelen = sockaddr_in6_len,
            .iov = @ptrCast(&iovs[slot]),
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        armUringRecv(&ring, &msgs[slot], slot, fd);
    }

    var tx = datagram.SendBatch.init(config.allocator, config.send_batch, config.send_batch * config.max_recv_buf) catch return;
    defer tx.deinit();

    tx.gso = config.gso_enabled and datagram.probeGso(fd);

    common.logSystem(config, "raw io_uring worker {d} up ({d} recv slots)", .{ worker_id, uring_recv_slots });

    var cqes: [uring_cqe_batch]linux.io_uring_cqe = undefined;

    while (true) {
        _ = ring.submit_and_wait(1) catch continue;

        const reaped = ring.copy_cqes(&cqes, 0) catch continue;
        for (cqes[0..reaped]) |cqe| {
            const slot: usize = @intCast(cqe.user_data);

            // res > 0 is the datagram length, res <= 0 is an empty datagram or a recvmsg error. Re-arm the
            // slot either way so the receive stays in flight.
            if (cqe.res > 0) {
                const len: usize = @min(@as(usize, @intCast(cqe.res)), config.max_recv_buf);
                common.serveDatagram(handler, .{ .data = bufs[slot * config.max_recv_buf ..][0..len], .from = names[slot] }, &tx, fd);
            }

            armUringRecv(&ring, &msgs[slot], slot, fd);
        }

        tx.flush(fd) catch tx.reset();
    }
}

/// Run the raw server with one SO_REUSEPORT io_uring worker per CPU. Non-Linux falls back to the portable
/// single-socket loop.
pub fn runUring(comptime handler: core.HandlerFn, config: UdpServerConfig) !void {
    if (!datagram.is_linux) return common.runFallback(handler, config);

    const want = common.effectiveWorkers(config);
    common.logSystem(config, "raw listening on {s}:{d} ({d} workers, SO_REUSEPORT + io_uring)", .{ config.ip, config.port, want });

    const threads = try config.allocator.alloc(std.Thread, want);
    defer config.allocator.free(threads);

    var spawned: usize = 0;
    for (0..want) |i| {
        threads[i] = std.Thread.spawn(.{ .stack_size = config.worker_stack_size_bytes }, workerLoopUring, .{ handler, config, i }) catch break;
        spawned += 1;
    }

    for (threads[0..spawned]) |t| t.join();
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: raw udp epoll and uring run shapes compile (monomorphize without running)" {
    // The per-core loops never return, so they cannot be run in a test. if (false) still type-checks the
    // whole call chain at comptime: runUring -> workerLoopUring, runEpoll -> workerLoopEpoll, so a compile
    // error in either generic body surfaces here rather than only when an example instantiates it.
    const noop = struct {
        fn h(_: []const u8, _: *const std.Io.net.IpAddress, _: *core.Sink) void {}
    }.h;

    if (false) {
        runUring(noop, undefined) catch {};
        epoll.runEpoll(noop, undefined) catch {};
        common.runSingle(noop, undefined) catch {};
        common.runMulti(noop, undefined) catch {};
    }
}

test "zix test: raw udp io_uring recvmsg delivers a datagram and its peer address by slot" {
    if (comptime !datagram.is_linux) return;

    var ring = initUringRing() catch return; // skip where io_uring is unavailable (sandbox / old kernel)
    defer ring.deinit();

    const r_fd = datagram.open("127.0.0.1", 19081, false) catch return; // skip if the port is busy
    defer datagram.close(r_fd);

    // Arm a single recvmsg on slot 5, then send one datagram to the receiver.
    var name: std.posix.sockaddr.in6 = undefined;
    var buf: [1500]u8 = undefined;
    var iov = std.posix.iovec{ .base = &buf, .len = buf.len };
    var msg = linux.msghdr{
        .name = @ptrCast(&name),
        .namelen = sockaddr_in6_len,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    armUringRecv(&ring, &msg, 5, r_fd);
    _ = ring.submit() catch return;

    const s_fd = datagram.open("127.0.0.1", 19082, false) catch return;
    defer datagram.close(s_fd);

    const dest = datagram.ipToSockaddr6(try std.Io.net.IpAddress.parse("127.0.0.1", 19081));
    var tx = try datagram.SendBatch.init(std.testing.allocator, 1, 64);
    defer tx.deinit();
    try std.testing.expect(tx.queue(dest, "ping"));
    try tx.flush(s_fd);

    // The completion carries the slot in user_data, the byte count in res, and the bytes in the buffer.
    _ = ring.submit_and_wait(1) catch return;
    var cqes: [4]linux.io_uring_cqe = undefined;
    const n = ring.copy_cqes(&cqes, 0) catch return;
    try std.testing.expect(n >= 1);
    try std.testing.expectEqual(@as(u64, 5), cqes[0].user_data);
    try std.testing.expect(cqes[0].res >= 4);
    try std.testing.expectEqualStrings("ping", buf[0..4]);
}
