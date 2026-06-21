//! zix http1 server: ASYNC, POOL, MIXED, EPOLL, and URING dispatch models.
//! EPOLL (readiness) and URING (io_uring completion) are native on Linux,
//! both shared-nothing per-worker event loops. Non-Linux falls back to POOL.

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig").Http1ServerConfig;
const DispatchModel = @import("../config.zig").DispatchModel;
const core = @import("core.zig");
const cache = @import("../../utils/response_cache.zig");
const ws = @import("websocket.zig");
const uring = @import("../../multiplexers/ring.zig");
const slab = @import("../../multiplexers/slab.zig");
const HandlerFn = core.HandlerFn;
const IoUring = std.os.linux.IoUring;

/// Max epoll events drained per epoll_wait call. 4096 reduces round-trips at
/// high connection counts where many fds can be ready simultaneously.
const EPOLL_MAX_EVENTS: usize = 4096;

/// Per-worker sink buffer for coalescing pipelined responses. 64 KiB gives enough
/// room for a full pipelined burst without mid-burst flushes.
const EPOLL_OUT_BUF_SIZE: usize = 64 * 1024;

// --------------------------------------------------------- //

/// Emit a server lifecycle line. Routes through config.logger when present.
/// Without a logger it prints to stderr only in Debug builds (silent in release).
fn logSystem(config: Config, comptime fmt: []const u8, args: anytype) void {
    if (config.logger) |lg| {
        lg.system(.INFO, "http1", fmt, args);
        return;
    }

    if (comptime builtin.mode == .Debug) std.debug.print("zix: " ++ fmt ++ "\n", args);
}

// --------------------------------------------------------- //
// Shared connection entry (ASYNC and MIXED)

const ConnArgs = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    handler: HandlerFn,
    handler_timeout_ms: u32 = 0,
    send_date_header: bool = true,
};

fn connEntry(args: ConnArgs) void {
    core.setDateHeader(args.send_date_header);

    defer args.stream.close(args.io);
    const fd = args.stream.socket.handle;
    core.serveConn(fd, args.handler, .{ .handler_timeout_ms = args.handler_timeout_ms });
}

// --------------------------------------------------------- //
// ASYNC model

fn runAsync(config: Config, handler: HandlerFn) !void {
    const io = config.io;
    const addr = try std.Io.net.IpAddress.resolve(io, config.ip, config.port);
    var srv = try addr.listen(io, .{
        .mode = .stream,
        .kernel_backlog = config.kernel_backlog,
        .reuse_address = true,
    });
    defer srv.deinit(io);

    logSystem(config, "listening on {s}:{d} (io.async)", .{ config.ip, config.port });

    while (true) {
        const stream = srv.accept(io) catch continue;
        _ = io.async(connEntry, .{ConnArgs{ .stream = stream, .io = io, .handler = handler, .handler_timeout_ms = config.handler_timeout_ms, .send_date_header = config.send_date_header }});
    }
}

// --------------------------------------------------------- //
// POOL model

const ConnQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    buf: []std.Io.net.Stream = &.{},
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,

    fn push(self: *ConnQueue, stream: std.Io.net.Stream, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        if (self.len == self.buf.len) {
            const new_cap = if (self.buf.len == 0) 16 else self.buf.len * 2;
            const new_buf = std.heap.smp_allocator.alloc(std.Io.net.Stream, new_cap) catch {
                self.mutex.unlock(io);
                stream.close(io);
                return;
            };
            if (self.buf.len > 0) {
                for (0..self.len) |i| new_buf[i] = self.buf[(self.head + i) % self.buf.len];
                std.heap.smp_allocator.free(self.buf);
            }
            self.buf = new_buf;
            self.head = 0;
        }
        self.buf[(self.head + self.len) % self.buf.len] = stream;
        self.len += 1;
        self.mutex.unlock(io);
        self.ready.signal(io);
    }

    fn pop(self: *ConnQueue, io: std.Io) ?std.Io.net.Stream {
        self.mutex.lockUncancelable(io);
        while (self.len == 0) {
            if (self.closed) {
                self.mutex.unlock(io);
                return null;
            }
            self.ready.waitUncancelable(io, &self.mutex);
        }
        const stream = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        self.len -= 1;
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
        if (self.buf.len > 0) std.heap.smp_allocator.free(self.buf);
    }
};

