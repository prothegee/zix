//! zix http1 .EPOLL dispatch model.

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("../config.zig").Http1ServerConfig;
const core = @import("../core.zig");
const cache = @import("../../../utils/response_cache.zig");
const ws = @import("../websocket.zig");
const slab = @import("../../../multiplexers/slab.zig");
const HandlerFn = core.HandlerFn;
const common = @import("common.zig");
const logSystem = common.logSystem;
const setNoDelay = common.setNoDelay;
const setNonBlock = common.setNonBlock;
const setBusyPoll = common.setBusyPoll;
const pinToCpu = common.pinToCpu;
const getAvailableCpuCount = common.getAvailableCpuCount;
const decodeChunkedInBuf = common.decodeChunkedInBuf;
const parseGetFastPath = common.parseGetFastPath;
const effectiveCacheEntries = common.effectiveCacheEntries;
const MAX_FD = common.MAX_FD;
const MAX_DRAIN_RECV = common.MAX_DRAIN_RECV;

/// Max epoll events drained per epoll_wait call. 4096 reduces round-trips at
/// high connection counts where many fds can be ready simultaneously.
const EPOLL_MAX_EVENTS: usize = 4096;

/// Per-worker sink buffer for coalescing pipelined responses. 64 KiB gives enough
/// room for a full pipelined burst without mid-burst flushes.
const EPOLL_OUT_BUF_SIZE: usize = 64 * 1024;

// --------------------------------------------------------- //
// EPOLL model (Linux only): shared-nothing, one listener + epoll per worker.
//
// Each worker owns a private SO_REUSEPORT listener and epoll instance. The
// kernel load-balances new connections across the per-worker listeners, so
// there is no accept thread, no shared queue, and no cross-thread fd handoff.
// A worker owns every fd it accepts for that connection's lifetime, and its
// ConnTable is private, so no slot is ever touched by two threads.

/// Per-connection read state. buf accumulates bytes until one or more whole
/// requests are present. filled is the live byte count held in buf. ws is set
/// once the connection upgrades to WebSocket: from then on buf holds raw frame
/// bytes and the engine echoes via the stored callback instead of parsing HTTP.
/// drain is the count of request-body bytes still to read and discard for a
/// body too large to buffer (the response was already sent), drain_close marks
/// that the connection must close once the drain finishes.
/// write_pending is a heap-owned slice of response bytes staged when a write
/// hits EAGAIN (send buffer full). The EPOLL loop arms EPOLLOUT and drains it
/// on the next writable event rather than blocking the worker. write_pending_off
/// tracks how many bytes have been flushed so far. write_pending_close marks
/// that the connection must close once the staged write drains.
const Conn = struct {
    fd: std.posix.fd_t,
    buf: []u8,
    filled: usize,
    ws: ?core.WsFrameFn = null,
    drain: usize = 0,
    drain_close: bool = false,
    write_pending: []u8 = &.{},
    write_pending_off: usize = 0,
    write_pending_close: bool = false,
};

/// Private per-worker fd to Conn map. Not shared between workers: a connection
/// fd is accepted and served by a single worker, and freed before its fd can
/// be reused, so a stale slot is always zeroed by the time it is reused.
/// Conn structs are stored inline in slots (no pointer indirection). recv
/// buffers are pre-allocated as a contiguous slab (MAX_FD * buf_size virtual
/// bytes, Linux demand-paged). On accept, alloc() assigns conn.buf from the
/// slab with no heap call. Empty slots are identified by buf.len == 0.
const ConnTable = struct {
    slots: []Conn,
    slab: []u8,
    buf_size: usize,

    fn init(buf_size: usize) !ConnTable {
        // Slots are mmap'd (kernel-zeroed, demand-paged) rather than allocated +
        // memset: an untouched slot reads as zero (which get() treats as empty)
        // and costs no physical memory, and a memset would fault in all MAX_FD
        // slots per worker (which scales with core count). See multiplexers/slab.
        const conn_slots = try slab.mapZeroedSlots(Conn, MAX_FD);

        // Slab is intentionally not memset: Linux demand-paging means physical
        // pages are only committed when a connection first recvs into its slot.
        const recv_slab = try std.heap.smp_allocator.alloc(u8, MAX_FD * buf_size);

        return .{ .slots = conn_slots, .slab = recv_slab, .buf_size = buf_size };
    }

    fn deinit(self: *ConnTable) void {
        for (self.slots) |*conn| {
            if (conn.buf.len == 0) continue;
            if (conn.write_pending.len > 0) std.heap.smp_allocator.free(conn.write_pending);
        }

        std.heap.smp_allocator.free(self.slab);
        slab.unmapSlots(self.slots);
    }

    fn get(self: *ConnTable, fd: std.posix.fd_t) ?*Conn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        const conn = &self.slots[idx];

        return if (conn.buf.len > 0) conn else null;
    }

    fn alloc(self: *ConnTable, fd: std.posix.fd_t) ?*Conn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        const buf = self.slab[idx * self.buf_size ..][0..self.buf_size];
        self.slots[idx] = .{ .fd = fd, .buf = buf, .filled = 0 };

        return &self.slots[idx];
    }

    fn free(self: *ConnTable, fd: std.posix.fd_t) void {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return;

        const conn = &self.slots[idx];
        if (conn.buf.len == 0) return;

        if (conn.write_pending.len > 0) std.heap.smp_allocator.free(conn.write_pending);
        slab.releaseSlabPages(conn.buf);
        conn.* = std.mem.zeroes(Conn);
    }
};

