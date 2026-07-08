//! zix http1 https serve path, event-driven (https/1.1 over TLS 1.3, RFC 8446 + 9112).
//!
//! What:
//! - One SO_REUSEPORT listener + epoll instance per worker, like the cleartext .EPOLL model, but each
//!   connection terminates TLS in place via the shared transport (multiplexers/tls_conn.zig), no thread
//!   per connection. recv ciphertext -> transport decrypts -> the plaintext feeds the http1 request
//!   loop -> the handler's response is encrypted back into TLS records -> sent. A worker multiplexes
//!   thousands of TLS connections, so high concurrency no longer spawns thousands of blocking threads
//!   (the thread-per-connection TLS path in tls_serve.zig serializes connections and starves the rest).
//! - Keep-alive (RFC 9112 9.3): a connection serves requests in a loop over the established session, so
//!   the handshake is paid once per connection, not once per request. The loop ends on Connection:
//!   close, a client close_notify, or a hangup.
//! - Writes are non-blocking: on EAGAIN the unsent ciphertext is staged per connection and EPOLLOUT is
//!   armed, so a slow client never parks the worker.
//! - WebSocket and SSE are hosted in the loop: a WebSocket.serve handoff switches the connection to
//!   the frame pump (echo frames encrypt per pass), and a beginStream handler streams each write as
//!   TLS records through the per-connection stream sink. Both stage on backpressure like any response.
//! - The connection machinery (TlsConn, ConnTable, onReadable, acceptAll) is pub: the dual-listener
//!   .EPOLL loop (dispatch/epoll.zig, config.tls_port) hosts the same connections in the cleartext
//!   worker instead of a second fleet.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const core = @import("core.zig");
const Config = @import("config.zig").Http1ServerConfig;
const common = @import("dispatch/common.zig");
const tls_serve = @import("tls_serve.zig");
const ws = @import("websocket.zig");
const Tls = @import("../../tls/Tls.zig");
const tls_conn = @import("../../multiplexers/tls_conn.zig");

const HandlerFn = core.HandlerFn;
const MAX_FD = common.MAX_FD;
const EPOLL_MAX_EVENTS: usize = 4096;
const allocator = std.heap.smp_allocator;

/// Inbound ciphertext read staging (may hold several records per read).
const TLS_READ_STAGING_SIZE: usize = tls_conn.read_staging_size;

/// Decrypted plaintext staging for one read (matches the read staging so a full read fits).
const TLS_PLAIN_STAGING_SIZE: usize = 32 * 1024;

/// One sealed response record staging: response plaintext plus AEAD and framing overhead.
const TLS_SEALED_OUT_SIZE: usize = 70 * 1024;

/// Per-connection request accumulator: the effective max request size over TLS (matches tls_serve).
const REQUEST_BUF_SIZE: usize = 17 * 1024;

/// Handler response staging: the effective max response size over TLS (matches tls_serve).
pub const RESPONSE_BUF_SIZE: usize = 64 * 1024;

/// One TLS connection: the shared byte transport (session + outbound backpressure buffer) plus the
/// http1 payload (request accumulator, WebSocket mode). One worker owns a connection for its whole
/// lifetime (shared-nothing).
pub const TlsConn = struct {
    transport: tls_conn.Transport,
    handler: HandlerFn,
    ctx: *const Tls.Context,

    // Set once the handler hands the connection to the engine (WebSocket.serve): from then on the
    // decrypted bytes are frames, pumped instead of parsed as HTTP.
    ws: ?core.WsFrameFn = null,

    // Partial request bytes across reads (and pipelined requests): the live bytes are rbuf[0..rlen].
    rbuf: [REQUEST_BUF_SIZE]u8 = undefined,
    rlen: usize = 0,
};

/// Per-worker fd -> TlsConn map (shared-nothing, one worker owns a connection for its lifetime).
pub const ConnTable = tls_conn.ConnTable(TlsConn, MAX_FD, freeConn);

fn freeConn(conn: *TlsConn) void {
    conn.transport.deinit();
    allocator.destroy(conn);
}

