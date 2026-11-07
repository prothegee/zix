//! ZIX Http1 dispatch epoll model
//!
//! ### file: src/zix/tcp/http1/dispatch/epoll.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Linux epoll model: worker threads share nothing, each owns a listener,
//! an epoll instance, and the connections it accepted.
//!
//! ### note:
//!
//! Cleartext HTTP/1.1 only. TLS, WebSocket, SSE, and the response cache are
//! not part of this model yet. A connection is served on one worker from
//! accept to close. A response larger than the staging cap falls back to the
//! blocking writer.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const chunk = @import("../chunk.zig");
const Config = @import("../Config.zig");
const common = @import("common.zig");
const handler = @import("../handler.zig");
const HandlerFn = handler.HandlerFn;
const head_module = @import("../head.zig");
const header = @import("../header.zig");
const parser = @import("../parser.zig");
const reader = @import("../reader.zig");
const RespSink = @import("../RespSink.zig");
const writer = @import("../writer.zig");

// --------------------------------------------------------- //
// Private:

/// Per-worker response staging buffer.
const OUT_BUF: usize = 64 * 1024;

/// A response larger than this is flushed directly instead of grown.
const MAX_RESPONSE_BYTES: usize = 8 * 1024 * 1024;

const EPOLL_MAX_EVENTS: usize = 256;
const EPOLL_WAIT_TIMEOUT_MS: i32 = 1000;

const RESPONSE_100_CONTINUE = "HTTP/1.1 100 Continue\r\n\r\n";
const RESPONSE_400_CLOSE =
    "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const RESPONSE_413_CLOSE =
    "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const RESPONSE_431 =
    "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n";

const ConnOutcome = enum {
    keep_alive,
    close,
};

/// One accepted connection and everything the worker needs to resume it.
const Conn = struct {
    fd: std.posix.fd_t,
    buf: []u8,
    filled: usize = 0,
    /// Bytes of buf already searched for the header terminator.
    scan_from: usize = 0,
    /// Set once the 100 Continue answer was staged for this request.
    continue_sent: bool = false,
    /// Body bytes still to read and discard for a body too large to buffer.
    drain: usize = 0,
    /// Body bytes already taken off the socket for the deferred request.
    drain_received: usize = 0,
    /// Head bytes parked at the front of buf while the drain runs.
    pending_head_len: usize = 0,
    /// Response bytes staged after EAGAIN.
    write_pending: []u8 = &.{},
    write_pending_len: usize = 0,
    write_pending_off: usize = 0,
    write_pending_close: bool = false,
};

/// What every connection needs from the worker, without the listener state.
const Session = struct {
    io: std.Io,
    handler: HandlerFn,
    allocator: std.mem.Allocator,
    /// Per-handler budget in milliseconds, from config.handler_timeout_ms. 0 disables it.
    handler_timeout_ms: u32 = 0,
    /// Declared request body larger than this is refused with 413. 0 disables the check.
    max_request_body: usize = 0,
    /// SO_RCVBUF set when a body larger than the receive buffer is drained. 0 keeps
    /// the kernel default.
    large_body_recv_buf: usize = 0,
};

/// One worker's setup, passed by value to the spawned thread.
const WorkerCtx = struct {
    config: Config,
    handler: HandlerFn,
    listener: std.Io.net.Server,
    allocator: std.mem.Allocator,
    stop: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
};

fn workerCount(workers: usize) usize {
    if (workers != 0) return workers;

    const cpu = std.Thread.getCpuCount() catch |err| switch (err) {
        else => 1,
    };

    return @max(1, cpu);
}

/// Best effort: a kernel that rejects TCP_NODELAY still serves the request.
fn setNoDelay(fd: std.posix.fd_t) void {
    std.posix.setsockopt(
        fd,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&@as(c_int, 1)),
    ) catch |err| switch (err) {
        else => {},
    };
}

fn setNonBlock(fd: std.posix.fd_t) bool {
    const rc = linux.fcntl(fd, linux.F.GETFL, 0);
    if (std.posix.errno(rc) != .SUCCESS) return false;

    const flags: linux.O = @bitCast(@as(u32, @intCast(rc)));
    var nonblock = flags;
    nonblock.NONBLOCK = true;
    const bits: u32 = @bitCast(nonblock);
    const set_rc = linux.fcntl(fd, linux.F.SETFL, @intCast(bits));

    return std.posix.errno(set_rc) == .SUCCESS;
}

fn closeListeners(listeners: []std.Io.net.Server, io: std.Io) void {
    for (listeners) |*listener| listener.deinit(io);
}

fn failSetup(ctx: *const WorkerCtx) void {
    ctx.failed.store(true, .release);
    ctx.stop.store(true, .release);
}

fn connAlloc(allocator: std.mem.Allocator, fd: std.posix.fd_t, buf_size: usize) ?*Conn {
    const conn = allocator.create(Conn) catch |err| switch (err) {
        error.OutOfMemory => return null,
    };
    const buf = allocator.alloc(u8, buf_size) catch |err| switch (err) {
        error.OutOfMemory => {
            allocator.destroy(conn);

            return null;
        },
    };
    conn.* = .{ .fd = fd, .buf = buf };

    return conn;
}

