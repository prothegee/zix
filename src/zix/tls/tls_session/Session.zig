//! ZIX tls session
//!
//! ### file: src/zix/tls/tls_session/Session.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One resumable TLS 1.3 server session over tlz. Ciphertext goes in as it
//! arrives, handshake flights and decrypted plaintext come out. No socket calls.
//!
//! ### note:
//!
//! TLS 1.3 only: a 1.2-only ClientHello gets a fatal alert. The thread per
//! connection path (tls_serve) keeps TLS 1.2 for the .ASYNC model.
//! The identity (cert, key, ALPN) is borrowed and must outlive the session.
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
const tlz = @import("tlz");
const Phase = @import("phase.zig").Phase;
const Outcome = @import("outcome.zig").Outcome;
const FeedResult = @import("FeedResult.zig");

const PssSalt = @FieldType(tlz.HandshakeOptions, "pss_salt");

// --------------------------------------------------------- //
// Fields:

/// The end-entity certificate DER, borrowed.
cert_der: []const u8,
/// The CertificateVerify key, borrowed.
signing_key: tlz.SigningKey,
/// Server ALPN preference order, borrowed.
alpn_prefs: []const tlz.Alpn,

phase: Phase = .HELLO,
/// Valid once the phase reaches FINISHED.
conn: tlz.Connection = undefined,
/// ALPN picked h2. Valid once established.
alpn_h2: bool = false,

/// Fresh per connection (RFC 8446).
ephemeral: [32]u8 = undefined,
server_random: [32]u8 = undefined,
pss_salt: PssSalt = undefined,

/// Ciphertext waits here until at least one whole record is present.
rbuf: [tlz.MAX_RECORD_WIRE]u8 = undefined,
rlen: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Server handshake flight assembly buffer.
const SERVER_FLIGHT_BUF: usize = 12 * 1024;

/// Bytes of a record header (type, version, length).
const RECORD_HEADER_LEN: usize = 5;

const CONTENT_CHANGE_CIPHER_SPEC: u8 = @intFromEnum(tlz.ContentType.CHANGE_CIPHER_SPEC);
const CONTENT_HANDSHAKE: u8 = @intFromEnum(tlz.ContentType.HANDSHAKE);
const CONTENT_APPLICATION_DATA: u8 = @intFromEnum(tlz.ContentType.APPLICATION_DATA);

fn handshakeOptions(self: *const Self) tlz.HandshakeOptions {
    return .{
        .certificate_der = self.cert_der,
        .signing_key = self.signing_key,
        .ephemeral_secret = self.ephemeral,
        .server_random = self.server_random,
        .pss_salt = self.pss_salt,
        .alpn_prefs = self.alpn_prefs,
    };
}

/// The full length (header + payload) of the record at the front of buf.
///
/// Return:
/// - usize (the record length)
/// - null when a whole record is not buffered yet
fn recordLen(buf: []const u8) ?usize {
    if (buf.len < RECORD_HEADER_LEN) return null;

    const length = (@as(usize, buf[3]) << 8) | buf[4];
    if (buf.len < RECORD_HEADER_LEN + length) return null;

    return RECORD_HEADER_LEN + length;
}

/// Append src into dst at offset at.
///
/// Return:
/// - usize (bytes written, 0 when src does not fit)
fn appendInto(dst: []u8, at: usize, src: []const u8) usize {
    if (at + src.len > dst.len) return 0;

    @memcpy(dst[at..][0..src.len], src);

    return src.len;
}

/// Answer the ClientHello record body. A rejected hello appends a fatal alert
/// and moves the phase to CLOSED.
///
/// Return:
/// - usize (bytes appended to to_send_buf)
fn onHello(self: *Self, body: []const u8, to_send_buf: []u8, at: usize) usize {
    var flight: [SERVER_FLIGHT_BUF]u8 = undefined;

    const result = tlz.serverHandshake(self.handshakeOptions(), body, &flight) catch |err| {
        switch (err) {
            // No usable 1.3 offer or a rejected ClientHello: fatal alert, then close.
            else => {
                self.phase = .CLOSED;

                var alert: [tlz.FATAL_RECORD_LEN]u8 = undefined;
                const failure = error.Tlz_Connection_HandshakeFailure;
                const bytes = tlz.alertRecordForError(&alert, failure) orelse return 0;

                return appendInto(to_send_buf, at, bytes);
            },
        }
    };

    self.conn = result.connection;
    self.alpn_h2 = result.alpn == .H2;
    self.phase = .FINISHED;

    return appendInto(to_send_buf, at, result.to_send);
}