/// Encrypt response plaintext into TLS records and send (staging on backpressure).
fn sendPlain(conn: *TlsConn, plaintext: []const u8) bool {
    var sealed: [TLS_SEALED_OUT_SIZE]u8 = undefined;

    return conn.transport.sendPlain(plaintext, &sealed);
}

/// Stream-sink write (SSE events, WebSocket frames): seal the plaintext into records and send
/// through the transport, staging on backpressure. Chunked, so one oversized write (a large frame
/// written straight through the frame sink) never overflows the sealed staging buffer.
fn streamWrite(ctx_ptr: *anyopaque, plaintext: []const u8) bool {
    const transport: *tls_conn.Transport = @ptrCast(@alignCast(ctx_ptr));

    var rest = plaintext;
    while (rest.len > 0) {
        const n = @min(rest.len, RESPONSE_BUF_SIZE);
        var sealed: [TLS_SEALED_OUT_SIZE]u8 = undefined;
        if (!transport.sendPlain(rest[0..n], &sealed)) return false;
        rest = rest[n..];
    }

    return true;
}

/// Handle a readable TLS connection: decrypt available records, drive the handshake, then feed the
/// plaintext to the http1 request loop (or the WebSocket frame pump) and seal the replies. Returns
/// false when the connection must close. payload_buf / out_buf are per-worker scratch for the frame
/// pump (frame payloads, coalesced echo frames).
pub fn onReadable(conn: *TlsConn, payload_buf: []u8, out_buf: []u8) bool {
    var cipher: [TLS_READ_STAGING_SIZE]u8 = undefined;

    while (true) {
        const rc = linux.read(conn.transport.fd, &cipher, cipher.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false; // peer closed
            },
            .INTR => continue,
            .AGAIN => return true, // drained
            else => return false,
        }

        if (!onCiphertext(conn, cipher[0..@intCast(rc)], payload_buf, out_buf)) return false;
        if (conn.transport.wclose) return conn.transport.want_out; // flush, then close
    }
}

/// Feed one received ciphertext chunk through the session and the request loop (or the WebSocket
/// frame pump). The recv-model-agnostic core of onReadable: the .EPOLL paths call it under their
/// own read loop, the .URING path calls it per recv completion. Returns false when the connection
/// must close now. transport.wclose set with staged bytes means flush, then close.
pub fn onCiphertext(conn: *TlsConn, cipher: []const u8, payload_buf: []u8, out_buf: []u8) bool {
    var to_send: [TLS_SEALED_OUT_SIZE]u8 = undefined;
    var plain_in: [TLS_PLAIN_STAGING_SIZE]u8 = undefined;

    const r = conn.transport.tls.feed(cipher, &to_send, &plain_in);

    if (r.to_send.len > 0 and !conn.transport.sendRaw(r.to_send)) return false;

    if (r.outcome == .close) {
        conn.transport.wclose = true; // keep the conn only to flush a final alert
        return true;
    }

    if (r.plaintext.len > 0) {
        if (conn.ws) |on_frame| {
            if (!feedFrames(conn, on_frame, r.plaintext, payload_buf, out_buf)) return false;
        } else {
            if (!feedRequests(conn, r.plaintext, payload_buf, out_buf)) return false;
        }
    }

    return true;
}

