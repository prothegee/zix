//! zix fix server: POOL, ASYNC, MIXED, and EPOLL (Linux-only) dispatch for FIX 4.x.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const FixServerConfig = @import("config.zig").FixServerConfig;
const DispatchModel = @import("../config.zig").DispatchModel;
const FixServeOpts = core.FixServeOpts;
const Logger = @import("../../logger/logger.zig").Logger;
const uring = @import("../io_uring/ring.zig");
const IoUring = std.os.linux.IoUring;

/// Emit a server lifecycle line. Routes through cfg.logger when present.
/// Without a logger it prints to stderr only in Debug builds (silent in release).
fn logSystem(cfg: FixServerConfig, comptime fmt: []const u8, args: anytype) void {
    if (cfg.logger) |lg| {
        lg.system(.INFO, "fix", fmt, args);
        return;
    }

    if (comptime builtin.mode == .Debug) std.debug.print("zix fix: " ++ fmt ++ "\n", args);
}

/// Max epoll events drained per epoll_wait call. 512 lets a worker clear its
/// ready-fd set in one syscall at high connection counts.
const EPOLL_MAX_EVENTS: usize = 512;

// --------------------------------------------------------- //

const ConnTask = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    comp_id: []const u8,
    opts: FixServeOpts,
};

fn dispatchConn(task: ConnTask) void {
    core.serveConn(task.stream, task.io, task.comp_id, task.opts) catch {};
}

// --------------------------------------------------------- //

const ConnQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    items: std.ArrayListUnmanaged(std.Io.net.Stream) = .empty,
    closed: bool = false,

    fn push(self: *ConnQueue, stream: std.Io.net.Stream, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.items.append(std.heap.smp_allocator, stream) catch {
            self.mutex.unlock(io);
            stream.close(io);
            return;
        };
        self.mutex.unlock(io);
        self.ready.signal(io);
    }

    fn pop(self: *ConnQueue, io: std.Io) ?std.Io.net.Stream {
        self.mutex.lockUncancelable(io);
        while (self.items.items.len == 0) {
            if (self.closed) {
                self.mutex.unlock(io);
                return null;
            }
            self.ready.waitUncancelable(io, &self.mutex);
        }
        const stream = self.items.orderedRemove(0);
        self.mutex.unlock(io);
        return stream;
    }

    fn close(self: *ConnQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.mutex.unlock(io);
        self.ready.broadcast(io);
    }

    fn deinit(self: *ConnQueue) void {
        self.items.deinit(std.heap.smp_allocator);
    }
};

// --------------------------------------------------------- //

const WorkerCtx = struct {
    queue: *ConnQueue,
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    opts: FixServeOpts,
};

fn workerEntry(ctx: WorkerCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch |err| {
        if (ctx.opts.logger) |lg| lg.system(.ERROR, "fix", "resolve error: {}", .{err});
        return;
    };
    var listener = addr.listen(ctx.io, .{
        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
        .kernel_backlog = ctx.kernel_backlog,
    }) catch |err| {
        if (ctx.opts.logger) |lg| lg.system(.ERROR, "fix", "listen error: {}", .{err});
        return;
    };
    defer listener.deinit(ctx.io);

    while (true) {
        const stream = listener.accept(ctx.io) catch |err| {
            if (err != error.ConnectionAborted) {
                if (ctx.opts.logger) |lg| lg.system(.WARN, "fix", "accept error: {}", .{err});
                break;
            }
            continue;
        };
        ctx.queue.push(stream, ctx.io);
    }
}

const PoolCtx = struct {
    queue: *ConnQueue,
    io: std.Io,
    comp_id: []const u8,
    opts: FixServeOpts,
};

fn poolEntry(ctx: PoolCtx) void {
    while (ctx.queue.pop(ctx.io)) |stream| {
        dispatchConn(.{ .stream = stream, .io = ctx.io, .comp_id = ctx.comp_id, .opts = ctx.opts });
    }
}

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

const EpollWorkerCtx = struct {
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    comp_id: []const u8,
    opts: FixServeOpts,
};