fn connFree(allocator: std.mem.Allocator, conn: *Conn) void {
    if (conn.write_pending.len > 0) allocator.free(conn.write_pending);

    allocator.free(conn.buf);
    allocator.destroy(conn);
}

/// Close with unread input still queued sends RST and can discard a response
/// already written. Half-close the write side first, then drain what the peer
/// already sent, so the last response is not lost.
fn drainInput(fd: std.posix.fd_t) void {
    var scratch: [4096]u8 = undefined;
    var rounds: usize = 0;
    while (rounds < 32) : (rounds += 1) {
        const rc = linux.recvfrom(
            fd,
            scratch[0..].ptr,
            scratch.len,
            linux.MSG.DONTWAIT,
            null,
            null,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const received: usize = @intCast(rc);
                if (received == 0) return;
            },
            .AGAIN => return,
            .INTR => continue,
            else => return,
        }
    }
}

fn closeConn(epfd: std.posix.fd_t, conn: *Conn, allocator: std.mem.Allocator) void {
    const fd = conn.fd;

    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, fd, null);
    connFree(allocator, conn);
    _ = linux.shutdown(fd, linux.SHUT.WR);
    drainInput(fd);
    _ = linux.close(fd);
}

/// Write as much as possible. On EAGAIN returns the count written so far.
/// Null means a permanent write error.
fn writeNonBlockFD(fd: std.posix.fd_t, data: []const u8) ?usize {
    var written: usize = 0;
    while (written < data.len) {
        const rc = std.posix.system.write(
            fd,
            data[written..].ptr,
            data.len - written,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const count: usize = @intCast(rc);
                if (count == 0) return null;
                written += count;
            },
            .INTR => continue,
            .AGAIN => return written,
            else => return null,
        }
    }

    return written;
}

fn stageResponse(fd: std.posix.fd_t, bytes: []const u8) bool {
    writer.writeAllFD(fd, bytes) catch |err| switch (err) {
        error.ZixHttp1_Writer_BrokenPipe,
        error.ZixHttp1_Writer_HeadBuild,
        => return false,
    };

    return true;
}

fn armOut(conn: *Conn, epfd: std.posix.fd_t) bool {
    var event = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.RDHUP,
        .data = .{ .ptr = @intFromPtr(conn) },
    };
    const rc = linux.epoll_ctl(
        epfd,
        linux.EPOLL.CTL_MOD,
        conn.fd,
        &event,
    );

    return std.posix.errno(rc) == .SUCCESS;
}

fn disarmOut(conn: *Conn, epfd: std.posix.fd_t) bool {
    var event = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
        .data = .{ .ptr = @intFromPtr(conn) },
    };
    const rc = linux.epoll_ctl(
        epfd,
        linux.EPOLL.CTL_MOD,
        conn.fd,
        &event,
    );

    return std.posix.errno(rc) == .SUCCESS;
}

fn stagePending(
    conn: *Conn,
    remaining: []const u8,
    outcome: ConnOutcome,
    epfd: std.posix.fd_t,
    allocator: std.mem.Allocator,
) ConnOutcome {
    const staged = allocator.alloc(u8, remaining.len) catch |err| switch (err) {
        error.OutOfMemory => return .close,
    };
    @memcpy(staged, remaining);

    conn.write_pending = staged;
    conn.write_pending_len = remaining.len;
    conn.write_pending_off = 0;
    conn.write_pending_close = outcome == .close;

    if (!armOut(conn, epfd)) {
        allocator.free(staged);
        conn.write_pending = &.{};
        conn.write_pending_len = 0;
        conn.write_pending_close = false;

        return .close;
    }

    return .keep_alive;
}

fn flushStaged(
    conn: *Conn,
    staged: []const u8,
    outcome: ConnOutcome,
    epfd: std.posix.fd_t,
    allocator: std.mem.Allocator,
) ConnOutcome {
    if (staged.len == 0) return outcome;

    const written = writeNonBlockFD(conn.fd, staged) orelse return .close;
    if (written < staged.len) {
        return stagePending(
            conn,
            staged[written..],
            outcome,
            epfd,
            allocator,
        );
    }

    return outcome;
}

fn serveWrite(
    conn: *Conn,
    epfd: std.posix.fd_t,
    allocator: std.mem.Allocator,
) ConnOutcome {
    const pending = conn.write_pending[conn.write_pending_off..conn.write_pending_len];
    const written = writeNonBlockFD(conn.fd, pending) orelse return .close;
    conn.write_pending_off += written;

    if (conn.write_pending_off < conn.write_pending_len) return .keep_alive;

    allocator.free(conn.write_pending);
    conn.write_pending = &.{};
    conn.write_pending_len = 0;
    conn.write_pending_off = 0;
    const should_close = conn.write_pending_close;
    conn.write_pending_close = false;

    if (!disarmOut(conn, epfd)) return .close;

    return if (should_close) .close else .keep_alive;
}

fn serveDrain(conn: *Conn, scratch: []u8) ConnOutcome {
    while (conn.drain > 0) {
        const want = @min(conn.drain, scratch.len);
        const rc = linux.recvfrom(
            conn.fd,
            scratch.ptr,
            want,
            0,
            null,
            null,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const received: usize = @intCast(rc);
                if (received == 0) return .close;
                conn.drain -= received;
                conn.drain_received += received;
            },
            .AGAIN => return .keep_alive,
            .INTR => continue,
            else => return .close,
        }
    }

    return .keep_alive;
}