/// Accept every pending connection on listener_fd and register each in epfd.
/// Level-triggered, so draining to EAGAIN guarantees no accept is missed.
fn acceptAll(table: *ConnTable, epfd: std.posix.fd_t, listener_fd: std.posix.fd_t) void {
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
        setBusyPoll(conn_fd);
        if (table.alloc(conn_fd) == null) {
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

/// One readable event on an HTTP connection. Installs the response sink so
/// every response produced by the parse pass coalesces into one write per
/// event. The flush is non-blocking: if the send buffer is full (EAGAIN) the
/// remaining bytes are staged in conn.write_pending and EPOLLOUT is armed so
/// the worker is never parked waiting for a slow client. An upgraded connection
/// is handed to the WebSocket pump only after the flush.
fn serveEpollConn(comptime handler_fn: HandlerFn, comptime raw_fn: ?core.RawFn, conn: *Conn, body_buf: []u8, out_buf: []u8, handler_timeout_ms: u32, epfd: std.posix.fd_t) core.ConnOutcome {
    const linux = std.os.linux;

    var sink = core.RespSink{ .fd = conn.fd, .buf = out_buf };
    core.tl_resp_sink = &sink;
    const outcome = serveEpollConnInner(handler_fn, raw_fn, conn, body_buf, handler_timeout_ms);
    core.tl_resp_sink = null;

    if (sink.failed) return .close;

    if (sink.len > 0) {
        const written = core.fdWriteNonBlock(conn.fd, sink.buf[0..sink.len]) orelse return .close;

        if (written < sink.len) {
            const remaining = sink.buf[written..sink.len];
            const staged = std.heap.smp_allocator.alloc(u8, remaining.len) catch return .close;
            @memcpy(staged, remaining);
            conn.write_pending = staged;
            conn.write_pending_off = 0;
            conn.write_pending_close = (outcome == .close);

            var arm_ev = linux.epoll_event{
                .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.RDHUP,
                .data = .{ .fd = conn.fd },
            };
            _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, conn.fd, &arm_ev);

            return .keep_alive;
        }
    }

    if (outcome == .close) return .close;

    // Just upgraded: a client can pipeline its first frame in the same packet
    // as the handshake request, so pump whatever is already buffered now
    // rather than waiting for another readable event (which may never come
    // until the client gets its echo).
    if (conn.ws) |on_frame| return serveEpollWs(conn, on_frame, body_buf, out_buf);

    return outcome;
}

/// Flush staged response bytes (conn.write_pending) for connections where a
/// prior write hit EAGAIN. Returns .keep_alive while bytes remain and
/// .close when the write completes and write_pending_close is set (or on
/// a permanent write error). Disarms EPOLLOUT once the buffer is drained.
fn serveEpollWrite(conn: *Conn, epfd: std.posix.fd_t) core.ConnOutcome {
    const linux = std.os.linux;

    const pending = conn.write_pending[conn.write_pending_off..];
    const written = core.fdWriteNonBlock(conn.fd, pending) orelse return .close;
    conn.write_pending_off += written;

    if (conn.write_pending_off < conn.write_pending.len) return .keep_alive;

    std.heap.smp_allocator.free(conn.write_pending);
    conn.write_pending = &.{};
    conn.write_pending_off = 0;
    const should_close = conn.write_pending_close;
    conn.write_pending_close = false;

    var disarm_ev = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
        .data = .{ .fd = conn.fd },
    };
    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, conn.fd, &disarm_ev);

    return if (should_close) .close else .keep_alive;
}