/// EPOLL worker: owns one SO_REUSEPORT listener and one epoll instance.
/// The kernel load-balances connections across per-worker listeners with no
/// shared queue and no cross-thread fd handoff. Each accepted connection is
/// dispatched via io.async so the worker returns to epoll_wait immediately
/// and is not parked on the session lifetime.
fn epollWorkerEntry(ctx: EpollWorkerCtx) void {
    const linux = std.os.linux;

    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch |err| {
        if (ctx.opts.logger) |lg| lg.system(.ERROR, "fix", "epoll worker resolve error: {}", .{err});
        return;
    };
    var srv = addr.listen(ctx.io, .{
        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX: each worker binds the same port
        .kernel_backlog = ctx.kernel_backlog,
    }) catch |err| {
        if (ctx.opts.logger) |lg| lg.system(.ERROR, "fix", "epoll worker listen error: {}", .{err});
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
                const stream: std.Io.net.Stream = .{ .socket = .{
                    .handle = conn_fd,
                    .address = .{ .ip4 = .unspecified(0) },
                } };

                _ = ctx.io.async(dispatchConn, .{ConnTask{
                    .stream = stream,
                    .io = ctx.io,
                    .comp_id = ctx.comp_id,
                    .opts = ctx.opts,
                }});
            }
        }

        epoll_timeout = 0;
    }
}

// --------------------------------------------------------- //

