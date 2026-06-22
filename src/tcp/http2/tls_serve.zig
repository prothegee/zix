//! zix http2 https serve path (h2 over TLS 1.3, RFC 8446 + 7540 + 7301 ALPN).
//!
//! Note:
//! - Gated on config.tls_cert_path. A blocking accept loop does the TLS 1.3 handshake via zix.Tls,
//!   negotiating ALPN from config.tls_alpn (h2 for HTTP/2 over TLS). It then terminates TLS in
//!   front of the EXISTING h2c engine: a socketpair carries plaintext, the engine runs unchanged
//!   on one end (core.serveConn, it thinks it speaks h2c to a socket), and a poll loop pumps
//!   inbound (decrypt the client record -> plaintext) and outbound (engine frames -> encrypt).
//! - This reuses the whole h2c frame state machine, so the cleartext dispatch models (ASYNC /
//!   POOL / MIXED) are untouched. https is a separate path on its own perf band (not the 1% gate),
//!   so the per-connection terminator thread + socketpair are acceptable here.
//! - Teardown uses shutdown(SHUT_WR) on our socketpair end rather than an abrupt close, so the
//!   engine sees EOF on its read and finishes without a write racing a closed peer (no SIGPIPE).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const core = @import("core.zig");
const Route = core.Route;
const Http2ServerConfig = @import("config.zig").Http2ServerConfig;
const common = @import("dispatch/common.zig");
const Tls = @import("../../tls/Tls.zig");
const pem = @import("../../tls/pem.zig");

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

const content_type_change_cipher_spec: u8 = 20;
const content_type_handshake: u8 = 22;
const content_type_application_data: u8 = 23;

const max_plaintext: usize = 16 * 1024;

/// Load the cert + key, listen, and serve h2 over TLS 1.3 (blocking accept loop). Routes are baked
/// in at compile time, so the per-connection engine thread is generated per route table.
pub fn runTls(comptime routes: []const Route, config: Http2ServerConfig) !void {
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

    common.logSystem(config, "listening on {s}:{d} (h2, TLS 1.3)", .{ config.ip, config.port });

    const opts = common.serveOpts(config);

    while (true) {
        var stream = srv.accept(io) catch continue;
        defer stream.close(io);

        serveConnTls(routes, stream.socket.handle, config, opts, cert_der, key_pair) catch {};
    }
}

/// Per-connection engine thread: runs the unchanged h2c state machine on the plaintext socketpair
/// end. Closing that end is the terminator's job (after the pump drains), so this only serves.
fn Terminator(comptime routes: []const Route) type {
    return struct {
        const EngineCtx = struct {
            inner_fd: posix.fd_t,
            opts: core.ServeOpts,
        };

        fn engineEntry(ctx: EngineCtx) void {
            core.serveConn(routes, ctx.inner_fd, ctx.opts);
        }
    };
}

