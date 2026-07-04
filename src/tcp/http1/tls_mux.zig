//! zix http1 https serve path, event-driven (https/1.1 over TLS 1.3, RFC 8446 + 9112).
//!
//! What:
//! - One SO_REUSEPORT listener + epoll instance per worker, like the cleartext .EPOLL model, but each
//!   connection terminates TLS in place via a resumable tls_session.Session (no thread per connection).
//!   recv ciphertext -> session decrypts -> the plaintext feeds the http1 request loop -> the handler's
//!   response is encrypted back into TLS records -> sent. A worker multiplexes thousands of TLS
//!   connections, so high concurrency no longer spawns thousands of blocking threads (the thread-per-
//!   connection TLS path in tls_serve.zig serializes connections and starves the rest).
//! - Keep-alive (RFC 9112 9.3): a connection serves requests in a loop over the established session, so
//!   the handshake is paid once per connection, not once per request. The loop ends on Connection:
//!   close, a client close_notify, or a hangup.
//! - Writes are non-blocking: on EAGAIN the unsent ciphertext is staged per connection and EPOLLOUT is
//!   armed, so a slow client never parks the worker.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const core = @import("core.zig");
const Config = @import("config.zig").Http1ServerConfig;
const common = @import("dispatch/common.zig");
const tls_serve = @import("tls_serve.zig");
const session = @import("../tls/tls_session.zig");
const Tls = @import("../../tls/Tls.zig");
const slab = @import("../../multiplexers/slab.zig");

const HandlerFn = core.HandlerFn;
const MAX_FD = common.MAX_FD;
const EPOLL_MAX_EVENTS: usize = 4096;
const allocator = std.heap.smp_allocator;

/// Inbound ciphertext read staging (may hold several records per read).
const TLS_READ_STAGING_SIZE: usize = 32 * 1024;

/// Decrypted plaintext staging for one read (matches the read staging so a full read fits).
const TLS_PLAIN_STAGING_SIZE: usize = 32 * 1024;

/// One sealed response record staging: response plaintext plus AEAD and framing overhead.
const TLS_SEALED_OUT_SIZE: usize = 70 * 1024;

/// Per-connection request accumulator: the effective max request size over TLS (matches tls_serve).
const REQUEST_BUF_SIZE: usize = 17 * 1024;

/// Handler response staging: the effective max response size over TLS (matches tls_serve).
const RESPONSE_BUF_SIZE: usize = 64 * 1024;

/// Initial size of the per-connection outbound-ciphertext backpressure buffer (grown on demand).
const tls_write_buf_initial: usize = 16 * 1024;

const content_type_application_data: u8 = 23;

/// One TLS connection: the resumable TLS session, the request accumulator, and the outbound-ciphertext
/// backpressure buffer. One worker owns a connection for its whole lifetime (shared-nothing).
const TlsConn = struct {
    fd: posix.fd_t,
    tls: session.Session,
    handler: HandlerFn,
    ctx: *const Tls.Context,

    // Partial request bytes across reads (and pipelined requests): the live bytes are rbuf[0..rlen].
    rbuf: [REQUEST_BUF_SIZE]u8 = undefined,
    rlen: usize = 0,

    // Outbound ciphertext staged on EAGAIN: a heap buffer flushed on the next EPOLLOUT. wbuf is the
    // allocation (capacity), the live bytes are wbuf[woff..wlen]. Capacity and length are tracked
    // separately so a grown buffer never transmits its uninitialized tail.
    wbuf: []u8 = &.{},
    woff: usize = 0,
    wlen: usize = 0,
    wclose: bool = false,
    want_out: bool = false,
};

/// Per-worker fd -> TlsConn map (shared-nothing, one worker owns a connection for its lifetime).
const ConnTable = struct {
    slots: []?*TlsConn,

    fn init() !ConnTable {
        return .{ .slots = try slab.mapZeroedSlots(?*TlsConn, MAX_FD) };
    }

    fn deinit(self: *ConnTable) void {
        for (self.slots) |maybe| {
            if (maybe) |conn| freeConn(conn);
        }
        slab.unmapSlots(self.slots);
    }

    fn get(self: *ConnTable, fd: posix.fd_t) ?*TlsConn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        return self.slots[idx];
    }

    fn put(self: *ConnTable, conn: *TlsConn) void {
        self.slots[@intCast(conn.fd)] = conn;
    }

    fn drop(self: *ConnTable, fd: posix.fd_t) void {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return;
        if (self.slots[idx]) |conn| freeConn(conn);
        self.slots[idx] = null;
    }
};

