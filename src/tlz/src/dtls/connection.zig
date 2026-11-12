//! TLZ dtls connection
//!
//! ### file: src/tlz/src/dtls/connection.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! DTLS 1.2 server handshake (RFC 6347), ECDHE-ECDSA with AES-128-GCM, sans-I/O:
//! answer a ClientHello with a cookie, send the server flight, then finish.
//!
//! ### note:
//!
//! This does NOT ride `tls12/connection.zig`. RFC 6347 4.2.6 hashes the transcript
//! over the DTLS handshake headers (message_seq and fragment fields included, as if
//! unfragmented), and it leaves out the first ClientHello and the HelloVerifyRequest.
//! Epoch 0 is the plaintext handshake, epoch 1 begins at ChangeCipherSpec, and record
//! sequence numbers restart at 0 for the new epoch.
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
const Writer = @import("../wire/Writer.zig");
const prf = @import("../tls12/prf.zig");
const record = @import("record.zig");
const handshake = @import("handshake.zig");
const hello = @import("hello.zig");
const cookie = @import("cookie.zig");
const use_srtp = @import("use_srtp.zig");
const exporter = @import("exporter.zig");

const P256 = std.crypto.ecc.P256;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const IpAddress = std.Io.net.IpAddress;

// --------------------------------------------------------- //
// Private:

const NAMED_CURVE_SECP256R1: u16 = 0x0017;
const SIG_ECDSA_SECP256R1_SHA256: u16 = 0x0403;
const ECCURVE_TYPE_NAMED_CURVE: u8 = 3;
const VERIFY_DATA_LEN: usize = prf.VERIFY_DATA_LENGTH;

/// Largest single handshake body this server builds (certificate included).
const MAX_BODY_LEN: usize = 2048;

/// message_seq is per side and counts every handshake message that side sends,
/// retransmissions reusing the same value (RFC 6347 4.2.2). The HelloVerifyRequest is
/// the server's message 0, so its flight starts at 1.
const SEQ_HELLO_VERIFY_REQUEST: u16 = 0;
const SEQ_SERVER_HELLO: u16 = 1;
const SEQ_CERTIFICATE: u16 = 2;
const SEQ_SERVER_KEY_EXCHANGE: u16 = 3;
const SEQ_SERVER_HELLO_DONE: u16 = 4;
const SEQ_SERVER_FINISHED: u16 = 5;

/// The cookie-bearing ClientHello is the client's message 1. The first one is 0 and
/// never enters the transcript.
const SEQ_CLIENT_HELLO_WITH_COOKIE: u16 = 1;
const SEQ_CLIENT_KEY_EXCHANGE: u16 = 2;
const SEQ_CLIENT_FINISHED: u16 = 3;

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
        else => return Error.Tlz_DtlsConnection_BadKeyShare,
    };
    const shared = peer.mul(scalar, .big) catch |err| switch (err) {
        error.IdentityElement => return Error.Tlz_DtlsConnection_BadKeyShare,
    };

    return shared.affineCoordinates().x.toBytes(.big);
}

/// The client's ephemeral point out of a ClientKeyExchange body.
fn readClientPoint(client_key_exchange_body: []const u8) Error![]const u8 {
    var reader: Reader = .{ .buf = client_key_exchange_body };

    const point_len = reader.readU8() catch |err| switch (err) {
        error.Tlz_WireReader_Truncated => return Error.Tlz_DtlsConnection_Truncated,
    };

    return reader.readBytes(point_len) catch |err| switch (err) {
        error.Tlz_WireReader_Truncated => Error.Tlz_DtlsConnection_Truncated,
    };
}

/// Write an epoch 0 plaintext record.
fn writePlainRecord(
    out: []u8,
    content_type: record.ContentType,
    sequence_number: u48,
    fragment: []const u8,
) Error![]const u8 {
    const epoch = EPOCH_HANDSHAKE;
    const seq = sequence_number;
    const written = record.writePlaintext(out, content_type, epoch, seq, fragment);

    return written catch |err| switch (err) {
        error.Tlz_DtlsRecord_BadRecord => Error.Tlz_DtlsConnection_BadRecord,
    };
}

/// Frame one handshake message, hash it, and write it as its own records.
///
/// Return:
/// - usize (bytes written to `out`)
/// - Error.Tlz_DtlsConnection_BadRecord when `out` cannot hold the records
fn emitMessage(
    out: []u8,
    state: *State,
    msg_type: handshake.MessageType,
    message_seq: u16,
    body: []const u8,
    max_fragment_len: usize,
) Error!usize {
    updateTranscript(&state.transcript, msg_type, message_seq, body);

    var message_buf: [MAX_BODY_LEN]u8 = undefined;
    var fragmenter: handshake.Fragmenter = .{
        .msg_type = msg_type,
        .message_seq = message_seq,
        .body = body,
        .max_fragment_len = max_fragment_len,
    };
    var written: usize = 0;

    while (fragmenter.next(&message_buf)) |message| {
        const bytes = try writePlainRecord(
            out[written..],
            .HANDSHAKE,
            state.next_record_seq,
            message,
        );

        state.next_record_seq += 1;
        written += bytes.len;
    }

    return written;
}

/// Which SRTP profile to answer with, or null for no media.
///
/// Note:
/// - A use_srtp extension this server cannot read is treated as no offer, not as a
///   fatal alert. The data channel half works either way.
fn selectSrtpProfile(
    extensions: []const u8,
    preferences: []const exporter.SrtpProfile,
) ?exporter.SrtpProfile {
    if (preferences.len == 0) return null;

    const found = use_srtp.find(extensions) catch |err| switch (err) {
        // Best effort: an unreadable block means no media offer.
        error.Tlz_DtlsUseSrtp_Malformed => return null,
    };
    const extension_data = found orelse return null;
    const offered = use_srtp.read(extension_data) catch |err| switch (err) {
        // Best effort: an unreadable offer means no media offer.
        error.Tlz_DtlsUseSrtp_Malformed => return null,
    };

    return use_srtp.select(offered, preferences);
}

