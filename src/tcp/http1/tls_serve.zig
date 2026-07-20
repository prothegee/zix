//! zix http1 https serve path (approach A, RFC 8446 + 9112).
//!
//! Note:
//! - Gated on config.tls (a *Tls.Context). The accept loop hands each connection to its own worker
//!   thread (.ASYNC / .POOL / .MIXED), so a slow handshake or a keep-alive client never serializes
//!   the others. The worker reads the ClientHello, then branches on the version policy: a 1.3-capable
//!   client takes the TLS 1.3 path (zix.Tls), a 1.2-only client takes the TLS 1.2 path (zix.Tls
//!   tls12_connection), each subject to the context's min_version / max_version. Either way it then
//!   per request decrypts the record, reuses core.parseHead, runs the handler with an in-memory
//!   response sink capturing its plaintext (runHandlerToBuffer), encrypts that, and sends it.
//! - The cleartext EPOLL / URING hot path is untouched: this whole file is reached only when
//!   config.tls is set (gated in server.zig before the dispatch switch). .EPOLL / .URING terminate
//!   TLS in the event-driven tls_mux worker instead. https is a separate path on its own perf band
//!   (not the 1% gate), so the per-request capture copy is acceptable.
//! - The cert / key are loaded and validated once in Tls.Context.init (the cold path), so the
//!   accept loop reads a ready context with no per-connection PEM work.
//! - Keep-alive (RFC 9112 9.3): once the handshake completes the connection serves requests in a
//!   loop over the established session, so the costly handshake is paid once per connection, not
//!   once per request. The loop ends on Connection: close, a client close_notify, or a hangup.
//! - Buffered responses by default. A handler that calls beginStream() (SSE) is served over TLS via
//!   the per-connection stream sink (ADR-054): each event encrypts one record and sends it. A
//!   WebSocket upgrade (bidirectional) is still out of scope here (ADR-055 adds the TLS read path).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Config = @import("config.zig").Http1ServerConfig;
const core = @import("core.zig");
const common = @import("dispatch/common.zig");
const ws = @import("websocket.zig");
const Tls = @import("../../tls/Tls.zig");
const tls12 = @import("../../tls/tls12_connection.zig");
const record = @import("../../tls/record.zig");

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const HandlerFn = core.HandlerFn;

const content_type_change_cipher_spec: u8 = 20;
const content_type_alert: u8 = 21;
const content_type_handshake: u8 = 22;
const content_type_application_data: u8 = 23;

/// Server handshake flight output staging (TLS 1.3 and TLS 1.2 server flights).
const server_flight_out_size: usize = 8 * 1024;

/// HelloRetryRequest output staging (RFC 8446 4.1.4).
const hello_retry_out_size: usize = 1024;

/// Incoming ClientKeyExchange body copy (TLS 1.2 path).
const client_key_exchange_size: usize = 256;

/// Outgoing server Finished output (TLS 1.2 path).
const server_finished_out_size: usize = 256;

/// Application-data encrypt output: one response record plus AEAD and framing overhead.
const app_data_encrypt_out_size: usize = 70 * 1024;

/// One encrypted alert record (close_notify or a fatal alert after keys exist).
const encrypted_alert_size: usize = 64;

/// Decrypted request plaintext buffer: the effective max request size over TLS.
const request_plain_size: usize = 17 * 1024;

/// Handler response buffer: the effective max response size over TLS.
const response_buf_size: usize = 64 * 1024;

/// WebSocket-over-TLS frame loop buffers (ADR-055): accumulated client frame bytes, one decrypted
/// record, the largest unmasked payload, and the coalesced outbound frames staged before encryption.
const ws_acc_size: usize = 17 * 1024;
const ws_record_plain_size: usize = 17 * 1024;
const ws_payload_size: usize = 16 * 1024;
const ws_out_size: usize = 32 * 1024;

/// A plaintext alert arriving mid-handshake (the peer aborted): parse it (RFC 8446 6) and signal a
/// clean teardown so the accept loop closes the connection rather than misreading it as a record.
fn peerAlert(body: []const u8) anyerror {
    _ = Tls.parseInboundAlert(body) catch {};

    return error.PeerAlert;
}

