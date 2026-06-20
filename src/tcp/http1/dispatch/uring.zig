//! zix http1 .URING (io_uring) dispatch model.

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("../config.zig").Http1ServerConfig;
const core = @import("../core.zig");
const cache = @import("../../../utils/response_cache.zig");
const ws = @import("../websocket.zig");
const uring = @import("../../../multiplexers/ring.zig");
const slab = @import("../../../multiplexers/slab.zig");
const HandlerFn = core.HandlerFn;
const IoUring = std.os.linux.IoUring;
const common = @import("common.zig");
const logSystem = common.logSystem;
const setNoDelay = common.setNoDelay;
const pinToCpu = common.pinToCpu;
const getAvailableCpuCount = common.getAvailableCpuCount;
const decodeChunkedInBuf = common.decodeChunkedInBuf;
const parseGetFastPath = common.parseGetFastPath;
const effectiveCacheEntries = common.effectiveCacheEntries;
const MAX_FD = common.MAX_FD;

// --------------------------------------------------------- //
// URING model: shared-nothing io_uring, one ring + listener per worker (ADR-037).
// Minimal correct core: multishot accept, an fd-indexed slot table with a
// generation-tagged user_data against fd reuse, a fixed per-connection recv
// buffer with a plain recv SQE (data lands directly in conn.buf, zero copy),
// one coalesced send per readable batch, and a batched CQE drain. Half-duplex
// per connection (at most one recv or one send in flight), so a blocking sink
// flush can never interleave with an in-flight send.
//
// Phase 3 (ADR-037) lever results (rnd/0.4.x/uring_phase3_results.txt):
// 1. ring setup flags (SINGLE_ISSUER | DEFER_TASKRUN): measured null on the
//    12-core loopback box, but the reference ring engines run with them at
//    scale, so they are applied here behind a kernel-version probe with a
//    flagless fallback (initUringRing). Costless where the kernel lacks them,
//    and matches the reference engines' single-issuer fast path otherwise.
// 2. multishot recv + provided buffer ring: REVERTED, a regression. It forces a
//    memcpy from the kernel-selected buffer into conn.buf for accumulation, and
//    that copy (largest at pipeline depth 16) outweighs the multishot re-arm
//    saving the plain recv-into-conn.buf path avoids by receiving in place.

/// SQ entries per worker ring.
const URING_ENTRIES: u16 = 4096;

/// CQ entries per worker ring. Multishot accept plus a coalesced send per
/// readable batch can land many completions per enter at high connection
/// counts, so the completion queue is requested larger than the default (2x SQ)
/// via IORING_SETUP_CQSIZE to leave overflow headroom.
const URING_CQ_ENTRIES: u32 = 16 * 1024;

/// Max CQEs drained per loop pass.
const URING_CQE_BATCH: usize = 512;

/// Per-connection staged-response buffer. Since URING is fully async (unlike
/// EPOLL), each connection needs its own buffer. 16 KiB easily covers the max
/// response (~12 KiB for `/json`) plus a tiny pipelined burst. Dropping this
/// from EPOLL's 64 KiB saves 48 KiB/conn, which is critical for memory limits
/// at high concurrency. A response larger than this grows send_buf up to
/// URING_SEND_BUF_MAX so it still leaves as one on-ring send.
const URING_SEND_BUF_SIZE: usize = 16 * 1024;

/// Hard ceiling for a grown per-connection send buffer. A handler emitting a
/// single response (or a coalesced pipelined batch) larger than
/// URING_SEND_BUF_SIZE grows send_buf up to this cap so the response still goes
/// out as one on-ring send, instead of a blocking off-ring write that would
/// stall every connection on the worker. Past the cap the core sink falls back
/// to a direct flush. 1 MiB covers any realistic inline response while bounding
/// worst-case per-connection memory.
const URING_SEND_BUF_MAX: usize = 1024 * 1024;

/// Idle-pool warm floor (A2). The minimum number of closed connections kept warm
/// (buffers resident, allocation-free to reuse) when the worker is otherwise idle,
/// so a trickle of new connections after a quiet spell still skips the allocator.
/// The effective warm cap is derived per worker as max(live_count, this floor),
/// see UringWorker.idleCap.
const URING_IDLE_POOL_FLOOR: usize = 64;

/// Initialize a worker ring with the single-issuer fast-path flags, falling
/// back to a flagless ring when the kernel does not support them.
///
/// Note:
/// - SINGLE_ISSUER and DEFER_TASKRUN cut enter-time task-run overhead on a
///   one-thread-per-ring loop (kernel >= 6.1, and the ring is created,
///   submitted, and reaped on this one worker thread). CQSIZE enlarges the
///   completion queue to URING_CQ_ENTRIES and CLAMP keeps the requested sizes
///   within the kernel maximum. On an older kernel init_params returns an
///   error, so the flagless init is the correct fallback (the same fallback the
///   reference ring engines ship).
///
/// Return:
/// - IoUring on success
/// - error only when the flagless fallback also fails (no ring possible)
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

/// WebSocket provided-buffer ring (ADR-037 Phase 4b). One ring per worker,
/// shared by every WebSocket connection, so an idle connection holds no recv
/// buffer: the kernel hands one over only when a frame actually arrives. That is
/// the memory-scaling win at high connection counts, and parsing in place out of
/// the selected buffer keeps the common whole-frame path zero-copy.
const WS_RING_BGID: u16 = 1;

const WS_RING_BUF_SIZE: u32 = 4096;

const WS_RING_BUF_COUNT: u16 = 256;

/// Per-connection ring state. buf accumulates request (or frame) bytes between
/// recv completions. send_buf front [0..inflight] is owned by the kernel while a
/// send SQE is outstanding, [inflight..staged] is appended and waiting.
/// closing marks a connection that must be freed once the last send lands. ws is
/// set once the connection upgrades to WebSocket: from then on buf holds frame
/// bytes and the recv loop pumps frames instead of parsing HTTP.
const UringConn = struct {
    fd: std.posix.fd_t,
    gen: u24,
    buf: []u8,
    filled: usize,
    send_buf: []u8,
    staged: usize,
    inflight: usize,
    closing: bool,
    /// Request-body bytes still to read and discard off the socket for a body
    /// too large to buffer (the response was already staged). Mirrors the EPOLL
    /// Conn.drain. While > 0 the connection is draining, not parsing requests.
    drain: usize = 0,
    /// Close the connection once the drain finishes (the request was not
    /// keep-alive). Mirrors the EPOLL Conn.drain_close.
    drain_close: bool = false,
    ws: ?core.WsFrameFn = null,
    /// Idle-pool links, valid only while this connection sits in the worker's
    /// idle pool between a close and the next accept that reuses it. The warm
    /// pool is doubly linked (most-recently-used at the head, least-recently-used
    /// at the tail) so the release path can evict the LRU tail in O(1). The cold
    /// stack uses next only.
    next: ?*UringConn = null,
    prev: ?*UringConn = null,
};

