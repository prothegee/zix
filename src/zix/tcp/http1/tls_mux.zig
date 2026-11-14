//! ZIX http1 tls mux
//!
//! ### file: src/zix/tcp/http1/tls_mux.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! https/1.1 serve path for .EPOLL and .URING: one SO_REUSEPORT listener and
//! epoll instance per worker, each connection terminates TLS in place.
//!
//! ### note:
//!
//! recv ciphertext, decrypt, feed the request loop, seal the reply, send. Writes
//! never block: on EAGAIN the ciphertext is staged and EPOLLOUT is armed.
//! WebSocket and SSE run in the same loop through the connection stream sink.
//! The connection machinery (ConnTable, onReadable, acceptAll) is public so the
//! dual-listener loop can host TLS connections next to cleartext ones.
//! TLS 1.3 only. The .ASYNC path (tls_serve) also serves TLS 1.2.
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
const tlz = @import("tlz");
const Config = @import("Config.zig");
const handler_mod = @import("handler.zig");
const HandlerFn = handler_mod.HandlerFn;
const head_mod = @import("head.zig");
const header = @import("header.zig");
const log = @import("log.zig");
const parser = @import("parser.zig");
const static = @import("static.zig");
const TlsStreamSink = @import("TlsStreamSink.zig");
const TlsPeers = @import("TlsPeers.zig");
const writer = @import("writer.zig");
const ws_pending = @import("websocket/pending.zig");
const ws_pump = @import("websocket/pump.zig");
const WsFrameFn = @import("websocket/frame_fn.zig").WsFrameFn;
const tls_serve = @import("tls_serve.zig");
const TlsConn = @import("tls_mux/TlsConn.zig");
const WorkerCtx = @import("tls_mux/WorkerCtx.zig");
const tls_conn = @import("../../multiplexers/tls_conn.zig");
const cpu_affinity = @import("../../multiplexers/cpu_affinity.zig");

const linux = std.os.linux;

// --------------------------------------------------------- //
// Private:

const MAX_FD: usize = 1 << 16;
const EPOLL_MAX_EVENTS: usize = 4096;
const EPOLL_WAIT_TIMEOUT_MS: i32 = 1000;

/// Inbound ciphertext read staging (may hold several records per read).
const TLS_READ_STAGING_SIZE: usize = tls_conn.READ_STAGING_SIZE;

/// Decrypted plaintext staging for one read.
const TLS_PLAIN_STAGING_SIZE: usize = 32 * 1024;

/// Sealed staging: every record a full-size response takes.
const TLS_SEALED_OUT_SIZE: usize = tlz.sealedLen(RESPONSE_BUF_SIZE);

/// Data word of the listener in a TLS-only worker. No fd reaches it.
const LISTENER_DATA: u64 = tls_conn.TLS_EVENT_TAG - 1;

const BAD_REQUEST =
    "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const PAYLOAD_TOO_LARGE =
    "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const HEAD_TOO_LARGE =
    "HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
    "Content-Length: 0\r\nConnection: close\r\n\r\n";
const MISDIRECTED =
    "HTTP/1.1 421 Misdirected Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const INTERNAL_ERROR =
    "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

fn freeConn(conn: *TlsConn) void {
    conn.destroy();
}

fn workerCount(workers: usize) usize {
    if (workers != 0) return workers;

    return @max(1, cpu_affinity.availableCpuCount());
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

    var flags: linux.O = @bitCast(@as(u32, @intCast(rc)));
    flags.NONBLOCK = true;
    const bits: u32 = @bitCast(flags);
    const set_rc = linux.fcntl(fd, linux.F.SETFL, @intCast(bits));

    return std.posix.errno(set_rc) == .SUCCESS;
}

fn closeListeners(listeners: []std.Io.net.Server, io: std.Io) void {
    for (listeners) |*listener| listener.deinit(io);
}

/// Seal plaintext into records and send, staging on backpressure.
fn sendPlain(conn: *TlsConn, plaintext: []const u8) bool {
    var sealed: [TLS_SEALED_OUT_SIZE]u8 = undefined;

    return conn.transport.sendPlain(plaintext, &sealed);
}

/// Answer with a status-only response and close once it is flushed.
fn refuse(conn: *TlsConn, answer: []const u8) bool {
    _ = sendPlain(conn, answer);
    conn.transport.wclose = true;

    return true;
}

