//! TLZ dtls client
//!
//! ### file: src/tlz/src/dtls/client.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! DTLS 1.2 client handshake (RFC 6347), ECDHE-ECDSA with AES-128-GCM, sans-I/O: the
//! mirror of `connection.zig`. Write a ClientHello twice, then answer the server flight.
//!
//! ### note:
//!
//! Not certificate validating: the ServerKeyExchange signature is not checked against
//! the certificate, because the peer is identified by a fingerprint carried out of
//! band (RFC 8122), and that check belongs with whatever carried it. Every message is
//! sent unfragmented, so the bytes written are the form the transcript hashes.
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
const Reader = @import("../wire/Reader.zig");
const prf = @import("../tls12/prf.zig");
const record = @import("record.zig");
const handshake = @import("handshake.zig");
const hello = @import("hello.zig");
const connection = @import("connection.zig");

const P256 = std.crypto.ecc.P256;
const Sha256 = std.crypto.hash.sha2.Sha256;

// --------------------------------------------------------- //
// Private:

const ECCURVE_TYPE_NAMED_CURVE: u8 = 3;

/// message_seq is per side and counts every handshake message that side sends. The
/// first ClientHello is 0, the cookie-bearing one is 1, and only that one enters the
/// transcript.
const SEQ_CLIENT_HELLO_FIRST: u16 = 0;
const SEQ_CLIENT_HELLO_WITH_COOKIE: u16 = 1;
const SEQ_CLIENT_KEY_EXCHANGE: u16 = 2;
const SEQ_CLIENT_FINISHED: u16 = 3;
const SEQ_SERVER_HELLO: u16 = 1;
const SEQ_CERTIFICATE: u16 = 2;
const SEQ_SERVER_KEY_EXCHANGE: u16 = 3;
const SEQ_SERVER_HELLO_DONE: u16 = 4;

/// The 32 random bytes a ServerHello carries, right after the version.
fn readServerRandom(server_hello: []const u8) Error![32]u8 {
    if (server_hello.len < 2 + 32) return Error.Tlz_DtlsClient_ServerFlightInvalid;

    return server_hello[2..34].*;
}

fn readServerPointInner(key_exchange: []const u8) (Error || Reader.Error)![]const u8 {
    var reader: Reader = .{ .buf = key_exchange };

    const curve_type = try reader.readU8();
    if (curve_type != ECCURVE_TYPE_NAMED_CURVE) return Error.Tlz_DtlsClient_ServerFlightInvalid;

    _ = try reader.readU16();

    return reader.readBytes(try reader.readU8());
}

/// The server's ephemeral point out of a ServerKeyExchange body (RFC 8422 5.4).
fn readServerPoint(key_exchange: []const u8) Error![]const u8 {
    return readServerPointInner(key_exchange) catch |err| switch (err) {
        error.Tlz_WireReader_Truncated => Error.Tlz_DtlsClient_Truncated,
        error.Tlz_DtlsClient_NoSpace,
        error.Tlz_DtlsClient_ServerFlightInvalid,
        error.Tlz_DtlsClient_BadKeyExchange,
        error.Tlz_DtlsClient_NoHandshakeInProgress,
        error.Tlz_DtlsClient_Truncated,
        error.Tlz_DtlsClient_BadHello,
        error.Tlz_DtlsClient_BadRecord,
        => |own| own,
    };
}

/// Hash one handshake message the way RFC 6347 4.2.6 requires: the 12-byte header
/// with the fragment fields set as if the message had been sent whole, then the body.
fn updateTranscript(
    transcript: *Sha256,
    msg_type: handshake.MessageType,
    message_seq: u16,
    body: []const u8,
) void {
    var header: [handshake.HEADER_LEN]u8 = undefined;

    handshake.writeHeader(&header, .{
        .msg_type = msg_type,
        .length = @intCast(body.len),
        .message_seq = message_seq,
        .fragment_offset = 0,
        .fragment_length = @intCast(body.len),
    });

    transcript.update(&header);
    transcript.update(body);
}

