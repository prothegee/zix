//! zix tcp .EPOLL dispatch model (Linux-only): shared-nothing epoll workers.
//! The per-connection .URING model folds here too: a blocking per-connection
//! handler cannot run on the single-threaded ring, so it is served by this
//! shared-nothing loop (the framed callback path runs natively on the ring).

const std = @import("std");
const Config = @import("../config.zig");
const TcpServerConfig = Config.TcpServerConfig;
const Logger = @import("../../logger/logger.zig").Logger;
const common = @import("common.zig");
const logSystem = common.logSystem;
const HandlerFn = common.HandlerFn;
const ConnTask = common.ConnTask;
const dispatchConn = common.dispatchConn;
const applyConnTimeout = common.applyConnTimeout;
const EPOLL_MAX_EVENTS = common.EPOLL_MAX_EVENTS;

// --------------------------------------------------------- //

const EpollWorkerCtx = struct {
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    recv_timeout_ms: u32,
    send_timeout_ms: u32,
    handler: HandlerFn,
    logger: ?*Logger,
};

/// EPOLL worker: owns one SO_REUSEPORT listener and one epoll instance.
/// The kernel load-balances connections across per-worker listeners with no
/// shared queue and no cross-thread fd handoff. Each accepted connection is
/// dispatched via io.async so the worker returns to epoll_wait immediately
/// and is not parked on the connection lifetime.
fn epollWorkerEntry(ctx: EpollWorkerCtx) void {
    const linux = std.os.linux;

    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch |err| {
        if (ctx.logger) |lg| lg.system(.ERROR, "tcp", "epoll worker resolve error: {}", .{err});
        return;
    };
    var srv = addr.listen(ctx.io, .{
        .mode = .stream,
        .protocol = .tcp,
        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX: each worker binds the same port
        .kernel_backlog = ctx.kernel_backlog,
    }) catch |err| {
        if (ctx.logger) |lg| lg.system(.ERROR, "tcp", "epoll worker listen error: {}", .{err});
        return;
    };
    defer srv.deinit(ctx.io);
    const listener_fd = srv.socket.handle;

    const cur_flags = linux.fcntl(listener_fd, std.posix.F.GETFL, 0);
    const nonblock_bit: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = linux.fcntl(listener_fd, std.posix.F.SETFL, cur_flags | @as(usize, nonblock_bit));

    const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (std.posix.errno(epfd_rc) != .SUCCESS) return;
    const epfd: std.posix.fd_t = @intCast(epfd_rc);
    defer _ = linux.close(epfd);

    var listener_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = listener_fd },
    };
    if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listener_fd, &listener_event)) != .SUCCESS) return;

    var events: [EPOLL_MAX_EVENTS]linux.epoll_event = undefined;
    var epoll_timeout: i32 = -1;
    while (true) {
        const wait_result = linux.epoll_wait(epfd, &events, EPOLL_MAX_EVENTS, epoll_timeout);
        switch (std.posix.errno(wait_result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return,
        }

        const n: usize = @intCast(wait_result);
        if (n == 0) {
            epoll_timeout = -1;
            continue;
        }

        for (events[0..n]) |ev| {
            if (ev.data.fd != listener_fd) continue;

            while (true) {
                const accept_result = linux.accept4(listener_fd, null, null, std.posix.SOCK.CLOEXEC);
                switch (std.posix.errno(accept_result)) {
                    .SUCCESS => {},
                    .AGAIN => break,
                    .INTR, .CONNABORTED => continue,
                    else => break,
                }

                const conn_fd: std.posix.fd_t = @intCast(accept_result);
                applyConnTimeout(conn_fd, ctx.recv_timeout_ms, ctx.send_timeout_ms);
                const stream: std.Io.net.Stream = .{ .socket = .{
                    .handle = conn_fd,
                    .address = .{ .ip4 = .unspecified(0) },
                } };

                _ = ctx.io.async(dispatchConn, .{ConnTask{
                    .stream = stream,
                    .io = ctx.io,
                    .handler = ctx.handler,
                    .logger = ctx.logger,
                }});
            }
        }

        epoll_timeout = 0;
    }
}

// --------------------------------------------------------- //
// EPOLL model

/// EPOLL dispatch: spawns shared-nothing workers, each with its own
/// SO_REUSEPORT listener and epoll instance. Linux-only.
///
/// Note:
/// - The kernel distributes connections across per-worker listeners with no
///   shared queue and no cross-thread fd handoff.
/// - Each accepted connection is dispatched via io.async: the worker returns
///   to epoll_wait immediately and is not parked on the connection lifetime.
/// - workers = 0 (default): cpu_count workers.
/// - pool_size is ignored for EPOLL (no session-worker pool needed).
pub fn runEpoll(cfg: TcpServerConfig, handler: HandlerFn) !void {
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

    logSystem(cfg, "listening on {s}:{d} (epoll/{d}, shared-nothing)", .{ cfg.ip, cfg.port, worker_count });

    const workers = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(workers);

    for (workers) |*t|
        t.* = try std.Thread.spawn(
            .{ .stack_size = cfg.worker_stack_size_bytes },
            epollWorkerEntry,
            .{EpollWorkerCtx{
                .io = cfg.io,
                .ip = cfg.ip,
                .port = cfg.port,
                .kernel_backlog = cfg.kernel_backlog,
                .recv_timeout_ms = cfg.recv_timeout_ms,
                .send_timeout_ms = cfg.send_timeout_ms,
                .handler = handler,
                .logger = cfg.logger,
            }},
        );

    for (workers) |t| t.join();
}
