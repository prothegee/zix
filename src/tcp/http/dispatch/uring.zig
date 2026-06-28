//! zix http .URING dispatch model (Linux-only): shared-nothing io_uring ring per
//! worker. Each readable batch recvs into the connection buffer, runs one request
//! through processRequest with the response staged into a RespSink, and submits
//! one coalesced send. Half-duplex per connection, one request per buffer (matches
//! the EPOLL path, ADR-037 Phase 4 step 4).

const std = @import("std");
const common = @import("common.zig");
const epoll_model = @import("epoll.zig");
const logSystem = common.logSystem;
const processRequest = common.processRequest;
const pinToCpu = common.pinToCpu;
const getAvailableCpuCount = common.getAvailableCpuCount;
const effectiveCacheEntries = common.effectiveCacheEntries;
const setNoDelay = common.setNoDelay;
const initUringRing = common.initUringRing;
const UringHttpConn = common.UringHttpConn;
const HttpProcOutcome = common.HttpProcOutcome;
const MAX_FD = common.MAX_FD;
const URING_CQE_BATCH = common.URING_CQE_BATCH;
const URING_SEND_BUF_SIZE = common.URING_SEND_BUF_SIZE;
const parser = @import("../parser.zig");
const rcache = @import("../../../utils/response_cache.zig");
const resp_mod = @import("../response.zig");
const setCache = resp_mod.setCache;
const setCompression = resp_mod.setCompression;
const RespSink = resp_mod.RespSink;
const fdWriteAll = resp_mod.fdWriteAll;
const uring = @import("../../../multiplexers/ring.zig");
const slab = @import("../../../multiplexers/slab.zig");
const IoUring = std.os.linux.IoUring;

/// Default minimum warm idle-connection pool floor. Overridden per worker from
/// config.uring_idle_pool_floor. Mirrors the zix.Http1 URING idle pool.
const URING_IDLE_POOL_FLOOR: usize = 64;

// --------------------------------------------------------- //
// URING dispatch (Linux): shared-nothing io_uring ring per worker.