// --------------------------------------------------------- //
// Public:

/// Start a session for a freshly accepted connection.
///
/// Param:
/// io - std.Io (the CSPRNG for the per-connection randoms)
/// cert_der - []const u8 (borrowed certificate DER)
/// signing_key - tlz.SigningKey (the key matching the certificate)
/// alpn_prefs - []const tlz.Alpn (borrowed server ALPN order)
///
/// Return:
/// - Self
pub fn init(
    io: std.Io,
    cert_der: []const u8,
    signing_key: tlz.SigningKey,
    alpn_prefs: []const tlz.Alpn,
) Self {
    var self: Self = .{
        .cert_der = cert_der,
        .signing_key = signing_key,
        .alpn_prefs = alpn_prefs,
    };
    io.random(&self.ephemeral);
    io.random(&self.server_random);
    io.random(&self.pss_salt);

    return self;
}

/// Whether ALPN selected h2. Only meaningful once established.
pub fn alpnIsH2(self: *const Self) bool {
    return self.alpn_h2;
}

/// Ciphertext bytes this session can take in one feed.
///
/// Note:
/// - The reassembly buffer holds one record. A caller that reads into a wider
///   buffer must size its read by this, or a busy socket hands over two records
///   at once and feed closes the connection.
/// - 0 means a record larger than the buffer is being reassembled, which
///   cannot complete.
///
/// Return:
/// - usize (bytes feed accepts right now)
pub fn readRoom(self: *const Self) usize {
    return self.rbuf.len - self.rlen;
}

/// Feed received ciphertext. Drains every complete record now buffered: drives
/// the handshake, then decrypts application data.
///
/// Note:
/// - Never hand this more than readRoom() bytes. Past that the session closes,
///   because dropping part of the input would desynchronize the record stream.
///
/// Param:
/// input - []const u8 (ciphertext as received)
/// to_send_buf - []u8 (collects handshake flights and alerts)
/// plain_buf - []u8 (collects decrypted plaintext)
///
/// Return:
/// - FeedResult (slices point into to_send_buf and plain_buf)
pub fn feed(self: *Self, input: []const u8, to_send_buf: []u8, plain_buf: []u8) FeedResult {
    if (self.phase == .CLOSED) return .{ .outcome = .CLOSE };

    if (input.len > self.rbuf.len - self.rlen) {
        self.phase = .CLOSED;

        return .{ .outcome = .CLOSE };
    }

    @memcpy(self.rbuf[self.rlen..][0..input.len], input);
    self.rlen += input.len;

    var to_send_len: usize = 0;
    var plain_len: usize = 0;
    var outcome: Outcome = .OK;
    var off: usize = 0;

    while (recordLen(self.rbuf[off..self.rlen])) |rec_len| {
        const rec = self.rbuf[off .. off + rec_len];
        const content_type = rec[0];
        const body = rec[RECORD_HEADER_LEN..];

        switch (self.phase) {
            .HELLO => {
                if (content_type != CONTENT_HANDSHAKE) {
                    outcome = .CLOSE;
                    break;
                }

                to_send_len += self.onHello(body, to_send_buf, to_send_len);
                if (self.phase == .CLOSED) {
                    outcome = .CLOSE;
                    break;
                }
            },
            .FINISHED => {
                if (content_type == CONTENT_CHANGE_CIPHER_SPEC) {
                    off += rec_len;
                    continue;
                }
                if (content_type != CONTENT_APPLICATION_DATA) {
                    outcome = .CLOSE;
                    break;
                }

                self.conn.verifyClientFinished(rec) catch |err| switch (err) {
                    else => {
                        outcome = .CLOSE;
                        break;
                    },
                };
                self.phase = .ESTABLISHED;
                outcome = .ESTABLISHED;
            },
            .ESTABLISHED => {
                if (content_type != CONTENT_APPLICATION_DATA) {
                    outcome = .CLOSE;
                    break;
                }

                const plain = self.conn.readAppData(rec, plain_buf[plain_len..]) catch |err| {
                    switch (err) {
                        else => {
                            outcome = .CLOSE;
                            break;
                        },
                    }
                };
                plain_len += plain.len;
            },
            .CLOSED => break,
        }

        off += rec_len;
    }

    // Drop the consumed records, keep a partial record tail for the next feed.
    if (off > 0 and off <= self.rlen) {
        std.mem.copyForwards(u8, self.rbuf[0 .. self.rlen - off], self.rbuf[off..self.rlen]);
        self.rlen -= off;
    }

    if (outcome == .CLOSE) self.phase = .CLOSED;

    return .{
        .to_send = to_send_buf[0..to_send_len],
        .plaintext = plain_buf[0..plain_len],
        .outcome = outcome,
    };
}

