//! zix http2 .URING dispatch model (Linux): shared-nothing io_uring, one ring + SO_REUSEPORT
//! listener per worker (ADR-037 Phase 4). Mirrors the gRPC URING model: multishot accept, an
//! fd-indexed slot table with a generation-tagged user_data against fd reuse, and a plain recv
//! into each connection's read accumulator that drives the resumable h2 state machine in `mux.zig`.
//!
//! Note:
//! - Unlike the gRPC ring, zix.Http2's handler writes the reply straight to the fd (via
//!   `frame.sendResponse`), so there is no reply cork to ring-send: the ring owns accept and recv,
//!   responses go direct-to-fd. The accepted fd is set non-blocking so `frame.fdWriteAll` polls on
//!   EAGAIN under backpressure instead of blocking the worker. One recv is in flight per connection.
//! - Falls back to the .EPOLL shared-nothing loop when io_uring is unavailable (old kernel, seccomp
//!   sandbox, or an RLIMIT_MEMLOCK cap too low for the ring), so selecting .URING never strands the
//!   server right after binding.

const std = @import("std");
const core = @import("../core.zig");
const mux = @import("../mux.zig");
const Http2ServerConfig = @import("../config.zig").Http2ServerConfig;
const Route = core.Route;
const common = @import("common.zig");
const epoll_model = @import("epoll.zig");
const logSystem = common.logSystem;
const setNoDelay = common.setNoDelay;
const MAX_FD = common.MAX_FD;
const effectiveCacheEntries = common.effectiveCacheEntries;
const uring = @import("../../../multiplexers/ring.zig");
const slab = @import("../../../multiplexers/slab.zig");
const rcache = @import("../../../utils/response_cache.zig");
const IoUring = std.os.linux.IoUring;

/// SQ entries per worker ring.
const URING_ENTRIES: u16 = 4096;
/// CQ entries per worker ring (larger than the default for multishot headroom).
const URING_CQ_ENTRIES: u32 = 16 * 1024;
/// Max CQEs drained per loop pass.
const URING_CQE_BATCH: usize = 512;

/// io_uring SQPOLL kernel-thread idle before it sleeps, in milliseconds. Inert
/// unless IORING_SETUP_SQPOLL is set (it is not here), kept for when it is.
const URING_SQ_THREAD_IDLE_MS: u32 = 1000;

/// Initialize a worker ring with the single-issuer fast-path flags, falling back to a flagless ring
/// when the kernel does not support them. Mirrors the zix.Http1 and gRPC ring init.
fn initUringRing() !IoUring {
    const linux = std.os.linux;
    var params = std.mem.zeroInit(linux.io_uring_params, .{
        .flags = linux.IORING_SETUP_SINGLE_ISSUER |
            linux.IORING_SETUP_DEFER_TASKRUN |
            linux.IORING_SETUP_CQSIZE |
            linux.IORING_SETUP_CLAMP,
        .cq_entries = URING_CQ_ENTRIES,
        .sq_thread_idle = URING_SQ_THREAD_IDLE_MS,
    });

    return IoUring.init_params(URING_ENTRIES, &params) catch return IoUring.init(URING_ENTRIES, 0);
}

/// Set a socket non-blocking so a direct `frame.fdWriteAll` reply polls on EAGAIN under backpressure
/// rather than blocking the worker thread.
fn setNonBlock(fd: std.posix.fd_t) void {
    const linux = std.os.linux;
    const cur = linux.fcntl(fd, std.posix.F.GETFL, 0);
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = linux.fcntl(fd, std.posix.F.SETFL, cur | @as(usize, nonblock));
}

/// Per-connection ring wrapper. conn holds the h2 state (the rbuf read accumulator). gen guards
/// against fd reuse: a stale recv CQE for a closed fd must not touch a freshly accepted connection.
const UringConn = struct {
    conn: *mux.MuxConn,
    gen: u24,
};

const UringMuxCtx = struct {
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    opts: core.ServeOpts,
    worker_id: usize,
    busy_poll_us: u32,
};

