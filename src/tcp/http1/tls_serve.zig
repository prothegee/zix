//! zix http1 https serve path (approach A, RFC 8446 + 9112).
//!
//! Note:
//! - Gated on config.tls_cert_path. A blocking accept loop reads the ClientHello, then branches on
//!   version: a 1.3-capable client takes the TLS 1.3 path (zix.Tls), a 1.2-only client takes the
//!   TLS 1.2 path (zix.Tls tls12_connection). Either way it then per request decrypts the record,
//!   reuses core.parseHead, runs the existing fd-handler against a pipe (so the handler writes
//!   plaintext unchanged), reads that back, encrypts it, and sends it.
//! - The cleartext EPOLL / URING hot path is untouched: this whole file is reached only when
//!   config.tls_cert_path is set (gated in server.zig before the dispatch switch). https is a
//!   separate path on its own perf band (not the 1% gate), so the per-request pipe is acceptable.
//! - Single request per connection for now (keep-alive is a later refinement).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Config = @import("config.zig").Http1ServerConfig;
const core = @import("core.zig");
const common = @import("dispatch/common.zig");
const Tls = @import("../../tls/Tls.zig");
const tls12 = @import("../../tls/tls12_connection.zig");
const pem = @import("../../tls/pem.zig");

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const HandlerFn = core.HandlerFn;

const content_type_change_cipher_spec: u8 = 20;
const content_type_handshake: u8 = 22;
const content_type_application_data: u8 = 23;

/// Load the cert + key, listen, and serve https/1.1 over TLS 1.3 (blocking accept loop).
pub fn runTls(config: Config, handler: HandlerFn) !void {
    const io = config.io;
    const allocator = std.heap.smp_allocator;

    const cert_pem = try std.Io.Dir.cwd().readFileAlloc(io, config.tls_cert_path.?, allocator, .limited(1 << 20));
    defer allocator.free(cert_pem);
    var cert_der_buf: [4096]u8 = undefined;
    const cert_der = try pem.pemToDer(&cert_der_buf, cert_pem);

    const key_pem = try std.Io.Dir.cwd().readFileAlloc(io, config.tls_key_path.?, allocator, .limited(1 << 20));
    defer allocator.free(key_pem);
    var key_der_buf: [512]u8 = undefined;
    const key_der = try pem.pemToDer(&key_der_buf, key_pem);
    const scalar = try pem.ecdsaScalarFromSec1(key_der);
    const key_pair = try EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(scalar));

    const addr = try std.Io.net.IpAddress.resolve(io, config.ip, config.port);
    var srv = try addr.listen(io, .{ .reuse_address = true });

    common.logSystem(config, "listening on {s}:{d} (https/1.1, TLS 1.3)", .{ config.ip, config.port });

    while (true) {
        var stream = srv.accept(io) catch continue;
        defer stream.close(io);

        serveConnTls(stream.socket.handle, handler, cert_der, key_pair) catch {};
    }
}