fn transcriptHash(state: *const State) [32]u8 {
    var copy = state.transcript;
    var hash: [32]u8 = undefined;
    copy.final(&hash);

    return hash;
}

/// Reduce 32 random bytes to a valid P-256 scalar. fromBytes48 reduces mod n.
fn reduceP256Scalar(seed: [32]u8) [32]u8 {
    var wide: [48]u8 = std.mem.zeroes([48]u8);
    @memcpy(wide[16..48], &seed);

    return P256.scalar.Scalar.fromBytes48(wide, .big).toBytes(.big);
}

/// The ECDHE pre-master secret: the x coordinate of scalar * peer point.
fn ecdheSharedX(scalar: [32]u8, peer_public: []const u8) Error![32]u8 {
    const peer = P256.fromSec1(peer_public) catch |err| switch (err) {
        else => return Error.Tlz_DtlsClient_BadKeyExchange,
    };
    const shared = peer.mul(scalar, .big) catch |err| switch (err) {
        error.IdentityElement => return Error.Tlz_DtlsClient_BadKeyExchange,
    };

    return shared.affineCoordinates().x.toBytes(.big);
}

/// Write an epoch 0 plaintext record.
fn writePlainRecord(
    out: []u8,
    content_type: record.ContentType,
    sequence_number: u48,
    fragment: []const u8,
) Error![]const u8 {
    const epoch = connection.EPOCH_HANDSHAKE;
    const seq = sequence_number;
    const written = record.writePlaintext(out, content_type, epoch, seq, fragment);

    return written catch |err| switch (err) {
        error.Tlz_DtlsRecord_BadRecord => Error.Tlz_DtlsClient_BadRecord,
    };
}

/// Frame one whole handshake message into `message_buf`.
fn wholeMessage(
    message_buf: []u8,
    msg_type: handshake.MessageType,
    message_seq: u16,
    body: []const u8,
) Error![]const u8 {
    var fragmenter: handshake.Fragmenter = .{
        .msg_type = msg_type,
        .message_seq = message_seq,
        .body = body,
        .max_fragment_len = @max(body.len, 1),
    };

    return fragmenter.next(message_buf) orelse Error.Tlz_DtlsClient_NoSpace;
}

// --------------------------------------------------------- //
// Public:

pub const Options = @import("client/Options.zig");
pub const ServerFlight = @import("client/ServerFlight.zig");
pub const State = @import("client/State.zig");
pub const ClientConnection = @import("client/ClientConnection.zig");
pub const FinishResult = @import("client/FinishResult.zig");

pub const Error = error{
    Tlz_DtlsClient_NoSpace,
    Tlz_DtlsClient_ServerFlightInvalid,
    Tlz_DtlsClient_BadKeyExchange,
    Tlz_DtlsClient_NoHandshakeInProgress,
    Tlz_DtlsClient_Truncated,
    Tlz_DtlsClient_BadHello,
    Tlz_DtlsClient_BadRecord,
};

/// The one suite this path implements, matching the server half.
pub const CIPHER_ECDHE_ECDSA_AES128_GCM_SHA256: u16 =
    connection.CIPHER_ECDHE_ECDSA_AES128_GCM_SHA256;

/// Largest ClientHello body this client builds, which caps the cookie it can carry.
pub const MAX_HELLO_BODY: usize = 512;

/// Bytes a Finished message carries (RFC 5246 7.4.9).
pub const VERIFY_DATA_LEN: usize = prf.VERIFY_DATA_LENGTH;

/// Begin a handshake.
///
/// Param:
/// options - Options (the client's material for this handshake)
///
/// Return:
/// - State (with an empty transcript)
pub fn start(options: Options) State {
    return .{
        .client_random = options.client_random,
        .client_eph_scalar = reduceP256Scalar(options.client_eph_secret),
        .transcript = Sha256.init(.{}),
        .next_record_seq = 0,
        .max_fragment_len = options.max_fragment_len,
        .hello_body = undefined,
        .hello_len = 0,
    };
}