/// Listen and serve https/1.1, one worker thread per connection (the .ASYNC / .POOL / .MIXED path,
/// .EPOLL / .URING use the event-driven tls_mux). The cert / key / policy are already loaded and
/// validated in the context (config.tls), so this only accepts and drives per-connection handshakes.
///
/// Note:
/// - Each accepted connection is handed to its own thread so a slow handshake or a keep-alive client
///   never blocks the accept loop (serving inline would serialize every connection, the slow path
///   that wedged json-tls). The connection thread runs the full keep-alive request loop.
pub fn runTls(handler: HandlerFn, config: Config) !void {
    const io = config.io;
    const ctx = config.tls.?;

    const addr = try std.Io.net.IpAddress.resolve(io, config.ip, config.port);
    var srv = try addr.listen(io, .{ .reuse_address = true, .kernel_backlog = config.kernel_backlog });

    common.logSystem(config, "listening on {s}:{d} (https/1.1)", .{ config.ip, config.port });

    while (true) {
        const stream = srv.accept(io) catch continue;
        const conn_fd = stream.socket.handle;

        const worker = std.Thread.spawn(.{ .stack_size = config.worker_stack_size_bytes }, connWorker, .{
            ConnCtx{ .fd = conn_fd, .handler = handler, .ctx = ctx, .io = io, .public_dir = config.public_dir, .max_response_headers = config.max_response_headers.value() },
        }) catch {
            // Spawn failed (thread / pid limit under extreme load): drop this connection and keep
            // accepting. Serving inline here would block the accept loop for the connection's whole
            // lifetime, wedging every other pending connection. The client retries the dropped one.
            _ = linux.close(conn_fd);

            continue;
        };

        worker.detach();
    }
}

/// One connection thread's inputs: the accepted fd plus the shared (borrowed) handler and context.
const ConnCtx = struct {
    fd: posix.fd_t,
    handler: HandlerFn,
    ctx: *const Tls.Context,
    io: std.Io,
    public_dir: []const u8 = "",
    max_response_headers: usize = 16,
};

/// Drive one https/1.1 connection (handshake + keep-alive request loop), then close it.
fn connWorker(conn_ctx: ConnCtx) void {
    core.setStatic(conn_ctx.public_dir, conn_ctx.io);
    core.setMaxResponseHeaders(conn_ctx.max_response_headers);

    serveConnTls(conn_ctx.fd, conn_ctx.handler, conn_ctx.ctx) catch {};

    _ = linux.close(conn_ctx.fd);
}