/// FIX 4.x session server. Dispatches connections via POOL, ASYNC, MIXED,
/// or EPOLL (Linux-only: non-Linux falls back to POOL).
/// Session messages (Logon, Logout, Heartbeat, TestRequest) are handled internally.
/// Application messages are dispatched to registered routes.
///
/// Usage:
/// ```zig
/// var server = try FixServer.init(
///     &[_]FixRoute{
///         .{ .msg_type = "D", .handler = handleOrder },
///         .{ .msg_type = "F", .handler = handleCancel },
///     },
///     .{ .io = io, .ip = "0.0.0.0", .port = 9500, .comp_id = "SRV" },
/// );
/// defer server.deinit();
/// try server.run();
/// ```
pub const FixServer = struct {
    const Self = @This();

    routes: []const core.FixRoute,
    config: FixServerConfig,

    // --------------------------------------------------------- //

    /// Initialize.
    ///
    /// Param:
    /// routes - []const FixRoute (application message route table. pass &.{} for echo-only mode)
    /// config - FixServerConfig
    ///
    /// Return:
    /// - !Self
    /// - error.PortNotConfigured if config.port is 0
    pub fn init(routes: []const core.FixRoute, config: FixServerConfig) !Self {
        if (config.port == 0) return error.PortNotConfigured;
        return .{ .routes = routes, .config = config };
    }

    /// No-op, resources released inside run via defer.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Listen and serve FIX sessions using the server's comp_id.
    pub fn run(self: *Self) !void {
        const cfg = self.config;
        const io = cfg.io;
        const cpu = try std.Thread.getCpuCount();
        const conn_opts = FixServeOpts{
            .logger = cfg.logger,
            .heartbeat_timeout_ms = cfg.heartbeat_timeout_ms,
            .conn_timeout_ms = cfg.conn_timeout_ms,
            .handler_timeout_ms = cfg.handler_timeout_ms,
            .routes = self.routes,
        };

        switch (cfg.dispatch_model) {
            .ASYNC => {
                logSystem(cfg, "listening on {s}:{d} (async)", .{ cfg.ip, cfg.port });

                const addr = try std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port);
                var listener = try addr.listen(io, .{
                    .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
                    .kernel_backlog = cfg.kernel_backlog,
                });
                defer listener.deinit(io);

                while (true) {
                    const stream = listener.accept(io) catch |err| {
                        if (err != error.ConnectionAborted) break;
                        continue;
                    };
                    _ = io.async(dispatchConn, .{ConnTask{
                        .stream = stream,
                        .io = io,
                        .comp_id = cfg.comp_id,
                        .opts = conn_opts,
                    }});
                }
            },

            .POOL => {
                const worker_count = if (cfg.workers == 0) cpu else cfg.workers;
                const pool_count = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

                logSystem(cfg, "listening on {s}:{d} (pool/{d}x{d})", .{ cfg.ip, cfg.port, worker_count, pool_count });

                var queue = ConnQueue{};
                defer queue.deinit();

                const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_count);
                defer std.heap.smp_allocator.free(pool_threads);
                for (pool_threads) |*t|
                    t.* = try std.Thread.spawn(
                        .{ .stack_size = 256 * 1024 },
                        poolEntry,
                        .{PoolCtx{ .queue = &queue, .io = io, .comp_id = cfg.comp_id, .opts = conn_opts }},
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
                            .opts = conn_opts,
                        }},
                    );

                for (acc_threads) |t| t.join();
                queue.close(io);
                for (pool_threads) |t| t.join();
            },

            .MIXED => {
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
            },

            .EPOLL => {
                if (comptime @import("builtin").target.os.tag == .linux) {
                    try self.runEpoll(io, conn_opts, cpu);
                } else {
                    logSystem(cfg, "EPOLL is Linux-only. Falling back to POOL.", .{});
                    var fallback = self.*;
                    fallback.config.dispatch_model = .POOL;
                    try fallback.run();
                }
            },

            // Native io_uring ring path (ADR-037 Phase 4 extension).
            .URING => {
                if (comptime @import("builtin").target.os.tag == .linux) {
                    try self.runUring(io, conn_opts, cpu);
                } else {
                    logSystem(cfg, "URING is Linux-only. Falling back to POOL.", .{});
                    var fallback = self.*;
                    fallback.config.dispatch_model = .POOL;
                    try fallback.run();
                }
            },
        }
    }

    /// EPOLL dispatch: spawns shared-nothing workers, each with its own
    /// SO_REUSEPORT listener and epoll instance. Linux-only.
    ///
    /// Note:
    /// - The kernel distributes connections across per-worker listeners with no
    ///   shared queue and no cross-thread fd handoff.
    /// - Each accepted connection is dispatched via io.async: the worker returns
    ///   to epoll_wait immediately and is not parked on the session lifetime.
    /// - workers = 0 (default): cpu_count workers.
    /// - pool_size is ignored for EPOLL (no session-worker pool needed).
    fn runEpoll(self: *Self, io: std.Io, conn_opts: FixServeOpts, cpu: usize) !void {
        const cfg = self.config;
        const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

        logSystem(cfg, "listening on {s}:{d} (epoll/{d}, shared-nothing)", .{ cfg.ip, cfg.port, worker_count });

        const workers = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
        defer std.heap.smp_allocator.free(workers);

        for (workers) |*t|
            t.* = try std.Thread.spawn(
                .{ .stack_size = 512 * 1024 },
                epollWorkerEntry,
                .{EpollWorkerCtx{
                    .io = io,
                    .ip = cfg.ip,
                    .port = cfg.port,
                    .kernel_backlog = cfg.kernel_backlog,
                    .comp_id = cfg.comp_id,
                    .opts = conn_opts,
                }},
            );

        for (workers) |t| t.join();
    }

    /// URING dispatch (Linux-only): shared-nothing io_uring ring per worker. Each
    /// worker drives many FIX sessions through the resumable core.processFixRing on
    /// a completion loop and sends one coalesced reply per readable batch (ADR-037
    /// Phase 4 extension). Serves the reactive session (Logon, routing, admin
    /// replies, Logout). The proactive idle-heartbeat timer is not driven on the
    /// ring (see core.processFixRing).
    fn runUring(self: *Self, io: std.Io, conn_opts: FixServeOpts, cpu: usize) !void {
        const cfg = self.config;
        const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

        logSystem(cfg, "listening on {s}:{d} (io_uring/{d}, shared-nothing)", .{ cfg.ip, cfg.port, worker_count });

        const workers = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
        defer std.heap.smp_allocator.free(workers);

        for (workers) |*t|
            t.* = try std.Thread.spawn(
                .{ .stack_size = 512 * 1024 },
                uringFixWorker,
                .{UringFixCtx{
                    .io = io,
                    .ip = cfg.ip,
                    .port = cfg.port,
                    .kernel_backlog = cfg.kernel_backlog,
                    .comp_id = cfg.comp_id,
                    .opts = conn_opts,
                }},
            );

        for (workers) |t| t.join();
    }
};

// --------------------------------------------------------- //
// Framed FIX io_uring ring (ADR-037 Phase 4 extension): shared-nothing, one ring
// + listener per worker. recv into the connection buffer, run the resumable FIX
// session processor (core.processFixRing) with replies staged through the sink,
// and submit one coalesced send per readable batch. Half-duplex per connection.