/// Accumulate decrypted plaintext and dispatch every complete request now buffered. Pipelined requests
/// drain in one pass. Returns false when the connection must close (request too large, bad request, or
/// a fatal write); sets transport.wclose when the client asked to close after the response.
fn feedRequests(conn: *TlsConn, plaintext: []const u8, payload_buf: []u8, out_buf: []u8) bool {
    // overflow guard: a single request larger than the buffer is rejected (matches tls_serve's cap).
    if (plaintext.len > conn.rbuf.len - conn.rlen) {
        conn.transport.wclose = true;
        return true;
    }

    @memcpy(conn.rbuf[conn.rlen..][0..plaintext.len], plaintext);
    conn.rlen += plaintext.len;

    // The per-connection stream sink (ADR-054): a handler that calls beginStream (SSE) or
    // WebSocket.serveTls detaches the buffered capture, and every subsequent write seals records
    // through the transport, staging on backpressure instead of parking the worker.
    var stream_sink = core.TlsStreamSink{ .ctx = &conn.transport, .writeFn = streamWrite };
    core.tl_tls_stream = &stream_sink;
    defer core.tl_tls_stream = null;

    var response_buf: [RESPONSE_BUF_SIZE]u8 = undefined;

    while (conn.rlen > 0) {
        const parsed = core.parseHead(conn.rbuf[0..conn.rlen]) catch |err| {
            if (err == error.IncompleteHeader) return true; // wait for the rest of the head

            conn.transport.wclose = true; // malformed request: close
            return true;
        };
        const total = parsed.body_offset + parsed.head.content_length;
        if (conn.rlen < total) return true; // wait for the full body

        const head = parsed.head;
        const body = conn.rbuf[parsed.body_offset..total];

        // RFC 9110 7.4: a request for an authority this cert does not serve is a misdirected request.
        // Match the Host (port stripped) against the cert SAN, respond 421 + close on a mismatch.
        if (tls_serve.hostFromHead(conn.rbuf[0..parsed.body_offset])) |host_raw| {
            const host = tls_serve.stripPort(host_raw);
            Tls.verifyCertIdentity(conn.ctx.cert_der, host) catch {
                const misdirected = "HTTP/1.1 421 Misdirected Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                _ = sendPlain(conn, misdirected);
                conn.transport.wclose = true;
                return true;
            };
        }

        const result = tls_serve.runHandlerToBuffer(conn.handler, &head, body, &response_buf) catch {
            _ = core.takeWebSocket(); // failed upgrade or oversized response: drop any handoff
            conn.transport.wclose = true;
            return true;
        };

        // A streamed response (beginStream / serveTls) already left through the stream sink.
        if (stream_sink.failed) return false;
        if (!result.streamed and !sendPlain(conn, result.bytes)) return false;

        // consume this request, sliding any pipelined bytes to the front.
        const remaining = conn.rlen - total;
        if (remaining > 0) std.mem.copyForwards(u8, conn.rbuf[0..remaining], conn.rbuf[total..conn.rlen]);
        conn.rlen = remaining;

        // WebSocket handoff (serve or serveTls): from now on rbuf holds frames. The client may have
        // pipelined its first frame with the handshake, so pump what is already buffered.
        if (core.takeWebSocket()) |pending| {
            conn.ws = pending.on_frame;

            return pumpFrames(conn, pending.on_frame, payload_buf, out_buf);
        }

        // honor Connection: close (and the HTTP/1.0 default): close_notify, then end the connection.
        if (!head.keep_alive) {
            var close_buf: [64]u8 = undefined;
            _ = conn.transport.sendRaw(conn.transport.tls.closeNotify(&close_buf));
            conn.transport.wclose = true;
            return true;
        }
    }

    return true;
}

/// Append decrypted plaintext (frame bytes) to the accumulator and pump the frames.
fn feedFrames(conn: *TlsConn, on_frame: core.WsFrameFn, plaintext: []const u8, payload_buf: []u8, out_buf: []u8) bool {
    // A frame that cannot ever fit the accumulator can never complete: close.
    if (plaintext.len > conn.rbuf.len - conn.rlen) return false;

    @memcpy(conn.rbuf[conn.rlen..][0..plaintext.len], plaintext);
    conn.rlen += plaintext.len;

    return pumpFrames(conn, on_frame, payload_buf, out_buf);
}

/// Parse and dispatch every complete frame buffered on an engine-owned WebSocket over TLS. Echo /
/// pong / close frames leave through the stream sink, sealed as records (coalesced per pass by the
/// frame send sink). Mirrors serveEpollWs, with encrypt-on-write.
fn pumpFrames(conn: *TlsConn, on_frame: core.WsFrameFn, payload_buf: []u8, out_buf: []u8) bool {
    if (conn.rlen == 0) return true;

    var stream_sink = core.TlsStreamSink{ .ctx = &conn.transport, .writeFn = streamWrite };
    core.tl_tls_stream = &stream_sink;
    defer core.tl_tls_stream = null;

    const result = ws.pump(conn.transport.fd, conn.rbuf[0..conn.rlen], payload_buf, out_buf, on_frame);

    if (result.consumed >= conn.rlen) {
        conn.rlen = 0;
    } else if (result.consumed > 0) {
        std.mem.copyForwards(u8, conn.rbuf[0 .. conn.rlen - result.consumed], conn.rbuf[result.consumed..conn.rlen]);
        conn.rlen -= result.consumed;
    }

    if (result.close or stream_sink.failed) {
        var close_buf: [64]u8 = undefined;
        _ = conn.transport.sendRaw(conn.transport.tls.closeNotify(&close_buf));
        conn.transport.wclose = true;
        return true;
    }

    // A frame wider than the whole buffer can never complete: close rather than spin.
    if (conn.rlen >= conn.rbuf.len) return false;

    return true;
}