fn freeConn(conn: *TlsConn) void {
    if (conn.wbuf.len > 0) allocator.free(conn.wbuf);
    allocator.destroy(conn);
}

fn armOut(epfd: posix.fd_t, fd: posix.fd_t, on: bool) void {
    var flags: u32 = linux.EPOLL.IN | linux.EPOLL.RDHUP;
    if (on) flags |= linux.EPOLL.OUT;

    var ev = linux.epoll_event{ .events = flags, .data = .{ .fd = fd } };
    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &ev);
}

/// Try to send `bytes` now, staging whatever does not fit and marking the connection for EPOLLOUT.
/// Returns false on a fatal write error (the caller closes).
///
/// Note:
/// - TLS records must reach the peer in order (the AEAD nonce is the record sequence number). If
///   ciphertext is already staged, this MUST append rather than write directly, or a later record
///   would overtake the staged one on the wire and break decryption.
fn sendRaw(conn: *TlsConn, bytes: []const u8) bool {
    if (conn.wlen > conn.woff) {
        stageWrite(conn, bytes);
        return true;
    }

    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(conn.fd, bytes[off..].ptr, bytes.len - off);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
                off += @intCast(rc);
            },
            .INTR => continue,
            .AGAIN => {
                stageWrite(conn, bytes[off..]);
                return true;
            },
            else => return false,
        }
    }

    return true;
}

/// Append unsent ciphertext to the connection's pending buffer (grown as needed) for the next EPOLLOUT.
/// The live bytes are wbuf[woff..wlen]. Capacity (wbuf.len) is never used as the data length, so a
/// grown buffer never flushes its uninitialized tail.
fn stageWrite(conn: *TlsConn, bytes: []const u8) void {
    const pending = conn.wlen - conn.woff;

    // Room already at the tail: append in place.
    if (conn.wbuf.len - conn.wlen >= bytes.len) {
        @memcpy(conn.wbuf[conn.wlen..][0..bytes.len], bytes);
        conn.wlen += bytes.len;
        conn.want_out = true;
        return;
    }

    const need = pending + bytes.len;

    // Compaction alone makes room: slide the live bytes to the front.
    if (conn.wbuf.len >= need) {
        std.mem.copyForwards(u8, conn.wbuf[0..pending], conn.wbuf[conn.woff..conn.wlen]);
        conn.woff = 0;
        conn.wlen = pending;

        @memcpy(conn.wbuf[conn.wlen..][0..bytes.len], bytes);
        conn.wlen += bytes.len;
        conn.want_out = true;
        return;
    }

    // Grow: allocate a larger buffer and move the live bytes to its front.
    var new_cap: usize = if (conn.wbuf.len == 0) tls_write_buf_initial else conn.wbuf.len * 2;
    while (new_cap < need) new_cap *= 2;

    const grown = allocator.alloc(u8, new_cap) catch {
        conn.wclose = true;
        return;
    };
    @memcpy(grown[0..pending], conn.wbuf[conn.woff..conn.wlen]);
    if (conn.wbuf.len > 0) allocator.free(conn.wbuf);
    conn.wbuf = grown;
    conn.woff = 0;
    conn.wlen = pending;

    @memcpy(conn.wbuf[conn.wlen..][0..bytes.len], bytes);
    conn.wlen += bytes.len;
    conn.want_out = true;
}

/// Encrypt response plaintext into TLS records and send (staging on backpressure).
fn sendPlain(conn: *TlsConn, plaintext: []const u8) bool {
    var sealed: [TLS_SEALED_OUT_SIZE]u8 = undefined;
    const ct = conn.tls.encrypt(plaintext, &sealed);

    return sendRaw(conn, ct);
}