fn writeServerHelloBody(
    writer: *Writer,
    server_random: [32]u8,
    session_id: []const u8,
    srtp_profile: ?exporter.SrtpProfile,
) Error!void {
    writer.writeU16(record.VERSION_DTLS_1_2);
    writer.writeBytes(&server_random);
    writer.writeU8(@intCast(session_id.len));
    writer.writeBytes(session_id);
    writer.writeU16(CIPHER_ECDHE_ECDSA_AES128_GCM_SHA256);
    writer.writeU8(0);

    // renegotiation_info (RFC 5746) and ec_point_formats (RFC 8422 5.1.2), the two a
    // 1.2 ECDHE peer expects to see echoed.
    const extensions = writer.placeU16();
    writer.writeU16(0xff01);
    writer.writeU16(1);
    writer.writeU8(0);
    writer.writeU16(0x000b);
    writer.writeU16(2);
    writer.writeU8(1);
    writer.writeU8(0);

    // use_srtp names the one profile the two sides settled on (RFC 5764 4.1.1).
    if (srtp_profile) |chosen| {
        var answer_buf: [use_srtp.ANSWER_LEN]u8 = undefined;
        const answer = use_srtp.writeAnswer(&answer_buf, chosen) catch |err| switch (err) {
            error.Tlz_DtlsUseSrtp_NoSpace => return Error.Tlz_DtlsConnection_NoSpace,
        };

        writer.writeBytes(answer);
    }

    writer.patchU16(extensions);
}

fn writeCertificateBody(writer: *Writer, der: []const u8) void {
    const list = writer.placeU24();
    const cert = writer.placeU24();

    writer.writeBytes(der);

    writer.patchU24(cert);
    writer.patchU24(list);
}

/// ServerKeyExchange: the ECDHE params, then an ECDSA signature over
/// client_random ++ server_random ++ params (RFC 5246 7.4.3).
fn writeServerKeyExchangeBody(
    writer: *Writer,
    key: EcdsaP256.KeyPair,
    client_random: [32]u8,
    server_random: [32]u8,
    point: []const u8,
) Error!void {
    const params_start = writer.len;

    writer.writeU8(ECCURVE_TYPE_NAMED_CURVE);
    writer.writeU16(NAMED_CURVE_SECP256R1);
    writer.writeU8(@intCast(point.len));
    writer.writeBytes(point);

    const params = writer.buf[params_start..writer.len];

    var signed: [32 + 32 + 70]u8 = undefined;
    @memcpy(signed[0..32], &client_random);
    @memcpy(signed[32..64], &server_random);
    @memcpy(signed[64 .. 64 + params.len], params);

    const signature = key.sign(signed[0 .. 64 + params.len], null) catch |err| switch (err) {
        else => return Error.Tlz_DtlsConnection_SignFailed,
    };

    var der_buf: [EcdsaP256.Signature.der_encoded_length_max]u8 = undefined;
    const der = signature.toDer(&der_buf);

    writer.writeU16(SIG_ECDSA_SECP256R1_SHA256);
    const signature_len = writer.placeU16();
    writer.writeBytes(der);
    writer.patchU16(signature_len);
}

/// The client verify_data out of an opened epoch 1 Finished record.
fn readClientVerifyData(plaintext: []const u8) Error![]const u8 {
    const header = handshake.parseHeader(plaintext) catch |err| switch (err) {
        error.Tlz_DtlsHandshake_Truncated => return Error.Tlz_DtlsConnection_Truncated,
    };
    if (header.msg_type != .FINISHED) return Error.Tlz_DtlsConnection_UnexpectedMessage;

    const verify_data = plaintext[handshake.HEADER_LEN..];
    if (verify_data.len != VERIFY_DATA_LEN) return Error.Tlz_DtlsConnection_UnexpectedMessage;

    return verify_data;
}

// --------------------------------------------------------- //
// Public:

pub const HandshakeOptions = @import("connection/HandshakeOptions.zig");
pub const State = @import("connection/State.zig");
pub const Flight = @import("connection/Flight.zig");
pub const FinishResult = @import("connection/FinishResult.zig");
pub const Connection = @import("connection/Connection.zig");

pub const Error = error{
    Tlz_DtlsConnection_NoSharedCipherSuite,
    Tlz_DtlsConnection_UnexpectedMessage,
    Tlz_DtlsConnection_ClientFinishedMismatch,
    Tlz_DtlsConnection_NoSpace,
    Tlz_DtlsConnection_Truncated,
    Tlz_DtlsConnection_BadHello,
    Tlz_DtlsConnection_BadRecord,
    Tlz_DtlsConnection_AuthenticationFailed,
    Tlz_DtlsConnection_BadKeyShare,
    Tlz_DtlsConnection_SignFailed,
};

/// The one suite this path implements, matching the TLS 1.2 server (RFC 5289).
pub const CIPHER_ECDHE_ECDSA_AES128_GCM_SHA256: u16 = 0xC02B;

/// Epoch of the plaintext handshake.
pub const EPOCH_HANDSHAKE: u16 = 0;

/// Epoch that begins at ChangeCipherSpec.
pub const EPOCH_APPLICATION: u16 = 1;

/// Default ceiling on one handshake fragment body, sized so a record fits a
/// 1200-byte datagram with room for IP and UDP headers.
pub const DEFAULT_MAX_FRAGMENT: usize = 1024;

/// Answer a first ClientHello with a HelloVerifyRequest (RFC 6347 4.2.1).
///
/// Note:
/// - No state is created here. A source address that cannot receive the cookie never
///   gets further.
/// - The reply reuses the ClientHello's own record sequence number (RFC 6347 4.2.1).
/// - Neither message enters the transcript (RFC 6347 4.2.6).
///
/// Param:
/// signer - *const cookie.Signer (the server's cookie signer)
/// peer - std.Io.net.IpAddress (source of the ClientHello)
/// client_hello - hello.ClientHello (already parsed)
/// client_record_seq - u48 (record sequence the ClientHello arrived on)
/// out - []u8 (destination for the record)
///
/// Return:
/// - []const u8 (one DTLS record, borrowing `out`)
/// - Error.Tlz_DtlsConnection_BadHello when the cookie does not fit a hello
/// - Error.Tlz_DtlsConnection_NoSpace when the message cannot be framed
/// - Error.Tlz_DtlsConnection_BadRecord when `out` cannot hold the record
pub fn serverHelloVerifyRequest(
    signer: *const cookie.Signer,
    peer: IpAddress,
    client_hello: hello.ClientHello,
    client_record_seq: u48,
    out: []u8,
) Error![]const u8 {
    const issued = signer.generate(peer, client_hello.paramsForCookie());

    var body_buf: [64]u8 = undefined;
    const body = hello.writeHelloVerifyRequestBody(&body_buf, &issued) catch |err| switch (err) {
        error.Tlz_DtlsHello_BadHello => return Error.Tlz_DtlsConnection_BadHello,
    };

    var message_buf: [96]u8 = undefined;
    var fragmenter: handshake.Fragmenter = .{
        .msg_type = .HELLO_VERIFY_REQUEST,
        .message_seq = SEQ_HELLO_VERIFY_REQUEST,
        .body = body,
        .max_fragment_len = body.len,
    };
    const message = fragmenter.next(&message_buf) orelse return Error.Tlz_DtlsConnection_NoSpace;

    return writePlainRecord(out, .HANDSHAKE, client_record_seq, message);
}