fn serveConnTls(
    comptime routes: []const Route,
    fd: posix.fd_t,
    config: Http2ServerConfig,
    opts: core.ServeOpts,
    cert_der: []const u8,
    key_pair: EcdsaP256.KeyPair,
) !void {
    var record_buf: [17 * 1024]u8 = undefined;

    // ClientHello (a plaintext handshake record carries the message in its body).
    const client_hello_rec = try readRecord(fd, &record_buf);
    if (client_hello_rec.content_type != content_type_handshake) return error.UnexpectedRecord;

    var ephemeral_secret: [32]u8 = undefined;
    var server_random: [32]u8 = undefined;
    _ = linux.getrandom(&ephemeral_secret, ephemeral_secret.len, 0);
    _ = linux.getrandom(&server_random, server_random.len, 0);

    var handshake_out: [8192]u8 = undefined;
    const result = try Tls.serverHandshake(.{
        .certificate_der = cert_der,
        .signing_key = key_pair,
        .ephemeral_secret = ephemeral_secret,
        .server_random = server_random,
        .alpn_prefs = config.tls_alpn,
    }, client_hello_rec.body, &handshake_out);
    try writeAll(fd, result.to_send);
    var conn = result.connection;

    // h2 over TLS requires ALPN to have selected h2 (RFC 7540 3.3). Without it, end the connection
    // rather than guess the application protocol.
    if (result.alpn != .H2) return error.AlpnNotH2;

    // client ChangeCipherSpec (skipped) + Finished.
    while (true) {
        const rec = try readRecord(fd, &record_buf);
        if (rec.content_type == content_type_change_cipher_spec) continue;
        if (rec.content_type != content_type_application_data) return error.UnexpectedRecord;

        try conn.verifyClientFinished(rec.full);
        break;
    }

    // socketpair: the engine runs h2c on inner_fd[1], the pump owns inner_fd[0].
    var pair: [2]posix.fd_t = undefined;
    if (posix.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair)) != .SUCCESS) return error.SocketpairFailed;
    const pump_fd = pair[0];
    const engine_fd = pair[1];

    var engine_thread = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, Terminator(routes).engineEntry, .{
        Terminator(routes).EngineCtx{ .inner_fd = engine_fd, .opts = opts },
    }) catch {
        _ = linux.close(pump_fd);
        _ = linux.close(engine_fd);
        return error.SpawnFailed;
    };

    pump(fd, pump_fd, &conn, &record_buf);

    // EOF the engine's read side so it finishes, drain its remaining output, then join + close.
    _ = linux.shutdown(pump_fd, linux.SHUT.WR);
    drain(pump_fd);
    engine_thread.join();
    _ = linux.close(pump_fd);

    var close_buf: [64]u8 = undefined;
    writeAll(fd, conn.closeNotify(&close_buf)) catch {};
}

/// Full-duplex relay between the TLS socket (fd) and the plaintext engine end (pump_fd): decrypt
/// inbound client records to plaintext, encrypt outbound engine bytes into records. Returns when
/// either side closes (client FIN / close_notify, or the engine closes its end).
fn pump(fd: posix.fd_t, pump_fd: posix.fd_t, conn: *Tls.Connection, record_buf: []u8) void {
    var plain_in: [max_plaintext]u8 = undefined;
    var plain_out: [max_plaintext]u8 = undefined;
    var encrypt_buf: [17 * 1024]u8 = undefined;

    var fds = [2]linux.pollfd{
        .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = pump_fd, .events = linux.POLL.IN, .revents = 0 },
    };

    while (true) {
        fds[0].revents = 0;
        fds[1].revents = 0;
        if (posix.errno(linux.poll(&fds, fds.len, -1)) != .SUCCESS) return;

        // inbound: one client record -> decrypt -> plaintext to the engine.
        if (fds[0].revents & linux.POLL.IN != 0) {
            const rec = readRecord(fd, record_buf) catch return;
            if (rec.content_type == content_type_change_cipher_spec) {
                // ignore a stray mid-stream ChangeCipherSpec
            } else if (rec.content_type == content_type_application_data) {
                const plain = conn.readAppData(rec.full, &plain_in) catch return;
                writeAll(pump_fd, plain) catch return;
            } else return;
        }
        if (fds[0].revents & (linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL) != 0) return;

        // outbound: engine bytes -> encrypt into a record -> the TLS socket.
        if (fds[1].revents & linux.POLL.IN != 0) {
            const rc = linux.read(pump_fd, &plain_out, plain_out.len);
            switch (posix.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return,
            }
            if (rc == 0) return;
            writeAll(fd, conn.writeAppData(plain_out[0..rc], &encrypt_buf)) catch return;
        }
        if (fds[1].revents & (linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL) != 0) return;
    }
}

/// Discard whatever the engine still writes after we shut its read side, until it closes (EOF).
fn drain(pump_fd: posix.fd_t) void {
    var scratch: [4096]u8 = undefined;
    while (true) {
        const rc = linux.read(pump_fd, &scratch, scratch.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return,
        }
        if (rc == 0) return;
    }
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