/// Per-connection recv accumulator. FIX messages are small, so 64 KiB holds a
/// deep batch of pipelined messages with headroom.
const FIX_RING_RECV_BUF: usize = 64 * 1024;
/// SQ entries per worker ring.
const URING_ENTRIES: u16 = 4096;
/// CQ entries per worker ring (multishot completion headroom).
const URING_CQ_ENTRIES: u32 = 16 * 1024;
/// Max CQEs drained per loop pass.
const URING_CQE_BATCH: usize = 512;
/// Per-connection staged-response buffer.
const URING_SEND_BUF_SIZE: usize = 64 * 1024;

/// Initialize a worker ring with the single-issuer fast-path flags, falling back
/// to a flagless ring when the kernel does not support them.
fn initUringRing() !IoUring {
    const linux = std.os.linux;
    var params = std.mem.zeroInit(linux.io_uring_params, .{
        .flags = linux.IORING_SETUP_SINGLE_ISSUER |
            linux.IORING_SETUP_DEFER_TASKRUN |
            linux.IORING_SETUP_CQSIZE |
            linux.IORING_SETUP_CLAMP,
        .cq_entries = URING_CQ_ENTRIES,
        .sq_thread_idle = 1000,
    });

    return IoUring.init_params(URING_ENTRIES, &params) catch return IoUring.init(URING_ENTRIES, 0);
}

fn ringSetNoDelay(fd: std.posix.fd_t) void {
    std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&@as(c_int, 1))) catch {};
}

/// Per-connection ring state. buf accumulates FIX bytes until whole messages are
/// present, send_buf holds the coalesced reply while a send is in flight, gen
/// guards against fd reuse, fix_state is the resumable FIX session.
const UringFixConn = struct {
    fd: std.posix.fd_t,
    gen: u24,
    buf: []u8,
    filled: usize,
    send_buf: []u8,
    staged: usize,
    inflight: usize,
    closing: bool,
    fix_state: core.FixRingState = .{},
};

const UringFixCtx = struct {
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    comp_id: []const u8,
    opts: FixServeOpts,
};