/// Whether a ClientHello carries a cookie this server issued to this peer.
///
/// Note:
/// - An invalid cookie reads exactly like no cookie (RFC 6347 4.2.1), so a client
///   holding a cookie signed by a rotated-out secret can try again.
///
/// Param:
/// signer - *const cookie.Signer (the server's cookie signer)
/// peer - std.Io.net.IpAddress (source of the ClientHello)
/// client_hello - hello.ClientHello (already parsed)
///
/// Return:
/// - bool
pub fn cookieAccepted(
    signer: *const cookie.Signer,
    peer: IpAddress,
    client_hello: hello.ClientHello,
) bool {
    if (!client_hello.hasCookie()) return false;

    return signer.verify(peer, client_hello.paramsForCookie(), client_hello.cookie);
}

/// Send the server flight: ServerHello, Certificate, ServerKeyExchange,
/// ServerHelloDone (RFC 6347 4.2.4 flight 4).
///
/// Note:
/// - `client_hello_body` must be the ClientHello that CARRIED THE COOKIE. That one
///   enters the transcript, the first one never does.
/// - Each message goes in its own records, so a caller drops them into datagrams on
///   record boundaries without re-fragmenting.
///
/// Param:
/// opts - HandshakeOptions (the server's material for this handshake)
/// client_hello_body - []const u8 (handshake body, header stripped)
/// out - []u8 (destination for the whole flight)
///
/// Return:
/// - Flight (records to send plus the state the finish needs)
/// - Error.Tlz_DtlsConnection_Truncated, BadHello when the hello does not parse
/// - Error.Tlz_DtlsConnection_NoSharedCipherSuite when the one suite is not offered
/// - Error.Tlz_DtlsConnection_BadKeyShare when the ephemeral seed reduces to zero
/// - Error.Tlz_DtlsConnection_SignFailed when the ServerKeyExchange cannot be signed
/// - Error.Tlz_DtlsConnection_NoSpace when the certificate or a SRTP answer does not fit
/// - Error.Tlz_DtlsConnection_BadRecord when `out` cannot hold the flight
pub fn serverFlight(
    opts: HandshakeOptions,
    client_hello_body: []const u8,
    out: []u8,
) Error!Flight {
    const client_hello = hello.parseClientHello(client_hello_body) catch |err| switch (err) {
        error.Tlz_DtlsHello_Truncated => return Error.Tlz_DtlsConnection_Truncated,
        error.Tlz_DtlsHello_BadHello => return Error.Tlz_DtlsConnection_BadHello,
    };
    if (!client_hello.offersCipherSuite(CIPHER_ECDHE_ECDSA_AES128_GCM_SHA256)) {
        return Error.Tlz_DtlsConnection_NoSharedCipherSuite;
    }
    if (opts.certificate_der.len + 6 > MAX_BODY_LEN) return Error.Tlz_DtlsConnection_NoSpace;

    var state: State = .{
        .client_random = client_hello.random,
        .server_random = opts.server_random,
        .server_eph_scalar = reduceP256Scalar(opts.server_eph_secret),
        .transcript = Sha256.init(.{}),
        .next_record_seq = opts.first_record_seq,
        .srtp_profile = selectSrtpProfile(client_hello.extensions, opts.srtp_profiles),
    };
    updateTranscript(
        &state.transcript,
        .CLIENT_HELLO,
        SEQ_CLIENT_HELLO_WITH_COOKIE,
        client_hello_body,
    );

    const server_base = P256.basePoint.mul(state.server_eph_scalar, .big) catch |err| {
        return switch (err) {
            error.IdentityElement => Error.Tlz_DtlsConnection_BadKeyShare,
        };
    };
    const server_point = server_base.toUncompressedSec1();
    const max_fragment = opts.max_fragment_len;

    var body_buf: [MAX_BODY_LEN]u8 = undefined;
    var cursor: usize = 0;

    var hello_writer: Writer = .{ .buf = &body_buf };
    try writeServerHelloBody(
        &hello_writer,
        state.server_random,
        client_hello.session_id,
        state.srtp_profile,
    );
    cursor += try emitMessage(
        out[cursor..],
        &state,
        .SERVER_HELLO,
        SEQ_SERVER_HELLO,
        hello_writer.slice(),
        max_fragment,
    );

    var cert_writer: Writer = .{ .buf = &body_buf };
    writeCertificateBody(&cert_writer, opts.certificate_der);
    cursor += try emitMessage(
        out[cursor..],
        &state,
        .CERTIFICATE,
        SEQ_CERTIFICATE,
        cert_writer.slice(),
        max_fragment,
    );

    var ske_writer: Writer = .{ .buf = &body_buf };
    try writeServerKeyExchangeBody(
        &ske_writer,
        opts.signing_key,
        state.client_random,
        state.server_random,
        &server_point,
    );
    cursor += try emitMessage(
        out[cursor..],
        &state,
        .SERVER_KEY_EXCHANGE,
        SEQ_SERVER_KEY_EXCHANGE,
        ske_writer.slice(),
        max_fragment,
    );

    cursor += try emitMessage(
        out[cursor..],
        &state,
        .SERVER_HELLO_DONE,
        SEQ_SERVER_HELLO_DONE,
        "",
        max_fragment,
    );

    return .{
        .to_send = out[0..cursor],
        .state = state,
    };
}