/// Send close_notify and close once it is flushed.
fn closeNotify(conn: *TlsConn) bool {
    var close_buf: [64]u8 = undefined;
    const slot = TlsPeers.shared.acquire(conn.transport.fd);
    defer if (slot) |held| held.release();

    _ = conn.transport.sendRaw(conn.transport.tls.closeNotify(&close_buf));
    conn.transport.wclose = true;

    return true;
}

/// Stream sink write (SSE events, WebSocket frames, spilled responses). Split
/// so one oversized write never overflows the sealed staging.
fn streamWrite(ctx_ptr: *anyopaque, plaintext: []const u8) bool {
    const transport: *tls_conn.Transport = @ptrCast(@alignCast(ctx_ptr));

    var rest = plaintext;
    while (rest.len > 0) {
        const take = @min(rest.len, RESPONSE_BUF_SIZE);
        var sealed: [TLS_SEALED_OUT_SIZE]u8 = undefined;
        if (!transport.sendPlain(rest[0..take], &sealed)) return false;

        rest = rest[take..];
    }

    return true;
}

/// TLS peer write (registered WebSocket): seal with this connection session and
/// send from whichever thread writes. The caller holds the peer lock.
fn sharedWrite(ctx_ptr: *anyopaque, plaintext: []const u8) bool {
    const conn: *TlsConn = @ptrCast(@alignCast(ctx_ptr));

    var rest = plaintext;
    while (rest.len > 0) {
        const take = @min(rest.len, RESPONSE_BUF_SIZE);
        var sealed: [TLS_SEALED_OUT_SIZE]u8 = undefined;
        const cipher = conn.transport.tls.encrypt(rest[0..take], &sealed);
        if (cipher.len == 0) return false;
        if (!conn.transport.sendShared(cipher)) return false;

        rest = rest[take..];
    }

    return true;
}

/// Make the connection a TLS peer, so a broadcast from any thread reaches it.
///
/// Note:
/// - Best effort: when the registry is full the WebSocket still works, only a
///   write from another thread does not reach it.
fn registerPeer(conn: *TlsConn) void {
    const fd = conn.transport.fd;

    TlsPeers.shared.register(fd, conn.io, conn, sharedWrite) catch |err| switch (err) {
        else => {},
    };
}

/// Parse and dispatch every complete frame buffered on a WebSocket over TLS.
/// Replies leave sealed through the stream sink.
fn pumpFrames(conn: *TlsConn, on_frame: WsFrameFn, payload_buf: []u8, out_buf: []u8) bool {
    if (conn.feed.filled == 0) return true;

    var stream_sink: TlsStreamSink = .{
        .ctx = &conn.transport,
        .writeFn = streamWrite,
        .fd = conn.transport.fd,
    };
    writer.tl_tls_stream = &stream_sink;
    defer writer.tl_tls_stream = null;

    const filled = conn.feed.filled;
    const result = ws_pump.pump(
        conn.transport.fd,
        conn.rbuf[0..filled],
        payload_buf,
        out_buf,
        on_frame,
    );

    if (result.consumed >= filled) {
        conn.feed.filled = 0;
    } else if (result.consumed > 0) {
        const rest = conn.rbuf[result.consumed..filled];
        std.mem.copyForwards(u8, conn.rbuf[0..rest.len], rest);
        conn.feed.filled = rest.len;
    }

    if (result.close or stream_sink.failed) return closeNotify(conn);

    // A frame wider than the whole buffer can never complete.
    if (conn.feed.filled >= conn.rbuf.len) return false;

    return true;
}

/// Append decrypted frame bytes and pump the frames.
fn feedFrames(
    conn: *TlsConn,
    on_frame: WsFrameFn,
    plaintext: []const u8,
    payload_buf: []u8,
    out_buf: []u8,
) bool {
    // A frame that can never fit the buffer can never complete.
    if (plaintext.len > conn.rbuf.len - conn.feed.filled) return false;

    @memcpy(conn.rbuf[conn.feed.filled..][0..plaintext.len], plaintext);
    conn.feed.filled += plaintext.len;

    return pumpFrames(conn, on_frame, payload_buf, out_buf);
}