const PoolCtx = struct { queue: *ConnQueue, io: std.Io, handler: HandlerFn, handler_timeout_ms: u32 = 0, send_date_header: bool = true };

const AcceptCtx = struct {
    queue: *ConnQueue,
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
};

fn poolEntry(ctx: PoolCtx) void {
    core.setDateHeader(ctx.send_date_header);

    while (ctx.queue.pop(ctx.io)) |stream| {
        defer stream.close(ctx.io);
        const fd = stream.socket.handle;
        core.serveConn(fd, ctx.handler, .{ .handler_timeout_ms = ctx.handler_timeout_ms });
    }
}

fn acceptEntry(ctx: AcceptCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
    var srv = addr.listen(ctx.io, .{
        .mode = .stream,
        .kernel_backlog = ctx.kernel_backlog,
        .reuse_address = true,
    }) catch return;
    defer srv.deinit(ctx.io);

    while (true) {
        const stream = srv.accept(ctx.io) catch continue;
        ctx.queue.push(stream, ctx.io);
    }
}

fn runPool(config: Config, handler: HandlerFn) !void {
    const io = config.io;
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (config.workers == 0) cpu else config.workers;
    const pool_count = if (config.pool_size == 0) @max(10, cpu * 2) else config.pool_size;

    logSystem(config, "listening on {s}:{d} ({d} accept, {d} pool)", .{ config.ip, config.port, worker_count, pool_count });

    var queue = ConnQueue{};
    defer queue.deinit();

    const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_count);
    defer std.heap.smp_allocator.free(pool_threads);
    for (pool_threads) |*t| {
        t.* = try std.Thread.spawn(
            .{ .stack_size = 512 * 1024 },
            poolEntry,
            .{PoolCtx{ .queue = &queue, .io = io, .handler = handler, .handler_timeout_ms = config.handler_timeout_ms, .send_date_header = config.send_date_header }},
        );
    }

    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(acc_threads);
    for (acc_threads) |*t| {
        t.* = try std.Thread.spawn(
            .{ .stack_size = 256 * 1024 },
            acceptEntry,
            .{AcceptCtx{ .queue = &queue, .io = io, .ip = config.ip, .port = config.port, .kernel_backlog = config.kernel_backlog }},
        );
    }

    for (acc_threads) |t| t.join();
    queue.close(io);
    for (pool_threads) |t| t.join();
}

// --------------------------------------------------------- //
// MIXED model

const MixedAcceptCtx = struct {
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    handler: HandlerFn,
    handler_timeout_ms: u32 = 0,
    send_date_header: bool = true,
};

fn mixedAcceptEntry(ctx: MixedAcceptCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
    var srv = addr.listen(ctx.io, .{
        .mode = .stream,
        .kernel_backlog = ctx.kernel_backlog,
        .reuse_address = true,
    }) catch return;
    defer srv.deinit(ctx.io);

    while (true) {
        const stream = srv.accept(ctx.io) catch continue;
        _ = ctx.io.async(connEntry, .{ConnArgs{ .stream = stream, .io = ctx.io, .handler = ctx.handler, .handler_timeout_ms = ctx.handler_timeout_ms, .send_date_header = ctx.send_date_header }});
    }
}

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

/// Highest fd a worker's table can index. Linux hands out the lowest free fd,
/// so the table stays sparse. Connections on fds at or above this are refused.
const MAX_FD: usize = 1 << 16;

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

const ChunkDecode = struct { len: usize, consumed: usize };

/// Decode a chunked request body that is fully present in src.
///
/// Note:
/// - Chunk extensions are ignored. Trailers are skipped to the final blank line.
///
/// Return:
/// - ChunkDecode (decoded length in out, bytes consumed from src)
/// - null when the terminating zero chunk has not arrived yet, or out is too small
fn decodeChunkedInBuf(src: []const u8, out: []u8) ?ChunkDecode {
    var pos: usize = 0;
    var out_pos: usize = 0;

    while (true) {
        const line_end = std.mem.indexOfPos(u8, src, pos, "\r\n") orelse return null;
        const size_field = src[pos..line_end];
        const hex = if (std.mem.indexOfScalar(u8, size_field, ';')) |s| size_field[0..s] else size_field;
        const chunk_size = std.fmt.parseInt(usize, std.mem.trim(u8, hex, " "), 16) catch return null;
        pos = line_end + 2;

        if (chunk_size == 0) {
            const trailer_end = std.mem.indexOfPos(u8, src, pos, "\r\n") orelse return null;
            return .{ .len = out_pos, .consumed = trailer_end + 2 };
        }

        if (pos + chunk_size + 2 > src.len) return null;
        if (out_pos + chunk_size > out.len) return null;

        @memcpy(out[out_pos..][0..chunk_size], src[pos..][0..chunk_size]);
        out_pos += chunk_size;
        pos += chunk_size + 2;
    }
}