/// Accept every pending TLS connection on listener_fd and register each in epfd with
/// `ev_tag | fd` as the event data. The TLS-only worker passes 0 (plain fd), the dual-listener
/// .EPOLL loop passes tls_conn.tls_event_tag so its one loop can route TLS events.
pub fn acceptAll(table: *ConnTable, epfd: posix.fd_t, listener_fd: posix.fd_t, handler: HandlerFn, ctx: *const Tls.Context, ev_tag: u64) void {
    while (true) {
        const rc = linux.accept4(listener_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return,
            .INTR, .CONNABORTED => continue,
            else => return,
        }

        const fd: posix.fd_t = @intCast(rc);
        common.setNoDelay(fd);

        const idx: usize = @intCast(fd);
        if (idx >= table.slots.len) {
            _ = linux.close(fd);
            continue;
        }

        const conn = allocator.create(TlsConn) catch {
            _ = linux.close(fd);
            continue;
        };
        conn.* = .{
            .transport = tls_conn.Transport.init(fd, ctx),
            .handler = handler,
            .ctx = ctx,
        };
        conn.transport.ep_data = ev_tag | @as(u64, @intCast(fd));
        table.put(fd, conn);

        var ev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.RDHUP, .data = .{ .u64 = conn.transport.ep_data } };
        if (posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &ev)) != .SUCCESS) {
            table.drop(fd);
            _ = linux.close(fd);
        }
    }
}

const WorkerCtx = struct {
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    stack_size: usize,
    worker_id: usize,
    handler: HandlerFn,
    ctx: *const Tls.Context,
    public_dir: []const u8 = "",
};

fn workerRun(worker: WorkerCtx) void {
    // Pin to one core like the cleartext .EPOLL model. Without this, and with the cpuset-aware
    // worker count below, a TLS handshake storm at high concurrency thrashes oversubscribed threads.
    common.pinToCpu(worker.worker_id);

    core.setStatic(worker.public_dir, worker.io);

    const addr = std.Io.net.IpAddress.resolve(worker.io, worker.ip, worker.port) catch return;
    var srv = addr.listen(worker.io, .{ .reuse_address = true, .kernel_backlog = worker.kernel_backlog }) catch return;
    defer srv.deinit(worker.io);
    const listener_fd = srv.socket.handle;
    common.setNonBlock(listener_fd);

    const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (posix.errno(epfd_rc) != .SUCCESS) return;
    const epfd: posix.fd_t = @intCast(epfd_rc);
    defer _ = linux.close(epfd);

    var lev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .u64 = @intCast(listener_fd) } };
    if (posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listener_fd, &lev)) != .SUCCESS) return;

    var table = ConnTable.init() catch return;
    defer table.deinit();

    // Per-worker scratch for the WebSocket frame pump (payloads, coalesced echo frames).
    const payload_buf = allocator.alloc(u8, core.BUF_SIZE) catch return;
    defer allocator.free(payload_buf);

    const out_buf = allocator.alloc(u8, RESPONSE_BUF_SIZE) catch return;
    defer allocator.free(out_buf);

    var events: [EPOLL_MAX_EVENTS]linux.epoll_event = undefined;
    while (true) {
        const wait_rc = linux.epoll_wait(epfd, &events, EPOLL_MAX_EVENTS, -1);
        switch (posix.errno(wait_rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return,
        }

        for (events[0..@intCast(wait_rc)]) |ev| {
            if (ev.data.fd == listener_fd) {
                acceptAll(&table, epfd, listener_fd, worker.handler, worker.ctx, 0);
                continue;
            }

            const conn = table.get(ev.data.fd) orelse continue;
            var keep = true;

            if ((ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0) {
                keep = false;
            } else {
                if ((ev.events & linux.EPOLL.OUT) != 0) keep = conn.transport.onWritable(epfd);
                if (keep and (ev.events & linux.EPOLL.IN) != 0) keep = onReadable(conn, payload_buf, out_buf);
                if (keep and conn.transport.want_out) tls_conn.armOut(epfd, conn.transport.fd, conn.transport.ep_data, true);
                if (keep and conn.transport.wclose and !conn.transport.want_out) keep = false;
            }

            if (!keep) {
                _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, ev.data.fd, null);
                table.drop(ev.data.fd);
                _ = linux.close(ev.data.fd);
            }
        }
    }
}