/// A peer that hangs up mid-request gets a 400. An idle keep-alive
/// connection closes without a byte, which is the ordinary end.
fn hangupOutcome(conn: *Conn) ConnOutcome {
    if (conn.filled > 0 or conn.pending_head_len > 0) {
        _ = writeNonBlockFD(conn.fd, RESPONSE_400_CLOSE);
    }

    return .close;
}

fn serveDrainThenServe(
    conn: *Conn,
    body_buf: []u8,
    out_buf: []u8,
    session: *const Session,
    epfd: std.posix.fd_t,
    arena: *std.heap.ArenaAllocator,
) ConnOutcome {
    const outcome = serveDrain(conn, body_buf);

    if (outcome == .close) {
        const hangup = hangupOutcome(conn);
        conn.pending_head_len = 0;
        conn.drain_received = 0;

        return hangup;
    }

    if (conn.drain > 0 or conn.pending_head_len == 0) return .keep_alive;

    conn.filled = conn.pending_head_len;

    return serveReadable(
        conn,
        body_buf,
        out_buf,
        session,
        epfd,
        arena,
        false,
    );
}

fn serveInner(
    conn: *Conn,
    body_buf: []u8,
    session: *const Session,
    arena: *std.heap.ArenaAllocator,
    do_read: bool,
) ConnOutcome {
    const fd = conn.fd;

    if (do_read) {
        const rc = std.posix.system.read(
            conn.fd,
            conn.buf[conn.filled..].ptr,
            conn.buf.len - conn.filled,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const received: usize = @intCast(rc);
                if (received == 0) return hangupOutcome(conn);
                conn.filled += received;
            },
            .AGAIN => {},
            .INTR => {},
            else => return .close,
        }
    }

    var consumed: usize = 0;
    var keep_alive = true;
    var scan_from = conn.scan_from;
    conn.scan_from = 0;

    while (consumed < conn.filled) {
        const rem = conn.buf[consumed..conn.filled];
        const header_end = std.mem.indexOfPos(
            u8,
            rem,
            scan_from,
            "\r\n\r\n",
        ) orelse {
            if (rem.len >= conn.buf.len) {
                _ = stageResponse(fd, RESPONSE_431);

                return .close;
            }

            conn.scan_from = if (rem.len > 3) rem.len - 3 else 0;
            break;
        };
        scan_from = 0;

        const parsed = parser.parseHeadAt(rem, header_end) catch |err| switch (err) {
            else => {
                _ = stageResponse(fd, parser.parseErrorResponse(err));

                return .close;
            },
        };
        const head = parsed.head;

        if (head.expect_continue and
            !conn.continue_sent and
            (head.content_length > 0 or head.chunked_request))
        {
            if (!stageResponse(fd, RESPONSE_100_CONTINUE)) return .close;
            conn.continue_sent = true;
        }

        var body: []const u8 = &.{};
        var request_len: usize = parsed.body_offset;

        if (head.chunked_request) {
            const decoded = chunk.decodeChunkedInBuf(
                rem[parsed.body_offset..],
                body_buf,
            );
            switch (decoded.stop) {
                .COMPLETE => {},
                .NEED_MORE => break,
                .MALFORMED => {
                    _ = stageResponse(fd, RESPONSE_400_CLOSE);

                    return .close;
                },
                .TOO_LARGE => {
                    _ = stageResponse(fd, RESPONSE_413_CLOSE);

                    return .close;
                },
            }

            body = body_buf[0..decoded.len];
            request_len = parsed.body_offset + decoded.consumed;
        } else if (head.content_length > 0) {
            if (session.max_request_body != 0 and
                head.content_length > session.max_request_body)
            {
                _ = stageResponse(fd, RESPONSE_413_CLOSE);

                return .close;
            }

            if (head.content_length >
                std.math.maxInt(usize) - parsed.body_offset)
            {
                _ = stageResponse(fd, RESPONSE_413_CLOSE);

                return .close;
            }

            const content_length: usize = @intCast(head.content_length);
            const need = parsed.body_offset + content_length;

            if (need <= rem.len) {
                body = rem[parsed.body_offset..need];
                request_len = need;
            } else if (conn.pending_head_len > 0) {
                handler.tl_body_info = .{
                    .received = conn.drain_received,
                    .complete = true,
                };
                conn.pending_head_len = 0;
                conn.drain_received = 0;
                request_len = parsed.body_offset;
            } else if (need > conn.buf.len) {
                // Best effort: a kernel that rejects SO_RCVBUF still drains the body.
                reader.setRecvBuf(fd, session.large_body_recv_buf) catch |err| switch (err) {
                    else => {},
                };

                if (consumed > 0) {
                    std.mem.copyForwards(
                        u8,
                        conn.buf[0..parsed.body_offset],
                        rem[0..parsed.body_offset],
                    );
                }

                const present_body = rem.len - parsed.body_offset;
                conn.drain = content_length - present_body;
                conn.drain_received = present_body;
                conn.pending_head_len = parsed.body_offset;
                consumed = conn.filled;

                break;
            } else {
                break;
            }
        }

        handler.setTimeout(session.io, session.handler_timeout_ms);
        _ = arena.reset(.retain_capacity);
        handler.invokeHandler(
            session.handler,
            &head,
            body,
            fd,
            session.io,
            arena.allocator(),
        );

        consumed += request_len;
        conn.continue_sent = false;

        if (!head.keep_alive) {
            keep_alive = false;
            break;
        }
    }

    if (consumed >= conn.filled) {
        conn.filled = 0;
    } else if (consumed > 0) {
        std.mem.copyForwards(
            u8,
            conn.buf[0 .. conn.filled - consumed],
            conn.buf[consumed..conn.filled],
        );
        conn.filled -= consumed;
    }

    return if (keep_alive) .keep_alive else .close;
}