/// Dispatch every complete request in rbuf. Pipelined requests leave in one pass.
///
/// Return:
/// - bool (false when the connection must close now, true when it stays or flushes)
fn serveBuffered(conn: *TlsConn, payload_buf: []u8, out_buf: []u8) bool {
    var stream_sink: TlsStreamSink = .{
        .ctx = &conn.transport,
        .writeFn = streamWrite,
        .fd = conn.transport.fd,
    };
    writer.tl_tls_stream = &stream_sink;
    defer writer.tl_tls_stream = null;

    var response_buf: [RESPONSE_BUF_SIZE]u8 = undefined;

    while (conn.feed.filled > 0) {
        const buffered = conn.rbuf[0..conn.feed.filled];
        const parsed = parser.parseHead(buffered) catch |err| switch (err) {
            error.ZixHttp1_Parser_IncompleteHeader => return true,
            error.ZixHttp1_Parser_InvalidRequest,
            error.ZixHttp1_Parser_UnknownMethod,
            => {
                conn.transport.wclose = true;

                return true;
            },
        };
        const head = parsed.head;

        const step = conn.feed.classify(
            parsed.body_offset,
            @intCast(head.content_length),
            conn.rbuf.len,
            conn.max_request_body,
        );
        const serve = switch (step) {
            .SERVE => |decided| decided,
            .WAIT => return true,
            .REFUSE_BODY => return refuse(conn, PAYLOAD_TOO_LARGE),
            .REFUSE_HEAD => return refuse(conn, HEAD_TOO_LARGE),
        };

        const body = conn.rbuf[parsed.body_offset..][0..serve.body_len];
        if (serve.received > 0) {
            handler_mod.tl_body_info = .{
                .received = serve.received,
                .complete = true,
            };
        }

        // RFC 9110 7.4: a Host this certificate does not cover is misdirected.
        if (tls_serve.hostFromHead(conn.rbuf[0..parsed.body_offset])) |host_raw| {
            const host = tls_serve.stripPort(host_raw);
            tlz.verifyCertIdentity(conn.ctx.cert_der, host) catch |err| switch (err) {
                else => return refuse(conn, MISDIRECTED),
            };
        }

        stream_sink.wrote = false;
        const result = tls_serve.runHandlerToBuffer(
            conn.handler,
            &head,
            body,
            conn.transport.fd,
            &response_buf,
            conn.io,
            &stream_sink,
        ) catch |err| switch (err) {
            else => {
                // A failed upgrade leaves a handoff nothing will run.
                _ = ws_pending.take();

                // Nothing reached the wire yet, so it can still carry a status.
                if (!stream_sink.wrote) _ = sendPlain(conn, INTERNAL_ERROR);
                conn.transport.wclose = true;

                return true;
            },
        };

        if (stream_sink.failed) return false;
        if (!result.streamed and result.bytes.len > 0 and !sendPlain(conn, result.bytes)) {
            return false;
        }

        conn.feed.consume(&conn.rbuf, serve.request_len);

        // WebSocket handoff: rbuf holds frames from now on. The first frame may
        // have been pipelined with the handshake.
        if (ws_pending.take()) |pending| {
            conn.ws = pending.on_frame;
            registerPeer(conn);

            return pumpFrames(conn, pending.on_frame, payload_buf, out_buf);
        }

        if (!head.keep_alive) return closeNotify(conn);
    }

    return true;
}

/// Accumulate decrypted plaintext and dispatch every complete request.
///
/// Note:
/// - A body larger than rbuf is never buffered: the head is parked and the body
///   is counted off the wire. rbuf bounds the head, not the upload.
/// - A chunk can be larger than rbuf, so this takes what fits, serves, and
///   comes back for the rest.
///
/// Return:
/// - bool (false when the connection must close now, true when it stays or flushes)
fn feedRequests(conn: *TlsConn, plaintext: []const u8, payload_buf: []u8, out_buf: []u8) bool {
    var rest = plaintext;

    while (true) {
        if (conn.feed.drain > 0) {
            rest = conn.feed.takeDrain(rest);
            if (conn.feed.drain > 0) return true;

            conn.feed.releaseParked();
        } else {
            if (rest.len == 0) return true;

            // rbuf is full with no whole head in it: the head alone is too large.
            if (conn.feed.headOverflowed(conn.rbuf.len)) return refuse(conn, HEAD_TOO_LARGE);

            rest = conn.feed.fill(&conn.rbuf, rest);
        }

        if (!serveBuffered(conn, payload_buf, out_buf)) return false;
        if (conn.transport.wclose) return true;

        // Just upgraded: the rest of this plaintext is frames.
        if (conn.ws) |on_frame| {
            if (rest.len == 0) return true;

            return feedFrames(conn, on_frame, rest, payload_buf, out_buf);
        }
    }
}