/// Listen and serve https/1.1 over TLS, multiplexed across one epoll worker per core. The cert / key /
/// policy are already loaded and validated in the context (config.tls).
pub fn runTlsMux(handler: HandlerFn, config: Config) !void {
    const ctx = config.tls.?;
    // Cpuset-aware count (sched_getaffinity), NOT the host CPU count, so a cgroup-pinned server does
    // not spawn host-many workers onto a few cores. This matches the cleartext .EPOLL model.
    const cpu = common.getAvailableCpuCount();
    const worker_count = if (config.workers == 0) cpu else config.workers;

    common.logSystem(config, "listening on {s}:{d} (https/1.1 TLS, epoll-mux/{d})", .{ config.ip, config.port, worker_count });

    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    for (threads, 0..) |*t, i|
        t.* = try std.Thread.spawn(.{ .stack_size = config.worker_stack_size_bytes }, workerRun, .{WorkerCtx{
            .io = config.io,
            .ip = config.ip,
            .port = config.port,
            .kernel_backlog = config.kernel_backlog,
            .stack_size = config.worker_stack_size_bytes,
            .worker_id = i,
            .handler = handler,
            .ctx = ctx,
            .public_dir = config.public_dir,
        }});

    for (threads) |t| t.join();
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

/// Test handler: write a fixed 200 response via the fd-handler write path (core.writeAllFD, so the
/// response sink installed by runHandlerToBuffer captures it), ignoring the request.
fn epollTestHandler(head: *const core.ParsedHead, body: []const u8, fd: posix.fd_t) void {
    _ = head;
    _ = body;

    core.writeAllFD(fd, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok") catch {};
}

/// Test handler: engine-owned WebSocket upgrade (the cleartext WebSocket.serve API, honored on the
/// TLS mux loop).
fn wsUpgradeTestHandler(head: *const core.ParsedHead, body: []const u8, fd: posix.fd_t) void {
    _ = body;

    const key = core.getHeader(head, "sec-websocket-key") orelse {
        core.writeAllFD(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
        return;
    };
    ws.serve(fd, key, wsEchoTestFrame) catch {};
}

fn wsEchoTestFrame(fd: posix.fd_t, opcode: u8, payload: []const u8) void {
    ws.sendFD(fd, @enumFromInt(opcode), payload) catch {};
}

/// Test handler: SSE-style streaming response (beginStream detaches the capture sink, every write
/// seals records through the connection's stream sink).
fn sseTestHandler(head: *const core.ParsedHead, body: []const u8, fd: posix.fd_t) void {
    _ = head;
    _ = body;

    core.beginStream();
    core.writeAllFD(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n") catch return;
    core.writeAllFD(fd, "data: one\n\n") catch return;
}

/// Read exactly one TLS record (5-byte header + body) from a blocking fd into buf, returning its full
/// bytes. Used by the test client to read the server flight and the encrypted responses.
fn readRecordFd(fd: posix.fd_t, buf: []u8) ![]const u8 {
    var got: usize = 0;
    while (got < 5) {
        const rc = linux.read(fd, buf[got..].ptr, 5 - got);
        if (posix.errno(rc) != .SUCCESS) return error.ReadFailed;
        if (rc == 0) return error.ConnectionClosed;
        got += @intCast(rc);
    }

    const length = std.mem.readInt(u16, buf[3..5], .big);
    const total = 5 + length;
    while (got < total) {
        const rc = linux.read(fd, buf[got..].ptr, total - got);
        if (posix.errno(rc) != .SUCCESS) return error.ReadFailed;
        if (rc == 0) return error.ConnectionClosed;
        got += @intCast(rc);
    }

    return buf[0..total];
}

/// Test fixture: a served TlsConn with an established client session over a socketpair. Drives the
/// full handshake through onReadable so every test starts from an application-data session.
const TestSession = struct {
    conn: TlsConn,
    client_fd: posix.fd_t,
    server_fd: posix.fd_t,
    finished: @import("../../tls/client.zig").FinishResult,
    payload_buf: [core.BUF_SIZE]u8 = undefined,
    out_buf: [RESPONSE_BUF_SIZE]u8 = undefined,

    fn deinit(self: *TestSession) void {
        self.conn.transport.deinit();
        _ = linux.close(self.client_fd);
        _ = linux.close(self.server_fd);
    }

    fn readable(self: *TestSession) bool {
        return onReadable(&self.conn, &self.payload_buf, &self.out_buf);
    }

    /// Encrypt request bytes as client application data and hand them to the server side.
    fn send(self: *TestSession, plaintext: []const u8) !void {
        var enc: [4096]u8 = undefined;
        try writeAllFD(self.client_fd, self.finished.connection.writeAppData(plaintext, &enc));
    }

    /// Read one encrypted record from the server and return its decrypted plaintext.
    fn recv(self: *TestSession, plain: []u8) ![]const u8 {
        var rec_buf: [4096]u8 = undefined;
        const rec = try readRecordFd(self.client_fd, &rec_buf);

        return self.finished.connection.readAppData(rec, plain);
    }
};

fn startTestSession(handler: HandlerFn, ctx: *Tls.Context) !TestSession {
    const client = @import("../../tls/client.zig");

    var pair: [2]posix.fd_t = undefined;
    try std.testing.expect(posix.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair)) == .SUCCESS);
    const client_fd = pair[0];
    const server_fd = pair[1];

    // the worker drives the server side via onReadable, which needs a non-blocking fd to detect drain.
    common.setNonBlock(server_fd);

    var self = TestSession{
        .conn = .{
            .transport = tls_conn.Transport.init(server_fd, ctx),
            .handler = handler,
            .ctx = ctx,
        },
        .client_fd = client_fd,
        .server_fd = server_fd,
        .finished = undefined,
    };

    // client ClientHello wrapped in a plaintext handshake record. The worker reads + answers it.
    var ch_buf: [512]u8 = undefined;
    const started = try client.start(.{ .client_random = @splat(0x11), .ephemeral_secret = @splat(0x42) }, &ch_buf);
    var state = started.state;

    var ch_rec: [600]u8 = undefined;
    ch_rec[0] = content_type_handshake_test;
    std.mem.writeInt(u16, ch_rec[1..3], 0x0303, .big);
    std.mem.writeInt(u16, ch_rec[3..5], @intCast(started.client_hello.len), .big);
    @memcpy(ch_rec[5 .. 5 + started.client_hello.len], started.client_hello);
    try writeAllFD(client_fd, ch_rec[0 .. 5 + started.client_hello.len]);

    try std.testing.expect(onReadable(&self.conn, &self.payload_buf, &self.out_buf)); // ClientHello -> server flight

    var flight_buf: [4096]u8 = undefined;
    var flen: usize = 0;
    for (0..3) |_| {
        const rec = try readRecordFd(client_fd, flight_buf[flen..]);
        flen += rec.len;
    }

    var fin_buf: [256]u8 = undefined;
    self.finished = try client.finish(&state, flight_buf[0..flen], &fin_buf);
    try writeAllFD(client_fd, self.finished.client_finished);

    return self;
}

fn testContext(cert_buf: *[512]u8) !Tls.Context {
    const context = @import("../../tls/context.zig");
    const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

    // server identity from the shared fixture.
    var skey: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&skey, tls_serve.fixture_key_hex);
    const server_key = try EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(skey));
    const cert_der = try std.fmt.hexToBytes(cert_buf, tls_serve.fixture_cert_hex);

    return .{
        .allocator = std.testing.allocator,
        .cert_der = cert_der,
        .signing_key = .{ .ecdsa_p256 = server_key },
        .alpn = &.{},
        .curves = context.default_curves,
        .ciphers = context.default_ciphers,
        .min_version = .TLS_1_2,
        .max_version = .TLS_1_3,
        .prefer_server_ciphers = true,
        .hsts_max_age_s = 0,
    };
}