fn serveConnTls(fd: posix.fd_t, handler: HandlerFn, cert_der: []const u8, key_pair: EcdsaP256.KeyPair) !void {
    var record_buf: [17 * 1024]u8 = undefined;

    // ClientHello (a plaintext handshake record carries the message in its body).
    const client_hello_rec = try readRecord(fd, &record_buf);
    if (client_hello_rec.content_type != content_type_handshake) return error.UnexpectedRecord;

    var ephemeral_secret: [32]u8 = undefined;
    var server_random: [32]u8 = undefined;
    _ = linux.getrandom(&ephemeral_secret, ephemeral_secret.len, 0);
    _ = linux.getrandom(&server_random, server_random.len, 0);

    var handshake_out: [8192]u8 = undefined;
    const result = Tls.serverHandshake(.{
        .certificate_der = cert_der,
        .signing_key = .{ .ecdsa_p256 = key_pair },
        .ephemeral_secret = ephemeral_secret,
        .server_random = server_random,
    }, client_hello_rec.body, &handshake_out) catch |err| {
        // no 1.3 offer -> the client is TLS 1.2 (the minimum floor), take the 1.2 path.
        if (err == error.UnsupportedTlsVersion) {
            return serveConnTls12(fd, handler, cert_der, key_pair, client_hello_rec.body, ephemeral_secret, server_random);
        }

        // any other rejected ClientHello: send the fatal alert in the clear (no keys yet), then close.
        var alert_buf: [Tls.fatal_record_len]u8 = undefined;
        if (Tls.alertRecordForError(&alert_buf, err)) |rec| writeAll(fd, rec) catch {};

        return err;
    };
    try writeAll(fd, result.to_send);
    var conn = result.connection;

    // client ChangeCipherSpec (skipped) + Finished.
    while (true) {
        const rec = try readRecord(fd, &record_buf);
        if (rec.content_type == content_type_change_cipher_spec) continue;
        if (rec.content_type != content_type_application_data) return error.UnexpectedRecord;

        try conn.verifyClientFinished(rec.full);
        break;
    }

    // one application request -> decrypt -> parse -> handler (over a pipe) -> encrypt response.
    const request_rec = try readRecord(fd, &record_buf);
    if (request_rec.content_type != content_type_application_data) return error.UnexpectedRecord;

    var request_plain: [17 * 1024]u8 = undefined;
    const request = try conn.readAppData(request_rec.full, &request_plain);

    const parsed = core.parseHead(request) catch return error.BadRequest;
    const head = parsed.head;
    const body = request[parsed.body_offset..];

    var response_buf: [64 * 1024]u8 = undefined;
    const response = try runHandlerToBuffer(handler, &head, body, &response_buf);

    var encrypt_buf: [70 * 1024]u8 = undefined;
    try writeAll(fd, conn.writeAppData(response, &encrypt_buf));

    var close_buf: [64]u8 = undefined;
    try writeAll(fd, conn.closeNotify(&close_buf));
}

/// TLS 1.2 path (RFC 5246 + 5288, ECDHE-ECDSA): the two-phase handshake via tls12_connection, then
/// one application request like the 1.3 path. Reached only when the client did not offer 1.3. The
/// 1.2 ephemeral reuses the same random bytes (reduced to a P-256 scalar inside the engine).
fn serveConnTls12(fd: posix.fd_t, handler: HandlerFn, cert_der: []const u8, key_pair: EcdsaP256.KeyPair, client_hello: []const u8, ephemeral_secret: [32]u8, server_random: [32]u8) !void {
    var flight_out: [8192]u8 = undefined;
    const flight = try tls12.serverFlight1(.{
        .certificate_der = cert_der,
        .signing_key = key_pair,
        .server_eph_secret = ephemeral_secret,
        .server_random = server_random,
    }, client_hello, &flight_out);
    try writeAll(fd, flight.to_send);
    var state = flight.state;

    var record_buf: [17 * 1024]u8 = undefined;

    // ClientKeyExchange (plaintext handshake record), copied out before record_buf is reused.
    const cke_rec = try readRecord(fd, &record_buf);
    if (cke_rec.content_type != content_type_handshake) return error.UnexpectedRecord;
    var cke_buf: [256]u8 = undefined;
    if (cke_rec.body.len > cke_buf.len) return error.RecordTooLarge;
    @memcpy(cke_buf[0..cke_rec.body.len], cke_rec.body);
    const client_key_exchange = cke_buf[0..cke_rec.body.len];

    // skip ChangeCipherSpec, then the encrypted client Finished (a handshake record).
    const finished_rec = while (true) {
        const rec = try readRecord(fd, &record_buf);
        if (rec.content_type == content_type_change_cipher_spec) continue;
        if (rec.content_type != content_type_handshake) return error.UnexpectedRecord;

        break rec;
    };

    var finish_out: [256]u8 = undefined;
    const finish = try tls12.serverFinish(&state, client_key_exchange, finished_rec.full, &finish_out);
    try writeAll(fd, finish.to_send);
    var conn = finish.connection;

    // one application request -> decrypt -> parse -> handler (over a pipe) -> encrypt response.
    const request_rec = try readRecord(fd, &record_buf);
    if (request_rec.content_type != content_type_application_data) return error.UnexpectedRecord;

    var request_plain: [17 * 1024]u8 = undefined;
    const request = try conn.readAppData(request_rec.full, &request_plain);

    const parsed = core.parseHead(request) catch return error.BadRequest;
    const head = parsed.head;
    const body = request[parsed.body_offset..];

    var response_buf: [64 * 1024]u8 = undefined;
    const response = try runHandlerToBuffer(handler, &head, body, &response_buf);

    var encrypt_buf: [70 * 1024]u8 = undefined;
    try writeAll(fd, conn.writeAppData(response, &encrypt_buf));

    var close_buf: [64]u8 = undefined;
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