fn serveReadable(
    conn: *Conn,
    body_buf: []u8,
    out_buf: []u8,
    session: *const Session,
    epfd: std.posix.fd_t,
    arena: *std.heap.ArenaAllocator,
    do_read: bool,
) ConnOutcome {
    var sink = RespSink{
        .fd = conn.fd,
        .buf = out_buf,
        .buf_owned = false,
        .grow_allocator = session.allocator,
        .grow_cap = MAX_RESPONSE_BYTES,
    };
    writer.tl_resp_sink = &sink;
    defer writer.tl_resp_sink = null;
    defer if (sink.buf_owned) {
        session.allocator.free(sink.buf);
    };

    const outcome = serveInner(conn, body_buf, session, arena, do_read);
    if (sink.failed) return .close;

    return flushStaged(
        conn,
        sink.buf[sink.off..sink.len],
        outcome,
        epfd,
        session.allocator,
    );
}

fn acceptAll(
    epfd: std.posix.fd_t,
    listener_fd: std.posix.fd_t,
    allocator: std.mem.Allocator,
    buf_size: usize,
) void {
    while (true) {
        const rc = linux.accept4(
            listener_fd,
            null,
            null,
            std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return,
            .INTR, .CONNABORTED => continue,
            else => return,
        }

        const fd: std.posix.fd_t = @intCast(rc);
        setNoDelay(fd);

        const conn = connAlloc(allocator, fd, buf_size) orelse {
            _ = linux.close(fd);
            continue;
        };

        var event = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
            .data = .{ .ptr = @intFromPtr(conn) },
        };
        const add_rc = linux.epoll_ctl(
            epfd,
            linux.EPOLL.CTL_ADD,
            fd,
            &event,
        );
        if (std.posix.errno(add_rc) != .SUCCESS) {
            connFree(allocator, conn);
            _ = linux.close(fd);
        }
    }
}