fn workerMain(ctx: WorkerCtx) void {
    var worker = ctx;
    const config = worker.config;
    const io = config.io;
    defer worker.listener.deinit(io);

    // Pinned like the cleartext loop, so a handshake storm does not thrash threads.
    cpu_affinity.pinToCpu(worker.worker_id);

    handler_mod.setAccessLogger(config.logger);
    head_mod.setDateHeader(config.send_date_header);
    header.setMaxResponseHeaders(config.max_response_headers.value());
    static.setStatic(config.public_dir, io);

    const listener_fd = worker.listener.socket.handle;
    if (!setNonBlock(listener_fd)) return worker.failSetup();

    const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (std.posix.errno(epfd_rc) != .SUCCESS) return worker.failSetup();

    const epfd: std.posix.fd_t = @intCast(epfd_rc);
    defer _ = linux.close(epfd);

    var listener_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .u64 = LISTENER_DATA },
    };
    const add_rc = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listener_fd, &listener_event);
    if (std.posix.errno(add_rc) != .SUCCESS) return worker.failSetup();

    var table = ConnTable.init() catch |err| switch (err) {
        error.ZixMultiplexers_ConnTable_OutOfMemory,
        error.ZixMultiplexers_ConnTable_MapFailed,
        => return worker.failSetup(),
    };
    defer table.deinit();

    const allocator = std.heap.smp_allocator;
    const payload_buf = allocator.alloc(u8, config.wsRecvBufSize()) catch |err| switch (err) {
        error.OutOfMemory => return worker.failSetup(),
    };
    defer allocator.free(payload_buf);

    const out_buf = allocator.alloc(u8, RESPONSE_BUF_SIZE) catch |err| switch (err) {
        error.OutOfMemory => return worker.failSetup(),
    };
    defer allocator.free(out_buf);

    var events: [EPOLL_MAX_EVENTS]linux.epoll_event = undefined;
    while (!worker.stop.load(.acquire)) {
        const wait_rc = linux.epoll_wait(epfd, &events, EPOLL_MAX_EVENTS, EPOLL_WAIT_TIMEOUT_MS);
        switch (std.posix.errno(wait_rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return worker.failSetup(),
        }

        const event_count: usize = @intCast(wait_rc);
        for (events[0..event_count]) |event| {
            if (event.data.u64 == LISTENER_DATA) {
                acceptAll(&table, epfd, listener_fd, .{
                    .io = io,
                    .handler = worker.handler,
                    .ctx = worker.ctx,
                    .max_request_body = config.max_request_body,
                    .ev_tag = 0,
                });
                continue;
            }

            const fd: std.posix.fd_t = @intCast(event.data.u64);
            const conn = table.get(fd) orelse continue;

            if (!onEvent(conn, epfd, event.events, payload_buf, out_buf)) {
                _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, fd, null);
                table.drop(fd);
                _ = linux.close(fd);
            }
        }
    }
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 TLS mux error
pub const Error = error {
    ZixHttp1_TlsMux_Unsupported,
    ZixHttp1_TlsMux_ResolveFailed,
    ZixHttp1_TlsMux_ListenFailed,
    ZixHttp1_TlsMux_OutOfMemory,
    ZixHttp1_TlsMux_SpawnFailed,
    ZixHttp1_TlsMux_SetupFailed,
};

/// Handler response staging. Not a ceiling: a larger response spills through
/// the connection stream sink while it renders.
pub const RESPONSE_BUF_SIZE: usize = 64 * 1024;

/// Per-worker fd to TlsConn map.
pub const ConnTable = tls_conn.ConnTable(TlsConn, MAX_FD, freeConn);

/// What every connection accepted on a TLS listener is given.
pub const AcceptOpts = @import("tls_mux/AcceptOpts.zig");

/// What a peer gets when it hangs up part way through a request.
///
/// Note:
/// - A request that never finished arriving is answered 400, because a bare
///   close reads the same as a crash.
/// - Between requests, or on a WebSocket, the peer is answered nothing.
///
/// Return:
/// - bool (true when the connection must stay to flush the answer)
pub fn hangupAnswer(conn: *TlsConn) bool {
    if (conn.ws != null) return false;
    if (!conn.feed.inFlight()) return false;

    _ = sendPlain(conn, BAD_REQUEST);
    conn.transport.wclose = true;

    return conn.transport.want_out;
}