fn serveConnTls(fd: posix.fd_t, handler: HandlerFn, ctx: *const Tls.Context) !void {
    var record_buf: [record.max_record_wire]u8 = undefined;

    // ClientHello (a plaintext handshake record carries the message in its body).
    const client_hello_rec = try readRecord(fd, &record_buf);
    if (client_hello_rec.content_type != content_type_handshake) return error.UnexpectedRecord;

    var ephemeral_secret: [32]u8 = undefined;
    var server_random: [32]u8 = undefined;
    var pss_salt: [32]u8 = undefined;
    _ = linux.getrandom(&ephemeral_secret, ephemeral_secret.len, 0);
    _ = linux.getrandom(&server_random, server_random.len, 0);
    _ = linux.getrandom(&pss_salt, pss_salt.len, 0);

    const opts = ctx.handshakeOptions(ephemeral_secret, server_random, pss_salt);

    // Version policy: when the ceiling is TLS 1.2, never take the 1.3 path. The 1.2 ServerKeyExchange
    // is ECDSA-signed, so an Ed25519 context cannot serve 1.2.
    if (!ctx.allowsTls13()) {
        const ecdsa_key = switch (ctx.signing_key) {
            .ecdsa_p256 => |kp| kp,
            else => return error.Tls12RequiresEcdsa,
        };

        return serveConnTls12(fd, handler, ctx, ecdsa_key, client_hello_rec.body, ephemeral_secret, server_random);
    }

    // HelloRetryRequest (RFC 8446 4.1.4): if the 1.3 client picked a group it gave no key_share for,
    // send the HRR and read a second ClientHello before completing. null = no retry needed. A 1.2
    // client surfaces as UnsupportedTlsVersion here and is handled by the serverHandshake path below.
    var handshake_out: [server_flight_out_size]u8 = undefined;
    var hrr_out: [hello_retry_out_size]u8 = undefined;
    var retry_state: ?Tls.RetryState = null;
    var second_hello: []const u8 = &.{};
    if (Tls.serverHelloRetry(opts, client_hello_rec.body, &hrr_out)) |maybe_retry| {
        if (maybe_retry) |retry| {
            try writeAllFD(fd, retry.to_send);

            const ch2_rec = try readRecord(fd, &record_buf);
            if (ch2_rec.content_type != content_type_handshake) return error.UnexpectedRecord;

            retry_state = retry.state;
            second_hello = ch2_rec.body;
        }
    } else |err| {
        // a malformed / non-1.3 ClientHello: 1.2 falls through to serverHandshake, else alert + close.
        if (err != error.UnsupportedTlsVersion) {
            var alert_buf: [Tls.fatal_record_len]u8 = undefined;
            if (Tls.alertRecordForError(&alert_buf, err)) |rec| writeAllFD(fd, rec) catch {};

            return err;
        }
    }

    const result = if (retry_state) |state|
        try Tls.serverHandshakeAfterRetry(state, second_hello, &handshake_out)
    else
        Tls.serverHandshake(opts, client_hello_rec.body, &handshake_out) catch |err| {
            // no 1.3 offer -> the client is TLS 1.2 only. Honor the floor: refuse when min_version
            // is 1.3, else take the 1.2 path. The 1.2 ServerKeyExchange is ECDSA-signed, so an
            // Ed25519 context is TLS 1.3 only.
            if (err == error.UnsupportedTlsVersion) {
                if (!ctx.allowsTls12()) {
                    var ver_alert: [Tls.fatal_record_len]u8 = undefined;
                    if (Tls.alertRecordForError(&ver_alert, err)) |rec| writeAllFD(fd, rec) catch {};

                    return err;
                }

                const ecdsa_key = switch (ctx.signing_key) {
                    .ecdsa_p256 => |kp| kp,
                    else => return error.Tls12RequiresEcdsa,
                };

                return serveConnTls12(fd, handler, ctx, ecdsa_key, client_hello_rec.body, ephemeral_secret, server_random);
            }

            // any other rejected ClientHello: send the fatal alert in the clear (no keys yet), then close.
            var alert_buf: [Tls.fatal_record_len]u8 = undefined;
            if (Tls.alertRecordForError(&alert_buf, err)) |rec| writeAllFD(fd, rec) catch {};

            return err;
        };
    try writeAllFD(fd, result.to_send);
    var conn = result.connection;

    // client ChangeCipherSpec (skipped) + Finished. A plaintext alert here means the peer aborted.
    while (true) {
        const rec = try readRecord(fd, &record_buf);
        if (rec.content_type == content_type_change_cipher_spec) continue;
        if (rec.content_type == content_type_alert) return peerAlert(rec.body);
        if (rec.content_type != content_type_application_data) return error.UnexpectedRecord;

        try conn.verifyClientFinished(rec.full);
        break;
    }

    // keep-alive request loop over the established 1.3 session.
    try serveRequests(fd, handler, ctx, &conn, &record_buf);
}