/// Finish the handshake: derive keys from ClientKeyExchange, verify the client
/// Finished, and send ChangeCipherSpec plus the server Finished (RFC 6347 4.2.4
/// flight 6).
///
/// Note:
/// - The client Finished arrives protected under epoch 1 at record sequence 0.
/// - ChangeCipherSpec is not a handshake message. It takes no message_seq and never
///   enters the transcript (RFC 6347 4.2.5).
///
/// Param:
/// state - *State (from serverFlight, advanced in place)
/// client_key_exchange_body - []const u8 (reassembled body, header stripped)
/// client_finished_record - []const u8 (one complete protected record)
/// out - []u8 (destination for the two records)
///
/// Return:
/// - FinishResult (records to send plus the established Connection)
/// - Error.Tlz_DtlsConnection_Truncated when a message is cut short
/// - Error.Tlz_DtlsConnection_BadKeyShare when the client point is invalid
/// - Error.Tlz_DtlsConnection_BadRecord, AuthenticationFailed when the Finished
///   record does not open
/// - Error.Tlz_DtlsConnection_UnexpectedMessage when the Finished is not an epoch 1
///   Finished of the right length
/// - Error.Tlz_DtlsConnection_ClientFinishedMismatch when verify_data is wrong
/// - Error.Tlz_DtlsConnection_BadRecord when `out` cannot hold the records
pub fn serverFinish(
    state: *State,
    client_key_exchange_body: []const u8,
    client_finished_record: []const u8,
    out: []u8,
) Error!FinishResult {
    const client_point = try readClientPoint(client_key_exchange_body);
    updateTranscript(
        &state.transcript,
        .CLIENT_KEY_EXCHANGE,
        SEQ_CLIENT_KEY_EXCHANGE,
        client_key_exchange_body,
    );

    const pre_master = try ecdheSharedX(state.server_eph_scalar, client_point);
    const master = prf.masterSecret(&pre_master, state.client_random, state.server_random);
    const km = prf.keyMaterial(master, state.client_random, state.server_random);
    const expected = prf.finishedFromHash(master, "client finished", transcriptHash(state));

    var plain_buf: [128]u8 = undefined;
    const opened = record.deprotect(
        &plain_buf,
        client_finished_record,
        km.client_write_key,
        km.client_write_iv,
    ) catch |err| switch (err) {
        error.Tlz_DtlsRecord_Truncated => return Error.Tlz_DtlsConnection_Truncated,
        error.Tlz_DtlsRecord_BadRecord => return Error.Tlz_DtlsConnection_BadRecord,
        error.Tlz_DtlsRecord_AuthenticationFailed => {
            return Error.Tlz_DtlsConnection_AuthenticationFailed;
        },
    };
    if (opened.header.epoch != EPOCH_APPLICATION) {
        return Error.Tlz_DtlsConnection_UnexpectedMessage;
    }

    const client_verify_data = try readClientVerifyData(opened.data);
    if (!std.mem.eql(u8, client_verify_data, &expected)) {
        return Error.Tlz_DtlsConnection_ClientFinishedMismatch;
    }

    updateTranscript(&state.transcript, .FINISHED, SEQ_CLIENT_FINISHED, client_verify_data);

    const server_verify_data = prf.finishedFromHash(
        master,
        "server finished",
        transcriptHash(state),
    );

    var finished_message: [handshake.HEADER_LEN + VERIFY_DATA_LEN]u8 = undefined;
    handshake.writeHeader(&finished_message, .{
        .msg_type = .FINISHED,
        .length = VERIFY_DATA_LEN,
        .message_seq = SEQ_SERVER_FINISHED,
        .fragment_offset = 0,
        .fragment_length = VERIFY_DATA_LEN,
    });
    @memcpy(finished_message[handshake.HEADER_LEN..], &server_verify_data);

    // ChangeCipherSpec closes epoch 0, the Finished is the first record of epoch 1.
    const ccs = try writePlainRecord(out, .CHANGE_CIPHER_SPEC, state.next_record_seq, &.{1});
    state.next_record_seq += 1;

    const finished = record.protect(
        out[ccs.len..],
        &finished_message,
        .HANDSHAKE,
        EPOCH_APPLICATION,
        0,
        km.server_write_key,
        km.server_write_iv,
    ) catch |err| switch (err) {
        error.Tlz_DtlsRecord_BadRecord => return Error.Tlz_DtlsConnection_BadRecord,
    };

    // The master secret exists only here, so the SRTP export happens here or not at
    // all (RFC 5764 4.2). A profile without a cipher key is reported as no media.
    var srtp_keys: ?exporter.SrtpKeys = null;
    if (state.srtp_profile) |profile| {
        srtp_keys = exporter.srtpKeys(
            profile,
            master,
            state.client_random,
            state.server_random,
        ) catch |err| switch (err) {
            // Best effort: a profile with nothing to export means no media.
            error.Tlz_DtlsExporter_UnsupportedProfile,
            error.Tlz_DtlsExporter_ContextTooLong,
            => null,
        };
    }

    return .{
        .to_send = out[0 .. ccs.len + finished.len],
        .connection = .{ .km = km },
        .srtp_keys = srtp_keys,
        .srtp_profile = if (srtp_keys == null) null else state.srtp_profile,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const TEST_PEER: IpAddress = .{
    .ip4 = .{
        .bytes = .{ 192, 0, 2, 1 },
        .port = 41000,
    },
};
const TEST_COOKIE_SECRET: [cookie.SECRET_LEN]u8 = @splat(0x5A);
const TEST_CLIENT_RANDOM: [32]u8 = @splat(0x11);
const TEST_DER = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };

/// What the in-test client derived, for checking what the server produced.
const TestRun = struct {
    finish: FinishResult,
    master: [48]u8,
    server_random: [32]u8,
};

fn testSigningKey() !EcdsaP256.KeyPair {
    var secret: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &secret,
        "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c",
    );

    return EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(secret));
}

fn testOptions(key: EcdsaP256.KeyPair) HandshakeOptions {
    return .{
        .certificate_der = &TEST_DER,
        .signing_key = key,
        .server_eph_secret = @splat(0x22),
        .server_random = @splat(0x33),
    };
}

fn testHello(out: []u8, hello_cookie: []const u8) hello.WriteError![]const u8 {
    return hello.writeClientHelloBody(
        out,
        record.VERSION_DTLS_1_2,
        TEST_CLIENT_RANDOM,
        "",
        hello_cookie,
        &.{CIPHER_ECDHE_ECDSA_AES128_GCM_SHA256},
    );
}

/// One ClientHello body carrying a use_srtp extension that offers `profiles`.
fn testHelloOfferingSrtp(
    out: []u8,
    hello_cookie: []const u8,
    profiles: []const exporter.SrtpProfile,
) hello.WriteError![]const u8 {
    var body_buf: [256]u8 = undefined;
    const body = try testHello(&body_buf, hello_cookie);
    @memcpy(out[0..body.len], body);

    var writer: Writer = .{ .buf = out[body.len..] };
    const block = writer.placeU16();
    writer.writeU16(use_srtp.EXTENSION_TYPE);

    const extension = writer.placeU16();
    writer.writeU16(@intCast(profiles.len * use_srtp.PROFILE_LEN));
    for (profiles) |profile| writer.writeU16(@intFromEnum(profile));
    writer.writeU8(0);
    writer.patchU16(extension);
    writer.patchU16(block);

    return out[0 .. body.len + writer.len];
}