/// Feed one received ciphertext chunk through the session and the request loop
/// (or the frame pump). The recv-model-agnostic core: epoll calls it from its
/// read loop, io_uring per recv completion.
///
/// Return:
/// - bool (false when the connection must close now. wclose with staged bytes
///   means flush, then close)
pub fn onCiphertext(conn: *TlsConn, cipher: []const u8, payload_buf: []u8, out_buf: []u8) bool {
    var to_send: [TLS_SEALED_OUT_SIZE]u8 = undefined;
    var plain_in: [TLS_PLAIN_STAGING_SIZE]u8 = undefined;

    const fed = conn.transport.tls.feed(cipher, &to_send, &plain_in);

    if (fed.to_send.len > 0 and !conn.transport.sendRaw(fed.to_send)) return false;

    if (fed.outcome == .CLOSE) {
        // Kept only to flush a final alert.
        conn.transport.wclose = true;

        return true;
    }

    if (fed.plaintext.len == 0) return true;

    if (conn.ws) |on_frame| {
        return feedFrames(conn, on_frame, fed.plaintext, payload_buf, out_buf);
    }

    return feedRequests(conn, fed.plaintext, payload_buf, out_buf);
}

/// Handle a readable connection: read what the session can take, feed it.
///
/// Note:
/// - The read is sized by readRoom, not by the staging buffer. A busy socket
///   would otherwise hand the session two records at once, which it refuses.
///
/// Return:
/// - bool (false when the connection must close)
pub fn onReadable(conn: *TlsConn, payload_buf: []u8, out_buf: []u8) bool {
    var cipher: [TLS_READ_STAGING_SIZE]u8 = undefined;

    while (true) {
        const room = conn.transport.tls.readRoom();
        if (room == 0) return false;

        const rc = linux.read(conn.transport.fd, &cipher, @min(cipher.len, room));
        switch (std.posix.errno(rc)) {
            .SUCCESS => if (rc == 0) return hangupAnswer(conn),
            .INTR => continue,
            .AGAIN => return true,
            else => return false,
        }

        if (!onCiphertext(conn, cipher[0..rc], payload_buf, out_buf)) return false;
        if (conn.transport.wclose) return conn.transport.want_out;
    }
}

/// Handle one epoll event on a TLS connection: flush, read, re-arm.
///
/// Return:
/// - bool (false when the connection must close)
pub fn onEvent(
    conn: *TlsConn,
    epfd: std.posix.fd_t,
    events: u32,
    payload_buf: []u8,
    out_buf: []u8,
) bool {
    if ((events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0) return false;

    var keep = true;
    const transport = &conn.transport;

    // A TLS peer may stage bytes from another thread: flush and re-arm under its lock.
    if ((events & linux.EPOLL.OUT) != 0) {
        const slot = TlsPeers.shared.acquire(transport.fd);
        defer if (slot) |held| held.release();

        keep = transport.onWritable(epfd);
    }

    if (keep and (events & linux.EPOLL.IN) != 0) keep = onReadable(conn, payload_buf, out_buf);

    const slot = TlsPeers.shared.acquire(transport.fd);
    defer if (slot) |held| held.release();

    if (keep and transport.want_out) {
        tls_conn.armOut(epfd, transport.fd, transport.ep_data, true);
    }
    if (keep and transport.wclose and !transport.want_out) keep = false;

    return keep;
}

/// Accept every pending TLS connection and register each in epfd with
/// ev_tag | fd as the event data.
pub fn acceptAll(
    table: *ConnTable,
    epfd: std.posix.fd_t,
    listener_fd: std.posix.fd_t,
    opts: AcceptOpts,
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

        if (rc >= table.slots.len) {
            _ = linux.close(fd);
            continue;
        }

        const conn = TlsConn.create(
            opts.io,
            fd,
            opts.handler,
            opts.ctx,
            opts.max_request_body,
        ) orelse {
            _ = linux.close(fd);
            continue;
        };
        conn.transport.ep_data = opts.ev_tag | rc;
        table.put(fd, conn);

        var event = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
            .data = .{ .u64 = conn.transport.ep_data },
        };
        const add_rc = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &event);
        if (std.posix.errno(add_rc) != .SUCCESS) {
            table.drop(fd);
            _ = linux.close(fd);
        }
    }
}

