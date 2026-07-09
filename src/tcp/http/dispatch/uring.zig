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
const setNonBlock = common.setNonBlock;
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
const writeAllFD = resp_mod.writeAllFD;
const uring = @import("../../../multiplexers/ring.zig");
const slab = @import("../../../multiplexers/slab.zig");
const reuseport = @import("../../../multiplexers/reuseport.zig");
const tls_mux = @import("../tls_mux.zig");
const tls_conn = @import("../../../multiplexers/tls_conn.zig");
const Tls = @import("../../../tls/Tls.zig");
const IoUring = std.os.linux.IoUring;

/// Default minimum warm idle-connection pool floor. Overridden per worker from
/// config.uring_idle_pool_floor. Mirrors the zix.Http1 URING idle pool.
const URING_IDLE_POOL_FLOOR: usize = 64;

// --------------------------------------------------------- //
// URING dispatch (Linux): shared-nothing io_uring ring per worker.

/// Per-worker io_uring completion loop, parameterized by the concrete server
/// pointer type (the router is comptime-baked into the server, ADR-043). Hoisting
/// this to module scope (instead of a struct local to uringWorker) lets the idle
/// pool and prewarm be unit-tested directly, mirroring the zix.Http1 URING worker.
///
/// Param:
/// ServerPtr - type (pointer to the HttpServerImpl instance)
fn UringWorker(comptime ServerPtr: type) type {
    return struct {
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
        /// Dual-listener TLS side (config.tls + config.tls_port). Inactive by default (-1 / null),
        /// so a cleartext-only worker sees zero layout change on its hot structures.
        tls_listener_fd: std.posix.fd_t = -1,
        tls_ctx: ?*Tls.Context = null,
        tls_conns: ?TlsConnTable = null,
        tls_gen_counter: u24 = 0,
        /// Requests served by this worker (cleartext dispatch). Single-owner plain
        /// increment (no contention), reported through the system logger at worker
        /// exit so REUSEPORT skew across workers is measurable.
        requests_served: u64 = 0,

        const W = @This();
        const allocator = std.heap.smp_allocator;
        const lx = std.os.linux;

        const TlsWorker = tls_mux.Worker(ServerPtr);

        /// Ring-hosted TLS connection (dual listener): the shared TLS connection (tls_mux) plus
        /// ring bookkeeping. The ciphertext recv buffer is per connection because the kernel
        /// fills it asynchronously (the .EPOLL paths read into per-event stack staging instead).
        const UringTlsConn = struct {
            conn: TlsWorker.TlsConn,
            gen: u24,
            cipher_buf: []u8,
        };

        fn freeUringTlsConn(ring_conn: *UringTlsConn) void {
            ring_conn.conn.transport.deinit();
            std.heap.smp_allocator.free(ring_conn.cipher_buf);
            std.heap.smp_allocator.destroy(ring_conn);
        }

        /// Per-worker fd -> UringTlsConn map for the dual-listener TLS side.
        const TlsConnTable = tls_conn.ConnTable(UringTlsConn, MAX_FD, freeUringTlsConn);

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
            if (worker.tls_conns) |*tls_table| tls_table.deinit();
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

        /// Seed the warm idle pool with idle_floor connections before the accept
        /// loop starts, so the first burst of accepts reuses resident buffers
        /// instead of allocating and first-touch faulting them under load. Without
        /// it the first run after startup pays every connection's allocation and
        /// page fault while a later run (pool already warm from the prior run) does
        /// not, which reads as a cold-first-run gap in back-to-back measurements.
        ///
        /// Note:
        /// - The seed count is idle_floor, the reserve the pool settles to when
        ///   idle (see idleCap). Seeding to it keeps the resident set identical to
        ///   steady state, so the cost is paid once at startup, not carried as
        ///   extra memory.
        /// - Each connection's recv and send buffers are touched page by page so
        ///   the pages are resident up front, not faulted on the first recv.
        /// - A partial allocation failure stops the seed early and leaves whatever
        ///   was already warmed. Startup never fails on a warm-pool short-fall: the
        ///   accept path still allocates on demand when the pool is empty.
        fn prewarmPool(worker: *W) void {
            var seeded: usize = 0;
            while (seeded < worker.idle_floor) : (seeded += 1) {
                const conn = allocator.create(UringHttpConn) catch break;
                const buf = allocator.alloc(u8, worker.recv_buf_size) catch {
                    allocator.destroy(conn);
                    break;
                };
                const send_buf = allocator.alloc(u8, worker.send_buf_size) catch {
                    allocator.free(buf);
                    allocator.destroy(conn);
                    break;
                };

                @memset(buf, 0);
                @memset(send_buf, 0);

                conn.buf = buf;
                conn.send_buf = send_buf;
                conn.prev = null;
                conn.next = worker.warm_head;
                if (worker.warm_head) |head| head.prev = conn;
                worker.warm_head = conn;
                if (worker.warm_tail == null) worker.warm_tail = conn;
                worker.warm_count += 1;
            }
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
                    writeAllFD(conn.fd, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n") catch {};
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
            worker.requests_served += 1;

            conn.staged = sink.len;
            conn.filled = 0;
            if (sink.failed) return .close;

            return if (outcome == .keep_alive) .keep_alive else .close;
        }

        // ----------------------------------------------------- //
        // Dual-listener TLS side (config.tls_port): ciphertext recv and the staged-ciphertext
        // flush ride the ring (tls_recv / tls_send ops), the TLS connection logic is tls_mux's
        // (shared with the .EPOLL paths). Half-duplex per connection: while a flush send is in
        // flight no recv is armed, so the transport's staging buffer is never compacted while
        // the kernel reads it.

        fn lookupTls(worker: *W, decoded: uring.Decoded) ?*UringTlsConn {
            const table = if (worker.tls_conns) |*tls_table| tls_table else return null;

            const ring_conn = table.get(decoded.fd) orelse return null;
            if (ring_conn.gen != decoded.gen) return null;

            return ring_conn;
        }

        fn armTlsAccept(worker: *W) void {
            const sqe = worker.getSqe() orelse return;
            sqe.prep_multishot_accept(worker.tls_listener_fd, null, null, 0);
            sqe.user_data = uring.packUserData(.tls_accept, 0, worker.tls_listener_fd);
        }

        fn handleTlsAccept(worker: *W, cqe: lx.io_uring_cqe) void {
            const rearm = (cqe.flags & lx.IORING_CQE_F_MORE) == 0;
            defer if (rearm) worker.armTlsAccept();

            if (cqe.res < 0) return;

            const conn_fd: std.posix.fd_t = cqe.res;
            const table = if (worker.tls_conns) |*tls_table| tls_table else {
                _ = lx.close(conn_fd);
                return;
            };
            const idx: usize = @intCast(conn_fd);
            if (idx >= table.slots.len) {
                _ = lx.close(conn_fd);
                return;
            }

            setNoDelay(conn_fd);
            // The transport writes records directly (staging on EAGAIN), so the fd must be
            // non-blocking.
            setNonBlock(conn_fd);

            const ring_conn = allocator.create(UringTlsConn) catch {
                _ = lx.close(conn_fd);
                return;
            };
            const cipher_buf = allocator.alloc(u8, tls_conn.read_staging_size) catch {
                allocator.destroy(ring_conn);
                _ = lx.close(conn_fd);
                return;
            };

            worker.tls_gen_counter +%= 1;
            ring_conn.* = .{
                .conn = .{
                    .transport = tls_conn.Transport.init(conn_fd, worker.tls_ctx.?),
                    .server = worker.server,
                    .ctx = worker.tls_ctx.?,
                },
                .gen = worker.tls_gen_counter,
                .cipher_buf = cipher_buf,
            };
            table.put(conn_fd, ring_conn);

            worker.armTlsRecv(ring_conn);
        }

        /// Tear a TLS connection down: drop it from the table (frees the conn object) and hand
        /// the fd close to the ring.
        fn closeTls(worker: *W, ring_conn: *UringTlsConn) void {
            const fd = ring_conn.conn.transport.fd;
            if (worker.tls_conns) |*tls_table| tls_table.drop(fd);

            const sqe = worker.getSqe() orelse {
                _ = lx.close(fd);
                return;
            };
            sqe.prep_close(fd);
            sqe.user_data = uring.packUserData(.close, 0, fd);
        }

        fn armTlsRecv(worker: *W, ring_conn: *UringTlsConn) void {
            const sqe = worker.getSqe() orelse {
                worker.closeTls(ring_conn);
                return;
            };
            sqe.prep_recv(ring_conn.conn.transport.fd, ring_conn.cipher_buf, 0);
            sqe.user_data = uring.packUserData(.tls_recv, ring_conn.gen, ring_conn.conn.transport.fd);
        }

        /// Flush the transport's staged ciphertext (wbuf[woff..wlen]) with an on-ring send.
        fn submitTlsSend(worker: *W, ring_conn: *UringTlsConn) void {
            const transport = &ring_conn.conn.transport;

            const sqe = worker.getSqe() orelse {
                worker.closeTls(ring_conn);
                return;
            };
            sqe.prep_send(transport.fd, transport.wbuf[transport.woff..transport.wlen], lx.MSG.NOSIGNAL);
            sqe.user_data = uring.packUserData(.tls_send, ring_conn.gen, transport.fd);
        }

        fn handleTlsRecv(worker: *W, cqe: lx.io_uring_cqe, decoded: uring.Decoded) void {
            const ring_conn = worker.lookupTls(decoded) orelse return;

            if (cqe.res <= 0) {
                worker.closeTls(ring_conn);
                return;
            }

            const keep = TlsWorker.onCiphertext(&ring_conn.conn, ring_conn.cipher_buf[0..@intCast(cqe.res)], worker.io, worker.arena);
            const transport = &ring_conn.conn.transport;

            if (!keep) {
                worker.closeTls(ring_conn);
                return;
            }

            // Backpressure-staged ciphertext: flush it on the ring before the next recv.
            if (transport.wlen > transport.woff) {
                worker.submitTlsSend(ring_conn);
                return;
            }

            if (transport.wclose) {
                worker.closeTls(ring_conn);
                return;
            }

            worker.armTlsRecv(ring_conn);
        }

        fn handleTlsSend(worker: *W, cqe: lx.io_uring_cqe, decoded: uring.Decoded) void {
            const ring_conn = worker.lookupTls(decoded) orelse return;
            const transport = &ring_conn.conn.transport;

            if (cqe.res <= 0) {
                worker.closeTls(ring_conn);
                return;
            }

            transport.woff += @intCast(cqe.res);
            if (transport.woff < transport.wlen) {
                worker.submitTlsSend(ring_conn);
                return;
            }

            // Drained. Keep the buffer for reuse (freed at close), mirroring the EPOLL flush.
            transport.woff = 0;
            transport.wlen = 0;
            transport.want_out = false;

            if (transport.wclose) {
                worker.closeTls(ring_conn);
                return;
            }

            worker.armTlsRecv(ring_conn);
        }

        // ----------------------------------------------------- //

        fn run(worker: *W) void {
            worker.armAccept();
            if (worker.tls_listener_fd != -1) worker.armTlsAccept();

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
                        .tls_accept => worker.handleTlsAccept(cqe),
                        .tls_recv => worker.handleTlsRecv(cqe, decoded),
                        .tls_send => worker.handleTlsSend(cqe, decoded),
                    }
                }
            }
        }
    };
}