/// Handle a readable TLS connection: decrypt available records, drive the handshake, then feed the
/// plaintext to the http1 request loop and seal its replies. Returns false when the connection must
/// close.
fn onReadable(conn: *TlsConn) bool {
    var cipher: [TLS_READ_STAGING_SIZE]u8 = undefined;
    var to_send: [TLS_SEALED_OUT_SIZE]u8 = undefined;
    var plain_in: [TLS_PLAIN_STAGING_SIZE]u8 = undefined;

    while (true) {
        const rc = linux.read(conn.fd, &cipher, cipher.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false; // peer closed
            },
            .INTR => continue,
            .AGAIN => return true, // drained
            else => return false,
        }

        const got = cipher[0..@intCast(rc)];
        const r = conn.tls.feed(got, &to_send, &plain_in);

        if (r.to_send.len > 0 and !sendRaw(conn, r.to_send)) return false;

        if (r.outcome == .close) {
            conn.wclose = true;
            return conn.want_out; // keep the conn only to flush a final alert
        }

        if (r.plaintext.len > 0) {
            if (!feedRequests(conn, r.plaintext)) return false;
            if (conn.wclose) return conn.want_out; // Connection: close handled, flush then close
        }
    }
}

/// Accumulate decrypted plaintext and dispatch every complete request now buffered. Pipelined requests
/// drain in one pass. Returns false when the connection must close (request too large, bad request, or
/// a fatal write); sets conn.wclose when the client asked to close after the response.
fn feedRequests(conn: *TlsConn, plaintext: []const u8) bool {
    // overflow guard: a single request larger than the buffer is rejected (matches tls_serve's cap).
    if (plaintext.len > conn.rbuf.len - conn.rlen) {
        conn.wclose = true;
        return true;
    }

    @memcpy(conn.rbuf[conn.rlen..][0..plaintext.len], plaintext);
    conn.rlen += plaintext.len;

    var response_buf: [RESPONSE_BUF_SIZE]u8 = undefined;

    while (conn.rlen > 0) {
        const parsed = core.parseHead(conn.rbuf[0..conn.rlen]) catch |err| {
            if (err == error.IncompleteHeader) return true; // wait for the rest of the head

            conn.wclose = true; // malformed request: close
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
                conn.wclose = true;
                return true;
            };
        }

        // the multiplexed path stays buffered (ADR-054): a streaming handler (beginStream) has no
        // stream sink armed here, so runHandlerToBuffer rejects it and the connection closes cleanly.
        const result = tls_serve.runHandlerToBuffer(conn.handler, &head, body, &response_buf) catch {
            _ = core.takeWebSocket(); // the multiplexed path does not host WS (ADR-055), drop any handoff
            conn.wclose = true;
            return true;
        };
        if (!sendPlain(conn, result.bytes)) return false;

        // consume this request, sliding any pipelined bytes to the front.
        const remaining = conn.rlen - total;
        if (remaining > 0) std.mem.copyForwards(u8, conn.rbuf[0..remaining], conn.rbuf[total..conn.rlen]);
        conn.rlen = remaining;

        // honor Connection: close (and the HTTP/1.0 default): close_notify, then end the connection.
        if (!head.keep_alive) {
            var close_buf: [64]u8 = undefined;
            _ = sendRaw(conn, conn.tls.closeNotify(&close_buf));
            conn.wclose = true;
            return true;
        }
    }

    return true;
}

/// Flush staged outbound ciphertext on an EPOLLOUT. Returns false when the connection must close.
fn onWritable(epfd: posix.fd_t, conn: *TlsConn) bool {
    while (conn.woff < conn.wlen) {
        const rc = linux.write(conn.fd, conn.wbuf[conn.woff..].ptr, conn.wlen - conn.woff);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
                conn.woff += @intCast(rc);
            },
            .INTR => continue,
            .AGAIN => return true,
            else => return false,
        }
    }

    // Drained. Keep the buffer for reuse instead of freeing: under sustained backpressure the
    // stage/drain cycle repeats, and a free here plus a realloc on the next stageWrite churns the
    // shared allocator on the hot path. freeConn releases it at close.
    conn.woff = 0;
    conn.wlen = 0;
    conn.want_out = false;
    armOut(epfd, conn.fd, false);

    return !conn.wclose;
}