/// Serve application requests over an established TLS session until the client signals close.
/// Each request: decrypt -> parse -> handler (captured by the response sink) -> encrypt -> write. The handshake is
/// already paid, so this loop is what makes the cost per connection rather than per request.
///
/// Note:
/// - Generic over the connection type so the TLS 1.3 and TLS 1.2 paths share one loop. Both expose
///   readAppData / writeAppData / closeNotify, only the 1.3 connection adds encryptedAlert.
/// - Ends cleanly on a peer hangup (ConnectionClosed), a client close_notify (an inner alert ->
///   PeerClosed on 1.3, an alert record on 1.2), or a request carrying Connection: close.
fn serveRequests(fd: posix.fd_t, handler: HandlerFn, ctx: *const Tls.Context, conn: anytype, record_buf: []u8) !void {
    var request_plain: [request_plain_size]u8 = undefined;
    var response_buf: [response_buf_size]u8 = undefined;
    var encrypt_buf: [app_data_encrypt_out_size]u8 = undefined;
    var close_buf: [encrypted_alert_size]u8 = undefined;

    // arm the streaming sink for this connection (ADR-054): an SSE handler that called beginStream()
    // writes each event through it, encrypting one record per write. A normal handler never touches
    // it (the capture sink wins in core.writeAllFD).
    const Stream = StreamSinkFor(@TypeOf(conn));
    var stream_state = Stream{ .conn = conn, .fd = fd, .enc = &encrypt_buf };
    const prev_stream = core.tl_tls_stream;
    var stream_sink = core.TlsStreamSink{ .ctx = &stream_state, .writeFn = Stream.write };
    core.tl_tls_stream = &stream_sink;
    defer core.tl_tls_stream = prev_stream;

    while (true) {
        const request_rec = readRecord(fd, record_buf) catch |err| {
            // the peer hung up between requests (no close_notify): a clean keep-alive end.
            if (err == error.ConnectionClosed) return;

            return err;
        };
        if (request_rec.content_type == content_type_alert) return; // peer close_notify / alert: done.
        if (request_rec.content_type != content_type_application_data) return error.UnexpectedRecord;

        const request = conn.readAppData(request_rec.full, &request_plain) catch |err| {
            // client close_notify arrives as an inner alert -> PeerClosed: a clean end.
            if (err == error.PeerClosed) return;

            // a post-handshake handshake message (renegotiation / KeyUpdate) is unexpected_message (RFC 8446 5.1).
            if (comptime @hasDecl(@TypeOf(conn.*), "encryptedAlert")) {
                if (err == error.UnexpectedMessage) {
                    var alert_buf: [encrypted_alert_size]u8 = undefined;
                    writeAllFD(fd, conn.encryptedAlert(.UNEXPECTED_MESSAGE, &alert_buf)) catch {};
                }
            }

            return err;
        };

        const parsed = core.parseHead(request) catch return error.BadRequest;
        const head = parsed.head;
        const body = request[parsed.body_offset..];

        // RFC 9110 7.4: a request for an authority this cert does not serve is a misdirected request.
        // Match the Host (port stripped) against the cert SAN (DNS or IP), respond 421 on a mismatch.
        if (hostFromHead(request[0..parsed.body_offset])) |host_raw| {
            const host = stripPort(host_raw);
            Tls.verifyCertIdentity(ctx.cert_der, host) catch {
                const misdirected = "HTTP/1.1 421 Misdirected Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                writeAllFD(fd, conn.writeAppData(misdirected, &encrypt_buf)) catch {};
                writeAllFD(fd, conn.closeNotify(&close_buf)) catch {};

                return;
            };
        }

        const result = try runHandlerToBuffer(handler, &head, body, &response_buf, core.tl_static_io orelse undefined);

        if (core.takeWebSocket()) |handoff| {
            // WebSocket upgrade over TLS (ADR-055): the 101 was already sent through the stream sink.
            // Run the inline frame loop over this TLS session, then close.
            serveWsTls(conn, fd, handoff.on_frame, record_buf) catch {};
            writeAllFD(fd, conn.closeNotify(&close_buf)) catch {};

            return;
        }

        if (result.streamed) {
            // the handler streamed the whole response over TLS (already encrypted + sent through the
            // stream sink). The stream owns the rest of the connection, so close after it returns.
            writeAllFD(fd, conn.closeNotify(&close_buf)) catch {};

            return;
        }

        try writeAllFD(fd, conn.writeAppData(result.bytes, &encrypt_buf));

        // honor Connection: close (and the HTTP/1.0 default): close_notify, then end the connection.
        if (!head.keep_alive) {
            writeAllFD(fd, conn.closeNotify(&close_buf)) catch {};

            return;
        }
    }
}