/// One io_uring worker: a private SO_REUSEPORT listener and completion
/// loop. Each readable batch recvs into the connection buffer, runs one
/// request through processRequest with the response staged into a
/// RespSink, and submits one coalesced send. Half-duplex per connection,
/// one request per buffer (matches the EPOLL path, ADR-037 Phase 4 step 4).
fn uringWorker(server: anytype, io: std.Io, worker_id: usize, steering: ?reuseport.Steering) void {
    const ServerPtr = @TypeOf(server);
    const cfg = server.config;

    pinToCpu(worker_id);

    // Bind under the order gate: REUSEPORT group index i = worker i,
    // so the cpu-mod-N steering lands on the worker pinned to that slot.
    var bind_turn = reuseport.BindTurn.begin(steering, worker_id);
    defer bind_turn.release();

    const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch return;
    var net_server = addr.listen(io, .{
        .mode = .stream,
        .kernel_backlog = @intCast(cfg.kernel_backlog),
        .reuse_address = true,
    }) catch return;
    defer net_server.deinit(io);
    const listener_fd = net_server.socket.handle;

    if (steering) |steer| reuseport.attachCpuSteering(listener_fd, steer.group_size);

    // Dual-listener TLS side: a second listener on tls_port whose connections terminate TLS in
    // this same ring loop (no separate epoll fleet).
    const tls_active = cfg.tls != null and cfg.tls_port != 0;
    var tls_srv: std.Io.net.Server = undefined;
    var tls_listener_fd: std.posix.fd_t = -1;
    if (tls_active) {
        const tls_addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.tls_port) catch return;
        tls_srv = tls_addr.listen(io, .{
            .mode = .stream,
            .kernel_backlog = @intCast(cfg.kernel_backlog),
            .reuse_address = true,
        }) catch return;
        tls_listener_fd = tls_srv.socket.handle;
        if (steering) |steer| reuseport.attachCpuSteering(tls_listener_fd, steer.group_size);
    }
    defer if (tls_active) tls_srv.deinit(io);

    // Both groups joined: release the bind turn to the next worker.
    bind_turn.release();

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

    const Worker = UringWorker(ServerPtr);

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
        .tls_listener_fd = tls_listener_fd,
        .tls_ctx = if (tls_active) cfg.tls else null,
    };
    worker.ring = initUringRing() catch return;
    if (tls_active) worker.tls_conns = Worker.TlsConnTable.init() catch return;
    defer worker.deinit();

    // Seed the warm idle pool before the accept loop so the first burst reuses
    // resident buffers instead of faulting them in under load.
    worker.prewarmPool();

    worker.run();

    logSystem(cfg, "uring worker {d}: {d} requests served", .{ worker_id, worker.requests_served });
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
    if (cfg.tls != null and cfg.tls_port != 0)
        logSystem(cfg, "dual listener: https/1.1 TLS on {s}:{d} (same workers, on-ring)", .{ cfg.ip, cfg.tls_port });

    const threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(threads);

    // std.compress.flate.Compress is about 230 KB and is built on the handler's stack
    // frame, so a compressing handler (sendNegotiated) needs more than the default
    // 512 KB worker stack. Thread stacks are demand-paged, so the larger limit costs
    // almost no RSS, and the bump applies only when compression is enabled.
    const worker_stack: usize = if (cfg.compress) @max(cfg.worker_stack_size_bytes, cfg.worker_stack_compress_bytes) else cfg.worker_stack_size_bytes;

    // CBPF steering: one shared bind-order gate, alive until join().
    var bind_gate = reuseport.BindOrderGate{};
    const steering: ?reuseport.Steering = if (cfg.reuseport_cbpf) .{ .gate = &bind_gate, .group_size = worker_count } else null;

    for (threads, 0..) |*thread, idx| {
        thread.* = try std.Thread.spawn(.{ .stack_size = worker_stack }, uringWorker, .{ server, io, idx, steering });
    }

    for (threads) |thread| thread.join();
}