/// Encrypt response plaintext into one or more application_data records
/// (RFC 8446 5.2).
///
/// Note:
/// - A record carries at most tlz.MAX_PLAINTEXT bytes, so a longer response is
///   split. Size out with tlz.sealedLen.
/// - All or nothing: an out too small for every record seals nothing, because a
///   peer reads a truncated body as a complete one.
///
/// Param:
/// plaintext - []const u8 (whole response bytes, any length)
/// out - []u8 (must hold tlz.sealedLen(plaintext.len) bytes)
///
/// Return:
/// - []const u8 (every sealed record, back to back)
/// - empty when out cannot hold them all
pub fn encrypt(self: *Self, plaintext: []const u8, out: []u8) []const u8 {
    if (out.len < tlz.sealedLen(plaintext.len)) return out[0..0];

    var rest = plaintext;
    var written: usize = 0;

    while (true) {
        const take = @min(rest.len, tlz.MAX_PLAINTEXT);
        const sealed = self.conn.writeAppData(rest[0..take], out[written..]);
        if (sealed.len == 0) return out[0..0];

        written += sealed.len;
        rest = rest[take..];

        if (rest.len == 0) break;
    }

    return out[0..written];
}

/// Gather form of encrypt: seal a staged prefix and a source tail as one
/// application_data record, without copying the tail first.
///
/// Note:
/// - ONE record, so prefix.len + tail.len must be at most tlz.MAX_PLAINTEXT.
///   Use encrypt for a payload that has to be split.
///
/// Return:
/// - []const u8 (the sealed record)
/// - empty when the two slices exceed one record or out cannot hold it
pub fn encrypt2(self: *Self, prefix: []const u8, tail: []const u8, out: []u8) []const u8 {
    return self.conn.writeAppData2(prefix, tail, out);
}

/// The close_notify alert record, sent before closing a healthy connection.
pub fn closeNotify(self: *Self, out: []u8) []const u8 {
    return self.conn.closeNotify(out);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const CERT_PATH = "examples/certs/ecdsa_p256_cert.pem";
const KEY_PATH = "examples/certs/ecdsa_p256_key.pem";

const TestPair = struct {
    session: Self,
    client_conn: tlz.Client.ClientConnection,
};

fn testContext() !tlz.Context {
    return tlz.Context.init(std.testing.allocator, std.testing.io, .{
        .cert_path = CERT_PATH,
        .key_path = KEY_PATH,
        .alpn = &.{.H2},
    });
}

/// Wrap a payload as a record of content_type into out.
fn wrapRecord(content_type: u8, payload: []const u8, out: []u8) []const u8 {
    out[0] = content_type;
    out[1] = 0x03;
    out[2] = 0x03;
    std.mem.writeInt(u16, out[3..5], @intCast(payload.len), .big);
    @memcpy(out[RECORD_HEADER_LEN..][0..payload.len], payload);

    return out[0 .. RECORD_HEADER_LEN + payload.len];
}

fn startClient(hello_buf: []u8) !tlz.Client.StartResult {
    return tlz.Client.start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
        .alpn = &.{.H2},
    }, hello_buf);
}

