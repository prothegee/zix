//! zix grpc .URING dispatch model (Linux): shared-nothing io_uring, one ring +
//! listener per worker (ADR-037 Phase 4 step 3). Mirrors the zix.Http1 ring core:
//! multishot accept, an fd-indexed slot table with a generation-tagged user_data
//! against fd reuse, a plain recv into the per-connection read accumulator, the
//! resumable h2 state machine (core.grpcMuxProcessRing) staging every reply into
//! the connection cork, one coalesced send per readable batch, and a batched CQE
//! drain. Half-duplex per connection (at most one recv or one send in flight).

const std = @import("std");
const core = @import("../core.zig");
const GrpcServerConfig = @import("../config.zig").GrpcServerConfig;
const Route = core.Route;
const common = @import("common.zig");
const epoll_model = @import("epoll.zig");
const logSystem = common.logSystem;
const effectiveCacheEntries = common.effectiveCacheEntries;
const setNoDelay = common.setNoDelay;
const MAX_FD = common.MAX_FD;
const rcache = @import("../../../../utils/response_cache.zig");
const uring = @import("../../../../multiplexers/ring.zig");
const slab = @import("../../../../multiplexers/slab.zig");
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

/// Initialize a worker ring with the single-issuer fast-path flags, falling back
/// to a flagless ring when the kernel does not support them. Mirrors the
/// zix.Http1 ring init.
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

/// Per-connection ring wrapper. conn holds the h2 state (the rbuf read
/// accumulator and the stage_buf reply cork). gen guards against fd reuse,
/// inflight is the byte count the kernel owns while a send is outstanding, and
/// closing defers the free until the last send lands.
const UringGrpcConn = struct {
    conn: *core.GrpcMuxConn,
    gen: u24,
    inflight: usize,
    closing: bool,
};

const UringMuxCtx = struct {
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    opts: core.GrpcServeOpts,
    worker_id: usize,
    busy_poll_us: u32,
};

