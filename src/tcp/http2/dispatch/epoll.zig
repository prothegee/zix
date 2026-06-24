//! zix http2 .EPOLL dispatch model (Linux-only): multiplexed shared-nothing, one SO_REUSEPORT
//! listener + epoll + ConnTable per worker. The kernel load-balances new connections across the
//! per-worker listeners, so a connection is accepted and driven to completion by a single worker
//! with no cross-thread state. Mirrors the gRPC EPOLL model, driving the h2 mux state machine in
//! `mux.zig` instead of the gRPC one.

const std = @import("std");
const core = @import("../core.zig");
const mux = @import("../mux.zig");
const Http2ServerConfig = @import("../config.zig").Http2ServerConfig;
const Route = core.Route;
const common = @import("common.zig");
const logSystem = common.logSystem;
const setNoDelay = common.setNoDelay;
const MAX_FD = common.MAX_FD;
const slab = @import("../../../multiplexers/slab.zig");

/// Max epoll events drained per epoll_wait call.
const EPOLL_MAX_EVENTS: usize = 512;

/// Private per-worker fd to MuxConn map. Not shared between workers.
const ConnTable = struct {
    slots: []?*mux.MuxConn,

    fn init() !ConnTable {
        // mmap'd pointer slots: kernel-zeroed (zero == null) and demand-paged.
        const slots = try slab.mapZeroedSlots(?*mux.MuxConn, MAX_FD);

        return .{ .slots = slots };
    }

    fn deinit(self: *ConnTable) void {
        for (self.slots) |maybe_conn| {
            if (maybe_conn) |conn| conn.deinit();
        }

        slab.unmapSlots(self.slots);
    }

    fn get(self: *ConnTable, fd: std.posix.fd_t) ?*mux.MuxConn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        return self.slots[idx];
    }

    fn alloc(self: *ConnTable, fd: std.posix.fd_t, opts: core.ServeOpts) ?*mux.MuxConn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        const conn = mux.MuxConn.init(fd, opts) orelse return null;
        self.slots[idx] = conn;

        return conn;
    }

    fn free(self: *ConnTable, fd: std.posix.fd_t) void {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return;

        if (self.slots[idx]) |conn| {
            conn.deinit();
            self.slots[idx] = null;
        }
    }
};

fn setNonBlock(fd: std.posix.fd_t) void {
    const linux = std.os.linux;
    const cur = linux.fcntl(fd, std.posix.F.GETFL, 0);
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = linux.fcntl(fd, std.posix.F.SETFL, cur | @as(usize, nonblock));
}

/// Accept every pending connection on listener_fd and register each in epfd. Level-triggered,
/// so draining to EAGAIN guarantees no accept is missed.
fn acceptAll(table: *ConnTable, epfd: std.posix.fd_t, listener_fd: std.posix.fd_t, opts: core.ServeOpts) void {
    const linux = std.os.linux;

    while (true) {
        const rc = linux.accept4(listener_fd, null, null, std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return,
            .INTR, .CONNABORTED => continue,
            else => return,
        }

        const conn_fd: std.posix.fd_t = @intCast(rc);
        setNoDelay(conn_fd);
        if (table.alloc(conn_fd, opts) == null) {
            _ = linux.close(conn_fd);
            continue;
        }

        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
            .data = .{ .fd = conn_fd },
        };
        if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, conn_fd, &ev)) != .SUCCESS) {
            table.free(conn_fd);
            _ = linux.close(conn_fd);
        }
    }
}

// --------------------------------------------------------- //

const MuxWorkerCtx = struct {
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    opts: core.ServeOpts,
};

/// Build a concrete epoll mux worker entry with the routes baked in at compile time. One worker:
/// a private SO_REUSEPORT listener + epoll instance driving many non-blocking connections through
/// the resumable h2 state machine.
fn epollMuxWorkerFn(comptime routes: []const Route) fn (MuxWorkerCtx) void {
    return struct {
        fn run(ctx: MuxWorkerCtx) void {
            const linux = std.os.linux;

            const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
            var srv = addr.listen(ctx.io, .{
                .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT: the kernel balances accepts across workers
                .kernel_backlog = ctx.kernel_backlog,
            }) catch return;
            defer srv.deinit(ctx.io);
            const listener_fd = srv.socket.handle;

            setNonBlock(listener_fd);

            const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
            if (std.posix.errno(epfd_rc) != .SUCCESS) return;
            const epfd: std.posix.fd_t = @intCast(epfd_rc);
            defer _ = linux.close(epfd);

            var listener_ev = linux.epoll_event{
                .events = linux.EPOLL.IN,
                .data = .{ .fd = listener_fd },
            };
            if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listener_fd, &listener_ev)) != .SUCCESS) return;

            var table = ConnTable.init() catch return;
            defer table.deinit();

            var events: [EPOLL_MAX_EVENTS]linux.epoll_event = undefined;
            var epoll_timeout: i32 = -1;
            while (true) {
                const wait_rc = linux.epoll_wait(epfd, &events, EPOLL_MAX_EVENTS, epoll_timeout);
                switch (std.posix.errno(wait_rc)) {
                    .SUCCESS => {},
                    .INTR => continue,
                    else => return,
                }

                const n: usize = @intCast(wait_rc);
                if (n == 0) {
                    epoll_timeout = -1;
                    continue;
                }

                for (events[0..n]) |ev| {
                    if (ev.data.fd == listener_fd) {
                        acceptAll(&table, epfd, listener_fd, ctx.opts);
                        continue;
                    }

                    const conn = table.get(ev.data.fd) orelse continue;
                    const outcome = if ((ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0)
                        mux.ConnOutcome.close
                    else
                        mux.onReadable(routes, conn);

                    if (outcome == .close) {
                        _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, ev.data.fd, null);
                        table.free(ev.data.fd);
                        _ = linux.close(ev.data.fd);
                    }
                }

                epoll_timeout = 0;
            }
        }
    }.run;
}

// --------------------------------------------------------- //

/// EPOLL dispatch (Linux-only): shared-nothing, one SO_REUSEPORT listener + epoll per worker. Each
/// worker multiplexes many non-blocking connections through the resumable h2 state machine.
///
/// Note:
/// - worker_count = pool_size (0 = cpu count). A handler runs on the event loop, so it must stay
///   bounded (it blocks the worker's other connections while running).
pub fn runEpoll(comptime routes: []const Route, cfg: Http2ServerConfig) !void {
    const io = cfg.io;
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (cfg.pool_size == 0) cpu else cfg.pool_size;
    const opts = common.serveOpts(cfg);

    logSystem(cfg, "listening on {s}:{d} (epoll-mux/{d})", .{ cfg.ip, cfg.port, worker_count });

    const workers = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(workers);

    const worker_fn = epollMuxWorkerFn(routes);
    for (workers) |*t|
        t.* = try std.Thread.spawn(
            .{ .stack_size = 512 * 1024 },
            worker_fn,
            .{MuxWorkerCtx{
                .io = io,
                .ip = cfg.ip,
                .port = cfg.port,
                .kernel_backlog = cfg.kernel_backlog,
                .opts = opts,
            }},
        );

    for (workers) |t| t.join();
}