/// Walk a flight's records, collecting the handshake fragments they carry.
fn collectMessages(flight: []const u8, out: *[8]handshake.Fragment) !usize {
    var iterator: record.RecordIterator = .{ .datagram = flight };
    var count: usize = 0;

    while (try iterator.next()) |bytes| {
        var messages: handshake.FragmentIterator = .{
            .body = try record.plaintextFragment(bytes),
        };

        while (try messages.next()) |fragment| : (count += 1) out[count] = fragment;
    }

    return count;
}

/// The use_srtp profile a ServerHello body answers with, or null when it has none.
fn serverHelloSrtpProfile(server_hello_body: []const u8) !?exporter.SrtpProfile {
    const session_id_len: usize = server_hello_body[34];
    const extensions_at = 35 + session_id_len + 3;
    const extensions_len = std.mem.readInt(u16, server_hello_body[extensions_at..][0..2], .big);
    const extensions = server_hello_body[extensions_at + 2 ..][0..extensions_len];
    const extension_data = (try use_srtp.find(extensions)) orelse return null;

    return (try use_srtp.read(extension_data)).at(0);
}

fn finishedMessage(verify_data: [VERIFY_DATA_LEN]u8) [handshake.HEADER_LEN + VERIFY_DATA_LEN]u8 {
    var message: [handshake.HEADER_LEN + VERIFY_DATA_LEN]u8 = undefined;

    handshake.writeHeader(&message, .{
        .msg_type = .FINISHED,
        .length = VERIFY_DATA_LEN,
        .message_seq = SEQ_CLIENT_FINISHED,
        .fragment_offset = 0,
        .fragment_length = VERIFY_DATA_LEN,
    });
    @memcpy(message[handshake.HEADER_LEN..], &verify_data);

    return message;
}

/// Drive one whole handshake with a client written here. Both buffers must outlive
/// the result.
fn runFullHandshake(
    opts: HandshakeOptions,
    client_hello_body: []const u8,
    flight_buf: []u8,
    finish_buf: []u8,
) !TestRun {
    const flight = try serverFlight(opts, client_hello_body, flight_buf);
    var state = flight.state;

    var messages: [8]handshake.Fragment = undefined;
    _ = try collectMessages(flight.to_send, &messages);

    const server_random_seen: [32]u8 = messages[0].data[2..34].*;
    const server_key_exchange = messages[2].data;
    const server_point = server_key_exchange[4 .. 4 + server_key_exchange[3]];
    const client_scalar = reduceP256Scalar(@splat(0x44));
    const client_point = (try P256.basePoint.mul(client_scalar, .big)).toUncompressedSec1();
    const pre_master = try ecdheSharedX(client_scalar, server_point);
    const master = prf.masterSecret(&pre_master, TEST_CLIENT_RANDOM, server_random_seen);
    const km = prf.keyMaterial(master, TEST_CLIENT_RANDOM, server_random_seen);
    const cke_body = [_]u8{65} ++ client_point;

    var transcript = Sha256.init(.{});
    const hash_into = &transcript;
    updateTranscript(hash_into, .CLIENT_HELLO, SEQ_CLIENT_HELLO_WITH_COOKIE, client_hello_body);
    updateTranscript(hash_into, .SERVER_HELLO, SEQ_SERVER_HELLO, messages[0].data);
    updateTranscript(hash_into, .CERTIFICATE, SEQ_CERTIFICATE, messages[1].data);
    updateTranscript(hash_into, .SERVER_KEY_EXCHANGE, SEQ_SERVER_KEY_EXCHANGE, messages[2].data);
    updateTranscript(hash_into, .SERVER_HELLO_DONE, SEQ_SERVER_HELLO_DONE, messages[3].data);
    updateTranscript(hash_into, .CLIENT_KEY_EXCHANGE, SEQ_CLIENT_KEY_EXCHANGE, &cke_body);

    var hash: [32]u8 = undefined;
    transcript.final(&hash);

    const client_verify_data = prf.finishedFromHash(master, "client finished", hash);
    const message = finishedMessage(client_verify_data);

    var record_buf: [128]u8 = undefined;
    const client_finished_record = try record.protect(
        &record_buf,
        &message,
        .HANDSHAKE,
        EPOCH_APPLICATION,
        0,
        km.client_write_key,
        km.client_write_iv,
    );

    return .{
        .finish = try serverFinish(&state, &cke_body, client_finished_record, finish_buf),
        .master = master,
        .server_random = server_random_seen,
    };
}

test "tlz dtls: connection, a first hello has no accepted cookie" {
    const signer = cookie.Signer.init(TEST_COOKIE_SECRET);
    var hello_buf: [256]u8 = undefined;

    const client_hello = try hello.parseClientHello(try testHello(&hello_buf, ""));

    try std.testing.expect(!cookieAccepted(&signer, TEST_PEER, client_hello));
}

test "tlz dtls: connection, HelloVerifyRequest reuses the hello record sequence" {
    const signer = cookie.Signer.init(TEST_COOKIE_SECRET);
    var hello_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var messages: [8]handshake.Fragment = undefined;
    const client_hello = try hello.parseClientHello(try testHello(&hello_buf, ""));

    const reply = try serverHelloVerifyRequest(&signer, TEST_PEER, client_hello, 7, &out);
    const header = try record.parseHeader(reply);

    try std.testing.expectEqual(@as(u48, 7), header.sequence_number);
    try std.testing.expectEqual(EPOCH_HANDSHAKE, header.epoch);
    try std.testing.expectEqual(@as(usize, 1), try collectMessages(reply, &messages));
    try std.testing.expectEqual(
        handshake.MessageType.HELLO_VERIFY_REQUEST,
        messages[0].header.msg_type,
    );
    try std.testing.expectEqual(@as(u16, 0), messages[0].header.message_seq);
}

