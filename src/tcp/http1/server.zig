//! zix http1 server: ASYNC, POOL, MIXED, and EPOLL dispatch models.
//! EPOLL is native on Linux (shared-nothing event loop), non-Linux falls back to POOL.

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig").Http1ServerConfig;
const DispatchModel = @import("../config.zig").DispatchModel;
const core = @import("core.zig");
const cache = @import("../../utils/response_cache.zig");
const ws = @import("websocket.zig");
const HandlerFn = core.HandlerFn;

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
        const slots = try std.heap.smp_allocator.alloc(Conn, MAX_FD);
        @memset(std.mem.sliceAsBytes(slots), 0);

        // Slab is intentionally not memset: Linux demand-paging means physical
        // pages are only committed when a connection first recvs into its slot.
        const slab = try std.heap.smp_allocator.alloc(u8, MAX_FD * buf_size);

        return .{ .slots = slots, .slab = slab, .buf_size = buf_size };
    }

    fn deinit(self: *ConnTable) void {
        for (self.slots) |*conn| {
            if (conn.buf.len == 0) continue;
            if (conn.write_pending.len > 0) std.heap.smp_allocator.free(conn.write_pending);
        }

        std.heap.smp_allocator.free(self.slab);
        std.heap.smp_allocator.free(self.slots);
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

/// Spin up to 50 µs before blocking. Reduces wake-up latency on saturated
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
    if (rem[0] != 'G' or rem[1] != 'E' or rem[2] != 'T' or rem[3] != ' ') return null;

    const line_end = std.mem.indexOfScalarPos(u8, rem, 4, '\r') orelse return null;

    // Minimum for "GET / HTTP/1.1": line_end >= 14; last 9 chars = " HTTP/1.1"
    if (line_end < 14) return null;
    if (rem[line_end - 9] != ' ') return null;
    if (!std.mem.eql(u8, rem[line_end - 8 .. line_end], "HTTP/1.1")) return null;

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
    /// path for that request. Only effective under EPOLL; other models ignore it.
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

test "zix http1: parseGetFastPath raw_headers covers host line" {
    const req = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";
    const header_end = std.mem.indexOf(u8, req, "\r\n\r\n").?;
    const result = parseGetFastPath(req, header_end).?;
    const host = core.getHeader(&result.head, "host");
    try std.testing.expect(host != null);
    try std.testing.expectEqualStrings("example.com", host.?);
}