fn setNoDelay(fd: std.posix.fd_t) void {
    if (comptime @import("builtin").target.os.tag != .windows) {
        std.posix.setsockopt(
            fd,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            std.mem.asBytes(&@as(c_int, 1)),
        ) catch {};
    }
}

fn setNonBlock(fd: std.posix.fd_t) void {
    const linux = std.os.linux;
    const cur = linux.fcntl(fd, std.posix.F.GETFL, 0);
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = linux.fcntl(fd, std.posix.F.SETFL, cur | @as(usize, nonblock));
}

/// Spin up to 50 us before blocking. Reduces wake-up latency on saturated
/// loopback benchmarks. Silent no-op when the kernel lacks SO_BUSY_POLL support.
fn setBusyPoll(fd: std.posix.fd_t) void {
    const SO_BUSY_POLL: u32 = 46;
    std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        SO_BUSY_POLL,
        std.mem.asBytes(&@as(c_int, 50)),
    ) catch {};
}

/// Pin the calling thread to the CPU slot assigned to worker_id, respecting
/// the cgroup-allowed CPU mask so we never select a CPU the container cannot use.
fn pinToCpu(worker_id: usize) void {
    const linux = std.os.linux;
    var cpu_set: linux.cpu_set_t = undefined;
    if (linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &cpu_set) != 0) return;

    var cpu_list: [256]u32 = undefined;
    var n_cpus: usize = 0;
    for (cpu_set, 0..) |word, word_idx| {
        var w = word;
        while (w != 0) : (w &= w - 1) {
            if (n_cpus < cpu_list.len) {
                cpu_list[n_cpus] = @intCast(word_idx * @bitSizeOf(usize) + @ctz(w));
                n_cpus += 1;
            }
        }
    }
    if (n_cpus == 0) return;

    const target = cpu_list[worker_id % n_cpus];
    var target_set: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
    const cpu_word = target / @bitSizeOf(usize);
    const cpu_bit: u6 = @intCast(target % @bitSizeOf(usize));
    target_set[cpu_word] |= @as(usize, 1) << cpu_bit;

    linux.sched_setaffinity(0, &target_set) catch {};
}

/// Count CPUs available to this process via sched_getaffinity, respecting cgroup
/// and taskset restrictions. Falls back to std.Thread.getCpuCount when the syscall
/// fails. Used by EPOLL to default to one worker per available CPU so that multiple
/// workers are never pinned to the same core under cgroup-limited bench environments.
fn getAvailableCpuCount() usize {
    const linux = std.os.linux;
    var cpu_set: linux.cpu_set_t = undefined;
    if (linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &cpu_set) != 0) {
        return std.Thread.getCpuCount() catch 1;
    }

    var count: usize = 0;
    for (cpu_set) |word| {
        count += @popCount(word);
    }

    return if (count == 0) 1 else count;
}

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

/// Fast path for HTTP/1.1 GET requests: extract method and path with direct
/// arithmetic, bypassing the full header scan loop in parseHeadAt. Only
/// keep_alive defaults (HTTP/1.1 = true) and content_length=0 are assumed;
/// raw_headers is still set so handlers can call getHeader() if needed.
/// Returns null when the request is not a GET or the format is unexpected.
fn parseGetFastPath(rem: []const u8, header_end: usize) ?core.ParseResult {
    if (rem.len < 16) return null;
    if (std.mem.readInt(u32, rem[0..4], .little) != comptime std.mem.readInt(u32, "GET ", .little)) return null;

    const line_end = std.mem.indexOfScalarPos(u8, rem, 4, '\r') orelse return null;

    // Minimum for "GET / HTTP/1.1": line_end >= 14, last 9 chars = " HTTP/1.1"
    if (line_end < 14) return null;
    if (rem[line_end - 9] != ' ') return null;
    if (std.mem.readInt(u64, rem[line_end - 8 ..][0..8], .little) != comptime std.mem.readInt(u64, "HTTP/1.1", .little)) return null;

    const full_path = rem[4 .. line_end - 9];
    var path = full_path;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, full_path, '?')) |q| {
        path = full_path[0..q];
        query = full_path[q + 1 ..];
    }

    const raw_start = line_end + 2;
    const raw_headers: []const u8 = if (raw_start < header_end + 2) rem[raw_start .. header_end + 2] else &.{};

    // Bail out to parseHeadAt when "close" appears in raw_headers so that
    // Connection: close is handled correctly. This is the rare case.
    if (std.mem.indexOf(u8, raw_headers, "close") != null) return null;

    return .{
        .head = .{
            .method = rem[0..3],
            .path = path,
            .query = query,
            .raw_headers = raw_headers,
            .version_minor = 1,
            .keep_alive = true,
            .content_length = 0,
            .chunked_request = false,
            .expect_continue = false,
        },
        .body_offset = header_end + 4,
    };
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
        const want = @min(conn.drain, @as(usize, 1 << 30));
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

