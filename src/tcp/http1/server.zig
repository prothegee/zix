//! zix http1 server: ASYNC, POOL, and MIXED dispatch models.
//! EPOLL falls back to POOL (Http1 uses raw fd I/O, not epoll event loop).

const std = @import("std");
const Config = @import("config.zig").Http1ServerConfig;
const DispatchModel = @import("../config.zig").DispatchModel;
const core = @import("core.zig");
const ws = @import("websocket.zig");
const HandlerFn = core.HandlerFn;

/// Max epoll events drained per epoll_wait call. 512 lets a worker clear its
/// ready-fd set in one syscall at high connection counts.
const EPOLL_MAX_EVENTS: usize = 512;

// --------------------------------------------------------- //

/// Emit a server lifecycle line. Routes through config.logger when present,
/// otherwise falls back to std.debug.print.
fn logSystem(config: Config, comptime fmt: []const u8, args: anytype) void {
    if (config.logger) |lg| {
        lg.system(.INFO, "http1", fmt, args);
        return;
    }

    std.debug.print("zix: " ++ fmt ++ "\n", args);
}

// --------------------------------------------------------- //
// Shared connection entry (ASYNC and MIXED)

const ConnArgs = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    handler: HandlerFn,
    handler_timeout_ms: u32 = 0,
};