/// Build a concrete io_uring mux worker entry with the routes baked in at compile time, mirroring
/// epollMuxWorkerFn.
fn uringMuxWorkerFn(comptime routes: []const Route) fn (UringMuxCtx) void {
    return struct {
        const Worker = struct {
            ring: IoUring,
            slots: []?*UringConn,
            listener_fd: std.posix.fd_t,
            gen_counter: u24,
            opts: core.ServeOpts,
            busy_poll_us: u32,

            const Self = @This();
            const allocator = std.heap.smp_allocator;
            const linux = std.os.linux;

            fn deinit(self: *Self) void {
                for (self.slots) |maybe_conn| {
                    if (maybe_conn) |uc| {
                        _ = linux.close(uc.conn.fd);
                        uc.conn.deinit();
                        allocator.destroy(uc);
                    }
                }

                slab.unmapSlots(self.slots);
                self.ring.deinit();
            }

            fn getSqe(self: *Self) ?*linux.io_uring_sqe {
                return self.ring.get_sqe() catch {
                    _ = self.ring.submit() catch return null;

                    return self.ring.get_sqe() catch null;
                };
            }

            fn lookup(self: *Self, decoded: uring.Decoded) ?*UringConn {
                const idx: usize = @intCast(decoded.fd);
                if (idx >= self.slots.len) return null;

                const uc = self.slots[idx] orelse return null;
                if (uc.gen != decoded.gen) return null;

                return uc;
            }

            fn closeConn(self: *Self, uc: *UringConn) void {
                self.slots[@intCast(uc.conn.fd)] = null;

                _ = linux.close(uc.conn.fd);
                uc.conn.deinit();
                allocator.destroy(uc);
            }

            fn armAccept(self: *Self) void {
                const sqe = self.getSqe() orelse return;
                sqe.prep_multishot_accept(self.listener_fd, null, null, 0);
                sqe.user_data = uring.packUserData(.accept, 0, self.listener_fd);
            }

            fn armRecv(self: *Self, uc: *UringConn) void {
                const c = uc.conn;

                // Compact the read accumulator before the next recv, mirroring onReadable's loop-top
                // compaction in mux.zig.
                if (c.rstart == c.rend) {
                    c.rstart = 0;
                    c.rend = 0;
                } else if (c.rend == c.rbuf.len) {
                    const n = c.rend - c.rstart;
                    std.mem.copyForwards(u8, c.rbuf[0..n], c.rbuf[c.rstart..c.rend]);
                    c.rstart = 0;
                    c.rend = n;
                }

                if (c.rend == c.rbuf.len) {
                    self.closeConn(uc);
                    return;
                }

                const sqe = self.getSqe() orelse {
                    self.closeConn(uc);
                    return;
                };
                sqe.prep_recv(c.fd, c.rbuf[c.rend..], 0);
                sqe.user_data = uring.packUserData(.recv, uc.gen, c.fd);
            }

            fn handleAccept(self: *Self, cqe: linux.io_uring_cqe) void {
                const rearm = (cqe.flags & linux.IORING_CQE_F_MORE) == 0;
                defer if (rearm) self.armAccept();

                if (cqe.res < 0) return;

                const conn_fd: std.posix.fd_t = cqe.res;
                const idx: usize = @intCast(conn_fd);
                if (idx >= self.slots.len) {
                    _ = linux.close(conn_fd);
                    return;
                }

                setNoDelay(conn_fd);
                setNonBlock(conn_fd);
                common.setBusyPoll(conn_fd, self.busy_poll_us);

                const c = mux.MuxConn.init(conn_fd, self.opts) orelse {
                    _ = linux.close(conn_fd);
                    return;
                };
                const uc = allocator.create(UringConn) catch {
                    c.deinit();
                    _ = linux.close(conn_fd);
                    return;
                };

                self.gen_counter +%= 1;
                uc.* = .{ .conn = c, .gen = self.gen_counter };
                self.slots[idx] = uc;

                self.armRecv(uc);
            }

            fn handleRecv(self: *Self, cqe: linux.io_uring_cqe, decoded: uring.Decoded) void {
                const uc = self.lookup(decoded) orelse return;

                // res == 0 is a peer hangup, res < 0 a receive error: both close.
                if (cqe.res <= 0) {
                    self.closeConn(uc);
                    return;
                }

                uc.conn.rend += @intCast(cqe.res);

                // The handler writes its reply straight to the fd during processing.
                if (mux.processRing(routes, uc.conn) == .close) {
                    self.closeConn(uc);
                    return;
                }

                self.armRecv(uc);
            }

            fn run(self: *Self) void {
                self.armAccept();

                var cqes: [URING_CQE_BATCH]linux.io_uring_cqe = undefined;
                while (true) {
                    _ = self.ring.submit_and_wait(1) catch |err| switch (err) {
                        error.SignalInterrupt => continue,
                        else => return,
                    };

                    const count = self.ring.copy_cqes(&cqes, 0) catch return;
                    for (cqes[0..count]) |cqe| {
                        const decoded = uring.unpackUserData(cqe.user_data);
                        switch (decoded.op) {
                            .accept => self.handleAccept(cqe),
                            .recv => self.handleRecv(cqe, decoded),
                            .send => {},
                            .timeout => {},
                            .close => {},
                        }
                    }
                }
            }
        };

        fn run(ctx: UringMuxCtx) void {
            // Pin to one cgroup-allowed CPU so workers never oversubscribe a core under a limited cpuset.
            common.pinToCpu(ctx.worker_id);

            const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
            var srv = addr.listen(ctx.io, .{
                .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT: the kernel balances accepts across workers
                .kernel_backlog = ctx.kernel_backlog,
            }) catch return;
            defer srv.deinit(ctx.io);
            const listener_fd = srv.socket.handle;

            const slots = slab.mapZeroedSlots(?*UringConn, MAX_FD) catch return;

            var worker = Worker{
                .ring = undefined,
                .slots = slots,
                .listener_fd = listener_fd,
                .gen_counter = 0,
                .opts = ctx.opts,
                .busy_poll_us = ctx.busy_poll_us,
            };
            worker.ring = initUringRing() catch return;
            defer worker.deinit();

            // Per-worker response cache: lock-free by ownership, never shared, like the EPOLL worker.
            var response_cache: rcache.ResponseCache = undefined;
            var cache_on = false;
            if (ctx.opts.response_cache) {
                if (rcache.ResponseCache.init(std.heap.smp_allocator, .{
                    .max_entries = effectiveCacheEntries(ctx.opts),
                    .max_value_bytes = ctx.opts.cache_max_value_bytes,
                })) |built| {
                    response_cache = built;
                    cache_on = true;
                    core.setCache(&response_cache, ctx.opts.cache_ttl_ms);
                } else |_| {
                    cache_on = false;
                }
            }
            defer if (cache_on) {
                core.setCache(null, 0);
                response_cache.deinit();
            };

            worker.run();
        }
    }.run;
}