/// Listen and serve https/1.1 over TLS, one epoll worker per core, or per
/// config.workers when non-zero.
///
/// Param:
/// config - Config (listen address, knobs)
/// handler_fn - HandlerFn
/// ctx - *const tlz.Context (borrowed, must outlive the server)
///
/// Return:
/// - void once every worker stopped
/// - Error.ZixHttp1_TlsMux_ResolveFailed or ListenFailed when a bind fails
/// - Error.ZixHttp1_TlsMux_SetupFailed when a worker could not set up
pub fn run(config: Config, handler_fn: HandlerFn, ctx: *const tlz.Context) Error!void {
    if (comptime builtin.target.os.tag != .linux) return Error.ZixHttp1_TlsMux_Unsupported;

    const io = config.io;
    const allocator = std.heap.smp_allocator;
    const workers = workerCount(config.workers);

    const address = std.Io.net.IpAddress.resolve(io, config.ip, config.port) catch |err| {
        switch (err) {
            else => return Error.ZixHttp1_TlsMux_ResolveFailed,
        }
    };

    const listeners = allocator.alloc(std.Io.net.Server, workers) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp1_TlsMux_OutOfMemory,
    };
    defer allocator.free(listeners);

    var bound: usize = 0;
    while (bound < workers) : (bound += 1) {
        listeners[bound] = address.listen(io, .{
            .mode = .stream,
            .reuse_address = true,
            .kernel_backlog = config.kernel_backlog,
        }) catch |err| switch (err) {
            else => {
                closeListeners(listeners[0..bound], io);

                return Error.ZixHttp1_TlsMux_ListenFailed;
            },
        };
    }

    const threads = allocator.alloc(std.Thread, workers) catch |err| switch (err) {
        error.OutOfMemory => {
            closeListeners(listeners, io);

            return Error.ZixHttp1_TlsMux_OutOfMemory;
        },
    };
    defer allocator.free(threads);

    var stop = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);

    var spawned: usize = 0;
    while (spawned < workers) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, workerMain, .{WorkerCtx{
            .config = config,
            .handler = handler_fn,
            .ctx = ctx,
            .listener = listeners[spawned],
            .worker_id = spawned,
            .stop = &stop,
            .failed = &failed,
        }}) catch |err| switch (err) {
            else => {
                stop.store(true, .release);
                closeListeners(listeners[spawned..], io);
                for (threads[0..spawned]) |thread| thread.join();

                return Error.ZixHttp1_TlsMux_SpawnFailed;
            },
        };
    }

    log.logSystem(config, .INFO, "listening on {s}:{d} (https/1.1 TLS, epoll-mux/{d})", .{
        config.ip,
        config.port,
        workers,
    });

    for (threads) |thread| thread.join();

    if (failed.load(.acquire)) return Error.ZixHttp1_TlsMux_SetupFailed;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");
const websocket = @import("websocket.zig");

const CERT_PATH = "examples/certs/ecdsa_p256_cert.pem";
const KEY_PATH = "examples/certs/ecdsa_p256_key.pem";
const CONTENT_HANDSHAKE: u8 = @intFromEnum(tlz.ContentType.HANDSHAKE);

fn okHandler(
    _: *@import("Request.zig"),
    res: *@import("Response.zig"),
    _: *@import("Context.zig"),
) anyerror!void {
    try res.sendRaw("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
}

fn wsEchoFrame(fd: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    websocket.sendFD(fd, @enumFromInt(opcode), payload) catch |err| switch (err) {
        // The pump closes a connection whose reply did not land.
        else => {},
    };
}

fn wsUpgradeHandler(
    req: *@import("Request.zig"),
    res: *@import("Response.zig"),
    _: *@import("Context.zig"),
) anyerror!void {
    const key = req.header("sec-websocket-key") orelse {
        try res.sendRaw("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");

        return;
    };

    try websocket.serve(req.fd, key, wsEchoFrame);
}

fn sseHandler(
    req: *@import("Request.zig"),
    _: *@import("Response.zig"),
    _: *@import("Context.zig"),
) anyerror!void {
    writer.beginStream();
    try writer.writeAllFD(req.fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n");
    try writer.writeAllFD(req.fd, "data: one\n\n");
}

fn testWriteAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (std.posix.errno(rc) != .SUCCESS) return error.ZixTest_WriteFailed;

        off += rc;
    }
}