/// Drive a WebSocket session over the established TLS connection (ADR-055). Each iteration reads one
/// ciphertext record, decrypts it, accumulates the plaintext, and pumps every complete frame: a
/// text / binary frame invokes on_frame, ping is auto-ponged, close is auto-echoed. Outbound frames
/// flow through the ADR-054 stream sink (writeAllFD -> conn.writeAppData), so each pump pass encrypts
/// its coalesced frames as one record. Ends on a peer hangup, a close frame, or a close_notify.
fn serveWsTls(conn: anytype, fd: posix.fd_t, on_frame: core.WsFrameFn, record_buf: []u8) !void {
    var acc: [ws_acc_size]u8 = undefined;
    var acc_len: usize = 0;
    var plain_temp: [ws_record_plain_size]u8 = undefined;
    var payload_buf: [ws_payload_size]u8 = undefined;
    var out_buf: [ws_out_size]u8 = undefined;

    while (true) {
        const rec = readRecord(fd, record_buf) catch |err| {
            if (err == error.ConnectionClosed) return; // peer hung up

            return err;
        };
        if (rec.content_type == content_type_alert) return; // peer close_notify
        if (rec.content_type != content_type_application_data) return error.UnexpectedRecord;

        const plain = conn.readAppData(rec.full, &plain_temp) catch |err| {
            if (err == error.PeerClosed) return; // client close_notify

            return err;
        };
        if (acc_len + plain.len > acc.len) return error.WsFrameTooLarge;
        @memcpy(acc[acc_len..][0..plain.len], plain);
        acc_len += plain.len;

        const result = ws.pump(fd, acc[0..acc_len], &payload_buf, &out_buf, on_frame);

        // slide any trailing partial frame down for the next record.
        const remaining = acc_len - result.consumed;
        if (remaining > 0) std.mem.copyForwards(u8, acc[0..remaining], acc[result.consumed..acc_len]);
        acc_len = remaining;

        if (result.close) return;
    }
}

/// The Host header value (RFC 9112 3.2) from a request head, or null when absent.
pub fn hostFromHead(head: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "host")) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }

    return null;
}

/// Strip the ":port" suffix from a Host value, leaving the authority host. Handles a bracketed IPv6
/// literal ([::1]:443 -> ::1) and host:port (localhost:443 -> localhost), leaves bare hosts as-is.
pub fn stripPort(host: []const u8) []const u8 {
    if (host.len == 0) return host;

    if (host[0] == '[') {
        if (std.mem.indexOfScalar(u8, host, ']')) |close| return host[1..close];

        return host;
    }

    // a single colon means host:port (a bare IPv6 literal has several colons, leave it intact).
    if (std.mem.indexOfScalar(u8, host, ':')) |first| {
        if (std.mem.lastIndexOfScalar(u8, host, ':').? == first) return host[0..first];
    }

    return host;
}

/// TLS 1.2 path (RFC 5246 + 5288, ECDHE-ECDSA): the two-phase handshake via tls12_connection, then
/// one application request like the 1.3 path. Reached only when the client did not offer 1.3. The
/// 1.2 ephemeral reuses the same random bytes (reduced to a P-256 scalar inside the engine).
fn serveConnTls12(fd: posix.fd_t, handler: HandlerFn, ctx: *const Tls.Context, key_pair: EcdsaP256.KeyPair, client_hello: []const u8, ephemeral_secret: [32]u8, server_random: [32]u8) !void {
    var flight_out: [server_flight_out_size]u8 = undefined;
    const flight = try tls12.serverFlight1(.{
        .certificate_der = ctx.cert_der,
        .signing_key = key_pair,
        .server_eph_secret = ephemeral_secret,
        .server_random = server_random,
        .alpn_prefs = ctx.alpn,
    }, client_hello, &flight_out);
    try writeAllFD(fd, flight.to_send);
    var state = flight.state;

    var record_buf: [record.max_record_wire]u8 = undefined;

    // ClientKeyExchange (plaintext handshake record), copied out before record_buf is reused.
    const cke_rec = try readRecord(fd, &record_buf);
    if (cke_rec.content_type != content_type_handshake) return error.UnexpectedRecord;
    var cke_buf: [client_key_exchange_size]u8 = undefined;
    if (cke_rec.body.len > cke_buf.len) return error.RecordTooLarge;
    @memcpy(cke_buf[0..cke_rec.body.len], cke_rec.body);
    const client_key_exchange = cke_buf[0..cke_rec.body.len];

    // skip ChangeCipherSpec, then the encrypted client Finished (a handshake record).
    const finished_rec = while (true) {
        const rec = try readRecord(fd, &record_buf);
        if (rec.content_type == content_type_change_cipher_spec) continue;
        if (rec.content_type == content_type_alert) return peerAlert(rec.body);
        if (rec.content_type != content_type_handshake) return error.UnexpectedRecord;

        break rec;
    };

    var finish_out: [server_finished_out_size]u8 = undefined;
    const finish = try tls12.serverFinish(&state, client_key_exchange, finished_rec.full, &finish_out);
    try writeAllFD(fd, finish.to_send);
    var conn = finish.connection;

    // keep-alive request loop over the established 1.2 session.
    try serveRequests(fd, handler, ctx, &conn, &record_buf);
}