/// Write a ClientHello as one record (RFC 6347 4.2.4 flights 1 and 3).
///
/// Note:
/// - An empty cookie is the first hello, which neither side hashes. A cookie-bearing
///   hello opens the transcript, and it is kept so `finish` can hash it.
///
/// Param:
/// state - *State (advanced in place)
/// cookie - []const u8 (empty for the first hello, the HelloVerifyRequest cookie next)
/// out - []u8 (destination for the record)
///
/// Return:
/// - []const u8 (one DTLS record, borrowing `out`)
/// - Error.Tlz_DtlsClient_BadHello when the cookie is over `hello.MAX_COOKIE_LEN`
/// - Error.Tlz_DtlsClient_NoSpace when the message cannot be framed
/// - Error.Tlz_DtlsClient_BadRecord when `out` cannot hold the record
pub fn writeHello(state: *State, cookie: []const u8, out: []u8) Error![]const u8 {
    var body_buf: [MAX_HELLO_BODY]u8 = undefined;
    const body = hello.writeClientHelloBody(
        &body_buf,
        record.VERSION_DTLS_1_2,
        state.client_random,
        "",
        cookie,
        &.{CIPHER_ECDHE_ECDSA_AES128_GCM_SHA256},
    ) catch |err| switch (err) {
        error.Tlz_DtlsHello_BadHello => return Error.Tlz_DtlsClient_BadHello,
    };
    const has_cookie = cookie.len > 0;
    const message_seq = if (has_cookie) SEQ_CLIENT_HELLO_WITH_COOKIE else SEQ_CLIENT_HELLO_FIRST;

    if (has_cookie) {
        @memcpy(state.hello_body[0..body.len], body);
        state.hello_len = body.len;
    }

    var message_buf: [MAX_HELLO_BODY + handshake.HEADER_LEN]u8 = undefined;
    const message = try wholeMessage(&message_buf, .CLIENT_HELLO, message_seq, body);
    const rec = try writePlainRecord(out, .HANDSHAKE, state.next_record_seq, message);
    state.next_record_seq += 1;

    return rec;
}