/// Read one whole record from a blocking fd.
fn readRecordFd(fd: std.posix.fd_t, buf: []u8) ![]const u8 {
    var got: usize = 0;
    var total: usize = 5;
    while (got < total) {
        const rc = linux.read(fd, buf[got..].ptr, total - got);
        if (std.posix.errno(rc) != .SUCCESS) return error.ZixTest_ReadFailed;
        if (rc == 0) return error.ZixTest_Closed;

        got += rc;
        if (got == 5) total = 5 + @as(usize, std.mem.readInt(u16, buf[3..5], .big));
    }

    return buf[0..total];
}

/// A served TlsConn with an established client session over a socketpair.
const TestSession = struct {
    conn: TlsConn,
    client_fd: std.posix.fd_t,
    server_fd: std.posix.fd_t,
    finished: tlz.Client.FinishResult,
    payload_buf: [16 * 1024]u8 = undefined,
    out_buf: [RESPONSE_BUF_SIZE]u8 = undefined,

    fn deinit(self: *TestSession) void {
        TlsPeers.shared.unregister(self.server_fd);
        self.conn.transport.deinit();
        _ = linux.close(self.client_fd);
        _ = linux.close(self.server_fd);
    }

    fn readable(self: *TestSession) bool {
        return onReadable(&self.conn, &self.payload_buf, &self.out_buf);
    }

    fn send(self: *TestSession, plaintext: []const u8) !void {
        var enc: [4096]u8 = undefined;

        try testWriteAll(self.client_fd, self.finished.connection.writeAppData(plaintext, &enc));
    }

    fn recv(self: *TestSession, plain: []u8) ![]const u8 {
        var rec_buf: [4096]u8 = undefined;
        const rec = try readRecordFd(self.client_fd, &rec_buf);

        return self.finished.connection.readAppData(rec, plain);
    }
};

fn startSession(
    self: *TestSession,
    handler_fn: HandlerFn,
    ctx: *const tlz.Context,
    max_request_body: usize,
) !void {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    try std.testing.expect(setNonBlock(fds[1]));

    self.* = .{
        .conn = .{
            .transport = tls_conn.Transport.init(std.testing.io, fds[1], ctx),
            .handler = handler_fn,
            .ctx = ctx,
            .io = std.testing.io,
            .max_request_body = max_request_body,
        },
        .client_fd = fds[0],
        .server_fd = fds[1],
        .finished = undefined,
    };

    var hello_buf: [512]u8 = undefined;
    const started = try tlz.Client.start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
    }, &hello_buf);
    var state = started.state;

    var hello_rec: [600]u8 = undefined;
    hello_rec[0] = CONTENT_HANDSHAKE;
    std.mem.writeInt(u16, hello_rec[1..3], 0x0303, .big);
    std.mem.writeInt(u16, hello_rec[3..5], @intCast(started.client_hello.len), .big);
    @memcpy(hello_rec[5..][0..started.client_hello.len], started.client_hello);
    try testWriteAll(self.client_fd, hello_rec[0 .. 5 + started.client_hello.len]);

    try std.testing.expect(self.readable());

    var flight_buf: [4096]u8 = undefined;
    var flight_len: usize = 0;
    for (0..3) |_| {
        const rec = try readRecordFd(self.client_fd, flight_buf[flight_len..]);
        flight_len += rec.len;
    }

    var fin_buf: [256]u8 = undefined;
    self.finished = try tlz.Client.finish(&state, flight_buf[0..flight_len], &fin_buf);
    try testWriteAll(self.client_fd, self.finished.client_finished);
}

fn testContext() !tlz.Context {
    return tlz.Context.init(std.testing.allocator, std.testing.io, .{
        .cert_path = CERT_PATH,
        .key_path = KEY_PATH,
    });
}

test "zix http1: tls_mux, keep-alive serves many requests on one session" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session: TestSession = undefined;
    try startSession(&session, okHandler, &ctx, 0);
    defer session.deinit();

    const requests = [_][]const u8{
        "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "GET /b HTTP/1.1\r\nHost: localhost\r\n\r\n",
    };
    for (requests) |request| {
        try session.send(request);

        try std.testing.expect(session.readable());
        try std.testing.expect(!session.conn.transport.wclose);

        var plain: [1024]u8 = undefined;
        const response = try session.recv(&plain);
        try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
    }
}