// --------------------------------------------------------- //

test "zix http: URING prewarmPool seeds the warm pool to idle_floor with sized buffers" {
    const gpa = std.heap.smp_allocator;

    const Worker = UringWorker(*u8);
    const recv_size: usize = 6 * 1024;
    const send_size: usize = 8 * 1024;
    var worker = Worker{
        .ring = undefined,
        .slots = &[_]?*UringHttpConn{},
        .listener_fd = -1,
        .gen_counter = 0,
        .server = undefined,
        .io = undefined,
        .arena = undefined,
        .recv_buf_size = recv_size,
        .send_buf_size = send_size,
        .idle_floor = 4,
    };

    worker.prewarmPool();

    try std.testing.expectEqual(@as(usize, 4), worker.warm_count);
    try std.testing.expect(worker.warm_head != null);
    try std.testing.expect(worker.warm_tail != null);

    // Every seeded connection carries buffers at the configured sizes, resident
    // and reusable: an accept pops them from the warm pool with no allocator call.
    var idx: usize = 0;
    while (idx < 4) : (idx += 1) {
        const conn = worker.acquireConn().?;
        try std.testing.expectEqual(recv_size, conn.buf.len);
        try std.testing.expectEqual(send_size, conn.send_buf.len);

        gpa.free(conn.buf);
        gpa.free(conn.send_buf);
        gpa.destroy(conn);
    }

    try std.testing.expectEqual(@as(usize, 0), worker.warm_count);
    try std.testing.expectEqual(@as(?*UringHttpConn, null), worker.warm_head);
    try std.testing.expectEqual(@as(?*UringHttpConn, null), worker.warm_tail);
}

test "zix http: URING prewarmPool with a zero floor seeds nothing" {
    const Worker = UringWorker(*u8);
    var worker = Worker{
        .ring = undefined,
        .slots = &[_]?*UringHttpConn{},
        .listener_fd = -1,
        .gen_counter = 0,
        .server = undefined,
        .io = undefined,
        .arena = undefined,
        .recv_buf_size = 4096,
        .send_buf_size = 4096,
        .idle_floor = 0,
    };

    worker.prewarmPool();

    try std.testing.expectEqual(@as(usize, 0), worker.warm_count);
    try std.testing.expectEqual(@as(?*UringHttpConn, null), worker.warm_head);
    try std.testing.expectEqual(@as(?*UringHttpConn, null), worker.warm_tail);
}