fn workerMain(ctx: WorkerCtx) void {
    var worker = ctx;
    const io = worker.config.io;
    defer worker.listener.deinit(io);

    handler.setAccessLogger(worker.config.logger);
    head_module.setDateHeader(worker.config.send_date_header);
    header.setMaxResponseHeaders(worker.config.max_response_headers.value());

    const recv_size = worker.config.recvBufSize();
    const listener_fd = worker.listener.socket.handle;
    if (!setNonBlock(listener_fd)) {
        failSetup(&worker);
        return;
    }

    const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (std.posix.errno(epfd_rc) != .SUCCESS) {
        failSetup(&worker);
        return;
    }
    const epfd: std.posix.fd_t = @intCast(epfd_rc);
    defer _ = linux.close(epfd);

    var listener_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .ptr = 0 },
    };
    const add_rc = linux.epoll_ctl(
        epfd,
        linux.EPOLL.CTL_ADD,
        listener_fd,
        &listener_event,
    );
    if (std.posix.errno(add_rc) != .SUCCESS) {
        failSetup(&worker);
        return;
    }

    const body_buf = worker.allocator.alloc(u8, recv_size) catch |err| switch (err) {
        error.OutOfMemory => {
            failSetup(&worker);
            return;
        },
    };
    defer worker.allocator.free(body_buf);

    const out_buf = worker.allocator.alloc(u8, OUT_BUF) catch |err| switch (err) {
        error.OutOfMemory => {
            failSetup(&worker);
            return;
        },
    };
    defer worker.allocator.free(out_buf);

    var arena = std.heap.ArenaAllocator.init(worker.allocator);
    defer arena.deinit();

    const session = Session{
        .io = io,
        .handler = worker.handler,
        .allocator = worker.allocator,
        .handler_timeout_ms = worker.config.handler_timeout_ms,
        .max_request_body = worker.config.max_request_body,
        .large_body_recv_buf = worker.config.large_body_recv_buf,
    };

    var events: [EPOLL_MAX_EVENTS]linux.epoll_event = undefined;
    while (!worker.stop.load(.acquire)) {
        const wait_rc = linux.epoll_wait(
            epfd,
            &events,
            EPOLL_MAX_EVENTS,
            EPOLL_WAIT_TIMEOUT_MS,
        );
        switch (std.posix.errno(wait_rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => {
                failSetup(&worker);
                return;
            },
        }

        const event_count: usize = @intCast(wait_rc);
        for (events[0..event_count]) |event| {
            if (event.data.ptr == 0) {
                acceptAll(epfd, listener_fd, worker.allocator, recv_size);
                continue;
            }

            const conn: *Conn = @ptrFromInt(event.data.ptr);
            const outcome: ConnOutcome = if ((event.events &
                (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0)
                .close
            else if (conn.write_pending_len > conn.write_pending_off)
                serveWrite(conn, epfd, worker.allocator)
            else if (conn.drain > 0)
                serveDrainThenServe(
                    conn,
                    body_buf,
                    out_buf,
                    &session,
                    epfd,
                    &arena,
                )
            else
                serveReadable(
                    conn,
                    body_buf,
                    out_buf,
                    &session,
                    epfd,
                    &arena,
                    true,
                );

            if (outcome == .close) {
                closeConn(epfd, conn, worker.allocator);
            }
        }
    }
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixHttp1_Epoll_Unsupported,
    ZixHttp1_Epoll_ResolveFailed,
    ZixHttp1_Epoll_ListenFailed,
    ZixHttp1_Epoll_OutOfMemory,
    ZixHttp1_Epoll_SpawnFailed,
    ZixHttp1_Epoll_SetupFailed,
};

/// Run one epoll worker per CPU, or per config.workers when non-zero.
pub fn run(config: Config, handler_fn: HandlerFn) Error!void {
    if (comptime builtin.target.os.tag != .linux) {
        return Error.ZixHttp1_Epoll_Unsupported;
    }

    const io = config.io;
    const allocator = std.heap.smp_allocator;
    const workers = workerCount(config.workers);

    const address = std.Io.net.IpAddress.resolve(
        io,
        config.ip,
        config.port,
    ) catch |err| switch (err) {
        else => return Error.ZixHttp1_Epoll_ResolveFailed,
    };

    const listeners = allocator.alloc(
        std.Io.net.Server,
        workers,
    ) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp1_Epoll_OutOfMemory,
    };

    var bound: usize = 0;
    while (bound < workers) : (bound += 1) {
        listeners[bound] = address.listen(io, .{
            .mode = .stream,
            .reuse_address = true,
            .kernel_backlog = config.kernel_backlog,
        }) catch |err| switch (err) {
            else => {
                closeListeners(listeners[0..bound], io);
                allocator.free(listeners);

                return Error.ZixHttp1_Epoll_ListenFailed;
            },
        };
    }

    const threads = allocator.alloc(
        std.Thread,
        workers,
    ) catch |err| switch (err) {
        error.OutOfMemory => {
            closeListeners(listeners, io);
            allocator.free(listeners);

            return Error.ZixHttp1_Epoll_OutOfMemory;
        },
    };
    defer allocator.free(threads);

    var stop = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);

    var spawned: usize = 0;
    while (spawned < workers) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(
            .{},
            workerMain,
            .{WorkerCtx{
                .config = config,
                .handler = handler_fn,
                .listener = listeners[spawned],
                .allocator = allocator,
                .stop = &stop,
                .failed = &failed,
            }},
        ) catch |err| switch (err) {
            else => {
                stop.store(true, .release);
                closeListeners(listeners[spawned..], io);
                for (threads[0..spawned]) |thread| thread.join();
                allocator.free(listeners);

                return Error.ZixHttp1_Epoll_SpawnFailed;
            },
        };
    }

    common.logSystem(
        config,
        .INFO,
        "listening on {s}:{d} (epoll, {d} workers)",
        .{ config.ip, config.port, workers },
    );

    for (threads) |thread| thread.join();

    allocator.free(listeners);

    if (failed.load(.acquire)) return Error.ZixHttp1_Epoll_SetupFailed;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Context = @import("../Context.zig");
const Request = @import("../Request.zig");
const Response = @import("../Response.zig");
const pair = @import("../../../utils/socket/pair.zig");

/// Receive buffer size the tests allocate, the same 16 KiB the worker used before
/// it read max_recv_buf from Config.
const TEST_CONN_BUF: usize = 16 * 1024;

/// SO_RCVBUF the kernel reports for fd.
fn testRecvBufSize(fd: std.posix.fd_t) !usize {
    var value: c_int = 0;
    var len: linux.socklen_t = @sizeOf(c_int);
    const rc = linux.getsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVBUF,
        std.mem.asBytes(&value),
        &len,
    );
    if (std.posix.errno(rc) != .SUCCESS) return error.ZixTest_GetSockOptFailed;

    return @intCast(value);
}

fn okHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("ok");
}

fn testSession(
    allocator: std.mem.Allocator,
    max_request_body: usize,
) Session {
    return .{
        .io = std.testing.io,
        .handler = okHandler,
        .allocator = allocator,
        .max_request_body = max_request_body,
    };
}

fn testWriteAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.posix.system.write(
            fd,
            bytes[written..].ptr,
            bytes.len - written,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const count: usize = @intCast(rc);
                if (count == 0) return error.TestWriteClosed;
                written += count;
            },
            .INTR => continue,
            else => return error.TestWriteFailed,
        }
    }
}