/// Build a concrete io_uring mux worker entry with the routes baked in at compile
/// time, mirroring epollMuxWorkerFn.
fn uringMuxWorkerFn(comptime routes: []const Route) fn (UringMuxCtx) void {
    return struct {
        const Worker = struct {
            ring: IoUring,
            slots: []?*UringGrpcConn,
            listener_fd: std.posix.fd_t,
            gen_counter: u24,
            opts: core.GrpcServeOpts,
            busy_poll_us: u32,

            const Self = @This();
            const allocator = std.heap.smp_allocator;
            const linux = std.os.linux;

            fn deinit(self: *Self) void {
                for (self.slots) |maybe_conn| {
                    if (maybe_conn) |gc| {
                        _ = linux.close(gc.conn.fd);
                        gc.conn.deinit();
                        allocator.destroy(gc);
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

            fn lookup(self: *Self, decoded: uring.Decoded) ?*UringGrpcConn {
                const idx: usize = @intCast(decoded.fd);
                if (idx >= self.slots.len) return null;

                const gc = self.slots[idx] orelse return null;
                if (gc.gen != decoded.gen) return null;

                return gc;
            }

            fn destroyConn(self: *Self, gc: *UringGrpcConn) void {
                self.slots[@intCast(gc.conn.fd)] = null;

                gc.conn.deinit();
                allocator.destroy(gc);
            }

            fn finishClose(self: *Self, gc: *UringGrpcConn) void {
                _ = linux.close(gc.conn.fd);
                self.destroyConn(gc);
            }

            /// Close intent: flush staged bytes first when possible, otherwise
            /// free now. With a send in flight the free is deferred to the send CQE.
            fn beginClose(self: *Self, gc: *UringGrpcConn) void {
                gc.closing = true;
                if (gc.inflight > 0) return;

                if (gc.conn.stage.len > 0) {
                    self.submitSend(gc);
                    return;
                }

                self.finishClose(gc);
            }

            fn armAccept(self: *Self) void {
                const sqe = self.getSqe() orelse return;
                sqe.prep_multishot_accept(self.listener_fd, null, null, 0);
                sqe.user_data = uring.packUserData(.accept, 0, self.listener_fd);
            }

            fn armRecv(self: *Self, gc: *UringGrpcConn) void {
                const c = gc.conn;

                // Compact the read accumulator before the next recv, mirroring
                // grpcMuxOnReadable's loop-top compaction.
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
                    self.beginClose(gc);
                    return;
                }

                const sqe = self.getSqe() orelse {
                    self.beginClose(gc);
                    return;
                };
                sqe.prep_recv(c.fd, c.rbuf[c.rend..], 0);
                sqe.user_data = uring.packUserData(.recv, gc.gen, c.fd);
            }

            fn submitSend(self: *Self, gc: *UringGrpcConn) void {
                const c = gc.conn;
                const sqe = self.getSqe() orelse {
                    self.finishClose(gc);
                    return;
                };
                sqe.prep_send(c.fd, c.stage.buf[0..c.stage.len], linux.MSG.NOSIGNAL);
                sqe.user_data = uring.packUserData(.send, gc.gen, c.fd);

                gc.inflight = c.stage.len;
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
                common.setBusyPoll(conn_fd, self.busy_poll_us);

                const c = core.GrpcMuxConn.init(conn_fd, self.opts) orelse {
                    _ = linux.close(conn_fd);
                    return;
                };
                const gc = allocator.create(UringGrpcConn) catch {
                    c.deinit();
                    _ = linux.close(conn_fd);
                    return;
                };

                self.gen_counter +%= 1;
                gc.* = .{ .conn = c, .gen = self.gen_counter, .inflight = 0, .closing = false };
                self.slots[idx] = gc;

                self.armRecv(gc);
            }

            fn handleRecv(self: *Self, cqe: linux.io_uring_cqe, decoded: uring.Decoded) void {
                const gc = self.lookup(decoded) orelse return;

                // res == 0 is a peer hangup, res < 0 a receive error: both close.
                if (cqe.res <= 0) {
                    self.beginClose(gc);
                    return;
                }

                gc.conn.rend += @intCast(cqe.res);

                const outcome = core.grpcMuxProcessRing(routes, gc.conn);

                if (gc.conn.stage.len > 0) {
                    self.submitSend(gc);
                    if (outcome == .close) gc.closing = true;

                    return;
                }

                if (outcome == .close) {
                    self.beginClose(gc);
                    return;
                }

                self.armRecv(gc);
            }

            fn handleSend(self: *Self, cqe: linux.io_uring_cqe, decoded: uring.Decoded) void {
                const gc = self.lookup(decoded) orelse return;

                if (cqe.res < 0) {
                    self.beginClose(gc);
                    return;
                }

                const c = gc.conn;
                const sent: usize = @intCast(cqe.res);
                if (sent < c.stage.len) {
                    std.mem.copyForwards(u8, c.stage.buf[0 .. c.stage.len - sent], c.stage.buf[sent..c.stage.len]);
                    c.stage.len -= sent;
                    gc.inflight = 0;
                    self.submitSend(gc);

                    return;
                }

                c.stage.len = 0;
                gc.inflight = 0;

                if (gc.closing) {
                    self.finishClose(gc);
                    return;
                }

                self.armRecv(gc);
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
                            .send => self.handleSend(cqe, decoded),
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
                .reuse_address = true,
                .kernel_backlog = ctx.kernel_backlog,
            }) catch return;
            defer srv.deinit(ctx.io);
            const listener_fd = srv.socket.handle;

            const slots = slab.mapZeroedSlots(?*UringGrpcConn, MAX_FD) catch return;

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

            // Per-worker unary response cache: lock-free by ownership, never
            // shared, exactly like the EPOLL mux worker.
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
// URING model

/// URING dispatch (Linux-only): shared-nothing, one SO_REUSEPORT listener plus
/// io_uring ring per worker. Each worker multiplexes many connections through the
/// resumable h2 state machine on a completion loop and sends one coalesced reply
/// per readable batch (ADR-037 Phase 4 step 3).
pub fn runUring(comptime routes: []const Route, cfg: GrpcServerConfig) !void {
    // Runtime probe: io_uring can be unavailable on this host (seccomp/sandbox,
    // RLIMIT_MEMLOCK, or an old kernel). Without this, every worker would fail
    // setup, return, and the server would vanish right after binding (a confusing
    // ServerStartTimeout downstream). Fall back to the EPOLL shared-nothing loop.
    var probe = initUringRing() catch |err| {
        logSystem(cfg, "io_uring unavailable ({s}): not suited to this environment (commonly RLIMIT_MEMLOCK, the ulimit -l cap, too low for the ring size). Falling back to EPOLL.", .{@errorName(err)});

        return epoll_model.runEpoll(routes, cfg);
    };
    probe.deinit();

    const io = cfg.io;
    // cgroup-aware so a limited cpuset defaults to one worker per available CPU, not one per machine core.
    const cpu = common.getAvailableCpuCount();
    const worker_count = if (cfg.pool_size == 0) cpu else cfg.pool_size;
    const opts = common.serveOptsWithCache(cfg);

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