/// The sentinel fd handed to the handler while a response sink is installed: its writeAllFD
/// calls match the sink by this fd and append to the buffer, they never touch a real descriptor.
const sink_fd: posix.fd_t = -1;

/// One handler outcome: the buffered plaintext response, or the streamed flag when the handler took
/// the streaming path (beginStream / SSE) over TLS. When `streamed` is true the response was already
/// encrypted and sent through the stream sink, so `bytes` is empty and the caller closes.
pub const HandlerResult = struct {
    bytes: []const u8,
    streamed: bool = false,
};

/// Run the handler with a response sink installed, returning the plaintext response it wrote into
/// `out`. The handler's writeAllFD appends to `out` directly (core.tl_resp_sink), so there is no
/// pipe2 / read / close per request, just an in-memory copy. An overflowing response (the sink would
/// flush to the sentinel fd, which fails) surfaces as error.ResponseTooLarge.
///
/// Note:
/// - A streaming handler calls beginStream(), which detaches the capture sink. With the stream sink
///   armed it already streamed over TLS (ADR-054), reported as streamed = true.
pub fn runHandlerToBuffer(handler: HandlerFn, head: *const core.ParsedHead, body: []const u8, out: []u8, io: std.Io) !HandlerResult {
    var sink = core.RespSink{ .fd = sink_fd, .buf = out };
    const prev = core.tl_resp_sink;
    core.tl_resp_sink = &sink;
    defer core.tl_resp_sink = prev;

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    core.invokeHandler(handler, head, body, sink_fd, io, arena.allocator());

    if (core.tl_resp_sink != &sink) {
        if (core.tl_tls_stream != null) return .{ .bytes = &.{}, .streamed = true };

        return error.StreamingNotSupported;
    }
    if (sink.failed) return error.ResponseTooLarge;

    return .{ .bytes = out[0..sink.len], .streamed = false };
}

/// Per-connection streaming state behind the type-erased core.TlsStreamSink (ADR-054). Generic over
/// the connection so the TLS 1.3 and 1.2 paths share one implementation: write encrypts one record
/// from `plaintext` and sends it straight to the socket, the streaming counterpart of writeAppData.
fn StreamSinkFor(comptime Conn: type) type {
    return struct {
        conn: Conn,
        fd: posix.fd_t,
        enc: []u8,

        fn write(ctx_ptr: *anyopaque, plaintext: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));

            const encrypted = self.conn.writeAppData(plaintext, self.enc);
            writeAllFD(self.fd, encrypted) catch return false;

            return true;
        }
    };
}

// --------------------------------------------------------------- //

const Record = struct {
    content_type: u8,
    full: []const u8,
    body: []const u8,
};

fn readRecord(fd: posix.fd_t, buf: []u8) !Record {
    try readAll(fd, buf[0..5]);

    const length = std.mem.readInt(u16, buf[3..5], .big);
    if (5 + length > buf.len) return error.RecordTooLarge;

    try readAll(fd, buf[5 .. 5 + length]);

    return .{ .content_type = buf[0], .full = buf[0 .. 5 + length], .body = buf[5 .. 5 + length] };
}

fn readAll(fd: posix.fd_t, buf: []u8) !void {
    var read: usize = 0;
    while (read < buf.len) {
        const chunk = buf[read..];
        const rc = linux.read(fd, chunk.ptr, chunk.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (rc == 0) return error.ConnectionClosed;
        read += rc;
    }
}

fn writeAllFD(fd: posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const chunk = bytes[written..];
        const rc = linux.write(fd, chunk.ptr, chunk.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.WriteFailed,
        }
        written += rc;
    }
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: tls_serve, stripPort strips host:port and bracketed ipv6" {
    try std.testing.expectEqualStrings("localhost", stripPort("localhost:9060"));
    try std.testing.expectEqualStrings("localhost", stripPort("localhost"));
    try std.testing.expectEqualStrings("127.0.0.1", stripPort("127.0.0.1:443"));
    try std.testing.expectEqualStrings("::1", stripPort("[::1]:443")); // bracketed ipv6 -> inside
    try std.testing.expectEqualStrings("::1", stripPort("::1")); // bare ipv6 left intact
}