/// Effective cache slot count for a worker, honoring cache_max_total_bytes.
/// When a memory ceiling is set, the entry count is reduced so the slab
/// (entries * value_bytes) fits. ResponseCache.init then rounds down to a power
/// of two, so the slab never exceeds the ceiling.
fn effectiveCacheEntries(config: Config) u32 {
    if (config.cache_max_total_bytes == 0) return config.cache_max_entries;

    const value_bytes: usize = @max(1, config.cache_max_value_bytes);
    const fit = config.cache_max_total_bytes / value_bytes;
    const capped = @min(@as(usize, config.cache_max_entries), fit);

    return @intCast(@max(@as(usize, 1), capped));
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

fn runEpoll(config: Config, comptime handler_fn: HandlerFn, comptime raw_fn: ?core.RawFn) !void {
    const cpu = getAvailableCpuCount();
    const worker_count = if (config.workers == 0) cpu else config.workers;

    logSystem(config, "listening on {s}:{d} (epoll, {d} workers, shared-nothing)", .{ config.ip, config.port, worker_count });

    const threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(threads);

    const worker = epollWorkerFn(handler_fn, raw_fn);
    for (threads, 0..) |*t, worker_id| {
        t.* = try std.Thread.spawn(
            .{ .stack_size = 512 * 1024 },
            worker,
            .{EpollWorkerCtx{ .config = config, .worker_id = worker_id }},
        );
    }

    for (threads) |t| t.join();
}

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
    /// Free-list link, valid only while this connection sits in the worker's
    /// idle pool between a close and the next accept that reuses it.
    next: ?*UringConn = null,
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
        /// Idle-connection pool. A closed connection is pushed here with its recv
        /// and send buffers intact instead of being freed, so a later accept
        /// reuses the allocation. This removes the three per-connection heap
        /// allocations (struct + recv buf + 64 KiB send buf) from the steady-state
        /// accept/close cycle, which dominates the short-lived (churn) test.
        free_list: ?*UringConn,

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

            var idle = self.free_list;
            while (idle) |conn| {
                idle = conn.next;
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
        fn acquireConn(self: *Self) ?*UringConn {
            if (self.free_list) |conn| {
                self.free_list = conn.next;
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

        /// Return a closed connection to the idle pool, keeping its buffers for
        /// the next accept to reuse. The slot table no longer references it.
        fn releaseConn(self: *Self, conn: *UringConn) void {
            conn.next = self.free_list;
            self.free_list = conn;
        }

        fn destroyConn(self: *Self, conn: *UringConn) void {
            self.slots[@intCast(conn.fd)] = null;

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
                .free_list = null,
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

fn runUring(config: Config, comptime handler_fn: HandlerFn, comptime raw_fn: ?core.RawFn) !void {
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

// --------------------------------------------------------- //

fn runMixed(config: Config, handler: HandlerFn) !void {
    const io = config.io;
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (config.workers == 0) cpu else config.workers;

    logSystem(config, "listening on {s}:{d} ({d} accept, io.async)", .{ config.ip, config.port, worker_count });

    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(acc_threads);

    for (acc_threads) |*t| {
        // Use default stack size (.{}), serveConn uses ~128KB stack via io.async scheduler.
        // Explicit 256KB here overflows when io.async falls back to inline dispatch.
        t.* = try std.Thread.spawn(
            .{},
            mixedAcceptEntry,
            .{MixedAcceptCtx{ .io = io, .ip = config.ip, .port = config.port, .kernel_backlog = config.kernel_backlog, .handler = handler, .handler_timeout_ms = config.handler_timeout_ms, .send_date_header = config.send_date_header }},
        );
    }

    for (acc_threads) |t| t.join();
}

// --------------------------------------------------------- //

/// Server type specialized over a comptime handler and optional raw interceptor.
///
/// Note:
/// - handler and raw_fn are baked into the type, so run() takes no argument.
/// - raw_fn is null in the normal path: the if(comptime raw_fn != null) block
///   compiles away entirely, adding zero overhead to servers that don't use it.
fn Http1ServerImpl(comptime handler: HandlerFn, comptime raw_fn: ?core.RawFn) type {
    return struct {
        config: Config,

        const Self = @This();

        pub fn init(config: Config) Self {
            return .{ .config = config };
        }

        pub fn deinit(_: *Self) void {}

        pub fn run(self: *const Self) !void {
            return switch (self.config.dispatch_model) {
                .ASYNC => runAsync(self.config, handler),
                .POOL => runPool(self.config, handler),
                .MIXED => runMixed(self.config, handler),
                .EPOLL => if (comptime @import("builtin").target.os.tag == .linux)
                    runEpoll(self.config, handler, raw_fn)
                else blk: {
                    logSystem(self.config, "EPOLL is Linux-only. Falling back to POOL.", .{});
                    break :blk runPool(self.config, handler);
                },
                .URING => if (comptime @import("builtin").target.os.tag == .linux)
                    runUring(self.config, handler, raw_fn)
                else blk: {
                    logSystem(self.config, "URING is Linux-only. Falling back to POOL.", .{});
                    break :blk runPool(self.config, handler);
                },
            };
        }
    };
}

/// http1 server - initialize with a comptime handler and a runtime config.
///
/// Note:
/// - handler must be comptime: it is baked into the server type, so there is no
///   dynamic registration after init. Pass a Router(routes).dispatch, a bare
///   handler, or a middleware chain.
/// - For raw-bytes interception before parsing, use initRaw.
///
/// Usage:
/// ```zig
/// const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
///     .{ .path = "/", .handler = home },
/// });
///
/// var server = zix.Http1.Server.init(Routes.dispatch, .{
///     .ip = "0.0.0.0",
///     .port = 8080,
/// });
/// try server.run();
/// ```
pub const Server = struct {
    /// Param:
    /// handler - comptime HandlerFn (baked into the server type)
    /// config - Http1ServerConfig
    ///
    /// Return:
    /// - Http1ServerImpl(handler, null)
    pub fn init(comptime handler: HandlerFn, config: Config) Http1ServerImpl(handler, null) {
        return Http1ServerImpl(handler, null).init(config);
    }

    /// Like init, but also installs a raw-request interceptor for the EPOLL
    /// dispatch model. raw_fn is called before any header parsing on each
    /// request. Returning a non-null offset skips the full parse-and-dispatch
    /// path for that request. Only effective under EPOLL, other models ignore it.
    ///
    /// Param:
    /// handler - comptime HandlerFn
    /// raw_fn - comptime RawFn (called before parsing on every EPOLL request)
    /// config - Http1ServerConfig
    ///
    /// Return:
    /// - Http1ServerImpl(handler, raw_fn)
    pub fn initRaw(comptime handler: HandlerFn, comptime raw_fn: core.RawFn, config: Config) Http1ServerImpl(handler, raw_fn) {
        return Http1ServerImpl(handler, raw_fn).init(config);
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

fn testNoopHandler(_: *const core.ParsedHead, _: []const u8, _: std.posix.fd_t) void {}

test "zix http1: Server.init valid config, deinit is safe" {
    var server = Server.init(testNoopHandler, .{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
    });
    server.deinit();
}

test "zix http1: Server.init with POOL dispatch model" {
    var server = Server.init(testNoopHandler, .{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .POOL,
    });
    server.deinit();
}

test "zix http1: Server.init with EPOLL dispatch model" {
    var server = Server.init(testNoopHandler, .{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .EPOLL,
    });
    server.deinit();
}

test "zix http1: Server.init with URING dispatch model" {
    var server = Server.init(testNoopHandler, .{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .URING,
    });
    server.deinit();
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
        .free_list = null,
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

test "zix http1: effectiveCacheEntries honors the memory ceiling" {
    const base = Config{ .io = undefined, .ip = "127.0.0.1", .port = 0, .cache_max_entries = 1024, .cache_max_value_bytes = 16 * 1024 };

    // no ceiling: entry count unchanged
    try std.testing.expectEqual(@as(u32, 1024), effectiveCacheEntries(base));

    // ceiling of 256 KiB / 16 KiB = 16 slots, below the configured 1024
    var capped = base;
    capped.cache_max_total_bytes = 256 * 1024;
    try std.testing.expectEqual(@as(u32, 16), effectiveCacheEntries(capped));

    // a tiny ceiling still yields at least one slot
    var tiny = base;
    tiny.cache_max_total_bytes = 1;
    try std.testing.expectEqual(@as(u32, 1), effectiveCacheEntries(tiny));
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

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix http1: parseGetFastPath basic GET with host header" {
    const req = "GET /pipeline HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const header_end = std.mem.indexOf(u8, req, "\r\n\r\n").?;
    const result = parseGetFastPath(req, header_end).?;

    try std.testing.expectEqualStrings("GET", result.head.method);
    try std.testing.expectEqualStrings("/pipeline", result.head.path);
    try std.testing.expectEqualStrings("", result.head.query);
    try std.testing.expectEqual(true, result.head.keep_alive);
    try std.testing.expectEqual(@as(u64, 0), result.head.content_length);
    try std.testing.expectEqual(false, result.head.chunked_request);
    try std.testing.expectEqual(@as(u8, 1), result.head.version_minor);
    try std.testing.expectEqual(header_end + 4, result.body_offset);
}

test "zix http1: parseGetFastPath with query string" {
    const req = "GET /baseline11?a=1&b=2 HTTP/1.1\r\nHost: x\r\n\r\n";
    const header_end = std.mem.indexOf(u8, req, "\r\n\r\n").?;
    const result = parseGetFastPath(req, header_end).?;

    try std.testing.expectEqualStrings("/baseline11", result.head.path);
    try std.testing.expectEqualStrings("a=1&b=2", result.head.query);
}

test "zix http1: parseGetFastPath rejects POST" {
    const req = "POST /upload HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    const header_end = std.mem.indexOf(u8, req, "\r\n\r\n").?;
    try std.testing.expectEqual(@as(?core.ParseResult, null), parseGetFastPath(req, header_end));
}

test "zix http1: parseGetFastPath rejects HTTP/1.0" {
    const req = "GET / HTTP/1.0\r\n\r\n";
    const header_end = std.mem.indexOf(u8, req, "\r\n\r\n").?;
    try std.testing.expectEqual(@as(?core.ParseResult, null), parseGetFastPath(req, header_end));
}

test "zix http1: parseGetFastPath integer compare matches the full word" {
    // Method differs only in the trailing byte ("GETX" vs "GET ").
    const bad_method = "GETX/ HTTP/1.1\r\n\r\n";
    try std.testing.expectEqual(@as(?core.ParseResult, null), parseGetFastPath(bad_method, std.mem.indexOf(u8, bad_method, "\r\n\r\n").?));

    // Version differs only in a middle byte ("HXTP/1.1" vs "HTTP/1.1").
    const bad_version = "GET / HXTP/1.1\r\n\r\n";
    try std.testing.expectEqual(@as(?core.ParseResult, null), parseGetFastPath(bad_version, std.mem.indexOf(u8, bad_version, "\r\n\r\n").?));

    // The exact words still match.
    const good = "GET / HTTP/1.1\r\n\r\n";
    try std.testing.expect(parseGetFastPath(good, std.mem.indexOf(u8, good, "\r\n\r\n").?) != null);
}

test "zix http1: parseGetFastPath raw_headers covers host line" {
    const req = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";
    const header_end = std.mem.indexOf(u8, req, "\r\n\r\n").?;
    const result = parseGetFastPath(req, header_end).?;
    const host = core.getHeader(&result.head, "host");
    try std.testing.expect(host != null);
    try std.testing.expectEqualStrings("example.com", host.?);
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
        .free_list = null,
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

    // Slot cleared and the connection recycled for the next accept to reuse.
    try std.testing.expectEqual(@as(?*UringConn, null), worker.slots[@intCast(fds[1])]);
    try std.testing.expectEqual(@as(?*UringConn, conn), worker.free_list);

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