/// One io_uring worker: a private SO_REUSEPORT listener and completion
/// loop. Each readable batch recvs into the connection buffer, runs one
/// request through processRequest with the response staged into a
/// RespSink, and submits one coalesced send. Half-duplex per connection,
/// one request per buffer (matches the EPOLL path, ADR-037 Phase 4 step 4).
fn uringWorker(server: anytype, io: std.Io, worker_id: usize) void {
    const ServerPtr = @TypeOf(server);
    const cfg = server.config;

    pinToCpu(worker_id);

    const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch return;
    var net_server = addr.listen(io, .{
        .mode = .stream,
        .kernel_backlog = @intCast(cfg.kernel_backlog),
        .reuse_address = true,
    }) catch return;
    defer net_server.deinit(io);
    const listener_fd = net_server.socket.handle;

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    _ = arena.allocator().alloc(u8, cfg.max_allocator_size) catch {};
    _ = arena.reset(.retain_capacity);

    // Per-worker response cache: lock-free by ownership, never shared.
    var response_cache: rcache.ResponseCache = undefined;
    var cache_on = false;
    if (cfg.response_cache) {
        if (rcache.ResponseCache.init(std.heap.smp_allocator, .{
            .max_entries = effectiveCacheEntries(cfg),
            .max_value_bytes = cfg.cache_max_value_bytes,
        })) |built| {
            response_cache = built;
            cache_on = true;
            setCache(&response_cache, cfg.cache_ttl_ms);
        } else |_| {
            cache_on = false;
        }
    }
    defer if (cache_on) {
        setCache(null, 0);
        response_cache.deinit();
    };

    // Response compression, stateless per worker. Active under .EPOLL and .URING,
    // like the cache.
    if (cfg.compress) setCompression(cfg.compress, cfg.compression_min_size, cfg.compression_max_out);
    defer setCompression(false, 0, 0);

    const slots = slab.mapZeroedSlots(?*UringHttpConn, MAX_FD) catch return;

    const Worker = struct {
        ring: IoUring,
        slots: []?*UringHttpConn,
        listener_fd: std.posix.fd_t,
        gen_counter: u24,
        server: ServerPtr,
        io: std.Io,
        arena: *std.heap.ArenaAllocator,
        recv_buf_size: usize,
        /// Per-connection send buffer size, set from config.uring_send_buf_size.
        send_buf_size: usize = URING_SEND_BUF_SIZE,
        /// SO_BUSY_POLL window applied to each accepted connection, set from config.busy_poll_us.
        /// Defaulted to 0 so dispatch-level tests need not set it (EPOLL parity).
        busy_poll_us: u32 = 0,
        /// Warm idle-connection pool, doubly linked (most-recently-used at the head). A closed
        /// connection is pooled with its recv and send buffers intact instead of freed, so a later
        /// accept reuses the allocation. This removes the three per-connection heap allocations
        /// (struct + recv buf + send buf) from the steady-state accept/close cycle. Past idleCap the
        /// least-recently-used tail is evicted, so the buffer reclaimed is never the one a churn
        /// accept is about to reuse. Mirrors the zix.Http1 URING idle pool.
        warm_head: ?*UringHttpConn = null,
        warm_tail: ?*UringHttpConn = null,
        warm_count: usize = 0,
        /// Cold idle-connection stack. An evicted warm tail has its buffer pages returned to the OS
        /// (MADV_DONTNEED) and is pushed here. The struct and virtual allocation stay reusable, so an
        /// accept that drains the warm pool reuses a cold connection with no allocator call, paying
        /// only a recv first-touch fault. Singly linked via next.
        cold_head: ?*UringHttpConn = null,
        /// Live connections held in the slot table (this worker's concurrency). The warm pool cap is
        /// derived from this so the pool always covers the active working set. See idleCap.
        live_count: usize = 0,
        /// Minimum warm pool floor, set from config.uring_idle_pool_floor.
        idle_floor: usize = URING_IDLE_POOL_FLOOR,

        const W = @This();
        const allocator = std.heap.smp_allocator;
        const lx = std.os.linux;

        fn deinit(worker: *W) void {
            for (worker.slots) |maybe_conn| {
                if (maybe_conn) |conn| {
                    _ = lx.close(conn.fd);
                    allocator.free(conn.buf);
                    allocator.free(conn.send_buf);
                    allocator.destroy(conn);
                }
            }

            var warm = worker.warm_head;
            while (warm) |conn| {
                warm = conn.next;
                allocator.free(conn.buf);
                allocator.free(conn.send_buf);
                allocator.destroy(conn);
            }

            var cold = worker.cold_head;
            while (cold) |conn| {
                cold = conn.next;
                allocator.free(conn.buf);
                allocator.free(conn.send_buf);
                allocator.destroy(conn);
            }

            slab.unmapSlots(worker.slots);
            worker.ring.deinit();
        }

        /// Take a connection object for a freshly accepted fd: pop one from the idle pool (recv and
        /// send buffers intact) when available, otherwise allocate a new one with both buffers. The
        /// warm pool is preferred (pages resident, no fault), the cold pool is the fallback (reusable,
        /// its first recv faults the pages back). Returns null only when a fresh allocation fails. The
        /// caller resets the per-connection state fields.
        fn acquireConn(worker: *W) ?*UringHttpConn {
            if (worker.warm_head) |conn| {
                worker.warm_head = conn.next;
                if (worker.warm_head) |head| head.prev = null else worker.warm_tail = null;
                worker.warm_count -= 1;

                return conn;
            }

            if (worker.cold_head) |conn| {
                worker.cold_head = conn.next;

                return conn;
            }

            const conn = allocator.create(UringHttpConn) catch return null;
            const buf = allocator.alloc(u8, worker.recv_buf_size) catch {
                allocator.destroy(conn);
                return null;
            };
            const send_buf = allocator.alloc(u8, worker.send_buf_size) catch {
                allocator.free(buf);
                allocator.destroy(conn);
                return null;
            };
            conn.buf = buf;
            conn.send_buf = send_buf;

            return conn;
        }

        /// Warm idle-pool cap, derived from this worker's live concurrency so the pool keeps up to one
        /// full reconnect of the live working set warm. The floor keeps a small warm reserve when idle.
        fn idleCap(worker: *const W) usize {
            return @max(worker.live_count, worker.idle_floor);
        }

        /// Evict the least-recently-used warm connection (the tail) to the cold stack: return its
        /// buffer pages to the OS with MADV_DONTNEED, unlink it from the warm pool, and push it cold.
        /// Reclaiming the LRU tail (not the connection just released, which is the hot head) keeps the
        /// active churn working set resident.
        fn evictColdTail(worker: *W) void {
            const victim = worker.warm_tail orelse return;

            worker.warm_tail = victim.prev;
            if (victim.prev) |p| p.next = null else worker.warm_head = null;
            worker.warm_count -= 1;

            slab.releaseSlabPages(victim.buf);
            slab.releaseSlabPages(victim.send_buf);

            victim.prev = null;
            victim.next = worker.cold_head;
            worker.cold_head = victim;
        }

        /// Return a closed connection to the warm idle pool, then trim the cold tail if the pool now
        /// exceeds the cap. A send_buf the grow allocator doubled for an oversized response is shrunk
        /// back to the base size so a connection that served one large response does not carry a
        /// multi-MiB buffer for life. Both steps are off the parse and handler hot path.
        fn releaseConn(worker: *W, conn: *UringHttpConn) void {
            if (conn.send_buf.len > worker.send_buf_size) {
                if (allocator.realloc(conn.send_buf, worker.send_buf_size)) |shrunk| {
                    conn.send_buf = shrunk;
                } else |_| {}
            }

            conn.prev = null;
            conn.next = worker.warm_head;
            if (worker.warm_head) |head| head.prev = conn;
            worker.warm_head = conn;
            if (worker.warm_tail == null) worker.warm_tail = conn;
            worker.warm_count += 1;

            if (worker.warm_count > worker.idleCap()) worker.evictColdTail();
        }

        fn getSqe(worker: *W) ?*lx.io_uring_sqe {
            return worker.ring.get_sqe() catch {
                _ = worker.ring.submit() catch return null;

                return worker.ring.get_sqe() catch null;
            };
        }

        fn lookup(worker: *W, decoded: uring.Decoded) ?*UringHttpConn {
            const idx: usize = @intCast(decoded.fd);
            if (idx >= worker.slots.len) return null;

            const conn = worker.slots[idx] orelse return null;
            if (conn.gen != decoded.gen) return null;

            return conn;
        }

        fn destroyConn(worker: *W, conn: *UringHttpConn) void {
            worker.slots[@intCast(conn.fd)] = null;
            worker.live_count -= 1;

            worker.releaseConn(conn);
        }

        fn finishClose(worker: *W, conn: *UringHttpConn) void {
            _ = lx.close(conn.fd);
            worker.destroyConn(conn);
        }

        fn beginClose(worker: *W, conn: *UringHttpConn) void {
            conn.closing = true;
            if (conn.inflight > 0) return;

            if (conn.staged > 0) {
                worker.submitSend(conn);
                return;
            }

            worker.finishClose(conn);
        }

        fn armAccept(worker: *W) void {
            const sqe = worker.getSqe() orelse return;
            sqe.prep_multishot_accept(worker.listener_fd, null, null, 0);
            sqe.user_data = uring.packUserData(.accept, 0, worker.listener_fd);
        }

        fn armRecv(worker: *W, conn: *UringHttpConn) void {
            if (conn.filled >= conn.buf.len) {
                worker.beginClose(conn);
                return;
            }

            const sqe = worker.getSqe() orelse {
                worker.beginClose(conn);
                return;
            };
            sqe.prep_recv(conn.fd, conn.buf[conn.filled..], 0);
            sqe.user_data = uring.packUserData(.recv, conn.gen, conn.fd);
        }

        fn submitSend(worker: *W, conn: *UringHttpConn) void {
            const sqe = worker.getSqe() orelse {
                worker.finishClose(conn);
                return;
            };
            sqe.prep_send(conn.fd, conn.send_buf[0..conn.staged], lx.MSG.NOSIGNAL);
            sqe.user_data = uring.packUserData(.send, conn.gen, conn.fd);

            conn.inflight = conn.staged;
        }

        fn handleAccept(worker: *W, cqe: lx.io_uring_cqe) void {
            const rearm = (cqe.flags & lx.IORING_CQE_F_MORE) == 0;
            defer if (rearm) worker.armAccept();

            if (cqe.res < 0) return;

            const conn_fd: std.posix.fd_t = cqe.res;
            const idx: usize = @intCast(conn_fd);
            if (idx >= worker.slots.len) {
                _ = lx.close(conn_fd);
                return;
            }

            setNoDelay(conn_fd);
            common.setBusyPoll(conn_fd, worker.busy_poll_us);

            const conn = worker.acquireConn() orelse {
                _ = lx.close(conn_fd);
                return;
            };

            worker.gen_counter +%= 1;
            const buf = conn.buf;
            const send_buf = conn.send_buf;
            conn.* = .{
                .fd = conn_fd,
                .gen = worker.gen_counter,
                .buf = buf,
                .filled = 0,
                .send_buf = send_buf,
                .staged = 0,
                .inflight = 0,
                .closing = false,
            };
            worker.slots[idx] = conn;
            worker.live_count += 1;

            worker.armRecv(conn);
        }

        fn handleRecv(worker: *W, cqe: lx.io_uring_cqe, decoded: uring.Decoded) void {
            const conn = worker.lookup(decoded) orelse return;

            if (cqe.res <= 0) {
                worker.beginClose(conn);
                return;
            }

            conn.filled += @intCast(cqe.res);

            switch (worker.process(conn)) {
                .need_more => worker.armRecv(conn),
                .keep_alive => {
                    if (conn.staged > 0) worker.submitSend(conn) else worker.armRecv(conn);
                },
                .close => {
                    if (conn.staged > 0) {
                        worker.submitSend(conn);
                        conn.closing = true;
                    } else {
                        worker.beginClose(conn);
                    }
                },
            }
        }

        fn handleSend(worker: *W, cqe: lx.io_uring_cqe, decoded: uring.Decoded) void {
            const conn = worker.lookup(decoded) orelse return;

            if (cqe.res < 0) {
                worker.beginClose(conn);
                return;
            }

            const sent: usize = @intCast(cqe.res);
            if (sent < conn.staged) {
                std.mem.copyForwards(u8, conn.send_buf[0 .. conn.staged - sent], conn.send_buf[sent..conn.staged]);
                conn.staged -= sent;
                conn.inflight = 0;
                worker.submitSend(conn);

                return;
            }

            conn.staged = 0;
            conn.inflight = 0;

            if (conn.closing) {
                worker.finishClose(conn);
                return;
            }

            worker.armRecv(conn);
        }

        /// Find the header terminator (accumulating across recvs), then
        /// run one request with the response staged into a RespSink. The
        /// request is consumed (conn.filled reset to 0), matching the
        /// EPOLL one-request-per-buffer behavior.
        fn process(worker: *W, conn: *UringHttpConn) HttpProcOutcome {
            if (parser.findHeaderEnd(conn.buf[0..conn.filled], 0) == null) {
                if (conn.filled >= conn.buf.len) {
                    fdWriteAll(conn.fd, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n") catch {};
                    return .close;
                }

                return .need_more;
            }

            var sink = RespSink{ .fd = conn.fd, .buf = conn.send_buf };
            resp_mod.tl_resp_sink = &sink;
            _ = worker.arena.reset(.retain_capacity);

            const stream = std.Io.net.Stream{ .socket = .{ .handle = conn.fd, .address = undefined } };
            const outcome = processRequest(worker.server, stream, conn.fd, worker.io, conn.buf[0..conn.filled], worker.arena);
            resp_mod.tl_resp_sink = null;

            conn.staged = sink.len;
            conn.filled = 0;
            if (sink.failed) return .close;

            return if (outcome == .keep_alive) .keep_alive else .close;
        }

        fn run(worker: *W) void {
            worker.armAccept();

            var cqes: [URING_CQE_BATCH]lx.io_uring_cqe = undefined;
            while (true) {
                _ = worker.ring.submit_and_wait(1) catch |err| switch (err) {
                    error.SignalInterrupt => continue,
                    else => return,
                };

                const count = worker.ring.copy_cqes(&cqes, 0) catch return;
                for (cqes[0..count]) |cqe| {
                    const decoded = uring.unpackUserData(cqe.user_data);
                    switch (decoded.op) {
                        .accept => worker.handleAccept(cqe),
                        .recv => worker.handleRecv(cqe, decoded),
                        .send => worker.handleSend(cqe, decoded),
                        .timeout => {},
                        .close => {},
                    }
                }
            }
        }
    };

    var worker = Worker{
        .ring = undefined,
        .slots = slots,
        .listener_fd = listener_fd,
        .gen_counter = 0,
        .server = server,
        .io = io,
        .arena = &arena,
        .recv_buf_size = cfg.max_recv_buf,
        .send_buf_size = cfg.uring_send_buf_size,
        .busy_poll_us = cfg.busy_poll_us,
        .idle_floor = cfg.uring_idle_pool_floor,
    };
    worker.ring = initUringRing() catch return;
    defer worker.deinit();

    worker.run();
}

// --------------------------------------------------------- //
// URING model

/// URING dispatch (Linux-only): shared-nothing io_uring ring per worker.
pub fn runUring(server: anytype, io: std.Io) !void {
    const cfg = server.config;

    // Runtime probe: io_uring can be unavailable on this host (seccomp/sandbox,
    // RLIMIT_MEMLOCK, or an old kernel). Without this, every worker would fail
    // setup, return, and the server would vanish right after binding (a confusing
    // ServerStartTimeout downstream). Fall back to the EPOLL shared-nothing loop.
    var probe = initUringRing() catch |err| {
        logSystem(cfg, "io_uring unavailable ({s}): not suited to this environment (commonly RLIMIT_MEMLOCK, the ulimit -l cap, too low for the ring size). Falling back to EPOLL.", .{@errorName(err)});

        return epoll_model.runEpoll(server, io);
    };
    probe.deinit();

    const worker_count = if (cfg.workers == 0) getAvailableCpuCount() else cfg.workers;

    logSystem(cfg, "listening on {s}:{d} (io_uring, {d} workers, shared-nothing)", .{
        cfg.ip, cfg.port, worker_count,
    });

    const threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(threads);

    // std.compress.flate.Compress is about 230 KB and is built on the handler's stack
    // frame, so a compressing handler (sendNegotiated) needs more than the default
    // 512 KB worker stack. Thread stacks are demand-paged, so the larger limit costs
    // almost no RSS, and the bump applies only when compression is enabled.
    const worker_stack: usize = if (cfg.compress) @max(cfg.worker_stack_size_bytes, cfg.worker_stack_compress_bytes) else cfg.worker_stack_size_bytes;

    for (threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{ .stack_size = worker_stack }, uringWorker, .{ server, io, idx });
    }

    for (threads) |t| t.join();
}