test "zix test: tls_serve, hostFromHead extracts the Host header" {
    const head = "GET / HTTP/1.1\r\nUser-Agent: x\r\nHost: localhost:9060\r\nAccept: */*\r\n\r\n";
    try std.testing.expectEqualStrings("localhost:9060", hostFromHead(head).?);

    const no_host = "GET / HTTP/1.1\r\nAccept: */*\r\n\r\n";
    try std.testing.expect(hostFromHead(no_host) == null);
}

/// Test handler: write a fixed 200 response, ignoring the request (keep-alive loop exercise).
fn keepAliveTestHandler(_: *core.Request, res: *core.Response, _: *core.Context) anyerror!void {
    try res.sendRaw("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
}

/// Test-only fixture: the localhost ECDSA P-256 cert DER (SAN localhost + 127.0.0.1), in hex. Public so
/// the event-driven tls_mux tests reuse the same identity without a third copy of the literal.
pub const fixture_cert_hex = "308201d43082017ba00302010202147a26ee491f091ac7c914f4a810c1ece713402574300a06082a8648ce3d040302302a3112301006035504030c096c6f63616c686f737431143012060355040a0c0b7a69782d746c732d706f63301e170d3236303632323132353432305a170d3336303631393132353432305a302a3112301006035504030c096c6f63616c686f737431143012060355040a0c0b7a69782d746c732d706f633059301306072a8648ce3d020106082a8648ce3d03010703420004c2a0121b298ac9cd389200e78d94e7bde1cc7cd8074795fab4f919799d40fdc231c5a90990ac8c6166ae472f33f74fced097f2edb7b8a1974be66a4ab07f253ba37f307d301d0603551d0e04160414c34e1d0a36a43947709b539e16dd0213aa4196aa301f0603551d23041830168014c34e1d0a36a43947709b539e16dd0213aa4196aa300f0603551d130101ff040530030101ff301a0603551d110413301182096c6f63616c686f737487047f000001300e0603551d0f0101ff040403020780300a06082a8648ce3d040302034700304402200b012f119db9b95d990bc482cb63e8f81e337a08634904e4caf513dc10c8aa8302202fdfe79ff6d5403e753ddf2aa52671923b8a2c28126bcbf196bd6fb7ecbcb14e";

/// Test-only fixture: the secret key paired with fixture_cert_hex, in hex.
pub const fixture_key_hex = "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c";

test "zix test: tls_serve, keep-alive serves many requests then honors Connection: close" {
    const client = @import("../../tls/client.zig");
    const context = @import("../../tls/context.zig");

    // server identity from the fixture cert + its secret key.
    var skey: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&skey, fixture_key_hex);
    const server_key = try EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(skey));
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, fixture_cert_hex);

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

    const Srv = struct {
        fn run(fd: posix.fd_t, server_ctx: *const Tls.Context) void {
            serveConnTls(fd, keepAliveTestHandler, server_ctx) catch {};

            _ = linux.close(fd);
        }
    };
    const t = try std.Thread.spawn(.{}, Srv.run, .{ server_fd, &ctx });
    defer t.join();

    // client handshake: ClientHello wrapped in a plaintext handshake record, then the server flight.
    var ch_buf: [512]u8 = undefined;
    const started = try client.start(.{ .client_random = @splat(0x11), .ephemeral_secret = @splat(0x42) }, &ch_buf);
    var state = started.state;

    var ch_rec: [600]u8 = undefined;
    ch_rec[0] = content_type_handshake;
    std.mem.writeInt(u16, ch_rec[1..3], 0x0303, .big);
    std.mem.writeInt(u16, ch_rec[3..5], @intCast(started.client_hello.len), .big);
    @memcpy(ch_rec[5 .. 5 + started.client_hello.len], started.client_hello);
    try writeAllFD(client_fd, ch_rec[0 .. 5 + started.client_hello.len]);

    var flight_buf: [4096]u8 = undefined;
    var flen: usize = 0;
    for (0..3) |_| {
        const rec = try readRecord(client_fd, flight_buf[flen..]);
        flen += rec.full.len;
    }

    var fin_buf: [256]u8 = undefined;
    var finished = try client.finish(&state, flight_buf[0..flen], &fin_buf);
    try writeAllFD(client_fd, finished.client_finished);

    // three requests on the one connection: two keep-alive, then Connection: close. All three must
    // get a 200 over the SAME session (no re-handshake), proving keep-alive.
    const requests = [_][]const u8{
        "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "GET /b HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "GET /c HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
    };
    for (requests) |req| {
        var enc: [512]u8 = undefined;
        try writeAllFD(client_fd, finished.connection.writeAppData(req, &enc));

        var resp_rec: [1024]u8 = undefined;
        const rec = try readRecord(client_fd, &resp_rec);
        var plain: [1024]u8 = undefined;
        const resp = try finished.connection.readAppData(rec.full, &plain);
        try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    }

    // after Connection: close the server sends one close_notify record (TLS 1.3 wraps the alert as
    // application_data) and then closes, so the next read hits EOF.
    var tail_rec: [256]u8 = undefined;
    const tail = try readRecord(client_fd, &tail_rec);
    try std.testing.expectEqual(content_type_application_data, tail.content_type);

    var eof_rec: [64]u8 = undefined;
    try std.testing.expectError(error.ConnectionClosed, readRecord(client_fd, &eof_rec));
}