fn testReadAvailable(fd: std.posix.fd_t, out: []u8) []u8 {
    var len: usize = 0;
    while (len < out.len) {
        const rc = linux.recvfrom(
            fd,
            out[len..].ptr,
            out.len - len,
            linux.MSG.DONTWAIT,
            null,
            null,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const count: usize = @intCast(rc);
                if (count == 0) break;
                len += count;
            },
            .AGAIN => break,
            .INTR => continue,
            else => break,
        }
    }

    return out[0..len];
}

fn testPair() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);

    return fds;
}

test "zix http1: epoll, answers one request" {
    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head_module.setDateHeader(false);
    defer head_module.setDateHeader(true);

    try testWriteAll(fds[0], "GET / HTTP/1.1\r\nConnection: close\r\n\r\n");

    const conn = connAlloc(std.testing.allocator, fds[1], TEST_CONN_BUF).?;
    defer connFree(std.testing.allocator, conn);

    var body_buf: [1024]u8 = undefined;
    var out_buf: [1024]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = testSession(std.testing.allocator, 0);

    const outcome = serveReadable(
        conn,
        &body_buf,
        &out_buf,
        &session,
        -1,
        &arena,
        true,
    );
    try std.testing.expectEqual(ConnOutcome.close, outcome);

    var out: [512]u8 = undefined;
    const response = testReadAvailable(fds[0], &out);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Ok\r\nContent-Type: text/plain\r\n" ++
            "Content-Length: 2\r\n\r\nok",
        response,
    );
}

test "zix http1: epoll, answers a pipelined burst in order" {
    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head_module.setDateHeader(false);
    defer head_module.setDateHeader(true);

    try testWriteAll(
        fds[0],
        "GET /a HTTP/1.1\r\nConnection: keep-alive\r\n\r\n" ++
            "GET /b HTTP/1.1\r\nConnection: close\r\n\r\n",
    );

    const conn = connAlloc(std.testing.allocator, fds[1], TEST_CONN_BUF).?;
    defer connFree(std.testing.allocator, conn);

    var body_buf: [1024]u8 = undefined;
    var out_buf: [1024]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = testSession(std.testing.allocator, 0);

    const outcome = serveReadable(
        conn,
        &body_buf,
        &out_buf,
        &session,
        -1,
        &arena,
        true,
    );
    try std.testing.expectEqual(ConnOutcome.close, outcome);
    try std.testing.expectEqual(@as(usize, 0), conn.filled);

    var out: [1024]u8 = undefined;
    const response = testReadAvailable(fds[0], &out);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, response, "HTTP/1.1 200 Ok"),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, response, "Content-Length: 2"),
    );
}

test "zix http1: epoll, waits for the rest of a split head" {
    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head_module.setDateHeader(false);
    defer head_module.setDateHeader(true);

    try testWriteAll(fds[0], "GET / HTTP/1.1\r\n");

    const conn = connAlloc(std.testing.allocator, fds[1], TEST_CONN_BUF).?;
    defer connFree(std.testing.allocator, conn);

    var body_buf: [1024]u8 = undefined;
    var out_buf: [1024]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = testSession(std.testing.allocator, 0);
    var out: [512]u8 = undefined;

    const first = serveReadable(
        conn,
        &body_buf,
        &out_buf,
        &session,
        -1,
        &arena,
        true,
    );
    try std.testing.expectEqual(ConnOutcome.keep_alive, first);
    try std.testing.expectEqual(@as(usize, 0), testReadAvailable(fds[0], &out).len);
    try std.testing.expect(conn.scan_from > 0);

    try testWriteAll(fds[0], "Connection: close\r\n\r\n");

    const second = serveReadable(
        conn,
        &body_buf,
        &out_buf,
        &session,
        -1,
        &arena,
        true,
    );
    try std.testing.expectEqual(ConnOutcome.close, second);

    const response = testReadAvailable(fds[0], &out);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Ok\r\nContent-Type: text/plain\r\n" ++
            "Content-Length: 2\r\n\r\nok",
        response,
    );
}

test "zix http1: epoll, serves a second request on keep-alive" {
    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head_module.setDateHeader(false);
    defer head_module.setDateHeader(true);

    const conn = connAlloc(std.testing.allocator, fds[1], TEST_CONN_BUF).?;
    defer connFree(std.testing.allocator, conn);

    var body_buf: [1024]u8 = undefined;
    var out_buf: [1024]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = testSession(std.testing.allocator, 0);
    var out: [512]u8 = undefined;

    try testWriteAll(fds[0], "GET /a HTTP/1.1\r\nConnection: keep-alive\r\n\r\n");

    const first = serveReadable(
        conn,
        &body_buf,
        &out_buf,
        &session,
        -1,
        &arena,
        true,
    );
    try std.testing.expectEqual(ConnOutcome.keep_alive, first);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Ok\r\nContent-Type: text/plain\r\n" ++
            "Content-Length: 2\r\n\r\nok",
        testReadAvailable(fds[0], &out),
    );

    try testWriteAll(fds[0], "GET /b HTTP/1.1\r\nConnection: close\r\n\r\n");

    const second = serveReadable(
        conn,
        &body_buf,
        &out_buf,
        &session,
        -1,
        &arena,
        true,
    );
    try std.testing.expectEqual(ConnOutcome.close, second);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Ok\r\nContent-Type: text/plain\r\n" ++
            "Content-Length: 2\r\n\r\nok",
        testReadAvailable(fds[0], &out),
    );
}