/// Answer the server flight: derive the keys, then send ClientKeyExchange,
/// ChangeCipherSpec, and the client Finished (RFC 6347 4.2.4 flight 5).
///
/// Note:
/// - The ServerKeyExchange signature is not verified here, see the file note.
/// - ChangeCipherSpec is not a handshake message. It takes no message_seq and never
///   enters the transcript (RFC 6347 4.2.5).
///
/// Param:
/// state - *State (from writeHello with a cookie, advanced in place)
/// flight - ServerFlight (the four bodies, headers stripped)
/// out - []u8 (destination for the three records)
///
/// Return:
/// - FinishResult (records to send, the verify data to expect, the connection)
/// - Error.Tlz_DtlsClient_NoHandshakeInProgress before a cookie hello was written
/// - Error.Tlz_DtlsClient_ServerFlightInvalid when a server message is not the
///   expected shape
/// - Error.Tlz_DtlsClient_Truncated when the ServerKeyExchange is cut short
/// - Error.Tlz_DtlsClient_BadKeyExchange when the server point is invalid
/// - Error.Tlz_DtlsClient_NoSpace when a message cannot be framed
/// - Error.Tlz_DtlsClient_BadRecord when `out` cannot hold the records
pub fn finish(state: *State, flight: ServerFlight, out: []u8) Error!FinishResult {
    if (state.hello_len == 0) return Error.Tlz_DtlsClient_NoHandshakeInProgress;

    const server_random = try readServerRandom(flight.server_hello);
    const server_point = try readServerPoint(flight.key_exchange);
    const client_base = P256.basePoint.mul(state.client_eph_scalar, .big) catch |err| {
        return switch (err) {
            error.IdentityElement => Error.Tlz_DtlsClient_BadKeyExchange,
        };
    };
    const client_point = client_base.toUncompressedSec1();
    const key_exchange_body = [_]u8{client_point.len} ++ client_point;

    // Both sides hash the same six messages, each with its unfragmented header.
    const transcript = &state.transcript;
    const cke = &key_exchange_body;
    const ske = flight.key_exchange;
    updateTranscript(transcript, .CLIENT_HELLO, SEQ_CLIENT_HELLO_WITH_COOKIE, state.helloBody());
    updateTranscript(transcript, .SERVER_HELLO, SEQ_SERVER_HELLO, flight.server_hello);
    updateTranscript(transcript, .CERTIFICATE, SEQ_CERTIFICATE, flight.certificate);
    updateTranscript(transcript, .SERVER_KEY_EXCHANGE, SEQ_SERVER_KEY_EXCHANGE, ske);
    updateTranscript(transcript, .SERVER_HELLO_DONE, SEQ_SERVER_HELLO_DONE, flight.hello_done);
    updateTranscript(transcript, .CLIENT_KEY_EXCHANGE, SEQ_CLIENT_KEY_EXCHANGE, cke);

    const pre_master = try ecdheSharedX(state.client_eph_scalar, server_point);
    const master = prf.masterSecret(&pre_master, state.client_random, server_random);
    const km = prf.keyMaterial(master, state.client_random, server_random);
    const client_verify_data = prf.finishedFromHash(
        master,
        "client finished",
        transcriptHash(state),
    );

    var finished_message: [handshake.HEADER_LEN + VERIFY_DATA_LEN]u8 = undefined;
    handshake.writeHeader(&finished_message, .{
        .msg_type = .FINISHED,
        .length = VERIFY_DATA_LEN,
        .message_seq = SEQ_CLIENT_FINISHED,
        .fragment_offset = 0,
        .fragment_length = VERIFY_DATA_LEN,
    });
    @memcpy(finished_message[handshake.HEADER_LEN..], &client_verify_data);

    var message_buf: [handshake.HEADER_LEN + key_exchange_body.len]u8 = undefined;
    const key_exchange = try wholeMessage(
        &message_buf,
        .CLIENT_KEY_EXCHANGE,
        SEQ_CLIENT_KEY_EXCHANGE,
        &key_exchange_body,
    );
    var cursor: usize = 0;

    const key_exchange_record = try writePlainRecord(
        out,
        .HANDSHAKE,
        state.next_record_seq,
        key_exchange,
    );
    state.next_record_seq += 1;
    cursor += key_exchange_record.len;

    const change_cipher = try writePlainRecord(
        out[cursor..],
        .CHANGE_CIPHER_SPEC,
        state.next_record_seq,
        &.{1},
    );
    state.next_record_seq += 1;
    cursor += change_cipher.len;

    const finished = record.protect(
        out[cursor..],
        &finished_message,
        .HANDSHAKE,
        connection.EPOCH_APPLICATION,
        0,
        km.client_write_key,
        km.client_write_iv,
    ) catch |err| switch (err) {
        error.Tlz_DtlsRecord_BadRecord => return Error.Tlz_DtlsClient_BadRecord,
    };
    cursor += finished.len;

    // The server hashes the client Finished before computing its own, so this side
    // does too.
    updateTranscript(transcript, .FINISHED, SEQ_CLIENT_FINISHED, &client_verify_data);

    return .{
        .to_send = out[0..cursor],
        .server_verify_data = prf.finishedFromHash(
            master,
            "server finished",
            transcriptHash(state),
        ),
        .connection = .{ .km = km },
    };
}

/// The verify data inside a Finished message the server sent.
///
/// Param:
/// plaintext - []const u8 (an opened epoch 1 record's contents)
///
/// Return:
/// - []const u8 (the verify data, borrowing `plaintext`)
/// - null when it is not a Finished of the right length
pub fn serverFinishedVerifyData(plaintext: []const u8) ?[]const u8 {
    const header = handshake.parseHeader(plaintext) catch |err| switch (err) {
        error.Tlz_DtlsHandshake_Truncated => return null,
    };
    if (header.msg_type != .FINISHED) return null;

    const verify_data = plaintext[handshake.HEADER_LEN..];
    if (verify_data.len != VERIFY_DATA_LEN) return null;

    return verify_data;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const cookie_mod = @import("cookie.zig");

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const IpAddress = std.Io.net.IpAddress;

const TEST_PEER: IpAddress = .{
    .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = 41000,
    },
};
const TEST_DER = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };

/// Both ends of one finished exchange, with the buffers they borrow.
const TestPair = struct {
    answer: FinishResult,
    server_done: connection.FinishResult,
    server_finished_record: []const u8,
};

fn testStart() State {
    return start(.{
        .client_random = @splat(0x11),
        .client_eph_secret = @splat(0x44),
    });
}

fn testSigningKey() !EcdsaP256.KeyPair {
    var secret: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &secret,
        "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c",
    );

    return EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(secret));
}

/// The bodies of the handshake messages packed into a flight, in arrival order.
fn collectBodies(flight: []const u8, out: *[8][]const u8) !usize {
    var records: record.RecordIterator = .{ .datagram = flight };
    var count: usize = 0;

    while (try records.next()) |rec| {
        var fragments: handshake.FragmentIterator = .{
            .body = try record.plaintextFragment(rec),
        };

        while (try fragments.next()) |fragment| : (count += 1) out[count] = fragment.data;
    }

    return count;
}

/// The handshake body inside a single-message plaintext record.
fn messageBody(rec: []const u8) ![]const u8 {
    return (try record.plaintextFragment(rec))[handshake.HEADER_LEN..];
}

/// Run flights 1 to 6 between this client and the server half.
fn runPair(
    state: *State,
    bufs: *[6][4096]u8,
) !TestPair {
    const key = try testSigningKey();
    const signer = cookie_mod.Signer.init(@splat(0x5A));

    const first = try writeHello(state, "", &bufs[0]);
    const verify = try connection.serverHelloVerifyRequest(
        &signer,
        TEST_PEER,
        try hello.parseClientHello(try messageBody(first)),
        0,
        &bufs[1],
    );
    const cookie = try hello.parseHelloVerifyRequestBody(try messageBody(verify));
    const second = try writeHello(state, cookie, &bufs[2]);
    const server_flight = try connection.serverFlight(.{
        .certificate_der = &TEST_DER,
        .signing_key = key,
        .server_eph_secret = @splat(0x22),
        .server_random = @splat(0x33),
    }, try messageBody(second), &bufs[3]);
    var server_state = server_flight.state;

    var bodies: [8][]const u8 = undefined;
    _ = try collectBodies(server_flight.to_send, &bodies);

    const answer = try finish(state, .{
        .server_hello = bodies[0],
        .certificate = bodies[1],
        .key_exchange = bodies[2],
        .hello_done = bodies[3],
    }, &bufs[4]);
    var answer_records: record.RecordIterator = .{ .datagram = answer.to_send };
    const key_exchange_record = (try answer_records.next()).?;
    _ = try answer_records.next();
    const client_finished_record = (try answer_records.next()).?;

    const server_done = try connection.serverFinish(
        &server_state,
        try messageBody(key_exchange_record),
        client_finished_record,
        &bufs[5],
    );
    var finish_records: record.RecordIterator = .{ .datagram = server_done.to_send };
    _ = try finish_records.next();

    return .{
        .answer = answer,
        .server_done = server_done,
        .server_finished_record = (try finish_records.next()).?,
    };
}

test "tlz dtls: client, the first hello carries no cookie and keeps no body" {
    var state = testStart();
    var out: [512]u8 = undefined;

    const rec = try writeHello(&state, "", &out);
    const header = try record.parseHeader(rec);
    const message = try handshake.parseHeader(try record.plaintextFragment(rec));

    try std.testing.expectEqual(record.ContentType.HANDSHAKE, header.content_type);
    try std.testing.expectEqual(@as(u48, 0), header.sequence_number);
    try std.testing.expectEqual(handshake.MessageType.CLIENT_HELLO, message.msg_type);
    try std.testing.expectEqual(@as(u16, 0), message.message_seq);
    try std.testing.expectEqual(@as(usize, 0), state.hello_len);
    try std.testing.expectEqual(@as(u48, 1), state.next_record_seq);
}