/// Drive a session to ESTABLISHED and hand back both ends.
fn establishedPair(ctx: *const tlz.Context) !TestPair {
    var session = Self.init(std.testing.io, ctx.cert_der, ctx.signing_key, ctx.alpn);

    var hello_buf: [512]u8 = undefined;
    const started = try startClient(&hello_buf);
    var state = started.state;

    var hello_rec: [600]u8 = undefined;
    const hello_record = wrapRecord(CONTENT_HANDSHAKE, started.client_hello, &hello_rec);

    var to_send: [16 * 1024]u8 = undefined;
    var plain: [4096]u8 = undefined;
    const flight = session.feed(hello_record, &to_send, &plain);

    var fin_buf: [256]u8 = undefined;
    const finished = try tlz.Client.finish(&state, flight.to_send, &fin_buf);
    _ = session.feed(finished.client_finished, &to_send, &plain);

    return .{
        .session = session,
        .client_conn = finished.connection,
    };
}

test "zix tls: Session, drives a full 1.3 handshake" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session = Self.init(std.testing.io, ctx.cert_der, ctx.signing_key, ctx.alpn);

    var hello_buf: [512]u8 = undefined;
    const started = try startClient(&hello_buf);
    var state = started.state;

    var hello_rec: [600]u8 = undefined;
    const hello_record = wrapRecord(CONTENT_HANDSHAKE, started.client_hello, &hello_rec);

    var to_send: [16 * 1024]u8 = undefined;
    var plain: [4096]u8 = undefined;
    const flight = session.feed(hello_record, &to_send, &plain);

    try std.testing.expectEqual(Outcome.OK, flight.outcome);
    try std.testing.expect(flight.to_send.len > 0);
    try std.testing.expectEqual(Phase.FINISHED, session.phase);

    var fin_buf: [256]u8 = undefined;
    const finished = try tlz.Client.finish(&state, flight.to_send, &fin_buf);
    const done = session.feed(finished.client_finished, &to_send, &plain);

    try std.testing.expectEqual(Outcome.ESTABLISHED, done.outcome);
    try std.testing.expect(session.alpnIsH2());
}

test "zix tls: Session, decrypts client application data" {
    var ctx = try testContext();
    defer ctx.deinit();

    var pair = try establishedPair(&ctx);

    var c2s_buf: [256]u8 = undefined;
    const c2s = pair.client_conn.writeAppData("ping from client", &c2s_buf);

    var to_send: [1024]u8 = undefined;
    var plain: [1024]u8 = undefined;
    const result = pair.session.feed(c2s, &to_send, &plain);

    try std.testing.expectEqual(Outcome.OK, result.outcome);
    try std.testing.expectEqualStrings("ping from client", result.plaintext);
}

test "zix tls: Session, encrypt reaches the client" {
    var ctx = try testContext();
    defer ctx.deinit();

    var pair = try establishedPair(&ctx);

    var sealed: [256]u8 = undefined;
    const wire = pair.session.encrypt("small", &sealed);

    try std.testing.expectEqual(tlz.sealedLen("small".len), wire.len);

    var plain_buf: [256]u8 = undefined;
    const opened = try pair.client_conn.readAppData(wire, &plain_buf);

    try std.testing.expectEqualStrings("small", opened);
}

test "zix tls: Session, encrypt splits a response past one record" {
    var ctx = try testContext();
    defer ctx.deinit();

    var pair = try establishedPair(&ctx);

    const body_len = tlz.MAX_PLAINTEXT * 3 + 1234;
    const body = try std.testing.allocator.alloc(u8, body_len);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*byte, index| byte.* = @intCast(index % 251);

    const sealed = try std.testing.allocator.alloc(u8, tlz.sealedLen(body_len));
    defer std.testing.allocator.free(sealed);

    const wire = pair.session.encrypt(body, sealed);
    try std.testing.expectEqual(tlz.sealedLen(body_len), wire.len);

    const reassembled = try std.testing.allocator.alloc(u8, body_len);
    defer std.testing.allocator.free(reassembled);

    var offset: usize = 0;
    var filled: usize = 0;
    var records: usize = 0;
    var plain_buf: [tlz.MAX_PLAINTEXT + 1]u8 = undefined;
    while (offset < wire.len) {
        const one_len = recordLen(wire[offset..]).?;
        const opened = try pair.client_conn.readAppData(wire[offset..][0..one_len], &plain_buf);
        @memcpy(reassembled[filled..][0..opened.len], opened);
        filled += opened.len;
        records += 1;
        offset += one_len;
    }

    try std.testing.expectEqual(@as(usize, 4), records);
    try std.testing.expectEqualSlices(u8, body, reassembled[0..filled]);
}