test "tlz dtls: connection, the echoed cookie is accepted from the same peer" {
    const signer = cookie.Signer.init(TEST_COOKIE_SECRET);
    var hello_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var second_buf: [256]u8 = undefined;
    var messages: [8]handshake.Fragment = undefined;
    const first = try hello.parseClientHello(try testHello(&hello_buf, ""));
    const reply = try serverHelloVerifyRequest(&signer, TEST_PEER, first, 0, &out);
    _ = try collectMessages(reply, &messages);

    const issued = try hello.parseHelloVerifyRequestBody(messages[0].data);
    const second = try hello.parseClientHello(try testHello(&second_buf, issued));

    try std.testing.expect(cookieAccepted(&signer, TEST_PEER, second));
}

test "tlz dtls: connection, the echoed cookie is refused from another peer" {
    const signer = cookie.Signer.init(TEST_COOKIE_SECRET);
    var second_buf: [256]u8 = undefined;
    const elsewhere: IpAddress = .{
        .ip4 = .{
            .bytes = .{ 198, 51, 100, 7 },
            .port = 41000,
        },
    };
    var hello_buf: [256]u8 = undefined;
    const first = try hello.parseClientHello(try testHello(&hello_buf, ""));
    const issued = signer.generate(TEST_PEER, first.paramsForCookie());

    const second = try hello.parseClientHello(try testHello(&second_buf, &issued));

    try std.testing.expect(!cookieAccepted(&signer, elsewhere, second));
}

test "tlz dtls: connection, serverFlight sends four messages in message_seq order" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var out: [4096]u8 = undefined;
    var messages: [8]handshake.Fragment = undefined;
    const expected = [_]handshake.MessageType{
        .SERVER_HELLO,
        .CERTIFICATE,
        .SERVER_KEY_EXCHANGE,
        .SERVER_HELLO_DONE,
    };

    const flight = try serverFlight(testOptions(key), try testHello(&hello_buf, "c"), &out);
    const count = try collectMessages(flight.to_send, &messages);

    try std.testing.expectEqual(@as(usize, 4), count);
    for (expected, 0..) |msg_type, i| {
        try std.testing.expectEqual(msg_type, messages[i].header.msg_type);
        try std.testing.expectEqual(@as(u16, @intCast(i + 1)), messages[i].header.message_seq);
        try std.testing.expect(messages[i].header.isWholeMessage());
    }
}

test "tlz dtls: connection, the ServerHello names the suite at DTLS 1.2" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var out: [4096]u8 = undefined;
    var messages: [8]handshake.Fragment = undefined;

    const flight = try serverFlight(testOptions(key), try testHello(&hello_buf, "c"), &out);
    _ = try collectMessages(flight.to_send, &messages);
    const server_hello = messages[0].data;

    try std.testing.expectEqual(
        record.VERSION_DTLS_1_2,
        std.mem.readInt(u16, server_hello[0..2], .big),
    );
    try std.testing.expectEqual(
        CIPHER_ECDHE_ECDSA_AES128_GCM_SHA256,
        std.mem.readInt(u16, server_hello[35..37], .big),
    );
}

test "tlz dtls: connection, serverFlight records count up from first_record_seq" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var out: [4096]u8 = undefined;
    var opts = testOptions(key);
    opts.first_record_seq = 8;

    const flight = try serverFlight(opts, try testHello(&hello_buf, "c"), &out);
    var iterator: record.RecordIterator = .{ .datagram = flight.to_send };
    var seq: u48 = 8;

    while (try iterator.next()) |bytes| : (seq += 1) {
        const header = try record.parseHeader(bytes);

        try std.testing.expectEqual(seq, header.sequence_number);
        try std.testing.expectEqual(EPOCH_HANDSHAKE, header.epoch);
    }

    try std.testing.expectEqual(@as(u48, 12), seq);
    try std.testing.expectEqual(@as(u48, 12), flight.state.next_record_seq);
}

test "tlz dtls: connection, use_srtp answers with the server choice" {
    const key = try testSigningKey();
    var hello_buf: [512]u8 = undefined;
    var out: [4096]u8 = undefined;
    var messages: [8]handshake.Fragment = undefined;
    var opts = testOptions(key);
    opts.srtp_profiles = &.{
        .SRTP_AES128_CM_HMAC_SHA1_80,
        .SRTP_AES128_CM_HMAC_SHA1_32,
    };
    const body = try testHelloOfferingSrtp(&hello_buf, "c", &.{
        .SRTP_AES128_CM_HMAC_SHA1_32,
        .SRTP_AES128_CM_HMAC_SHA1_80,
    });

    const flight = try serverFlight(opts, body, &out);
    _ = try collectMessages(flight.to_send, &messages);

    try std.testing.expectEqual(
        exporter.SrtpProfile.SRTP_AES128_CM_HMAC_SHA1_80,
        flight.state.srtp_profile.?,
    );
    try std.testing.expectEqual(
        exporter.SrtpProfile.SRTP_AES128_CM_HMAC_SHA1_80,
        (try serverHelloSrtpProfile(messages[0].data)).?,
    );
}

test "tlz dtls: connection, a hello without use_srtp is answered without one" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var out: [4096]u8 = undefined;
    var messages: [8]handshake.Fragment = undefined;
    var opts = testOptions(key);
    opts.srtp_profiles = &.{.SRTP_AES128_CM_HMAC_SHA1_80};

    const flight = try serverFlight(opts, try testHello(&hello_buf, "c"), &out);
    _ = try collectMessages(flight.to_send, &messages);

    try std.testing.expect(flight.state.srtp_profile == null);
    try std.testing.expect((try serverHelloSrtpProfile(messages[0].data)) == null);
}

test "tlz dtls: connection, a server with no profiles leaves an offer unanswered" {
    const key = try testSigningKey();
    var hello_buf: [512]u8 = undefined;
    var out: [4096]u8 = undefined;
    const body = try testHelloOfferingSrtp(&hello_buf, "c", &.{.SRTP_AES128_CM_HMAC_SHA1_80});

    const flight = try serverFlight(testOptions(key), body, &out);

    try std.testing.expect(flight.state.srtp_profile == null);
}

test "tlz dtls: connection, no profile in common leaves media unnegotiated" {
    const key = try testSigningKey();
    var hello_buf: [512]u8 = undefined;
    var out: [4096]u8 = undefined;
    var opts = testOptions(key);
    opts.srtp_profiles = &.{.SRTP_AES128_CM_HMAC_SHA1_80};
    const body = try testHelloOfferingSrtp(&hello_buf, "c", &.{.SRTP_AES128_CM_HMAC_SHA1_32});

    const flight = try serverFlight(opts, body, &out);

    try std.testing.expect(flight.state.srtp_profile == null);
}