test "tlz dtls: client, the cookie hello is message 1 and is kept" {
    var state = testStart();
    var out: [512]u8 = undefined;
    const cookie: [32]u8 = @splat(0xAB);

    _ = try writeHello(&state, "", &out);
    const rec = try writeHello(&state, &cookie, &out);
    const message = try handshake.parseHeader(try record.plaintextFragment(rec));

    try std.testing.expectEqual(@as(u16, 1), message.message_seq);
    try std.testing.expect(state.hello_len > 0);
}

test "tlz dtls: client, a cookie past the hello limit is a bad hello" {
    var state = testStart();
    var out: [1024]u8 = undefined;
    const cookie: [hello.MAX_COOKIE_LEN + 1]u8 = @splat(0xAB);

    try std.testing.expectError(
        Error.Tlz_DtlsClient_BadHello,
        writeHello(&state, &cookie, &out),
    );
}

test "tlz dtls: client, writeHello into a small buffer is a bad record" {
    var state = testStart();
    var out: [16]u8 = undefined;

    try std.testing.expectError(Error.Tlz_DtlsClient_BadRecord, writeHello(&state, "", &out));
}

test "tlz dtls: client, finish before a cookie hello has no handshake in progress" {
    var state = testStart();
    var out: [512]u8 = undefined;

    try std.testing.expectError(Error.Tlz_DtlsClient_NoHandshakeInProgress, finish(&state, .{
        .server_hello = "",
        .certificate = "",
        .key_exchange = "",
        .hello_done = "",
    }, &out));
}

test "tlz dtls: client, a short ServerHello is an invalid flight" {
    var state = testStart();
    var out: [512]u8 = undefined;
    const cookie: [32]u8 = @splat(0xAB);
    _ = try writeHello(&state, &cookie, &out);

    try std.testing.expectError(Error.Tlz_DtlsClient_ServerFlightInvalid, finish(&state, .{
        .server_hello = &[_]u8{ 0xFE, 0xFD },
        .certificate = "",
        .key_exchange = &[_]u8{ 3, 0, 23, 1, 0 },
        .hello_done = "",
    }, &out));
}

test "tlz dtls: client, a non named-curve ServerKeyExchange is an invalid flight" {
    var state = testStart();
    var out: [512]u8 = undefined;
    const cookie: [32]u8 = @splat(0xAB);
    const full_hello: [40]u8 = @splat(0);
    _ = try writeHello(&state, &cookie, &out);

    try std.testing.expectError(Error.Tlz_DtlsClient_ServerFlightInvalid, finish(&state, .{
        .server_hello = &full_hello,
        .certificate = "",
        .key_exchange = &[_]u8{ 1, 0, 23, 1, 0 },
        .hello_done = "",
    }, &out));
}

test "tlz dtls: client, a cut ServerKeyExchange is truncated" {
    var state = testStart();
    var out: [512]u8 = undefined;
    const cookie: [32]u8 = @splat(0xAB);
    const full_hello: [40]u8 = @splat(0);
    _ = try writeHello(&state, &cookie, &out);

    try std.testing.expectError(Error.Tlz_DtlsClient_Truncated, finish(&state, .{
        .server_hello = &full_hello,
        .certificate = "",
        .key_exchange = &[_]u8{ 3, 0, 23, 65, 4 },
        .hello_done = "",
    }, &out));
}

test "tlz dtls: client, an off-curve server point is a bad key exchange" {
    var state = testStart();
    var out: [512]u8 = undefined;
    const cookie: [32]u8 = @splat(0xAB);
    const full_hello: [40]u8 = @splat(0);
    _ = try writeHello(&state, &cookie, &out);

    try std.testing.expectError(Error.Tlz_DtlsClient_BadKeyExchange, finish(&state, .{
        .server_hello = &full_hello,
        .certificate = "",
        .key_exchange = &[_]u8{ 3, 0, 23, 5, 4, 1, 2, 3, 4 },
        .hello_done = "",
    }, &out));
}