test "zix tls: Session, encrypt seals nothing when out is one byte short" {
    var ctx = try testContext();
    defer ctx.deinit();

    var pair = try establishedPair(&ctx);

    const body_len = tlz.MAX_PLAINTEXT * 2;
    const body = try std.testing.allocator.alloc(u8, body_len);
    defer std.testing.allocator.free(body);
    @memset(body, 'z');

    const tight = try std.testing.allocator.alloc(u8, tlz.sealedLen(body_len) - 1);
    defer std.testing.allocator.free(tight);

    try std.testing.expectEqual(@as(usize, 0), pair.session.encrypt(body, tight).len);
}

test "zix tls: Session, holds a fragmented record until it completes" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session = Self.init(std.testing.io, ctx.cert_der, ctx.signing_key, ctx.alpn);

    var hello_buf: [512]u8 = undefined;
    const started = try startClient(&hello_buf);

    var hello_rec: [600]u8 = undefined;
    const hello_record = wrapRecord(CONTENT_HANDSHAKE, started.client_hello, &hello_rec);

    var to_send: [16 * 1024]u8 = undefined;
    var plain: [4096]u8 = undefined;

    const partial = session.feed(hello_record[0 .. hello_record.len - 1], &to_send, &plain);
    try std.testing.expectEqual(@as(usize, 0), partial.to_send.len);
    try std.testing.expectEqual(Phase.HELLO, session.phase);

    const rest = session.feed(hello_record[hello_record.len - 1 ..], &to_send, &plain);
    try std.testing.expect(rest.to_send.len > 0);
    try std.testing.expectEqual(Phase.FINISHED, session.phase);
}

test "zix tls: Session, non-handshake first record closes" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session = Self.init(std.testing.io, ctx.cert_der, ctx.signing_key, ctx.alpn);

    var rec_buf: [16]u8 = undefined;
    const rec = wrapRecord(CONTENT_APPLICATION_DATA, "x", &rec_buf);

    var to_send: [64]u8 = undefined;
    var plain: [64]u8 = undefined;
    const result = session.feed(rec, &to_send, &plain);

    try std.testing.expectEqual(Outcome.CLOSE, result.outcome);
    try std.testing.expectEqual(Phase.CLOSED, session.phase);
}

test "zix tls: Session, malformed ClientHello sends a fatal alert" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session = Self.init(std.testing.io, ctx.cert_der, ctx.signing_key, ctx.alpn);

    var rec_buf: [16]u8 = undefined;
    const rec = wrapRecord(CONTENT_HANDSHAKE, "\x01\x00\x00\x01\x00", &rec_buf);

    var to_send: [64]u8 = undefined;
    var plain: [64]u8 = undefined;
    const result = session.feed(rec, &to_send, &plain);

    try std.testing.expectEqual(Outcome.CLOSE, result.outcome);
    try std.testing.expectEqual(tlz.FATAL_RECORD_LEN, result.to_send.len);
}

test "zix tls: Session, input past readRoom closes" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session = Self.init(std.testing.io, ctx.cert_der, ctx.signing_key, ctx.alpn);

    const big = try std.testing.allocator.alloc(u8, session.readRoom() + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 0);

    var to_send: [64]u8 = undefined;
    var plain: [64]u8 = undefined;
    const result = session.feed(big, &to_send, &plain);

    try std.testing.expectEqual(Outcome.CLOSE, result.outcome);
}

test "zix tls: Session, closed session keeps answering CLOSE" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session = Self.init(std.testing.io, ctx.cert_der, ctx.signing_key, ctx.alpn);
    session.phase = .CLOSED;

    var to_send: [64]u8 = undefined;
    var plain: [64]u8 = undefined;
    const result = session.feed("", &to_send, &plain);

    try std.testing.expectEqual(Outcome.CLOSE, result.outcome);
}

test "zix tls: Session, readRoom shrinks with a buffered partial record" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session = Self.init(std.testing.io, ctx.cert_der, ctx.signing_key, ctx.alpn);
    const full = session.readRoom();

    var to_send: [64]u8 = undefined;
    var plain: [64]u8 = undefined;
    _ = session.feed("\x16\x03", &to_send, &plain);

    try std.testing.expectEqual(full - 2, session.readRoom());
}