// --------------------------------------------------------- //

/// URING dispatch (Linux-only): shared-nothing, one SO_REUSEPORT listener plus io_uring ring per
/// worker. Each worker multiplexes many connections through the resumable h2 state machine on a
/// completion loop (ADR-037 Phase 4).
///
/// Note:
/// - worker_count = pool_size (0 = cpu count). A handler runs on the completion loop, so it must
///   stay bounded (it blocks the worker's other connections while running).
pub fn runUring(comptime routes: []const Route, cfg: Http2ServerConfig) !void {
    // Runtime probe: io_uring can be unavailable on this host (seccomp/sandbox, RLIMIT_MEMLOCK, or
    // an old kernel). Without this, every worker would fail setup, return, and the server would
    // vanish right after binding (a confusing ServerStartTimeout downstream). Fall back to the EPOLL
    // shared-nothing loop.
    var probe = initUringRing() catch |err| {
        logSystem(cfg, "io_uring unavailable ({s}): not suited to this environment (commonly RLIMIT_MEMLOCK, the ulimit -l cap, too low for the ring size). Falling back to EPOLL.", .{@errorName(err)});

        return epoll_model.runEpoll(routes, cfg);
    };
    probe.deinit();

    const io = cfg.io;
    // cgroup-aware so a limited cpuset defaults to one worker per available CPU, not one per machine core.
    const cpu = common.getAvailableCpuCount();
    const worker_count = if (cfg.pool_size == 0) cpu else cfg.pool_size;
    const opts = common.serveOpts(cfg);

    logSystem(cfg, "listening on {s}:{d} (io_uring-mux/{d})", .{ cfg.ip, cfg.port, worker_count });

    const workers = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(workers);

    const worker_fn = uringMuxWorkerFn(routes);
    for (workers, 0..) |*t, idx|
        t.* = try std.Thread.spawn(
            .{ .stack_size = cfg.worker_stack_size_bytes },
            worker_fn,
            .{UringMuxCtx{
                .io = io,
                .ip = cfg.ip,
                .port = cfg.port,
                .kernel_backlog = cfg.kernel_backlog,
                .opts = opts,
                .worker_id = idx,
                .busy_poll_us = cfg.busy_poll_us,
            }},
        );

    for (workers) |t| t.join();
}