test "tlz dtls: client, finish sends key exchange, ChangeCipherSpec, and Finished" {
    var state = testStart();
    var bufs: [6][4096]u8 = undefined;

    const pair = try runPair(&state, &bufs);
    var records: record.RecordIterator = .{ .datagram = pair.answer.to_send };
    const key_exchange = try record.parseHeader((try records.next()).?);
    const change_cipher = try record.parseHeader((try records.next()).?);
    const finished = try record.parseHeader((try records.next()).?);

    try std.testing.expectEqual(record.ContentType.HANDSHAKE, key_exchange.content_type);
    try std.testing.expectEqual(
        record.ContentType.CHANGE_CIPHER_SPEC,
        change_cipher.content_type,
    );
    try std.testing.expectEqual(connection.EPOCH_APPLICATION, finished.epoch);
    try std.testing.expectEqual(@as(u48, 0), finished.sequence_number);
}

test "tlz dtls: client, the server Finished matches the expected verify_data" {
    var state = testStart();
    var bufs: [6][4096]u8 = undefined;
    var plain: [128]u8 = undefined;

    var pair = try runPair(&state, &bufs);
    const conn = &pair.answer.connection;
    const opened = (try conn.readRecord(pair.server_finished_record, &plain)).?;

    try std.testing.expectEqualSlices(
        u8,
        &pair.answer.server_verify_data,
        serverFinishedVerifyData(opened).?,
    );
}

test "tlz dtls: client, application data flows both ways with the server" {
    var state = testStart();
    var bufs: [6][4096]u8 = undefined;
    var to_server_buf: [128]u8 = undefined;
    var to_client_buf: [128]u8 = undefined;
    var server_read: [128]u8 = undefined;
    var client_read: [128]u8 = undefined;
    var plain: [128]u8 = undefined;

    var pair = try runPair(&state, &bufs);
    _ = try pair.answer.connection.readRecord(pair.server_finished_record, &plain);
    const to_server = try pair.answer.connection.writeAppData("ping dialer", &to_server_buf);
    const to_client = try pair.server_done.connection.writeAppData("pong", &to_client_buf);

    try std.testing.expectEqualStrings(
        "ping dialer",
        (try pair.server_done.connection.readAppData(to_server, &server_read)).?,
    );
    try std.testing.expectEqualStrings(
        "pong",
        (try pair.answer.connection.readRecord(to_client, &client_read)).?,
    );
}

test "tlz dtls: client, a replayed server record is dropped" {
    var state = testStart();
    var bufs: [6][4096]u8 = undefined;
    var to_client_buf: [128]u8 = undefined;
    var plain: [128]u8 = undefined;

    var pair = try runPair(&state, &bufs);
    const to_client = try pair.server_done.connection.writeAppData("once only", &to_client_buf);
    _ = try pair.answer.connection.readRecord(to_client, &plain);

    try std.testing.expectEqual(
        @as(?[]const u8, null),
        try pair.answer.connection.readRecord(to_client, &plain),
    );
}

test "tlz dtls: client, serverFinishedVerifyData refuses a non Finished message" {
    var message: [handshake.HEADER_LEN + VERIFY_DATA_LEN]u8 = @splat(0);

    handshake.writeHeader(&message, .{
        .msg_type = .SERVER_HELLO,
        .length = VERIFY_DATA_LEN,
        .message_seq = 5,
        .fragment_offset = 0,
        .fragment_length = VERIFY_DATA_LEN,
    });

    try std.testing.expectEqual(@as(?[]const u8, null), serverFinishedVerifyData(&message));
}

test "tlz dtls: client, serverFinishedVerifyData refuses a wrong length" {
    var message: [handshake.HEADER_LEN + 4]u8 = @splat(0);

    handshake.writeHeader(&message, .{
        .msg_type = .FINISHED,
        .length = 4,
        .message_seq = 5,
        .fragment_offset = 0,
        .fragment_length = 4,
    });

    try std.testing.expectEqual(@as(?[]const u8, null), serverFinishedVerifyData(&message));
    try std.testing.expectEqual(@as(?[]const u8, null), serverFinishedVerifyData("abc"));
}