/// Test handler: an SSE stream that opts in via beginStream(), then writes one event and returns.
fn sseTestHandler(req: *core.Request, _: *core.Response, _: *core.Context) anyerror!void {
    core.beginStream();
    core.writeAllFD(req.fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n") catch return;
    core.writeAllFD(req.fd, "data: hello\n\n") catch return;
}

/// Capture stream sink for the test: a streaming handler's writes land in `buf` instead of a socket.
const CaptureStream = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn write(ctx_ptr: *anyopaque, plaintext: []const u8) bool {
        const self: *CaptureStream = @ptrCast(@alignCast(ctx_ptr));

        @memcpy(self.buf[self.len..][0..plaintext.len], plaintext);
        self.len += plaintext.len;

        return true;
    }
};

test "zix test: tls_serve, runHandlerToBuffer streams over TLS when the stream sink is armed" {
    var capture = CaptureStream{};
    var stream_sink = core.TlsStreamSink{ .ctx = &capture, .writeFn = CaptureStream.write };
    const prev = core.tl_tls_stream;
    core.tl_tls_stream = &stream_sink;
    defer core.tl_tls_stream = prev;

    const req = "GET /events HTTP/1.1\r\nHost: x\r\n\r\n";
    const parsed = try core.parseHead(req);

    var out: [4096]u8 = undefined;

    // beginStream() detaches the capture sink, so both writes route through the stream sink.
    const result = try runHandlerToBuffer(sseTestHandler, &parsed.head, req[parsed.body_offset..], &out, undefined);
    try std.testing.expect(result.streamed);
    try std.testing.expect(std.mem.indexOf(u8, capture.buf[0..capture.len], "text/event-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.buf[0..capture.len], "data: hello") != null);
}

fn wsNoopFrame(fd: posix.fd_t, opcode: u8, payload: []const u8) void {
    _ = fd;
    _ = opcode;
    _ = payload;
}

test "zix test: tls_serve, serveTls encrypts the 101 through the stream sink and registers the handoff" {
    var capture = CaptureStream{};
    var stream_sink = core.TlsStreamSink{ .ctx = &capture, .writeFn = CaptureStream.write };
    const prev = core.tl_tls_stream;
    core.tl_tls_stream = &stream_sink;
    defer core.tl_tls_stream = prev;

    // the 101 routes through the stream sink (encrypted over TLS in production), the handoff is set.
    try ws.serveTls(-1, "dGhlIHNhbXBsZSBub25jZQ==", wsNoopFrame);
    try std.testing.expect(std.mem.indexOf(u8, capture.buf[0..capture.len], "101 Switching Protocols") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.buf[0..capture.len], "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);

    const handoff = core.takeWebSocket();
    try std.testing.expect(handoff != null);
}
