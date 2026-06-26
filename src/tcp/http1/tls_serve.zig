//! zix http1 https serve path (approach A, RFC 8446 + 9112).
//!
//! Note:
//! - Gated on config.tls (a *Tls.Context). A blocking accept loop reads the ClientHello, then
//!   branches on the version policy: a 1.3-capable client takes the TLS 1.3 path (zix.Tls), a
//!   1.2-only client takes the TLS 1.2 path (zix.Tls tls12_connection), each subject to the
//!   context's min_version / max_version. Either way it then per request decrypts the record,
//!   reuses core.parseHead, runs the existing fd-handler against a pipe (so the handler writes
//!   plaintext unchanged), reads that back, encrypts it, and sends it.
//! - The cleartext EPOLL / URING hot path is untouched: this whole file is reached only when
//!   config.tls is set (gated in server.zig before the dispatch switch). https is a separate path
//!   on its own perf band (not the 1% gate), so the per-request pipe is acceptable.
//! - The cert / key are loaded and validated once in Tls.Context.init (the cold path), so the
//!   accept loop reads a ready context with no per-connection PEM work.
//! - Single request per connection for now (keep-alive is a later refinement).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Config = @import("config.zig").Http1ServerConfig;
const core = @import("core.zig");
const common = @import("dispatch/common.zig");
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

/// A plaintext alert arriving mid-handshake (the peer aborted): parse it (RFC 8446 6) and signal a
/// clean teardown so the accept loop closes the connection rather than misreading it as a record.
fn peerAlert(body: []const u8) anyerror {
    _ = Tls.parseInboundAlert(body) catch {};

    return error.PeerAlert;
}

/// Listen and serve https/1.1 (blocking accept loop). The cert / key / policy are already loaded and
/// validated in the context (config.tls), so this only accepts and drives per-connection handshakes.
pub fn runTls(config: Config, handler: HandlerFn) !void {
    const io = config.io;
    const ctx = config.tls.?;

    const addr = try std.Io.net.IpAddress.resolve(io, config.ip, config.port);
    var srv = try addr.listen(io, .{ .reuse_address = true });

    common.logSystem(config, "listening on {s}:{d} (https/1.1)", .{ config.ip, config.port });

    while (true) {
        var stream = srv.accept(io) catch continue;
        defer stream.close(io);

        serveConnTls(stream.socket.handle, handler, ctx) catch {};
    }
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
            try writeAll(fd, retry.to_send);

            const ch2_rec = try readRecord(fd, &record_buf);
            if (ch2_rec.content_type != content_type_handshake) return error.UnexpectedRecord;

            retry_state = retry.state;
            second_hello = ch2_rec.body;
        }
    } else |err| {
        // a malformed / non-1.3 ClientHello: 1.2 falls through to serverHandshake, else alert + close.
        if (err != error.UnsupportedTlsVersion) {
            var alert_buf: [Tls.fatal_record_len]u8 = undefined;
            if (Tls.alertRecordForError(&alert_buf, err)) |rec| writeAll(fd, rec) catch {};

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
                    if (Tls.alertRecordForError(&ver_alert, err)) |rec| writeAll(fd, rec) catch {};

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
            if (Tls.alertRecordForError(&alert_buf, err)) |rec| writeAll(fd, rec) catch {};

            return err;
        };
    try writeAll(fd, result.to_send);
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

    // one application request -> decrypt -> parse -> handler (over a pipe) -> encrypt response.
    const request_rec = try readRecord(fd, &record_buf);
    if (request_rec.content_type != content_type_application_data) return error.UnexpectedRecord;

    var request_plain: [request_plain_size]u8 = undefined;
    const request = conn.readAppData(request_rec.full, &request_plain) catch |err| {
        // a post-handshake handshake message (renegotiation / KeyUpdate) is unexpected_message (RFC 8446 5.1).
        if (err == error.UnexpectedMessage) {
            var alert_buf: [encrypted_alert_size]u8 = undefined;
            writeAll(fd, conn.encryptedAlert(.UNEXPECTED_MESSAGE, &alert_buf)) catch {};
        }

        return err;
    };

    const parsed = core.parseHead(request) catch return error.BadRequest;
    const head = parsed.head;
    const body = request[parsed.body_offset..];

    var encrypt_buf: [app_data_encrypt_out_size]u8 = undefined;
    var close_buf: [encrypted_alert_size]u8 = undefined;

    // RFC 9110 7.4: a request for an authority this cert does not serve is a misdirected request.
    // Match the Host (port stripped) against the cert SAN (DNS or IP), respond 421 on a mismatch.
    if (hostFromHead(request[0..parsed.body_offset])) |host_raw| {
        const host = stripPort(host_raw);
        Tls.verifyCertIdentity(ctx.cert_der, host) catch {
            const misdirected = "HTTP/1.1 421 Misdirected Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            writeAll(fd, conn.writeAppData(misdirected, &encrypt_buf)) catch {};
            writeAll(fd, conn.closeNotify(&close_buf)) catch {};

            return;
        };
    }

    var response_buf: [response_buf_size]u8 = undefined;
    const response = try runHandlerToBuffer(handler, &head, body, &response_buf);

    try writeAll(fd, conn.writeAppData(response, &encrypt_buf));

    try writeAll(fd, conn.closeNotify(&close_buf));
}

/// The Host header value (RFC 9112 3.2) from a request head, or null when absent.
fn hostFromHead(head: []const u8) ?[]const u8 {
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
fn stripPort(host: []const u8) []const u8 {
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
    try writeAll(fd, flight.to_send);
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
    try writeAll(fd, finish.to_send);
    var conn = finish.connection;

    // one application request -> decrypt -> parse -> handler (over a pipe) -> encrypt response.
    const request_rec = try readRecord(fd, &record_buf);
    if (request_rec.content_type != content_type_application_data) return error.UnexpectedRecord;

    var request_plain: [request_plain_size]u8 = undefined;
    const request = try conn.readAppData(request_rec.full, &request_plain);

    const parsed = core.parseHead(request) catch return error.BadRequest;
    const head = parsed.head;
    const body = request[parsed.body_offset..];

    var response_buf: [response_buf_size]u8 = undefined;
    const response = try runHandlerToBuffer(handler, &head, body, &response_buf);

    var encrypt_buf: [app_data_encrypt_out_size]u8 = undefined;
    try writeAll(fd, conn.writeAppData(response, &encrypt_buf));

    var close_buf: [encrypted_alert_size]u8 = undefined;
    writeAll(fd, conn.closeNotify(&close_buf)) catch {};
}

/// Run the fd-handler against a pipe, returning the plaintext response it wrote. The handler
/// writes to the pipe write end unchanged, then it is closed so the read end drains to EOF.
fn runHandlerToBuffer(handler: HandlerFn, head: *const core.ParsedHead, body: []const u8, out: []u8) ![]const u8 {
    var pipe_fds: [2]i32 = undefined;
    if (posix.errno(linux.pipe2(&pipe_fds, .{})) != .SUCCESS) return error.PipeFailed;
    defer _ = linux.close(pipe_fds[0]);

    handler(head, body, pipe_fds[1]);
    _ = linux.close(pipe_fds[1]);

    var len: usize = 0;
    while (len < out.len) {
        const rc = linux.read(pipe_fds[0], out[len..].ptr, out.len - len);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (rc == 0) break;
        len += rc;
    }

    return out[0..len];
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

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
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