test "zix http1: epoll, answers 431 for an oversized head" {
    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var buf: [64]u8 = @splat('a');
    var conn = Conn{ .fd = fds[1], .buf = &buf, .filled = buf.len };

    var body_buf: [64]u8 = undefined;
    var out_buf: [512]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = testSession(std.testing.allocator, 0);

    const outcome = serveReadable(
        &conn,
        &body_buf,
        &out_buf,
        &session,
        -1,
        &arena,
        false,
    );
    try std.testing.expectEqual(ConnOutcome.close, outcome);

    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        RESPONSE_431,
        testReadAvailable(fds[0], &out),
    );
}

test "zix http1: epoll, refuses a body past the cap with 413" {
    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const request = "POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n";
    var buf: [128]u8 = undefined;
    @memcpy(buf[0..request.len], request);
    var conn = Conn{ .fd = fds[1], .buf = &buf, .filled = request.len };

    var body_buf: [64]u8 = undefined;
    var out_buf: [512]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = testSession(std.testing.allocator, 4);

    const outcome = serveReadable(
        &conn,
        &body_buf,
        &out_buf,
        &session,
        -1,
        &arena,
        false,
    );
    try std.testing.expectEqual(ConnOutcome.close, outcome);

    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        RESPONSE_413_CLOSE,
        testReadAvailable(fds[0], &out),
    );
}

test "zix http1: epoll, answers 400 on a malformed chunked body" {
    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const request =
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n";
    var buf: [128]u8 = undefined;
    @memcpy(buf[0..request.len], request);
    var conn = Conn{ .fd = fds[1], .buf = &buf, .filled = request.len };

    var body_buf: [64]u8 = undefined;
    var out_buf: [512]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = testSession(std.testing.allocator, 0);

    const outcome = serveReadable(
        &conn,
        &body_buf,
        &out_buf,
        &session,
        -1,
        &arena,
        false,
    );
    try std.testing.expectEqual(ConnOutcome.close, outcome);

    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        RESPONSE_400_CLOSE,
        testReadAvailable(fds[0], &out),
    );
}

test "zix http1: epoll, stages a partial write until EPOLLOUT" {
    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const sndbuf: c_int = 1024;
    try std.posix.setsockopt(
        fds[1],
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDBUF,
        std.mem.asBytes(&sndbuf),
    );
    try std.testing.expect(setNonBlock(fds[1]));

    const conn = connAlloc(std.testing.allocator, fds[1], TEST_CONN_BUF).?;
    defer connFree(std.testing.allocator, conn);

    const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    try std.testing.expectEqual(
        std.posix.E.SUCCESS,
        std.posix.errno(epfd_rc),
    );
    const epfd: std.posix.fd_t = @intCast(epfd_rc);
    defer _ = linux.close(epfd);

    var event = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
        .data = .{ .ptr = @intFromPtr(conn) },
    };
    try std.testing.expectEqual(
        std.posix.E.SUCCESS,
        std.posix.errno(linux.epoll_ctl(
            epfd,
            linux.EPOLL.CTL_ADD,
            conn.fd,
            &event,
        )),
    );

    const payload = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'a');

    const staged = flushStaged(
        conn,
        payload,
        .keep_alive,
        epfd,
        std.testing.allocator,
    );
    try std.testing.expectEqual(ConnOutcome.keep_alive, staged);
    try std.testing.expect(conn.write_pending_len > 0);

    var out: [4096]u8 = undefined;
    var guard: usize = 0;
    while (conn.write_pending_len > conn.write_pending_off) : (guard += 1) {
        try std.testing.expect(guard < 1000);
        _ = testReadAvailable(fds[0], &out);
        const drained = serveWrite(conn, epfd, std.testing.allocator);
        try std.testing.expectEqual(ConnOutcome.keep_alive, drained);
    }

    try std.testing.expectEqual(@as(usize, 0), conn.write_pending_len);
    try std.testing.expectEqual(@as(usize, 0), conn.write_pending_off);
}

test "zix http1: epoll, drains queued input before close" {
    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try testWriteAll(fds[0], "abc");
    drainInput(fds[1]);

    var out: [8]u8 = undefined;
    const rc = linux.recvfrom(
        fds[1],
        out[0..].ptr,
        out.len,
        linux.MSG.DONTWAIT,
        null,
        null,
    );
    try std.testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(rc));
}

test "zix http1: epoll, sends 100 Continue while the body still arrives" {
    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head_module.setDateHeader(false);
    defer head_module.setDateHeader(true);

    try testWriteAll(
        fds[0],
        "POST / HTTP/1.1\r\nContent-Length: 5\r\nExpect: 100-continue\r\n" ++
            "Connection: close\r\n\r\n",
    );

    const conn = connAlloc(std.testing.allocator, fds[1], TEST_CONN_BUF).?;
    defer connFree(std.testing.allocator, conn);

    var body_buf: [1024]u8 = undefined;
    var out_buf: [1024]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = testSession(std.testing.allocator, 0);
    var out: [512]u8 = undefined;

    const first = serveReadable(
        conn,
        &body_buf,
        &out_buf,
        &session,
        -1,
        &arena,
        true,
    );
    try std.testing.expectEqual(ConnOutcome.keep_alive, first);
    try std.testing.expectEqualStrings(
        RESPONSE_100_CONTINUE,
        testReadAvailable(fds[0], &out),
    );

    try testWriteAll(fds[0], "hello");

    const second = serveReadable(
        conn,
        &body_buf,
        &out_buf,
        &session,
        -1,
        &arena,
        true,
    );
    try std.testing.expectEqual(ConnOutcome.close, second);

    const response = testReadAvailable(fds[0], &out);
    try std.testing.expect(
        std.mem.indexOf(u8, response, "HTTP/1.1 200 Ok") != null,
    );
    try std.testing.expect(std.mem.endsWith(u8, response, "ok"));
}