fn uringFixWorker(ctx: UringFixCtx) void {
    const Worker = struct {
        ring: IoUring,
        slots: []?*UringFixConn,
        listener_fd: std.posix.fd_t,
        gen_counter: u24,
        comp_id: []const u8,
        opts: FixServeOpts,
        hb_ms: u32,
        hb_timespec: lx.kernel_timespec,

        const W = @This();
        const allocator = std.heap.smp_allocator;
        const lx = std.os.linux;

        fn deinit(w: *W) void {
            for (w.slots) |maybe_conn| {
                if (maybe_conn) |conn| {
                    _ = lx.close(conn.fd);
                    allocator.free(conn.buf);
                    allocator.free(conn.send_buf);
                    allocator.destroy(conn);
                }
            }

            allocator.free(w.slots);
            w.ring.deinit();
        }

        fn getSqe(w: *W) ?*lx.io_uring_sqe {
            return w.ring.get_sqe() catch {
                _ = w.ring.submit() catch return null;

                return w.ring.get_sqe() catch null;
            };
        }

        fn lookup(w: *W, decoded: uring.Decoded) ?*UringFixConn {
            const idx: usize = @intCast(decoded.fd);
            if (idx >= w.slots.len) return null;

            const conn = w.slots[idx] orelse return null;
            if (conn.gen != decoded.gen) return null;

            return conn;
        }

        fn destroyConn(w: *W, conn: *UringFixConn) void {
            w.slots[@intCast(conn.fd)] = null;

            allocator.free(conn.buf);
            allocator.free(conn.send_buf);
            allocator.destroy(conn);
        }

        fn finishClose(w: *W, conn: *UringFixConn) void {
            _ = lx.close(conn.fd);
            w.destroyConn(conn);
        }

        fn beginClose(w: *W, conn: *UringFixConn) void {
            conn.closing = true;
            if (conn.inflight > 0) return;

            if (conn.staged > 0) {
                w.submitSend(conn);
                return;
            }

            w.finishClose(conn);
        }

        fn armAccept(w: *W) void {
            const sqe = w.getSqe() orelse return;
            sqe.prep_multishot_accept(w.listener_fd, null, null, 0);
            sqe.user_data = uring.packUserData(.accept, 0, w.listener_fd);
        }

        fn armRecv(w: *W, conn: *UringFixConn) void {
            if (conn.filled >= conn.buf.len) {
                w.beginClose(conn);
                return;
            }

            const sqe = w.getSqe() orelse {
                w.beginClose(conn);
                return;
            };
            sqe.prep_recv(conn.fd, conn.buf[conn.filled..], 0);
            sqe.user_data = uring.packUserData(.recv, conn.gen, conn.fd);
        }

        fn submitSend(w: *W, conn: *UringFixConn) void {
            const sqe = w.getSqe() orelse {
                w.finishClose(conn);
                return;
            };
            sqe.prep_send(conn.fd, conn.send_buf[0..conn.staged], lx.MSG.NOSIGNAL);
            sqe.user_data = uring.packUserData(.send, conn.gen, conn.fd);

            conn.inflight = conn.staged;
        }

        fn handleAccept(w: *W, cqe: lx.io_uring_cqe) void {
            const rearm = (cqe.flags & lx.IORING_CQE_F_MORE) == 0;
            defer if (rearm) w.armAccept();

            if (cqe.res < 0) return;

            const conn_fd: std.posix.fd_t = cqe.res;
            const idx: usize = @intCast(conn_fd);
            if (idx >= w.slots.len) {
                _ = lx.close(conn_fd);
                return;
            }

            ringSetNoDelay(conn_fd);

            const conn = allocator.create(UringFixConn) catch {
                _ = lx.close(conn_fd);
                return;
            };
            const buf = allocator.alloc(u8, FIX_RING_RECV_BUF) catch {
                allocator.destroy(conn);
                _ = lx.close(conn_fd);
                return;
            };
            const send_buf = allocator.alloc(u8, URING_SEND_BUF_SIZE) catch {
                allocator.free(buf);
                allocator.destroy(conn);
                _ = lx.close(conn_fd);
                return;
            };

            w.gen_counter +%= 1;
            conn.* = .{
                .fd = conn_fd,
                .gen = w.gen_counter,
                .buf = buf,
                .filled = 0,
                .send_buf = send_buf,
                .staged = 0,
                .inflight = 0,
                .closing = false,
                .fix_state = .{},
            };
            w.slots[idx] = conn;

            w.armRecv(conn);
        }

        fn handleRecv(w: *W, cqe: lx.io_uring_cqe, decoded: uring.Decoded) void {
            const conn = w.lookup(decoded) orelse return;

            if (cqe.res <= 0) {
                w.beginClose(conn);
                return;
            }

            conn.filled += @intCast(cqe.res);
            conn.fix_state.last_activity_ms = core.monotonicMs();
            conn.fix_state.sent_test_request = false;

            const close = w.dispatch(conn);

            if (conn.staged > 0) {
                w.submitSend(conn);
                if (close) conn.closing = true;

                return;
            }

            if (close) {
                w.beginClose(conn);
                return;
            }

            w.armRecv(conn);
        }

        fn handleSend(w: *W, cqe: lx.io_uring_cqe, decoded: uring.Decoded) void {
            const conn = w.lookup(decoded) orelse return;

            if (cqe.res < 0) {
                w.beginClose(conn);
                return;
            }

            const sent: usize = @intCast(cqe.res);
            if (sent < conn.staged) {
                std.mem.copyForwards(u8, conn.send_buf[0 .. conn.staged - sent], conn.send_buf[sent..conn.staged]);
                conn.staged -= sent;
                conn.inflight = 0;
                w.submitSend(conn);

                return;
            }

            conn.staged = 0;
            conn.inflight = 0;

            if (conn.closing) {
                w.finishClose(conn);
                return;
            }

            w.armRecv(conn);
        }

        /// Install the sink, run the resumable FIX processor over conn.buf, then
        /// compact the unconsumed tail. Returns true when the session must close.
        fn dispatch(w: *W, conn: *UringFixConn) bool {
            const fd = conn.fd;

            var sink = core.RespSink{ .fd = fd, .buf = conn.send_buf };
            core.tl_resp_sink = &sink;
            defer core.tl_resp_sink = null;

            const result = core.processFixRing(&conn.fix_state, w.comp_id, w.opts, conn.buf[0..conn.filled], fd);

            if (result.consumed >= conn.filled) {
                conn.filled = 0;
            } else if (result.consumed > 0) {
                std.mem.copyForwards(u8, conn.buf[0 .. conn.filled - result.consumed], conn.buf[result.consumed..conn.filled]);
                conn.filled -= result.consumed;
            }

            conn.staged = sink.len;

            return result.close or sink.failed;
        }

        fn armTimeout(w: *W) void {
            if (w.hb_ms == 0) return;

            const sqe = w.getSqe() orelse return;
            sqe.prep_timeout(&w.hb_timespec, 0, 0);
            sqe.user_data = uring.packUserData(.timeout, 0, w.listener_fd);
        }

        /// Periodic heartbeat tick: send a TestRequest to every idle logged-in
        /// session, reap one that stayed silent through a Logout, then re-arm. The
        /// reaped connection has only an idle recv in flight (no buffered data), so
        /// closing it is safe: the stale recv completion is dropped by the gen tag.
        fn handleTimeout(w: *W, cqe: lx.io_uring_cqe) void {
            _ = cqe;

            const now = core.monotonicMs();
            for (w.slots) |maybe_conn| {
                if (maybe_conn) |conn| {
                    if (core.fixHeartbeatTick(&conn.fix_state, w.comp_id, conn.fd, now, w.hb_ms)) {
                        w.finishClose(conn);
                    }
                }
            }

            w.armTimeout();
        }

        fn run(w: *W) void {
            w.armAccept();
            w.armTimeout();

            var cqes: [URING_CQE_BATCH]lx.io_uring_cqe = undefined;
            while (true) {
                _ = w.ring.submit_and_wait(1) catch |err| switch (err) {
                    error.SignalInterrupt => continue,
                    else => return,
                };

                const count = w.ring.copy_cqes(&cqes, 0) catch return;
                for (cqes[0..count]) |cqe| {
                    const decoded = uring.unpackUserData(cqe.user_data);
                    switch (decoded.op) {
                        .accept => w.handleAccept(cqe),
                        .recv => w.handleRecv(cqe, decoded),
                        .send => w.handleSend(cqe, decoded),
                        .timeout => w.handleTimeout(cqe),
                    }
                }
            }
        }
    };

    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
    var net_server = addr.listen(ctx.io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = ctx.kernel_backlog,
    }) catch return;
    defer net_server.deinit(ctx.io);
    const listener_fd = net_server.socket.handle;

    const slots = std.heap.smp_allocator.alloc(?*UringFixConn, 1 << 16) catch return;
    @memset(slots, null);

    const hb_ms = ctx.opts.heartbeat_timeout_ms;
    var worker = Worker{
        .ring = undefined,
        .slots = slots,
        .listener_fd = listener_fd,
        .gen_counter = 0,
        .comp_id = ctx.comp_id,
        .opts = ctx.opts,
        .hb_ms = hb_ms,
        .hb_timespec = .{ .sec = @intCast(hb_ms / 1000), .nsec = @intCast((hb_ms % 1000) * 1_000_000) },
    };
    worker.ring = initUringRing() catch return;
    defer worker.deinit();

    worker.run();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix fix: FixServer.init, port zero returns PortNotConfigured" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(
        error.PortNotConfigured,
        FixServer.init(&.{}, .{ .io = io, .ip = "127.0.0.1", .port = 0, .comp_id = "SERVER" }),
    );
}

test "zix fix: FixServer.init, valid config succeeds and deinit is safe" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try FixServer.init(&.{}, .{ .io = io, .ip = "127.0.0.1", .port = 9500, .comp_id = "SERVER" });
    server.deinit();
}

test "zix fix: FixServer.init with EPOLL dispatch model succeeds" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try FixServer.init(&.{}, .{ .io = io, .ip = "127.0.0.1", .port = 9500, .comp_id = "SERVER", .dispatch_model = .EPOLL });
    server.deinit();
}

test "zix fix: FixServer EPOLL uses workers field for worker count, pool_size is ignored" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const server = try FixServer.init(&.{}, .{
        .io = io,
        .ip = "127.0.0.1",
        .port = 9500,
        .comp_id = "SERVER",
        .dispatch_model = .EPOLL,
        .workers = 4,
        .pool_size = 99,
    });
    try std.testing.expectEqual(@as(usize, 4), server.config.workers);
    try std.testing.expectEqual(@as(usize, 99), server.config.pool_size);
}