test "zix test: tls_mux, event-driven keep-alive serves many requests then Connection: close" {
    var cert_buf: [512]u8 = undefined;
    var ctx = try testContext(&cert_buf);

    var tst = try startTestSession(epollTestHandler, &ctx);
    defer tst.deinit();

    // two keep-alive requests on the one connection: both get a 200 over the SAME session driven by
    // onReadable (no re-handshake), and onReadable keeps the connection alive (returns true).
    const keepalive_reqs = [_][]const u8{
        "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "GET /b HTTP/1.1\r\nHost: localhost\r\n\r\n",
    };
    for (keepalive_reqs) |req| {
        try tst.send(req);

        try std.testing.expect(tst.readable());
        try std.testing.expect(!tst.conn.transport.wclose);

        var plain: [1024]u8 = undefined;
        const resp = try tst.recv(&plain);
        try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    }

    // the Connection: close request still gets its 200, but onReadable signals close (returns false)
    // and the loop ends. The response is sent before the close path.
    try tst.send("GET /c HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

    try std.testing.expect(!tst.readable());
    try std.testing.expect(tst.conn.transport.wclose);

    var plain: [1024]u8 = undefined;
    const resp = try tst.recv(&plain);
    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
}

test "zix test: tls_mux, WebSocket.serve handoff pumps frames with encrypt-on-write" {
    var cert_buf: [512]u8 = undefined;
    var ctx = try testContext(&cert_buf);

    var tst = try startTestSession(wsUpgradeTestHandler, &ctx);
    defer tst.deinit();

    // Upgrade request: the 101 is captured by the response sink and arrives as one sealed record.
    try tst.send("GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n");

    try std.testing.expect(tst.readable());
    try std.testing.expect(tst.conn.ws != null);

    var plain: [1024]u8 = undefined;
    const upgrade_resp = try tst.recv(&plain);
    try std.testing.expect(std.mem.indexOf(u8, upgrade_resp, "101 Switching Protocols") != null);

    // One masked client text frame "hi": the echo comes back as an encrypted record holding an
    // unmasked server frame with the same payload.
    const frame = [_]u8{ 0x81, 0x82, 0x01, 0x02, 0x03, 0x04, 'h' ^ 0x01, 'i' ^ 0x02 };
    try tst.send(&frame);

    try std.testing.expect(tst.readable());
    try std.testing.expect(!tst.conn.transport.wclose);

    var echo_plain: [1024]u8 = undefined;
    const echo = try tst.recv(&echo_plain);
    var scratch: [128]u8 = undefined;
    const parsed = ws.parseFrame(echo, &scratch).?;
    try std.testing.expectEqualStrings("hi", parsed.frame.payload);
}

test "zix test: tls_mux, beginStream handler streams SSE records and keeps the connection" {
    var cert_buf: [512]u8 = undefined;
    var ctx = try testContext(&cert_buf);

    var tst = try startTestSession(sseTestHandler, &ctx);
    defer tst.deinit();

    try tst.send("GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n");

    // The handler streamed two writes (headers, one event): each write is its own sealed record,
    // and the connection stays open for more events.
    try std.testing.expect(tst.readable());
    try std.testing.expect(!tst.conn.transport.wclose);

    var plain_a: [1024]u8 = undefined;
    const headers = try tst.recv(&plain_a);
    try std.testing.expect(std.mem.indexOf(u8, headers, "text/event-stream") != null);

    var plain_b: [1024]u8 = undefined;
    const event = try tst.recv(&plain_b);
    try std.testing.expectEqualStrings("data: one\n\n", event);
}

const content_type_handshake_test: u8 = 22;

fn writeAllFD(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (posix.errno(rc) != .SUCCESS) return error.WriteFailed;
        off += @intCast(rc);
    }
}