fn serveEpollConnInner(comptime handler_fn: HandlerFn, comptime raw_fn: ?core.RawFn, conn: *Conn, body_buf: []u8, handler_timeout_ms: u32) core.ConnOutcome {
    const linux = std.os.linux;
    const fd = conn.fd;

    {
        const rc = linux.read(fd, conn.buf[conn.filled..].ptr, conn.buf.len - conn.filled);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return .close;
                conn.filled += n;
            },
            .AGAIN => {},
            .INTR => {},
            else => return .close,
        }
    }

    var consumed: usize = 0;
    var keep_alive = true;
    while (consumed < conn.filled) {
        const rem = conn.buf[consumed..conn.filled];
        const header_end = std.mem.indexOf(u8, rem, "\r\n\r\n") orelse {
            if (rem.len >= conn.buf.len) {
                core.fdWriteAll(fd, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n") catch {};
                return .close;
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
            return .close;
        };
        const head = parsed.head;

        var body: []const u8 = &.{};
        var request_len = parsed.body_offset;
        if (head.chunked_request) {
            const decoded = decodeChunkedInBuf(rem[parsed.body_offset..], body_buf) orelse break;
            body = body_buf[0..decoded.len];
            request_len = parsed.body_offset + decoded.consumed;
        } else if (head.content_length > 0) {
            const content_length: usize = @intCast(head.content_length);
            const need = parsed.body_offset + content_length;

            if (need <= rem.len) {
                body = rem[parsed.body_offset..need];
                request_len = need;
            } else if (need > conn.buf.len) {
                // Body is larger than the read buffer and can never fit. Respond
                // now with an empty body (large-body endpoints use content_length,
                // not the bytes), then drain the rest off the socket over later
                // events so the connection stays usable for keep-alive.
                if (handler_timeout_ms != 0) core.setTimeout(handler_timeout_ms);
                handler_fn(&head, &.{}, fd);

                const present_body = rem.len - parsed.body_offset;
                conn.drain = content_length - present_body;
                conn.drain_close = !head.keep_alive;
                conn.filled = 0;

                return .keep_alive;
            } else {
                break;
            }
        }

        if (handler_timeout_ms != 0) core.setTimeout(handler_timeout_ms);
        handler_fn(&head, body, fd);

        consumed += request_len;

        // The handler may have promoted this connection to WebSocket via
        // WebSocket.serve. From here buf bytes are frames, not requests, so
        // stop the HTTP parse loop and let the WS path take over below.
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

    return if (keep_alive) .keep_alive else .close;
}

/// Drive an engine-owned WebSocket connection for one readable event. Reads
/// to EAGAIN so pipelined frames arriving in one network burst are all drained
/// in a single epoll dispatch. Pump+compact runs after each read so a partial
/// frame in conn.buf never blocks the next read. Ping/close are auto-handled
/// by ws.pump. The worker is never parked here.
///
/// Return:
/// - .keep_alive when the connection may receive more frames
/// - .close on peer hangup, a close frame, write failure, or an oversize frame
fn serveEpollWs(conn: *Conn, on_frame: core.WsFrameFn, payload_buf: []u8, out_buf: []u8) core.ConnOutcome {
    const linux = std.os.linux;
    const fd = conn.fd;

    while (true) {
        if (conn.filled < conn.buf.len) {
            const rc = linux.read(fd, conn.buf[conn.filled..].ptr, conn.buf.len - conn.filled);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    const n: usize = @intCast(rc);
                    if (n == 0) return .close;

                    conn.filled += n;
                },
                .AGAIN => break,
                .INTR => continue,
                else => return .close,
            }
        }

        const result = ws.pump(fd, conn.buf[0..conn.filled], payload_buf, out_buf, on_frame);

        if (result.consumed >= conn.filled) {
            conn.filled = 0;
        } else if (result.consumed > 0) {
            std.mem.copyForwards(u8, conn.buf[0 .. conn.filled - result.consumed], conn.buf[result.consumed..conn.filled]);
            conn.filled -= result.consumed;
        }

        if (result.close) return .close;

        // A frame wider than the whole buffer can never complete: close rather
        // than spin on a connection that can make no progress.
        if (conn.filled >= conn.buf.len) return .close;
    }

    return .keep_alive;
}