/// Build a concrete io_uring worker with the handler and optional raw
/// interceptor baked in at compile time, mirroring epollWorkerFn.
fn UringWorker(comptime handler_fn: HandlerFn, comptime raw_fn: ?core.RawFn) type {
    return struct {
        ring: IoUring,
        slots: []?*UringConn,
        listener_fd: std.posix.fd_t,
        gen_counter: u24,
        recv_buf_size: usize,
        handler_timeout_ms: u32,
        /// Shared per-worker scratch for unmasking WebSocket frame payloads
        /// during a pump pass. Used transiently, never held across calls.
        ws_payload_buf: []u8,
        /// Shared per-worker scratch holding a decoded chunked request body while
        /// the handler runs. Sized to the recv buffer (a chunked body must be
        /// fully present in conn.buf to decode, so its decoded form never exceeds
        /// that). Used transiently, never held across calls.
        body_buf: []u8,
        /// Shared provided-buffer ring for WebSocket recvs (Phase 4b). null when
        /// the kernel does not support buffer rings: WebSocket then falls back to
        /// the plain recv-into-conn.buf path (4a).
        ws_bufs: ?IoUring.BufferGroup,
        /// Warm idle-connection pool, doubly linked. A closed connection is pushed
        /// to the head (most-recently-used) with its recv and send buffers intact
        /// instead of being freed, so a later accept reuses the allocation. This
        /// removes the three per-connection heap allocations (struct + recv buf +
        /// send buf) from the steady-state accept/close cycle, which dominates the
        /// short-lived (churn) test. When the pool grows past idleCap the
        /// least-recently-used tail is evicted, not the connection just released,
        /// so the active working set at the head is never the one reclaimed.
        warm_head: ?*UringConn = null,
        warm_tail: ?*UringConn = null,
        /// Number of connections currently in the warm pool. Compared against
        /// idleCap to decide when to evict the LRU tail. The single worker thread
        /// owns it, so no synchronization is needed.
        warm_count: usize = 0,
        /// Cold idle-connection stack. An evicted warm tail has its buffer pages
        /// returned to the OS (MADV_DONTNEED) and is pushed here. The struct and
        /// virtual allocation stay reusable, so an accept that drains the warm pool
        /// reuses a cold connection with no allocator call, paying only a recv
        /// first-touch fault to bring its pages back. Singly linked via next.
        cold_head: ?*UringConn = null,
        /// Live connections currently held in the slot table (this worker's
        /// concurrency). Incremented when an accepted connection installs into a
        /// slot, decremented when it is torn down. The warm idle-pool cap is
        /// derived from this so the pool always covers the active working set
        /// regardless of how many workers split the host, see idleCap.
        live_count: usize = 0,
        /// Minimum warm pool floor. See URING_IDLE_POOL_FLOOR. A field (not the
        /// constant directly) so tests can drive the eviction path with a small
        /// pool.
        idle_floor: usize = URING_IDLE_POOL_FLOOR,

        const Self = @This();
        const allocator = std.heap.smp_allocator;
        const linux = std.os.linux;

        fn deinit(self: *Self) void {
            for (self.slots) |maybe_conn| {
                if (maybe_conn) |conn| {
                    _ = linux.close(conn.fd);
                    allocator.free(conn.buf);
                    allocator.free(conn.send_buf);
                    allocator.destroy(conn);
                }
            }

            var warm = self.warm_head;
            while (warm) |conn| {
                warm = conn.next;
                allocator.free(conn.buf);
                allocator.free(conn.send_buf);
                allocator.destroy(conn);
            }

            var cold = self.cold_head;
            while (cold) |conn| {
                cold = conn.next;
                allocator.free(conn.buf);
                allocator.free(conn.send_buf);
                allocator.destroy(conn);
            }

            slab.unmapSlots(self.slots);
            allocator.free(self.ws_payload_buf);
            allocator.free(self.body_buf);
            if (self.ws_bufs) |*bg| bg.deinit(allocator);
            self.ring.deinit();
        }

        /// Get an SQE, submitting the staged batch first when the SQ is full.
        fn getSqe(self: *Self) ?*linux.io_uring_sqe {
            return self.ring.get_sqe() catch {
                _ = self.ring.submit() catch return null;

                return self.ring.get_sqe() catch null;
            };
        }

        fn lookup(self: *Self, decoded: uring.Decoded) ?*UringConn {
            const idx: usize = @intCast(decoded.fd);
            if (idx >= self.slots.len) return null;

            const conn = self.slots[idx] orelse return null;
            if (conn.gen != decoded.gen) return null;

            return conn;
        }

        /// Take a connection object for a freshly accepted fd: pop one from the
        /// idle pool (recv and send buffers intact) when available, otherwise
        /// allocate a new one with both buffers. Returns null only when a fresh
        /// allocation fails. The caller resets the per-connection state fields.
        ///
        /// Note:
        /// - The warm pool is preferred (its pages are resident, no fault), and
        ///   the cold pool is the fallback (reusable, but its first recv faults
        ///   the pages back). Only when both are empty is a buffer allocated.
        fn acquireConn(self: *Self) ?*UringConn {
            if (self.warm_head) |conn| {
                self.warm_head = conn.next;
                if (self.warm_head) |head| head.prev = null else self.warm_tail = null;
                self.warm_count -= 1;

                return conn;
            }

            if (self.cold_head) |conn| {
                self.cold_head = conn.next;

                return conn;
            }

            const conn = allocator.create(UringConn) catch return null;
            const buf = allocator.alloc(u8, self.recv_buf_size) catch {
                allocator.destroy(conn);
                return null;
            };
            const send_buf = allocator.alloc(u8, URING_SEND_BUF_SIZE) catch {
                allocator.free(buf);
                allocator.destroy(conn);
                return null;
            };
            conn.buf = buf;
            conn.send_buf = send_buf;

            return conn;
        }

        /// Warm idle-pool cap, derived from this worker's live concurrency. The
        /// pool keeps up to one full reconnect of the live working set warm, so
        /// steady connection churn always finds a resident buffer at the head. The
        /// floor keeps a small warm reserve when the worker is idle. Deriving from
        /// live_count (not a flat constant) makes the cap scale with the per-worker
        /// concurrency, which differs by how many workers split the host.
        fn idleCap(self: *const Self) usize {
            return @max(self.live_count, self.idle_floor);
        }

        /// Evict the least-recently-used warm connection (the tail) to the cold
        /// stack: return its buffer pages to the OS with MADV_DONTNEED, unlink it
        /// from the warm pool, and push it cold. The struct and virtual allocation
        /// stay reusable, only the physical pages go back, and a later accept that
        /// reaches the cold stack faults them in on the next recv. Reclaiming the
        /// LRU tail (not the connection just released, which is the hot head) is
        /// what keeps the active churn working set resident.
        fn evictColdTail(self: *Self) void {
            const victim = self.warm_tail orelse return;

            self.warm_tail = victim.prev;
            if (victim.prev) |p| p.next = null else self.warm_head = null;
            self.warm_count -= 1;

            slab.releaseSlabPages(victim.buf);
            slab.releaseSlabPages(victim.send_buf);

            victim.prev = null;
            victim.next = self.cold_head;
            self.cold_head = victim;
        }

        /// Return a closed connection to the warm idle pool (A2), then trim the
        /// cold tail if the pool now exceeds the cap. Both steps are off the parse
        /// and handler hot path.
        ///
        /// Note:
        /// - A send_buf the grow allocator doubled for an oversized response is
        ///   shrunk back to the base size. Oversized responses are rare, so this
        ///   realloc is off the churn path, and it stops a connection that served
        ///   one large response from carrying a multi-MiB buffer for life.
        /// - The connection is pushed to the warm head (most-recently-used). Past
        ///   the cap the least-recently-used tail is evicted to the cold stack, so
        ///   the buffer reclaimed is never the one a churn accept is about to
        ///   reuse. The accept path overwrites buf and send_buf before reading, so
        ///   a cold connection's zeroed pages are safe to reuse.
        fn releaseConn(self: *Self, conn: *UringConn) void {
            if (conn.send_buf.len > URING_SEND_BUF_SIZE) {
                if (allocator.realloc(conn.send_buf, URING_SEND_BUF_SIZE)) |shrunk| {
                    conn.send_buf = shrunk;
                } else |_| {}
            }

            conn.prev = null;
            conn.next = self.warm_head;
            if (self.warm_head) |head| head.prev = conn;
            self.warm_head = conn;
            if (self.warm_tail == null) self.warm_tail = conn;
            self.warm_count += 1;

            if (self.warm_count > self.idleCap()) self.evictColdTail();
        }

        fn destroyConn(self: *Self, conn: *UringConn) void {
            self.slots[@intCast(conn.fd)] = null;
            self.live_count -= 1;

            self.releaseConn(conn);
        }

        /// Tear a connection down via a ring close (prep_close) instead of a
        /// synchronous linux.close on the worker thread. Under connection churn
        /// (short-lived and limited-keep-alive requests) teardown happens once
        /// per few requests, and a blocking close syscall on the hot loop kept
        /// the worker from reaping other completions while it ran, leaving cores
        /// idle. Handing the close to the kernel lets the worker keep draining
        /// CQEs. The slot is cleared first, so the .close CQE carries no
        /// connection and the loop ignores it. The kernel does not reuse the fd
        /// integer until the close actually runs, so no in-flight op (none is
        /// outstanding here anyway, the path is half-duplex) can target it.
        fn finishClose(self: *Self, conn: *UringConn) void {
            const fd = conn.fd;
            self.destroyConn(conn);

            const sqe = self.getSqe() orelse {
                // SQ momentarily full: close synchronously so the fd is never
                // leaked, then return.
                _ = linux.close(fd);
                return;
            };

            sqe.prep_close(fd);
            sqe.user_data = uring.packUserData(.close, 0, fd);
        }

        /// Close intent: flush staged bytes first when possible, otherwise free
        /// now. With a send in flight the free is deferred to the send CQE.
        fn beginClose(self: *Self, conn: *UringConn) void {
            conn.closing = true;
            if (conn.inflight > 0) return;

            if (conn.staged > 0) {
                self.submitSend(conn);
                return;
            }

            self.finishClose(conn);
        }

        fn armAccept(self: *Self) void {
            const sqe = self.getSqe() orelse return;
            sqe.prep_multishot_accept(self.listener_fd, null, null, 0);
            sqe.user_data = uring.packUserData(.accept, 0, self.listener_fd);
        }

        fn armRecv(self: *Self, conn: *UringConn) void {
            if (conn.filled >= conn.buf.len) {
                self.beginClose(conn);
                return;
            }

            // WebSocket reads come off the shared provided-buffer ring when it is
            // available, so an idle connection ties up no recv buffer.
            if (conn.ws != null) {
                if (self.ws_bufs) |*bg| {
                    self.armWsRecv(conn, bg);
                    return;
                }
            }

            const sqe = self.getSqe() orelse {
                self.beginClose(conn);
                return;
            };
            sqe.prep_recv(conn.fd, conn.buf[conn.filled..], 0);
            sqe.user_data = uring.packUserData(.recv, conn.gen, conn.fd);
        }

        /// Arm a discard recv for a connection draining an oversized request
        /// body whose response was already staged. MSG.TRUNC makes the kernel
        /// drop the bytes in place (no copy into conn.buf), and the request is
        /// not capped by the buffer length, so a single recv drains up to the
        /// whole remaining body instead of one round-trip per buffer. Mirrors
        /// serveEpollDrain. Capping at conn.drain leaves any pipelined bytes
        /// after the body untouched on the socket.
        ///
        /// Note:
        /// - prep_recv derives len from the buffer slice, so len is overridden
        ///   after it to request the full remaining drain. With MSG.TRUNC the
        ///   kernel never writes the buffer, so a len past conn.buf.len is safe
        ///   (the same trick serveEpollDrain uses with recvfrom).
        fn armDrainRecv(self: *Self, conn: *UringConn) void {
            const want = @min(conn.drain, @as(usize, 1 << 30));
            const sqe = self.getSqe() orelse {
                self.beginClose(conn);
                return;
            };

            sqe.prep_recv(conn.fd, conn.buf, linux.MSG.TRUNC);
            sqe.len = @intCast(want);
            sqe.user_data = uring.packUserData(.recv, conn.gen, conn.fd);
        }

        /// Arm a buffer-select recv for a WebSocket connection: the kernel picks
        /// a buffer from the shared ring only when a frame arrives. Submits and
        /// retries once if the SQ is momentarily full.
        fn armWsRecv(self: *Self, conn: *UringConn, bg: *IoUring.BufferGroup) void {
            const ud = uring.packUserData(.recv, conn.gen, conn.fd);
            if (bg.recv(ud, conn.fd, 0)) |_| {
                return;
            } else |_| {
                _ = self.ring.submit() catch {};
                if (bg.recv(ud, conn.fd, 0)) |_| {} else |_| self.beginClose(conn);
            }
        }

        fn submitSend(self: *Self, conn: *UringConn) void {
            const sqe = self.getSqe() orelse {
                self.finishClose(conn);
                return;
            };
            sqe.prep_send(conn.fd, conn.send_buf[0..conn.staged], linux.MSG.NOSIGNAL);
            sqe.user_data = uring.packUserData(.send, conn.gen, conn.fd);

            conn.inflight = conn.staged;
        }

        // ----------------------------------------------------- //

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

            const conn = self.acquireConn() orelse {
                _ = linux.close(conn_fd);
                return;
            };

            self.gen_counter +%= 1;
            const buf = conn.buf;
            const send_buf = conn.send_buf;
            conn.* = .{
                .fd = conn_fd,
                .gen = self.gen_counter,
                .buf = buf,
                .filled = 0,
                .send_buf = send_buf,
                .staged = 0,
                .inflight = 0,
                .closing = false,
            };
            self.slots[idx] = conn;
            self.live_count += 1;

            self.armRecv(conn);
        }

        fn handleRecv(self: *Self, cqe: linux.io_uring_cqe, decoded: uring.Decoded) void {
            const has_buf = (cqe.flags & linux.IORING_CQE_F_BUFFER) != 0;

            const conn = self.lookup(decoded) orelse {
                // The connection was freed while this buffer-select recv was in
                // flight: hand the selected buffer back so it is not leaked.
                if (has_buf) {
                    if (self.ws_bufs) |*bg| bg.put(cqe) catch {};
                }

                return;
            };

            if (cqe.res <= 0) {
                // The buffer ring ran dry: re-arm rather than drop the connection.
                if (cqe.res == -@as(i32, @intFromEnum(linux.E.NOBUFS)) and conn.ws != null and self.ws_bufs != null) {
                    self.armRecv(conn);
                    return;
                }

                if (has_buf) {
                    if (self.ws_bufs) |*bg| bg.put(cqe) catch {};
                }

                self.beginClose(conn);
                return;
            }

            // Large request-body overflow in progress: these bytes are body to
            // discard (the response is already on its way), not a new request.
            // Count them down and keep draining off the socket until the declared
            // length is consumed, then resume normal reads or close.
            if (conn.drain > 0) {
                const n: usize = @intCast(cqe.res);
                conn.drain -= @min(n, conn.drain);
                if (conn.drain == 0) {
                    if (conn.drain_close) self.beginClose(conn) else self.armRecv(conn);
                } else {
                    self.armDrainRecv(conn);
                }

                return;
            }

            // WebSocket frames delivered into a ring-selected buffer: parse in
            // place, then recycle the buffer.
            if (has_buf) {
                const close = blk: {
                    const bg = if (self.ws_bufs) |*b| b else break :blk true;
                    const data = bg.get(cqe) catch break :blk true;
                    const should_close = self.wsHandleBuf(conn, data);
                    bg.put(cqe) catch {};

                    break :blk should_close;
                };

                self.afterDrain(conn, if (close) .close else .keep_alive);
                return;
            }

            conn.filled += @intCast(cqe.res);

            // Established WebSocket on the plain-recv fallback (no buffer ring).
            if (conn.ws != null) {
                const close = self.wsPump(conn);
                self.afterDrain(conn, if (close) .close else .keep_alive);

                return;
            }

            var outcome = self.dispatch(conn);

            // dispatch may have just upgraded this connection (the 101 is staged
            // and conn.ws is set). Pump any frames the client pipelined after the
            // handshake so the first echo rides out with the 101.
            if (conn.ws != null and conn.filled > 0) {
                if (self.wsPump(conn)) outcome = .close;
            }

            self.afterDrain(conn, outcome);
        }

        /// Submit the staged send when there is one, otherwise close or re-arm a
        /// recv. Shared by the HTTP and WebSocket recv completions.
        fn afterDrain(self: *Self, conn: *UringConn, outcome: core.ConnOutcome) void {
            if (conn.staged > 0) {
                self.submitSend(conn);
                if (outcome == .close) conn.closing = true;

                return;
            }

            if (outcome == .close) {
                self.beginClose(conn);
                return;
            }

            self.armRecv(conn);
        }

        /// Pump every complete frame in conn.buf through the WebSocket frame
        /// loop, staging echoes after the bytes already in send_buf (the 101 on
        /// the first pass), then compact the trailing partial frame to the front
        /// of conn.buf for the next recv.
        ///
        /// Return:
        /// - bool (true when the connection must close: a close frame or a write
        ///   failure)
        fn wsPump(self: *Self, conn: *UringConn) bool {
            const result = ws.pumpRing(conn.fd, conn.buf[0..conn.filled], self.ws_payload_buf, conn.send_buf[conn.staged..], conn.ws.?);
            conn.staged += result.staged;

            if (result.consumed >= conn.filled) {
                conn.filled = 0;
            } else if (result.consumed > 0) {
                std.mem.copyForwards(u8, conn.buf[0 .. conn.filled - result.consumed], conn.buf[result.consumed..conn.filled]);
                conn.filled -= result.consumed;
            }

            return result.close;
        }

        /// Handle a WebSocket frame batch delivered into a ring-selected buffer.
        /// With no carried partial frame the bytes are pumped straight from the
        /// selected buffer (zero copy) and only a trailing partial frame is
        /// copied into conn.buf. With a carry, the new bytes are appended into
        /// conn.buf and pumped from there.
        ///
        /// Return:
        /// - bool (true when the connection must close)
        fn wsHandleBuf(self: *Self, conn: *UringConn, data: []const u8) bool {
            if (conn.filled > 0) {
                const room = conn.buf.len - conn.filled;
                if (data.len > room) return true;

                @memcpy(conn.buf[conn.filled..][0..data.len], data);
                conn.filled += data.len;

                return self.wsPump(conn);
            }

            const result = ws.pumpRing(conn.fd, data, self.ws_payload_buf, conn.send_buf[conn.staged..], conn.ws.?);
            conn.staged += result.staged;

            const leftover = data[result.consumed..];
            if (leftover.len > conn.buf.len) return true;

            if (leftover.len > 0) {
                @memcpy(conn.buf[0..leftover.len], leftover);
                conn.filled = leftover.len;
            } else {
                conn.filled = 0;
            }

            return result.close;
        }

        /// Parse every complete request in conn.buf and dispatch it. Responses
        /// stage into conn.send_buf through the core sink, so a pipelined burst
        /// coalesces into one send. Trailing partial bytes are compacted to the
        /// front for the next recv completion. Mirrors serveEpollConnInner's
        /// parse loop without the read.
        ///
        /// Note:
        /// - A chunked request body that is fully present in conn.buf is decoded
        ///   into self.body_buf and served. A body larger than the recv buffer is
        ///   answered with an empty-body response, then its remainder is drained
        ///   off the socket (see armDrainRecv) so keep-alive survives. A WebSocket
        ///   upgrade switches the connection to the frame loop.
        fn dispatch(self: *Self, conn: *UringConn) core.ConnOutcome {
            const fd = conn.fd;

            var sink = core.RespSink{
                .fd = fd,
                .buf = conn.send_buf,
                .grow_allocator = allocator,
                .grow_cap = URING_SEND_BUF_MAX,
            };
            core.tl_resp_sink = &sink;
            defer core.tl_resp_sink = null;

            var consumed: usize = 0;
            var keep_alive = true;
            while (consumed < conn.filled) {
                const rem = conn.buf[consumed..conn.filled];
                const header_end = std.mem.indexOf(u8, rem, "\r\n\r\n") orelse {
                    if (rem.len >= conn.buf.len) {
                        core.fdWriteAll(fd, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n") catch {};
                        keep_alive = false;
                    }

                    break;
                };

                if (comptime raw_fn != null) {
                    if (raw_fn.?(rem, header_end, fd)) |end| {
                        consumed += end;
                        continue;
                    }
                }

                const parsed = parseGetFastPath(rem, header_end) orelse
                    core.parseHeadAt(rem, header_end) catch {
                    core.fdWriteAll(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
                    keep_alive = false;
                    break;
                };
                const head = parsed.head;

                var body: []const u8 = &.{};
                var request_len = parsed.body_offset;
                if (head.chunked_request) {
                    const decoded = decodeChunkedInBuf(rem[parsed.body_offset..], self.body_buf) orelse break;
                    body = self.body_buf[0..decoded.len];
                    request_len = parsed.body_offset + decoded.consumed;
                } else if (head.content_length > 0) {
                    const content_length: usize = @intCast(head.content_length);
                    const need = parsed.body_offset + content_length;

                    if (need <= rem.len) {
                        body = rem[parsed.body_offset..need];
                        request_len = need;
                    } else if (need > conn.buf.len) {
                        // Body is larger than the recv buffer and can never fit.
                        // Respond now with an empty body (large-body endpoints use
                        // content_length, not the bytes), stage it, then drain the
                        // declared remainder off the socket over later completions
                        // so the connection stays usable for keep-alive.
                        if (self.handler_timeout_ms != 0) core.setTimeout(self.handler_timeout_ms);
                        handler_fn(&head, &.{}, fd);

                        const present_body = rem.len - parsed.body_offset;
                        conn.drain = content_length - present_body;
                        conn.drain_close = !head.keep_alive;
                        consumed = conn.filled;

                        break;
                    } else {
                        break;
                    }
                }

                if (self.handler_timeout_ms != 0) core.setTimeout(self.handler_timeout_ms);
                handler_fn(&head, body, fd);

                consumed += request_len;

                // WebSocket upgrade: stop parsing HTTP and switch to the frame
                // loop. The 101 is already staged in the sink. Bytes the client
                // pipelined after the handshake are pumped by handleRecv.
                if (core.takeWebSocket()) |pending| {
                    conn.ws = pending.on_frame;
                    break;
                }

                if (!head.keep_alive) {
                    keep_alive = false;
                    break;
                }
            }

            if (consumed >= conn.filled) {
                conn.filled = 0;
            } else if (consumed > 0) {
                std.mem.copyForwards(u8, conn.buf[0 .. conn.filled - consumed], conn.buf[consumed..conn.filled]);
                conn.filled -= consumed;
            }

            // The sink may have grown send_buf to fit an oversized response, so
            // adopt the (possibly reallocated) buffer before submitSend and
            // handleSend reference it.
            conn.send_buf = sink.buf;
            conn.staged = sink.len;
            if (sink.failed) return .close;

            return if (keep_alive) .keep_alive else .close;
        }

        fn handleSend(self: *Self, cqe: linux.io_uring_cqe, decoded: uring.Decoded) void {
            const conn = self.lookup(decoded) orelse return;

            if (cqe.res < 0) {
                self.beginClose(conn);
                return;
            }

            // A short send leaves a remainder: shift it to the front and send
            // again before reading the next request.
            const sent: usize = @intCast(cqe.res);
            if (sent < conn.staged) {
                std.mem.copyForwards(u8, conn.send_buf, conn.send_buf[sent..conn.staged]);
                conn.staged -= sent;
                conn.inflight = 0;
                self.submitSend(conn);

                return;
            }

            conn.staged = 0;
            conn.inflight = 0;

            if (conn.closing) {
                self.finishClose(conn);
                return;
            }

            // The response for an oversized request went out first. Now read and
            // discard the rest of that body before serving the next request.
            if (conn.drain > 0) {
                self.armDrainRecv(conn);
                return;
            }

            self.armRecv(conn);
        }

        // ----------------------------------------------------- //

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
}

const UringWorkerCtx = struct { config: Config, worker_id: usize };

/// Return a concrete io_uring worker entry with handler_fn baked in at compile
/// time, mirroring epollWorkerFn so Thread.spawn gets a direct call.
fn uringWorkerFn(comptime handler_fn: HandlerFn, comptime raw_fn: ?core.RawFn) fn (UringWorkerCtx) void {
    return struct {
        fn run(ctx: UringWorkerCtx) void {
            pinToCpu(ctx.worker_id);

            const config = ctx.config;
            const io = config.io;

            core.setDateHeader(config.send_date_header);

            const addr = std.Io.net.IpAddress.resolve(io, config.ip, config.port) catch return;
            var srv = addr.listen(io, .{
                .mode = .stream,
                .kernel_backlog = config.kernel_backlog,
                .reuse_address = true,
            }) catch return;
            defer srv.deinit(io);
            const listener_fd = srv.socket.handle;

            const slots = slab.mapZeroedSlots(?*UringConn, MAX_FD) catch return;

            // Per-worker scratch for unmasking WebSocket payloads. Sized to the
            // recv buffer, the largest frame a connection can accumulate.
            const ws_payload_buf = std.heap.smp_allocator.alloc(u8, config.max_recv_buf) catch return;

            // Per-worker scratch for a decoded chunked request body. Sized to the
            // recv buffer, since a chunked body must be fully present in conn.buf
            // to decode and its decoded form is always shorter than the raw bytes.
            const body_buf = std.heap.smp_allocator.alloc(u8, config.max_recv_buf) catch return;

            const Worker = UringWorker(handler_fn, raw_fn);
            var worker = Worker{
                .ring = undefined,
                .slots = slots,
                .listener_fd = listener_fd,
                .gen_counter = 0,
                .recv_buf_size = config.max_recv_buf,
                .handler_timeout_ms = config.handler_timeout_ms,
                .ws_payload_buf = ws_payload_buf,
                .body_buf = body_buf,
                .ws_bufs = null,
            };
            worker.ring = initUringRing() catch return;
            // Provided-buffer ring for WebSocket recvs (Phase 4b). Optional: a
            // kernel without buffer-ring support leaves it null, and WebSocket
            // uses the plain recv path.
            worker.ws_bufs = IoUring.BufferGroup.init(&worker.ring, std.heap.smp_allocator, WS_RING_BGID, WS_RING_BUF_SIZE, WS_RING_BUF_COUNT) catch null;
            defer worker.deinit();

            // Per-worker response cache (ADR-036), owned for this worker's
            // lifetime. Lock-free by ownership: this thread is the sole creator,
            // setter, and user, exactly like the EPOLL worker, so the same
            // install holds on the ring path. Lives on the worker stack so
            // tl_cache stays valid until run() returns.
            var response_cache: cache.ResponseCache = undefined;
            var cache_on = false;
            if (config.response_cache) {
                if (cache.ResponseCache.init(std.heap.smp_allocator, .{
                    .max_entries = effectiveCacheEntries(config),
                    .max_value_bytes = config.cache_max_value_bytes,
                })) |built| {
                    response_cache = built;
                    cache_on = true;
                    core.setCache(&response_cache, config.cache_ttl_ms);
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

pub fn runUring(config: Config, comptime handler_fn: HandlerFn, comptime raw_fn: ?core.RawFn) !void {
    const cpu = getAvailableCpuCount();
    const worker_count = if (config.workers == 0) cpu else config.workers;

    logSystem(config, "listening on {s}:{d} (io_uring, {d} workers, shared-nothing)", .{ config.ip, config.port, worker_count });

    const threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(threads);

    const worker = uringWorkerFn(handler_fn, raw_fn);
    for (threads, 0..) |*t, worker_id| {
        t.* = try std.Thread.spawn(
            .{ .stack_size = 512 * 1024 },
            worker,
            .{UringWorkerCtx{ .config = config, .worker_id = worker_id }},
        );
    }

    for (threads) |t| t.join();
}

// Echo the received body size: content_length when present (the large-body
// drain path passes an empty body), otherwise the decoded body length.
fn testEchoLenHandler(head: *const core.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    var buf: [24]u8 = undefined;
    const n: u64 = if (head.content_length > 0) head.content_length else body.len;
    const out = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;

    core.writeSimple(fd, 200, "text/plain", out) catch {};
}

// Build a UringWorker instance for dispatch-level tests. dispatch() reads only
// body_buf and handler_timeout_ms and never touches the ring, so the ring and
// slots can stay empty.
fn testUringWorker(comptime handler: HandlerFn, body_buf: []u8) UringWorker(handler, null) {
    return .{
        .ring = undefined,
        .slots = &[_]?*UringConn{},
        .listener_fd = -1,
        .gen_counter = 0,
        .recv_buf_size = body_buf.len,
        .handler_timeout_ms = 0,
        .ws_payload_buf = &[_]u8{},
        .body_buf = body_buf,
        .ws_bufs = null,
    };
}

test "zix http1: URING dispatch decodes a fully-present chunked body" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    var body_buf: [4096]u8 = undefined;
    var worker = testUringWorker(testEchoLenHandler, &body_buf);

    // One chunk "20" (2 bytes) then the zero terminator: decodes to "20".
    const req = "POST /u HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n20\r\n0\r\n\r\n";
    var conn_buf: [4096]u8 = undefined;
    @memcpy(conn_buf[0..req.len], req);
    var send_buf: [4096]u8 = undefined;
    var conn = UringConn{ .fd = fds[1], .gen = 0, .buf = &conn_buf, .filled = req.len, .send_buf = &send_buf, .staged = 0, .inflight = 0, .closing = false };

    const outcome = worker.dispatch(&conn);

    try std.testing.expectEqual(core.ConnOutcome.keep_alive, outcome);
    try std.testing.expectEqual(@as(usize, 0), conn.drain);
    try std.testing.expectEqual(@as(usize, 0), conn.filled);

    // The handler saw a 2-byte decoded body, so it echoes "2".
    const resp = send_buf[0..conn.staged];
    try std.testing.expect(std.mem.indexOf(u8, resp, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\n2"));
}

test "zix http1: URING dispatch arms drain for an oversized request body" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    var body_buf: [256]u8 = undefined;
    var worker = testUringWorker(testEchoLenHandler, &body_buf);

    // Content-Length far exceeds the 256-byte conn.buf, with only a partial body
    // present: dispatch must respond, arm the drain, and clear the buffer.
    const head = "POST /u HTTP/1.1\r\nHost: t\r\nContent-Length: 100000\r\n\r\n";
    const partial = "abcdef";
    var conn_buf: [256]u8 = undefined;
    @memcpy(conn_buf[0..head.len], head);
    @memcpy(conn_buf[head.len..][0..partial.len], partial);
    var send_buf: [4096]u8 = undefined;
    var conn = UringConn{ .fd = fds[1], .gen = 0, .buf = &conn_buf, .filled = head.len + partial.len, .send_buf = &send_buf, .staged = 0, .inflight = 0, .closing = false };

    const outcome = worker.dispatch(&conn);

    try std.testing.expectEqual(core.ConnOutcome.keep_alive, outcome);
    try std.testing.expectEqual(@as(usize, 100000 - partial.len), conn.drain);
    try std.testing.expectEqual(false, conn.drain_close);
    try std.testing.expectEqual(@as(usize, 0), conn.filled);

    // The handler echoed content_length, and the buffer was cleared for the drain.
    const resp = send_buf[0..conn.staged];
    try std.testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\n100000"));
}

fn testOkHandler(_: *const core.ParsedHead, _: []const u8, fd: std.posix.fd_t) void {
    core.writeSimple(fd, 200, "text/plain", "ok") catch {};
}

test "zix http1: initUringRing yields a usable ring (flags or flagless fallback)" {
    if (comptime @import("builtin").target.os.tag != .linux) return error.SkipZigTest;

    // Skip where io_uring is unavailable (older kernel, or blocked by a seccomp
    // sandbox): the engine itself falls back to POOL in that case.
    var ring = initUringRing() catch return error.SkipZigTest;
    defer ring.deinit();

    // Usable whether the kernel accepted the single-issuer fast-path flags or
    // the flagless fallback was taken. Getting an SQE proves the queues mapped.
    _ = try ring.get_sqe();
}

test "zix http1: URING finishClose rings the close and recycles the slot" {
    if (comptime @import("builtin").target.os.tag != .linux) return error.SkipZigTest;

    const linux = std.os.linux;
    const gpa = std.testing.allocator;

    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds));
    defer _ = linux.close(fds[0]);
    // fds[1] is handed to finishClose, which closes it via the ring (not here).

    const Worker = UringWorker(testOkHandler, null);
    var worker = Worker{
        .ring = initUringRing() catch return error.SkipZigTest,
        .slots = try gpa.alloc(?*UringConn, @as(usize, @intCast(fds[1])) + 1),
        .listener_fd = -1,
        .gen_counter = 0,
        .recv_buf_size = 64,
        .handler_timeout_ms = 0,
        .ws_payload_buf = &[_]u8{},
        .body_buf = &[_]u8{},
        .ws_bufs = null,
        .live_count = 1,
    };
    @memset(worker.slots, null);
    defer {
        worker.ring.deinit();
        gpa.free(worker.slots);
    }

    // A connection parked in its fd slot. finishClose recycles it to the free
    // list (it is not freed), so the test owns the cleanup of its buffers.
    const conn = try gpa.create(UringConn);
    conn.* = .{ .fd = fds[1], .gen = 1, .buf = try gpa.alloc(u8, 64), .filled = 0, .send_buf = try gpa.alloc(u8, 64), .staged = 0, .inflight = 0, .closing = true };
    worker.slots[@intCast(fds[1])] = conn;
    defer {
        gpa.free(conn.buf);
        gpa.free(conn.send_buf);
        gpa.destroy(conn);
    }

    worker.finishClose(conn);

    // Slot cleared and the connection recycled into the warm pool for reuse.
    try std.testing.expectEqual(@as(?*UringConn, null), worker.slots[@intCast(fds[1])]);
    try std.testing.expectEqual(@as(?*UringConn, conn), worker.warm_head);

    // The close was staged on the ring, not run as a synchronous syscall:
    // submit and reap its CQE, which must report success and carry the .close
    // tag so the run loop routes it to the no-op arm.
    _ = try worker.ring.submit_and_wait(1);
    var cqes: [4]linux.io_uring_cqe = undefined;
    const count = try worker.ring.copy_cqes(&cqes, 0);
    try std.testing.expect(count >= 1);

    const decoded = uring.unpackUserData(cqes[0].user_data);
    try std.testing.expectEqual(uring.OpKind.close, decoded.op);
    try std.testing.expectEqual(@as(i32, 0), cqes[0].res);
}

test "zix http1: URING releaseConn pools warm under cap, acquireConn reuses LIFO" {
    const gpa = std.testing.allocator;

    const Worker = UringWorker(testOkHandler, null);
    var worker = Worker{
        .ring = undefined,
        .slots = &[_]?*UringConn{},
        .listener_fd = -1,
        .gen_counter = 0,
        .recv_buf_size = 64,
        .handler_timeout_ms = 0,
        .ws_payload_buf = &[_]u8{},
        .body_buf = &[_]u8{},
        .ws_bufs = null,
        .idle_floor = 4,
    };

    const conn_a = try gpa.create(UringConn);
    conn_a.* = .{ .fd = 10, .gen = 1, .buf = try gpa.alloc(u8, 64), .filled = 0, .send_buf = try gpa.alloc(u8, 64), .staged = 0, .inflight = 0, .closing = false };
    const conn_b = try gpa.create(UringConn);
    conn_b.* = .{ .fd = 11, .gen = 1, .buf = try gpa.alloc(u8, 64), .filled = 0, .send_buf = try gpa.alloc(u8, 64), .staged = 0, .inflight = 0, .closing = false };
    defer {
        gpa.free(conn_a.buf);
        gpa.free(conn_a.send_buf);
        gpa.destroy(conn_a);
        gpa.free(conn_b.buf);
        gpa.free(conn_b.send_buf);
        gpa.destroy(conn_b);
    }

    worker.releaseConn(conn_a);
    worker.releaseConn(conn_b);
    try std.testing.expectEqual(@as(usize, 2), worker.warm_count);
    try std.testing.expectEqual(@as(?*UringConn, conn_b), worker.warm_head);
    try std.testing.expectEqual(@as(?*UringConn, conn_a), worker.warm_tail);

    // LIFO: the most recently released connection is reused first off the warm
    // head, and the count tracks the pool so the release path can spot an
    // overflow.
    const first = worker.acquireConn().?;
    try std.testing.expectEqual(@as(?*UringConn, conn_b), first);
    try std.testing.expectEqual(@as(usize, 1), worker.warm_count);

    const second = worker.acquireConn().?;
    try std.testing.expectEqual(@as(?*UringConn, conn_a), second);
    try std.testing.expectEqual(@as(usize, 0), worker.warm_count);
}

test "zix http1: URING idleCap holds the floor when idle and tracks live concurrency under load" {
    const Worker = UringWorker(testOkHandler, null);
    var worker = Worker{
        .ring = undefined,
        .slots = &[_]?*UringConn{},
        .listener_fd = -1,
        .gen_counter = 0,
        .recv_buf_size = 64,
        .handler_timeout_ms = 0,
        .ws_payload_buf = &[_]u8{},
        .body_buf = &[_]u8{},
        .ws_bufs = null,
        .idle_floor = 8,
    };

    // Idle: the cap is the floor, so a quiet worker still keeps a small warm pool.
    try std.testing.expectEqual(@as(usize, 8), worker.idleCap());

    // Under load: the cap rises to the live connection count, so the pool can keep
    // a full reconnect of the working set warm and never reclaims a buffer it is
    // about to reuse.
    worker.live_count = 700;
    try std.testing.expectEqual(@as(usize, 700), worker.idleCap());
}

test "zix http1: URING releaseConn shrinks a grown send_buf back to the base size" {
    const gpa = std.heap.smp_allocator;

    const Worker = UringWorker(testOkHandler, null);
    var worker = Worker{
        .ring = undefined,
        .slots = &[_]?*UringConn{},
        .listener_fd = -1,
        .gen_counter = 0,
        .recv_buf_size = 64,
        .handler_timeout_ms = 0,
        .ws_payload_buf = &[_]u8{},
        .body_buf = &[_]u8{},
        .ws_bufs = null,
    };

    // A send_buf the grow allocator doubled past the base for an oversized
    // response. recv_buf stays small so no eviction is involved (cap not reached).
    const conn = try gpa.create(UringConn);
    conn.* = .{ .fd = 12, .gen = 1, .buf = try gpa.alloc(u8, 64), .filled = 0, .send_buf = try gpa.alloc(u8, 2 * URING_SEND_BUF_SIZE), .staged = 0, .inflight = 0, .closing = false };
    defer {
        gpa.free(conn.buf);
        gpa.free(conn.send_buf);
        gpa.destroy(conn);
    }

    worker.releaseConn(conn);

    try std.testing.expectEqual(@as(usize, URING_SEND_BUF_SIZE), conn.send_buf.len);
    try std.testing.expectEqual(@as(?*UringConn, conn), worker.warm_head);
}

test "zix http1: URING releaseConn past the cap returns buffer pages to the OS" {
    if (comptime @import("builtin").target.os.tag != .linux) return error.SkipZigTest;

    const page = std.heap.page_allocator;

    // Cap of 1 (floor 1, no live connections): the second release overflows.
    const Worker = UringWorker(testOkHandler, null);
    var worker = Worker{
        .ring = undefined,
        .slots = &[_]?*UringConn{},
        .listener_fd = -1,
        .gen_counter = 0,
        .recv_buf_size = 64,
        .handler_timeout_ms = 0,
        .ws_payload_buf = &[_]u8{},
        .body_buf = &[_]u8{},
        .ws_bufs = null,
        .idle_floor = 1,
    };

    // Page-aligned, page-sized buffers so MADV_DONTNEED acts on exactly these
    // pages. Both stay at or under the base size, so the shrink branch is skipped.
    const lru = try page.create(UringConn);
    lru.* = .{ .fd = 13, .gen = 1, .buf = try page.alloc(u8, 4096), .filled = 0, .send_buf = try page.alloc(u8, 4096), .staged = 0, .inflight = 0, .closing = false };
    const mru = try page.create(UringConn);
    mru.* = .{ .fd = 14, .gen = 1, .buf = try page.alloc(u8, 4096), .filled = 0, .send_buf = try page.alloc(u8, 4096), .staged = 0, .inflight = 0, .closing = false };
    defer {
        page.free(lru.buf);
        page.free(lru.send_buf);
        page.destroy(lru);
        page.free(mru.buf);
        page.free(mru.send_buf);
        page.destroy(mru);
    }

    @memset(lru.buf, 0xAA);
    @memset(lru.send_buf, 0xAA);
    @memset(mru.buf, 0xAA);
    @memset(mru.send_buf, 0xAA);

    // Release lru first, then mru. The second release pushes mru to the warm head
    // and overflows the cap, so the least-recently-used tail (lru) is evicted to
    // the cold stack: its pages go back and read as zero, while mru stays warm and
    // resident. Reclaiming the LRU tail, not the just-released mru, is the point.
    worker.releaseConn(lru);
    worker.releaseConn(mru);

    try std.testing.expectEqual(@as(u8, 0xAA), mru.buf[0]);
    try std.testing.expectEqual(@as(?*UringConn, mru), worker.warm_head);
    try std.testing.expectEqual(@as(usize, 1), worker.warm_count);

    try std.testing.expectEqual(@as(u8, 0), lru.buf[0]);
    try std.testing.expectEqual(@as(u8, 0), lru.send_buf[0]);
    try std.testing.expectEqual(@as(?*UringConn, lru), worker.cold_head);

    // Reuse drains the warm head first, then the cold stack, both allocation-free.
    try std.testing.expectEqual(@as(?*UringConn, mru), worker.acquireConn());
    try std.testing.expectEqual(@as(?*UringConn, lru), worker.acquireConn());
}