test "zix http1: tls_mux, Connection: close answers then signals close" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session: TestSession = undefined;
    try startSession(&session, okHandler, &ctx, 0);
    defer session.deinit();

    try session.send("GET /c HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

    try std.testing.expect(!session.readable());
    try std.testing.expect(session.conn.transport.wclose);

    var plain: [1024]u8 = undefined;
    const response = try session.recv(&plain);
    try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
}

test "zix http1: tls_mux, WebSocket handoff echoes frames sealed" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session: TestSession = undefined;
    try startSession(&session, wsUpgradeHandler, &ctx, 0);
    defer session.deinit();

    try session.send(
        "GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n" ++
            "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
    );

    try std.testing.expect(session.readable());
    try std.testing.expect(session.conn.ws != null);

    var plain: [1024]u8 = undefined;
    const upgrade = try session.recv(&plain);
    try std.testing.expect(std.mem.indexOf(u8, upgrade, "101 Switching Protocols") != null);

    const frame = [_]u8{ 0x81, 0x82, 0x01, 0x02, 0x03, 0x04, 'h' ^ 0x01, 'i' ^ 0x02 };
    try session.send(&frame);

    try std.testing.expect(session.readable());
    try std.testing.expect(!session.conn.transport.wclose);

    var echo_plain: [1024]u8 = undefined;
    const echo = try session.recv(&echo_plain);
    var scratch: [128]u8 = undefined;
    const parsed = (try websocket.parseFrame(echo, &scratch)).?;

    try std.testing.expectEqualStrings("hi", parsed.frame.payload);
}

test "zix http1: tls_mux, SSE streams records and keeps the connection" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session: TestSession = undefined;
    try startSession(&session, sseHandler, &ctx, 0);
    defer session.deinit();

    try session.send("GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n");

    try std.testing.expect(session.readable());
    try std.testing.expect(!session.conn.transport.wclose);

    var plain_a: [1024]u8 = undefined;
    const headers = try session.recv(&plain_a);
    try std.testing.expect(std.mem.indexOf(u8, headers, "text/event-stream") != null);

    var plain_b: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("data: one\n\n", try session.recv(&plain_b));
}

test "zix http1: tls_mux, a declared body past the limit gets 413" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session: TestSession = undefined;
    try startSession(&session, okHandler, &ctx, 8);
    defer session.deinit();

    try session.send("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 64\r\n\r\n");

    _ = session.readable();
    try std.testing.expect(session.conn.transport.wclose);

    var plain: [1024]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try session.recv(&plain), "HTTP/1.1 413"));
}

test "zix http1: tls_mux, a Host outside the certificate gets 421" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session: TestSession = undefined;
    try startSession(&session, okHandler, &ctx, 0);
    defer session.deinit();

    try session.send("GET / HTTP/1.1\r\nHost: other.example\r\n\r\n");

    _ = session.readable();

    var plain: [1024]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try session.recv(&plain), "HTTP/1.1 421"));
}

test "zix http1: tls_mux, a hangup mid-request gets 400" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session: TestSession = undefined;
    try startSession(&session, okHandler, &ctx, 0);
    defer session.deinit();

    try session.send("GET / HTTP/1.1\r\nHost: local");
    _ = linux.shutdown(session.client_fd, linux.SHUT.WR);

    _ = session.readable();

    var plain: [1024]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try session.recv(&plain), "HTTP/1.1 400"));
}

test "zix http1: tls_mux, a hangup between requests answers nothing" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session: TestSession = undefined;
    try startSession(&session, okHandler, &ctx, 0);
    defer session.deinit();

    try std.testing.expect(session.readable());
    try std.testing.expect(!hangupAnswer(&session.conn));
    try std.testing.expect(!session.conn.transport.wclose);
}

test "zix http1: tls_mux, onEvent closes on HUP" {
    var conn: TlsConn = undefined;

    try std.testing.expect(!onEvent(&conn, -1, linux.EPOLL.HUP, &.{}, &.{}));
}

test "zix http1: tls_mux, workerCount honors an explicit count" {
    try std.testing.expectEqual(@as(usize, 3), workerCount(3));
    try std.testing.expect(workerCount(0) >= 1);
}