fn acceptAll(table: *ConnTable, epfd: posix.fd_t, listener_fd: posix.fd_t, handler: HandlerFn, ctx: *const Tls.Context) void {
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
            .fd = fd,
            .tls = session.Session.init(ctx.cert_der, ctx.signing_key, ctx.alpn),
            .handler = handler,
            .ctx = ctx,
        };
        table.put(conn);

        var ev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.RDHUP, .data = .{ .fd = fd } };
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

    var lev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = listener_fd } };
    if (posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listener_fd, &lev)) != .SUCCESS) return;

    var table = ConnTable.init() catch return;
    defer table.deinit();

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
                acceptAll(&table, epfd, listener_fd, worker.handler, worker.ctx);
                continue;
            }

            const conn = table.get(ev.data.fd) orelse continue;
            var keep = true;

            if ((ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0) {
                keep = false;
            } else {
                if ((ev.events & linux.EPOLL.OUT) != 0) keep = onWritable(epfd, conn);
                if (keep and (ev.events & linux.EPOLL.IN) != 0) keep = onReadable(conn);
                if (keep and conn.want_out) armOut(epfd, conn.fd, true);
                if (keep and conn.wclose and !conn.want_out) keep = false;
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
pub fn runTlsMux(config: Config, handler: HandlerFn) !void {
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

test "zix test: tls_mux, event-driven keep-alive serves many requests then Connection: close" {
    const client = @import("../../tls/client.zig");
    const context = @import("../../tls/context.zig");
    const tls_serve_mod = @import("tls_serve.zig");
    const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

    // server identity from the shared fixture.
    var skey: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&skey, tls_serve_mod.fixture_key_hex);
    const server_key = try EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(skey));
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, tls_serve_mod.fixture_cert_hex);

    var ctx = Tls.Context{
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

    var pair: [2]posix.fd_t = undefined;
    try std.testing.expect(posix.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair)) == .SUCCESS);
    const client_fd = pair[0];
    const server_fd = pair[1];
    defer _ = linux.close(client_fd);
    defer _ = linux.close(server_fd);

    // the worker drives the server side via onReadable, which needs a non-blocking fd to detect drain.
    common.setNonBlock(server_fd);

    var conn = TlsConn{
        .fd = server_fd,
        .tls = session.Session.init(ctx.cert_der, ctx.signing_key, ctx.alpn),
        .handler = epollTestHandler,
        .ctx = &ctx,
    };
    defer if (conn.wbuf.len > 0) allocator.free(conn.wbuf);

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

    try std.testing.expect(onReadable(&conn)); // process ClientHello, emit the server flight

    var flight_buf: [4096]u8 = undefined;
    var flen: usize = 0;
    for (0..3) |_| {
        const rec = try readRecordFd(client_fd, flight_buf[flen..]);
        flen += rec.len;
    }

    var fin_buf: [256]u8 = undefined;
    var finished = try client.finish(&state, flight_buf[0..flen], &fin_buf);
    try writeAllFD(client_fd, finished.client_finished);

    // two keep-alive requests on the one connection: both get a 200 over the SAME session driven by
    // onReadable (no re-handshake), and onReadable keeps the connection alive (returns true).
    const keepalive_reqs = [_][]const u8{
        "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "GET /b HTTP/1.1\r\nHost: localhost\r\n\r\n",
    };
    for (keepalive_reqs) |req| {
        var enc: [512]u8 = undefined;
        try writeAllFD(client_fd, finished.connection.writeAppData(req, &enc));

        try std.testing.expect(onReadable(&conn));
        try std.testing.expect(!conn.wclose);

        var resp_rec: [1024]u8 = undefined;
        const rec = try readRecordFd(client_fd, &resp_rec);
        var plain: [1024]u8 = undefined;
        const resp = try finished.connection.readAppData(rec, &plain);
        try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    }

    // the Connection: close request still gets its 200, but onReadable signals close (returns false)
    // and the loop ends. The response is sent before the close path.
    var enc: [512]u8 = undefined;
    try writeAllFD(client_fd, finished.connection.writeAppData("GET /c HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &enc));

    try std.testing.expect(!onReadable(&conn));
    try std.testing.expect(conn.wclose);

    var resp_rec: [1024]u8 = undefined;
    const rec = try readRecordFd(client_fd, &resp_rec);
    var plain: [1024]u8 = undefined;
    const resp = try finished.connection.readAppData(rec, &plain);
    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
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