test "zix http1: epoll, drains a body larger than the receive buffer" {
    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head_module.setDateHeader(false);
    defer head_module.setDateHeader(true);

    const head = "POST / HTTP/1.1\r\nContent-Length: 200\r\n" ++
        "Connection: close\r\n\r\n";
    var wire: [512]u8 = undefined;
    @memcpy(wire[0..head.len], head);
    @memset(wire[head.len..][0..200], 'a');
    try testWriteAll(fds[0], wire[0 .. head.len + 200]);

    var buf: [128]u8 = undefined;
    var conn = Conn{ .fd = fds[1], .buf = &buf };

    var body_buf: [1024]u8 = undefined;
    var out_buf: [512]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = testSession(std.testing.allocator, 0);

    const first = serveReadable(
        &conn,
        &body_buf,
        &out_buf,
        &session,
        -1,
        &arena,
        true,
    );
    try std.testing.expectEqual(ConnOutcome.keep_alive, first);
    try std.testing.expect(conn.drain > 0);

    const second = serveDrainThenServe(
        &conn,
        &body_buf,
        &out_buf,
        &session,
        -1,
        &arena,
    );
    try std.testing.expectEqual(ConnOutcome.close, second);
    try std.testing.expectEqual(@as(usize, 0), conn.pending_head_len);

    var out: [512]u8 = undefined;
    const response = testReadAvailable(fds[0], &out);
    try std.testing.expect(
        std.mem.indexOf(u8, response, "HTTP/1.1 200 Ok") != null,
    );
    try std.testing.expect(std.mem.endsWith(u8, response, "ok"));
}

test "zix http1: epoll, Session leaves the request knobs off by default" {
    const session = Session{
        .io = std.testing.io,
        .handler = okHandler,
        .allocator = std.testing.allocator,
    };

    try std.testing.expectEqual(@as(u32, 0), session.handler_timeout_ms);
    try std.testing.expectEqual(@as(usize, 0), session.max_request_body);
    try std.testing.expectEqual(@as(usize, 0), session.large_body_recv_buf);
}

test "zix http1: epoll, connAlloc sizes the buffer from max_recv_buf" {
    const conn = connAlloc(std.testing.allocator, -1, 2048).?;
    defer connFree(std.testing.allocator, conn);

    try std.testing.expectEqual(@as(usize, 2048), conn.buf.len);
}

test "zix http1: epoll, connAlloc fails without memory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });

    try std.testing.expectEqual(
        @as(?*Conn, null),
        connAlloc(failing.allocator(), -1, 2048),
    );
}

test "zix http1: epoll, large body drain applies large_body_recv_buf" {
    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head_module.setDateHeader(false);
    defer head_module.setDateHeader(true);

    const before = try testRecvBufSize(fds[1]);

    const head = "POST / HTTP/1.1\r\nContent-Length: 200\r\n" ++
        "Connection: close\r\n\r\n";
    var wire: [512]u8 = undefined;
    @memcpy(wire[0..head.len], head);
    @memset(wire[head.len..][0..200], 'a');
    try testWriteAll(fds[0], wire[0 .. head.len + 200]);

    var buf: [128]u8 = undefined;
    var conn = Conn{
        .fd = fds[1],
        .buf = &buf,
    };

    var body_buf: [1024]u8 = undefined;
    var out_buf: [512]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var session = testSession(std.testing.allocator, 0);
    session.large_body_recv_buf = 4096;

    _ = serveReadable(
        &conn,
        &body_buf,
        &out_buf,
        &session,
        -1,
        &arena,
        true,
    );

    try std.testing.expect(conn.drain > 0);
    try std.testing.expect(try testRecvBufSize(fds[1]) != before);
}

test "zix http1: epoll, small body leaves SO_RCVBUF untouched" {
    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head_module.setDateHeader(false);
    defer head_module.setDateHeader(true);

    const before = try testRecvBufSize(fds[1]);

    try testWriteAll(
        fds[0],
        "POST / HTTP/1.1\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi",
    );

    var buf: [128]u8 = undefined;
    var conn = Conn{
        .fd = fds[1],
        .buf = &buf,
    };

    var body_buf: [1024]u8 = undefined;
    var out_buf: [512]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var session = testSession(std.testing.allocator, 0);
    session.large_body_recv_buf = 4096;

    _ = serveReadable(
        &conn,
        &body_buf,
        &out_buf,
        &session,
        -1,
        &arena,
        true,
    );

    try std.testing.expectEqual(before, try testRecvBufSize(fds[1]));
}