test "tlz dtls: connection, a hello without the supported suite is refused" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var out: [4096]u8 = undefined;
    const body = try hello.writeClientHelloBody(
        &hello_buf,
        record.VERSION_DTLS_1_2,
        TEST_CLIENT_RANDOM,
        "",
        "c",
        &.{0x1301},
    );

    try std.testing.expectError(
        Error.Tlz_DtlsConnection_NoSharedCipherSuite,
        serverFlight(testOptions(key), body, &out),
    );
}

test "tlz dtls: connection, a cut hello is truncated" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var out: [4096]u8 = undefined;
    const body = try testHello(&hello_buf, "c");

    try std.testing.expectError(
        Error.Tlz_DtlsConnection_Truncated,
        serverFlight(testOptions(key), body[0..8], &out),
    );
}

test "tlz dtls: connection, a small out buffer is a bad record" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var out: [64]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_DtlsConnection_BadRecord,
        serverFlight(testOptions(key), try testHello(&hello_buf, "c"), &out),
    );
}

test "tlz dtls: connection, a large certificate fragments across records" {
    const key = try testSigningKey();
    var big_der: [1400]u8 = undefined;
    for (&big_der, 0..) |*byte, i| byte.* = @intCast(i % 251);

    var hello_buf: [256]u8 = undefined;
    var out: [8192]u8 = undefined;
    var messages: [8]handshake.Fragment = undefined;
    var reassembler: handshake.Reassembler(4096) = .{};
    var certificate_fragments: usize = 0;
    var opts = testOptions(key);
    opts.certificate_der = &big_der;
    opts.max_fragment_len = 400;

    const flight = try serverFlight(opts, try testHello(&hello_buf, "c"), &out);
    const count = try collectMessages(flight.to_send, &messages);

    for (messages[0..count]) |fragment| {
        if (fragment.header.msg_type != .CERTIFICATE) continue;

        try std.testing.expect(fragment.header.fragment_length <= 400);
        try reassembler.accept(fragment);
        certificate_fragments += 1;
    }

    try std.testing.expect(certificate_fragments > 1);
    try std.testing.expect(std.mem.indexOf(u8, reassembler.message().?, &big_der) != null);
}

test "tlz dtls: connection, a certificate past MAX_BODY_LEN has no space" {
    const key = try testSigningKey();
    const huge_der: [MAX_BODY_LEN]u8 = @splat(0);
    var hello_buf: [256]u8 = undefined;
    var out: [8192]u8 = undefined;
    var opts = testOptions(key);
    opts.certificate_der = &huge_der;

    try std.testing.expectError(
        Error.Tlz_DtlsConnection_NoSpace,
        serverFlight(opts, try testHello(&hello_buf, "c"), &out),
    );
}

test "tlz dtls: connection, a full exchange sends ChangeCipherSpec then an epoch 1 Finished" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var finish_buf: [512]u8 = undefined;

    const run = try runFullHandshake(
        testOptions(key),
        try testHello(&hello_buf, "c"),
        &flight_buf,
        &finish_buf,
    );
    var records: record.RecordIterator = .{ .datagram = run.finish.to_send };
    const ccs = try record.parseHeader((try records.next()).?);
    const finished = try record.parseHeader((try records.next()).?);

    try std.testing.expectEqual(record.ContentType.CHANGE_CIPHER_SPEC, ccs.content_type);
    try std.testing.expectEqual(EPOCH_HANDSHAKE, ccs.epoch);
    try std.testing.expectEqual(EPOCH_APPLICATION, finished.epoch);
    try std.testing.expectEqual(@as(u48, 0), finished.sequence_number);
}

test "tlz dtls: connection, the server Finished matches the client transcript" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var finish_buf: [512]u8 = undefined;
    var plain: [128]u8 = undefined;

    const run = try runFullHandshake(
        testOptions(key),
        try testHello(&hello_buf, "c"),
        &flight_buf,
        &finish_buf,
    );
    const km = prf.keyMaterial(run.master, TEST_CLIENT_RANDOM, run.server_random);
    var records: record.RecordIterator = .{ .datagram = run.finish.to_send };
    _ = try records.next();
    const opened = try record.deprotect(
        &plain,
        (try records.next()).?,
        km.server_write_key,
        km.server_write_iv,
    );

    const header = try handshake.parseHeader(opened.data);

    try std.testing.expectEqual(handshake.MessageType.FINISHED, header.msg_type);
    try std.testing.expectEqual(handshake.HEADER_LEN + VERIFY_DATA_LEN, opened.data.len);
}

test "tlz dtls: connection, application data flows both ways after the finish" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var finish_buf: [512]u8 = undefined;
    var app_buf: [128]u8 = undefined;
    var plain: [128]u8 = undefined;
    var from_client_buf: [128]u8 = undefined;
    var read_buf: [128]u8 = undefined;

    var run = try runFullHandshake(
        testOptions(key),
        try testHello(&hello_buf, "c"),
        &flight_buf,
        &finish_buf,
    );
    const km = prf.keyMaterial(run.master, TEST_CLIENT_RANDOM, run.server_random);
    const to_client = try run.finish.connection.writeAppData("hello over dtls 1.2", &app_buf);
    const got = try record.deprotect(&plain, to_client, km.server_write_key, km.server_write_iv);
    const from_client = try record.protect(
        &from_client_buf,
        "hello back",
        .APPLICATION_DATA,
        EPOCH_APPLICATION,
        1,
        km.client_write_key,
        km.client_write_iv,
    );

    try std.testing.expectEqualStrings("hello over dtls 1.2", got.data);
    try std.testing.expectEqual(@as(u48, 1), got.header.sequence_number);
    try std.testing.expectEqualStrings(
        "hello back",
        (try run.finish.connection.readAppData(from_client, &read_buf)).?,
    );
}

test "tlz dtls: connection, the SRTP keys match what the peer derives" {
    const key = try testSigningKey();
    var hello_buf: [512]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var finish_buf: [512]u8 = undefined;
    var opts = testOptions(key);
    opts.srtp_profiles = &.{.SRTP_AES128_CM_HMAC_SHA1_80};
    const body = try testHelloOfferingSrtp(&hello_buf, "c", &.{.SRTP_AES128_CM_HMAC_SHA1_80});

    const run = try runFullHandshake(opts, body, &flight_buf, &finish_buf);
    const peer_keys = try exporter.srtpKeys(
        .SRTP_AES128_CM_HMAC_SHA1_80,
        run.master,
        TEST_CLIENT_RANDOM,
        run.server_random,
    );
    const server_keys = run.finish.srtp_keys.?;

    try std.testing.expectEqual(
        exporter.SrtpProfile.SRTP_AES128_CM_HMAC_SHA1_80,
        run.finish.srtp_profile.?,
    );
    try std.testing.expectEqualDeep(peer_keys, server_keys);
}