/// Read and discard the remaining body bytes of an over-large request whose
/// response was already sent. Discards with MSG_TRUNC, so the kernel drops
/// the bytes in place: no copy into conn.buf and the per-call chunk is not
/// capped by the buffer length. Reads to EAGAIN, never past conn.drain, so
/// the next request's bytes are left untouched. When the drain finishes, the
/// connection resumes normal HTTP parsing, or closes if the request asked to.
///
/// Return:
/// - .keep_alive while bytes remain or once a keep-alive body is fully drained
/// - .close on peer hangup or once a Connection: close body is fully drained
fn serveEpollDrain(conn: *Conn) core.ConnOutcome {
    const linux = std.os.linux;
    const fd = conn.fd;

    while (conn.drain > 0) {
        const want = @min(conn.drain, MAX_DRAIN_RECV);
        const rc = linux.recvfrom(fd, conn.buf.ptr, want, linux.MSG.TRUNC, null, null);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return .close;

                conn.drain -= n;
            },
            .AGAIN => return .keep_alive,
            .INTR => {},
            else => return .close,
        }
    }

    return if (conn.drain_close) .close else .keep_alive;
}

const EpollWorkerCtx = struct { config: Config, worker_id: usize };

/// Return a concrete epoll worker function with handler_fn baked in at compile
/// time. Thread.spawn receives the returned function, eliminating the indirect
/// HandlerFn call on every request in the event loop.
fn epollWorkerFn(comptime handler_fn: HandlerFn, comptime raw_fn: ?core.RawFn) fn (EpollWorkerCtx) void {
    return struct {
        fn run(ctx: EpollWorkerCtx) void {
            pinToCpu(ctx.worker_id);

            const linux = std.os.linux;
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

            const ws_buf_size = if (config.ws_recv_buf > config.max_recv_buf) config.ws_recv_buf else config.max_recv_buf;
            var table = ConnTable.init(ws_buf_size) catch return;
            defer table.deinit();

            const body_buf = std.heap.smp_allocator.alloc(u8, core.BUF_SIZE) catch return;
            defer std.heap.smp_allocator.free(body_buf);

            const out_buf = std.heap.smp_allocator.alloc(u8, EPOLL_OUT_BUF_SIZE) catch return;
            defer std.heap.smp_allocator.free(out_buf);

            // Per-worker response cache, owned for this worker's lifetime. Lives
            // on the worker stack so tl_cache stays valid until run() returns.
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

            // Response compression, stateless per worker (no owned structure). Active
            // under .EPOLL and .URING, like the cache.
            if (config.compression) core.setCompression(config.compression, config.compression_min_size, config.compression_max_out);
            defer core.setCompression(false, 0, 0);

            var events: [EPOLL_MAX_EVENTS]linux.epoll_event = undefined;
            var epoll_timeout: i32 = -1;
            while (true) {
                const wait_rc = linux.epoll_wait(epfd, &events, EPOLL_MAX_EVENTS, epoll_timeout);
                switch (std.posix.errno(wait_rc)) {
                    .SUCCESS => {},
                    .INTR => continue,
                    else => return,
                }

                const event_count: usize = @intCast(wait_rc);
                if (event_count == 0) {
                    epoll_timeout = -1;
                    continue;
                }

                for (events[0..event_count]) |ev| {
                    if (ev.data.fd == listener_fd) {
                        acceptAll(&table, epfd, listener_fd);
                        continue;
                    }

                    const conn = table.get(ev.data.fd) orelse continue;
                    const outcome = if ((ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0)
                        core.ConnOutcome.close
                    else if (conn.write_pending.len > conn.write_pending_off)
                        serveEpollWrite(conn, epfd)
                    else if (conn.drain > 0)
                        serveEpollDrain(conn)
                    else if (conn.ws) |on_frame|
                        serveEpollWs(conn, on_frame, body_buf, out_buf)
                    else
                        serveEpollConn(handler_fn, raw_fn, conn, body_buf, out_buf, config.handler_timeout_ms, epfd);

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

pub fn runEpoll(config: Config, comptime handler_fn: HandlerFn, comptime raw_fn: ?core.RawFn) !void {
    const cpu = getAvailableCpuCount();
    const worker_count = if (config.workers == 0) cpu else config.workers;

    logSystem(config, "listening on {s}:{d} (epoll, {d} workers, shared-nothing)", .{ config.ip, config.port, worker_count });

    const threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(threads);

    // std.compress.flate.Compress is about 230 KB and is built on the handler's stack
    // frame, so a compressing handler (writeNegotiated) needs more than the default
    // 512 KB worker stack. Thread stacks are demand-paged, so the larger limit costs
    // almost no RSS, and the bump applies only when compression is enabled.
    const worker_stack: usize = if (config.compression) common.WORKER_STACK_COMPRESS else common.WORKER_STACK_DEFAULT;

    const worker = epollWorkerFn(handler_fn, raw_fn);
    for (threads, 0..) |*t, worker_id| {
        t.* = try std.Thread.spawn(
            .{ .stack_size = worker_stack },
            worker,
            .{EpollWorkerCtx{ .config = config, .worker_id = worker_id }},
        );
    }

    for (threads) |t| t.join();
}

fn testOkHandler(_: *const core.ParsedHead, _: []const u8, fd: std.posix.fd_t) void {
    core.writeSimple(fd, 200, "text/plain", "ok") catch {};
}

fn testWsEcho(fd: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    ws.send(fd, @enumFromInt(opcode), payload) catch {};
}

test "zix http1: serveEpollConn answers a pipelined burst in order" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    // 16 pipelined requests arriving as one readable event.
    const request = "GET /pipeline HTTP/1.1\r\nHost: t\r\n\r\n";
    const depth = 16;
    var burst: [depth * request.len]u8 = undefined;
    for (0..depth) |i| {
        @memcpy(burst[i * request.len ..][0..request.len], request);
    }
    try std.testing.expectEqual(burst.len, std.os.linux.write(fds[0], &burst, burst.len));

    var conn_buf: [8 * 1024]u8 = undefined;
    var conn = Conn{ .fd = fds[1], .buf = &conn_buf, .filled = 0 };
    var body_buf: [1024]u8 = undefined;
    var out_buf: [4 * 1024]u8 = undefined;

    // epfd = -1: EPOLLOUT staging won't trigger for this burst (socketpair
    // buffer fits all 16 responses), so no epoll_ctl calls are made.
    const outcome = serveEpollConn(testOkHandler, null, &conn, &body_buf, &out_buf, 0, -1);
    try std.testing.expectEqual(core.ConnOutcome.keep_alive, outcome);
    try std.testing.expectEqual(@as(usize, 0), conn.filled);

    // All 16 responses flushed in one coalesced write, parseable in order.
    var recv: [8 * 1024]u8 = undefined;
    const n = try std.posix.read(fds[0], &recv);
    try std.testing.expectEqual(@as(usize, depth), std.mem.count(u8, recv[0..n], "HTTP/1.1 200 OK\r\n"));
    try std.testing.expectEqual(@as(usize, depth), std.mem.count(u8, recv[0..n], "\r\n\r\nok"));
}

fn testCacheHandler(head: *const core.ParsedHead, _: []const u8, fd: std.posix.fd_t) void {
    if (core.cacheLookup(head)) |bytes| {
        core.fdWriteAll(fd, bytes) catch {};
        return;
    }

    core.writeWithCache(fd, head, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", core.cacheTtl()) catch {};
}

test "zix http1: EPOLL path serves a miss then a hit from the cache" {
    var rc = try cache.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 256 });
    defer rc.deinit();

    core.setCache(&rc, 1000);
    defer core.setCache(null, 0);

    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    // Two pipelined requests in one event: the first misses and stores, the
    // second hits the cache. Both responses are identical.
    const request = "GET /cached HTTP/1.1\r\nHost: t\r\n\r\n";
    var burst: [request.len * 2]u8 = undefined;
    @memcpy(burst[0..request.len], request);
    @memcpy(burst[request.len..], request);
    try std.testing.expectEqual(burst.len, std.os.linux.write(fds[0], &burst, burst.len));

    var conn_buf: [8 * 1024]u8 = undefined;
    var conn = Conn{ .fd = fds[1], .buf = &conn_buf, .filled = 0 };
    var body_buf: [1024]u8 = undefined;
    var out_buf: [4 * 1024]u8 = undefined;

    const outcome = serveEpollConn(testCacheHandler, null, &conn, &body_buf, &out_buf, 0, -1);
    try std.testing.expectEqual(core.ConnOutcome.keep_alive, outcome);

    var recv: [4 * 1024]u8 = undefined;
    const n = try std.posix.read(fds[0], &recv);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, recv[0..n], "HTTP/1.1 200 OK\r\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, recv[0..n], "\r\n\r\nhello"));

    // The entry is present for subsequent requests.
    const parsed = try core.parseHead(request);
    try std.testing.expect(core.cacheLookup(&parsed.head) != null);
}

test "zix http1: ConnTable inline slab alloc and free lifecycle" {
    var table = try ConnTable.init(256);
    defer table.deinit();

    try std.testing.expectEqual(@as(?*Conn, null), table.get(5));

    const conn = table.alloc(5).?;
    try std.testing.expectEqual(@as(std.posix.fd_t, 5), conn.fd);
    try std.testing.expectEqual(@as(usize, 256), conn.buf.len);

    const got = table.get(5).?;
    try std.testing.expectEqual(conn, got);

    table.free(5);
    try std.testing.expectEqual(@as(?*Conn, null), table.get(5));

    table.free(5);
}

test "zix http1: ConnTable slots read empty without an init memset (demand-paged)" {
    var table = try ConnTable.init(256);
    defer table.deinit();

    // The slots array is no longer memset, so this proves untouched slots across
    // the whole array still read as zero (empty), which is what keeps get()
    // correct while letting the array demand-page instead of being fully resident.
    for ([_]std.posix.fd_t{ 0, 1, 7, 100, 1000, 50000, MAX_FD - 1 }) |fd| {
        try std.testing.expectEqual(@as(?*Conn, null), table.get(fd));
    }
}

test "zix http1: ConnTable buf_size takes ws_recv_buf when larger" {
    var table = try ConnTable.init(512);
    defer table.deinit();

    const conn = table.alloc(3).?;
    try std.testing.expectEqual(@as(usize, 512), conn.buf.len);
}

test "zix http1: serveEpollWs drains pipelined frames to EAGAIN in one call" {
    var fds: [2]i32 = undefined;
    const linux = std.os.linux;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0, &fds));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    // Two masked client text frames: "hi" (8 bytes) and "yo" (8 bytes) = 16 bytes total.
    const data = [_]u8{
        0x81, 0x82, 0x01, 0x02, 0x03, 0x04, 'h' ^ 0x01, 'i' ^ 0x02,
        0x81, 0x82, 0x05, 0x06, 0x07, 0x08, 'y' ^ 0x05, 'o' ^ 0x06,
    };
    try std.testing.expectEqual(data.len, linux.write(fds[0], &data, data.len));

    // conn.buf is 10 bytes: first read fills it (frame1 + 2 bytes of frame2),
    // pump extracts frame1, compact leaves 2 bytes, second read fetches the
    // remaining 6 bytes of frame2, pump extracts it. Third read yields EAGAIN.
    var conn_buf: [10]u8 = undefined;
    var conn = Conn{ .fd = fds[1], .buf = &conn_buf, .filled = 0 };
    var payload_buf: [128]u8 = undefined;
    var out_buf: [256]u8 = undefined;

    const outcome = serveEpollWs(&conn, testWsEcho, &payload_buf, &out_buf);
    try std.testing.expectEqual(core.ConnOutcome.keep_alive, outcome);
    try std.testing.expectEqual(@as(usize, 0), conn.filled);

    // Both echo frames arrive coalesced on fds[0].
    var recv: [128]u8 = undefined;
    const n = try std.posix.read(fds[0], &recv);

    var scratch: [128]u8 = undefined;
    const first = ws.parseFrame(recv[0..n], &scratch).?;
    try std.testing.expectEqualStrings("hi", first.frame.payload);

    const second = ws.parseFrame(recv[first.consumed..n], &scratch).?;
    try std.testing.expectEqualStrings("yo", second.frame.payload);
}