fn connEntry(args: ConnArgs) void {
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
        _ = io.async(connEntry, .{ConnArgs{ .stream = stream, .io = io, .handler = handler, .handler_timeout_ms = config.handler_timeout_ms }});
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

const PoolCtx = struct { queue: *ConnQueue, io: std.Io, handler: HandlerFn, handler_timeout_ms: u32 = 0 };

const AcceptCtx = struct {
    queue: *ConnQueue,
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
};

fn poolEntry(ctx: PoolCtx) void {
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
            .{PoolCtx{ .queue = &queue, .io = io, .handler = handler, .handler_timeout_ms = config.handler_timeout_ms }},
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
        _ = ctx.io.async(connEntry, .{ConnArgs{ .stream = stream, .io = ctx.io, .handler = ctx.handler, .handler_timeout_ms = ctx.handler_timeout_ms }});
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
const Conn = struct {
    fd: std.posix.fd_t,
    buf: []u8,
    filled: usize,
    ws: ?core.WsFrameFn = null,
    drain: usize = 0,
    drain_close: bool = false,
};

/// Highest fd a worker's table can index. Linux hands out the lowest free fd,
/// so the table stays sparse. Connections on fds at or above this are refused.
const MAX_FD: usize = 1 << 16;

/// Private per-worker fd to Conn map. Not shared between workers: a connection
/// fd is accepted and served by a single worker, and freed before its fd can
/// be reused, so a stale slot is always null by the time it is reused.
const ConnTable = struct {
    slots: []?*Conn,

    fn init() !ConnTable {
        const slots = try std.heap.smp_allocator.alloc(?*Conn, MAX_FD);
        @memset(slots, null);

        return .{ .slots = slots };
    }

    fn deinit(self: *ConnTable) void {
        for (self.slots) |maybe_conn| {
            if (maybe_conn) |conn| {
                std.heap.smp_allocator.free(conn.buf);
                std.heap.smp_allocator.destroy(conn);
            }
        }

        std.heap.smp_allocator.free(self.slots);
    }

    fn get(self: *ConnTable, fd: std.posix.fd_t) ?*Conn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        return self.slots[idx];
    }

    fn alloc(self: *ConnTable, fd: std.posix.fd_t, buf_size: usize) ?*Conn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        const conn = std.heap.smp_allocator.create(Conn) catch return null;
        const buf = std.heap.smp_allocator.alloc(u8, buf_size) catch {
            std.heap.smp_allocator.destroy(conn);
            return null;
        };

        conn.* = .{ .fd = fd, .buf = buf, .filled = 0, .ws = null, .drain = 0, .drain_close = false };
        self.slots[idx] = conn;

        return conn;
    }

    fn free(self: *ConnTable, fd: std.posix.fd_t) void {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return;

        if (self.slots[idx]) |conn| {
            std.heap.smp_allocator.free(conn.buf);
            std.heap.smp_allocator.destroy(conn);
            self.slots[idx] = null;
        }
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

/// Accept every pending connection on listener_fd and register each in epfd.
/// Level-triggered, so draining to EAGAIN guarantees no accept is missed.
fn acceptAll(table: *ConnTable, epfd: std.posix.fd_t, listener_fd: std.posix.fd_t, buf_size: usize) void {
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
        if (table.alloc(conn_fd, buf_size) == null) {
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

/// Drain readable bytes into conn.buf, then dispatch every complete request it
/// holds. Pipelined requests are all served in this one pass. Trailing partial
/// bytes are kept for the next readable event.
///
/// Return:
/// - .keep_alive when the connection may receive more requests
/// - .close on peer hangup, parse error, oversize header, or Connection: close
fn serveEpollConn(conn: *Conn, handler: HandlerFn, body_buf: []u8, out_buf: []u8, handler_timeout_ms: u32) core.ConnOutcome {
    const linux = std.os.linux;
    const fd = conn.fd;

    while (true) {
        if (conn.filled >= conn.buf.len) {
            core.fdWriteAll(fd, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n") catch {};
            return .close;
        }

        const rc = linux.read(fd, conn.buf[conn.filled..].ptr, conn.buf.len - conn.filled);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return .close;

                conn.filled += n;
                break;
            },
            .AGAIN => break,
            .INTR => continue,
            else => return .close,
        }
    }

    var consumed: usize = 0;
    var keep_alive = true;
    while (consumed < conn.filled) {
        const rem = conn.buf[consumed..conn.filled];
        const header_end = std.mem.indexOf(u8, rem, "\r\n\r\n") orelse break;

        const parsed = core.parseHead(rem[0 .. header_end + 4]) catch {
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
                core.setTimeout(handler_timeout_ms);
                handler(&head, &.{}, fd);

                const present_body = rem.len - parsed.body_offset;
                conn.drain = content_length - present_body;
                conn.drain_close = !head.keep_alive;
                conn.filled = 0;

                return .keep_alive;
            } else {
                break;
            }
        }

        core.setTimeout(handler_timeout_ms);
        handler(&head, body, fd);

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

    // Just upgraded: a client can pipeline its first frame in the same packet
    // as the handshake request, so pump whatever is already buffered now
    // rather than waiting for another readable event (which may never come
    // until the client gets its echo).
    if (conn.ws) |on_frame| return serveEpollWs(conn, on_frame, body_buf, out_buf);

    return if (keep_alive) .keep_alive else .close;
}

/// Drive an engine-owned WebSocket connection for one readable event. Reads
/// once (level-triggered, so more bytes re-fire), then echoes every complete
/// frame buffered. Ping/close are auto-handled by ws.pump. The worker is never
/// parked here: it returns to the epoll loop after draining what is ready.
///
/// Return:
/// - .keep_alive when the connection may receive more frames
/// - .close on peer hangup, a close frame, write failure, or an oversize frame
fn serveEpollWs(conn: *Conn, on_frame: core.WsFrameFn, payload_buf: []u8, out_buf: []u8) core.ConnOutcome {
    const linux = std.os.linux;
    const fd = conn.fd;

    if (conn.filled < conn.buf.len) {
        const rc = linux.read(fd, conn.buf[conn.filled..].ptr, conn.buf.len - conn.filled);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return .close;

                conn.filled += n;
            },
            .AGAIN, .INTR => {},
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

    // A frame wider than the whole buffer can never complete: close rather than
    // spin on a connection that can make no progress.
    if (conn.filled >= conn.buf.len) return .close;

    return .keep_alive;
}

/// Read and discard the remaining body bytes of an over-large request whose
/// response was already sent. Reads to EAGAIN, never past conn.drain, so the
/// next request's bytes are left untouched. When the drain finishes, the
/// connection resumes normal HTTP parsing, or closes if the request asked to.
///
/// Return:
/// - .keep_alive while bytes remain or once a keep-alive body is fully drained
/// - .close on peer hangup or once a Connection: close body is fully drained
fn serveEpollDrain(conn: *Conn) core.ConnOutcome {
    const linux = std.os.linux;
    const fd = conn.fd;

    while (conn.drain > 0) {
        const want = @min(conn.drain, conn.buf.len);
        const rc = linux.read(fd, conn.buf.ptr, want);
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

const EpollWorkerCtx = struct { config: Config, handler: HandlerFn };

fn epollWorker(ctx: EpollWorkerCtx) void {
    const linux = std.os.linux;
    const config = ctx.config;
    const io = config.io;

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

    var table = ConnTable.init() catch return;
    defer table.deinit();

    const body_buf = std.heap.smp_allocator.alloc(u8, core.BUF_SIZE) catch return;
    defer std.heap.smp_allocator.free(body_buf);

    const out_buf = std.heap.smp_allocator.alloc(u8, core.BUF_SIZE) catch return;
    defer std.heap.smp_allocator.free(out_buf);

    var events: [EPOLL_MAX_EVENTS]linux.epoll_event = undefined;
    while (true) {
        const wait_rc = linux.epoll_wait(epfd, &events, EPOLL_MAX_EVENTS, -1);
        switch (std.posix.errno(wait_rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return,
        }

        const n: usize = @intCast(wait_rc);
        for (events[0..n]) |ev| {
            if (ev.data.fd == listener_fd) {
                acceptAll(&table, epfd, listener_fd, config.max_recv_buf);
                continue;
            }

            const conn = table.get(ev.data.fd) orelse continue;
            const outcome = if ((ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0)
                core.ConnOutcome.close
            else if (conn.drain > 0)
                serveEpollDrain(conn)
            else if (conn.ws) |on_frame|
                serveEpollWs(conn, on_frame, body_buf, out_buf)
            else
                serveEpollConn(conn, ctx.handler, body_buf, out_buf, config.handler_timeout_ms);

            if (outcome == .close) {
                _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, ev.data.fd, null);
                table.free(ev.data.fd);
                _ = linux.close(ev.data.fd);
            }
        }
    }
}

fn runEpoll(config: Config, handler: HandlerFn) !void {
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (config.workers == 0) cpu else config.workers;

    logSystem(config, "listening on {s}:{d} (epoll, {d} workers, shared-nothing)", .{ config.ip, config.port, worker_count });

    const threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(threads);

    for (threads) |*t| {
        t.* = try std.Thread.spawn(
            .{ .stack_size = 512 * 1024 },
            epollWorker,
            .{EpollWorkerCtx{ .config = config, .handler = handler }},
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
            .{MixedAcceptCtx{ .io = io, .ip = config.ip, .port = config.port, .kernel_backlog = config.kernel_backlog, .handler = handler, .handler_timeout_ms = config.handler_timeout_ms }},
        );
    }

    for (acc_threads) |t| t.join();
}

// --------------------------------------------------------- //

/// Server type specialized over a comptime handler.
///
/// Note:
/// - handler is baked into the type, so run() takes no argument. The server core
///   stays routing-agnostic: handler can be a Router(routes).dispatch, a bare
///   HandlerFn, or a middleware chain.
fn Http1ServerImpl(comptime handler: HandlerFn) type {
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
                    runEpoll(self.config, handler)
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
    /// - Http1ServerImpl(handler)
    pub fn init(comptime handler: HandlerFn, config: Config) Http1ServerImpl(handler) {
        return Http1ServerImpl(handler).init(config);
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