test "tlz dtls: connection, a handshake with no media exports nothing" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var finish_buf: [512]u8 = undefined;

    const run = try runFullHandshake(
        testOptions(key),
        try testHello(&hello_buf, "c"),
        &flight_buf,
        &finish_buf,
    );

    try std.testing.expect(run.finish.srtp_keys == null);
    try std.testing.expect(run.finish.srtp_profile == null);
}

test "tlz dtls: connection, a wrong client Finished is a mismatch" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var messages: [8]handshake.Fragment = undefined;
    var record_buf: [128]u8 = undefined;
    var out: [512]u8 = undefined;

    const body = try testHello(&hello_buf, "c");
    const flight = try serverFlight(testOptions(key), body, &flight_buf);
    var state = flight.state;
    _ = try collectMessages(flight.to_send, &messages);

    const server_random_seen: [32]u8 = messages[0].data[2..34].*;
    const server_key_exchange = messages[2].data;
    const server_point = server_key_exchange[4 .. 4 + server_key_exchange[3]];
    const client_scalar = reduceP256Scalar(@splat(0x44));
    const client_point = (try P256.basePoint.mul(client_scalar, .big)).toUncompressedSec1();
    const pre_master = try ecdheSharedX(client_scalar, server_point);
    const master = prf.masterSecret(&pre_master, TEST_CLIENT_RANDOM, server_random_seen);
    const km = prf.keyMaterial(master, TEST_CLIENT_RANDOM, server_random_seen);
    const cke_body = [_]u8{65} ++ client_point;
    const message = finishedMessage(@splat(0xEE));
    const wrong_finished = try record.protect(
        &record_buf,
        &message,
        .HANDSHAKE,
        EPOCH_APPLICATION,
        0,
        km.client_write_key,
        km.client_write_iv,
    );

    try std.testing.expectError(
        Error.Tlz_DtlsConnection_ClientFinishedMismatch,
        serverFinish(&state, &cke_body, wrong_finished, &out),
    );
}

test "tlz dtls: connection, a client Finished in epoch 0 is unexpected" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var messages: [8]handshake.Fragment = undefined;
    var record_buf: [128]u8 = undefined;
    var out: [512]u8 = undefined;

    const body = try testHello(&hello_buf, "c");
    const flight = try serverFlight(testOptions(key), body, &flight_buf);
    var state = flight.state;
    _ = try collectMessages(flight.to_send, &messages);

    const server_random_seen: [32]u8 = messages[0].data[2..34].*;
    const server_key_exchange = messages[2].data;
    const server_point = server_key_exchange[4 .. 4 + server_key_exchange[3]];
    const client_scalar = reduceP256Scalar(@splat(0x44));
    const client_point = (try P256.basePoint.mul(client_scalar, .big)).toUncompressedSec1();
    const pre_master = try ecdheSharedX(client_scalar, server_point);
    const master = prf.masterSecret(&pre_master, TEST_CLIENT_RANDOM, server_random_seen);
    const km = prf.keyMaterial(master, TEST_CLIENT_RANDOM, server_random_seen);
    const cke_body = [_]u8{65} ++ client_point;
    const message = finishedMessage(@splat(0xEE));
    const wrong_epoch = try record.protect(
        &record_buf,
        &message,
        .HANDSHAKE,
        EPOCH_HANDSHAKE,
        0,
        km.client_write_key,
        km.client_write_iv,
    );

    try std.testing.expectError(
        Error.Tlz_DtlsConnection_UnexpectedMessage,
        serverFinish(&state, &cke_body, wrong_epoch, &out),
    );
}

test "tlz dtls: connection, a cut ClientKeyExchange is truncated" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var out: [512]u8 = undefined;

    const body = try testHello(&hello_buf, "c");
    const flight = try serverFlight(testOptions(key), body, &flight_buf);
    var state = flight.state;

    try std.testing.expectError(
        Error.Tlz_DtlsConnection_Truncated,
        serverFinish(&state, &[_]u8{65}, "", &out),
    );
}

test "tlz dtls: connection, an off-curve client point is a bad key share" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var out: [512]u8 = undefined;
    const off_curve = [_]u8{ 5, 4, 1, 2, 3, 4 };

    const body = try testHello(&hello_buf, "c");
    const flight = try serverFlight(testOptions(key), body, &flight_buf);
    var state = flight.state;

    try std.testing.expectError(
        Error.Tlz_DtlsConnection_BadKeyShare,
        serverFinish(&state, &off_curve, "", &out),
    );
}

test "tlz dtls: connection, a tampered client Finished fails authentication" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var record_buf: [128]u8 = undefined;
    var out: [512]u8 = undefined;
    const body = try testHello(&hello_buf, "c");
    const flight = try serverFlight(testOptions(key), body, &flight_buf);
    var state = flight.state;
    const client_scalar = reduceP256Scalar(@splat(0x44));
    const client_point = (try P256.basePoint.mul(client_scalar, .big)).toUncompressedSec1();
    const cke_body = [_]u8{65} ++ client_point;
    const message = finishedMessage(@splat(0xEE));

    const forged = try record.protect(
        &record_buf,
        &message,
        .HANDSHAKE,
        EPOCH_APPLICATION,
        0,
        @splat(0x01),
        @splat(0x02),
    );

    try std.testing.expectError(
        Error.Tlz_DtlsConnection_AuthenticationFailed,
        serverFinish(&state, &cke_body, forged, &out),
    );
}

test "tlz dtls: connection, a cut client Finished record is truncated" {
    const key = try testSigningKey();
    var hello_buf: [256]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var out: [512]u8 = undefined;
    const body = try testHello(&hello_buf, "c");
    const flight = try serverFlight(testOptions(key), body, &flight_buf);
    var state = flight.state;
    const client_scalar = reduceP256Scalar(@splat(0x44));
    const client_point = (try P256.basePoint.mul(client_scalar, .big)).toUncompressedSec1();
    const cke_body = [_]u8{65} ++ client_point;

    try std.testing.expectError(
        Error.Tlz_DtlsConnection_Truncated,
        serverFinish(&state, &cke_body, &[_]u8{ 22, 0xFE }, &out),
    );
}

