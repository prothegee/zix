//! TLZ tls12 connection
//!
//! ### file: src/tlz/src/tls12/connection.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLS 1.2 server handshake (RFC 5246, RFC 5288, ECDHE-ECDSA, AES-128-GCM), sans-I/O,
//! in two phases: `serverFlight1` answers the ClientHello, `serverFinish` checks the
//! client Finished and returns the Connection.
//!
//! ### note:
//!
//! Only ECDHE_ECDSA_AES128_GCM_SHA256 on secp256r1. The downgrade sentinel is planted
//! when the client also offered TLS 1.3. The TLS 1.3 path (`connection.zig`) is
//! separate.
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
const handshake = @import("../handshake.zig");
const extensions = @import("../extensions.zig");
const prf = @import("prf.zig");
const record = @import("record.zig");
const version = @import("version.zig");
const Alpn = @import("../alpn.zig").Alpn;
const HandshakeType = @import("../handshake/handshake_type.zig").HandshakeType;
const ExtensionType = @import("../extension_type.zig").ExtensionType;
const CipherSuite = @import("../cipher_suite.zig").CipherSuite;
const NamedGroup = @import("../named_group.zig").NamedGroup;
const SignatureScheme = @import("../signature_scheme.zig").SignatureScheme;
const ContentType = @import("../record/content_type.zig").ContentType;

const P256 = std.crypto.ecc.P256;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

// --------------------------------------------------------- //
// Private:

/// ECCurveType named_curve (RFC 8422 5.4).
const CURVE_TYPE_NAMED: u8 = 3;

/// An uncompressed secp256r1 point.
const P256_POINT_LENGTH = 65;

/// ServerECDHParams: curve type, named curve, point length, point.
const SKE_PARAMS_LENGTH = 4 + P256_POINT_LENGTH;

/// A Finished message: type, u24 length, verify_data.
const FINISHED_MESSAGE_LENGTH = 4 + prf.VERIFY_DATA_LENGTH;

/// A ChangeCipherSpec record: header plus one byte.
const CCS_RECORD_LENGTH = 6;

/// The finish path: this module's own errors plus the reader and the record layer.
const Inner = Error || Reader.Error || record.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_WireReader_Truncated => Error.Tlz_Tls12Connection_Truncated,
        error.Tlz_Tls12Record_BadRecord => Error.Tlz_Tls12Connection_BadRecord,
        error.Tlz_Tls12Record_AuthenticationFailed => {
            return Error.Tlz_Tls12Connection_AuthenticationFailed;
        },
        error.Tlz_Tls12Connection_ClientHelloInvalid,
        error.Tlz_Tls12Connection_UnexpectedMessage,
        error.Tlz_Tls12Connection_ClientFinishedMismatch,
        error.Tlz_Tls12Connection_Truncated,
        error.Tlz_Tls12Connection_BadKeyShare,
        error.Tlz_Tls12Connection_SignFailed,
        error.Tlz_Tls12Connection_BadRecord,
        error.Tlz_Tls12Connection_AuthenticationFailed,
        => |own| own,
    };
}

/// Reduce 32 random bytes to a valid P-256 scalar. fromBytes48 reduces mod n.
fn reduceP256Scalar(seed: [32]u8) [32]u8 {
    var wide: [48]u8 = std.mem.zeroes([48]u8);
    @memcpy(wide[16..48], &seed);

    return P256.scalar.Scalar.fromBytes48(wide, .big).toBytes(.big);
}

/// secp256r1 ECDHE: the pre_master is the shared X coordinate (RFC 8422 5.10).
fn ecdheSharedX(scalar: [32]u8, peer_public: []const u8) Error![32]u8 {
    const peer = P256.fromSec1(peer_public) catch |err| switch (err) {
        else => return Error.Tlz_Tls12Connection_BadKeyShare,
    };
    const shared = peer.mul(scalar, .big) catch |err| switch (err) {
        else => return Error.Tlz_Tls12Connection_BadKeyShare,
    };

    return shared.affineCoordinates().x.toBytes(.big);
}

fn writeServerHello(
    writer: *Writer,
    server_random: [32]u8,
    session_id: []const u8,
    alpn: ?Alpn,
) void {
    writer.writeU8(@intFromEnum(HandshakeType.SERVER_HELLO));
    const header = writer.placeU24();

    writer.writeU16(handshake.VERSION_TLS_1_2);
    writer.writeBytes(&server_random);
    writer.writeU8(@intCast(session_id.len));
    writer.writeBytes(session_id);
    writer.writeU16(@intFromEnum(CipherSuite.ECDHE_ECDSA_AES128_GCM_SHA256));
    writer.writeU8(0);

    const exts = writer.placeU16();

    // renegotiation_info (RFC 5746): empty on the initial handshake
    writer.writeU16(@intFromEnum(ExtensionType.RENEGOTIATION_INFO));
    writer.writeU16(1);
    writer.writeU8(0);

    // ec_point_formats (RFC 8422 5.1.2): uncompressed only
    writer.writeU16(@intFromEnum(ExtensionType.EC_POINT_FORMATS));
    writer.writeU16(2);
    writer.writeU8(1);
    writer.writeU8(0);

    // ALPN (RFC 7301): the one selected protocol
    if (alpn) |protocol| {
        writer.writeU16(@intFromEnum(ExtensionType.APPLICATION_LAYER_PROTOCOL_NEGOTIATION));
        const ext = writer.placeU16();
        const list = writer.placeU16();
        const token = protocol.token();
        writer.writeU8(@intCast(token.len));
        writer.writeBytes(token);
        writer.patchU16(list);
        writer.patchU16(ext);
    }

    writer.patchU16(exts);
    writer.patchU24(header);
}

/// TLS 1.2 Certificate (RFC 5246 7.4.2): no request context, one entry.
fn writeCertificate(writer: *Writer, der: []const u8) void {
    writer.writeU8(@intFromEnum(HandshakeType.CERTIFICATE));
    const header = writer.placeU24();
    const list = writer.placeU24();
    const cert = writer.placeU24();

    writer.writeBytes(der);

    writer.patchU24(cert);
    writer.patchU24(list);
    writer.patchU24(header);
}

/// ServerKeyExchange (RFC 5246 7.4.3): the ECDH params, signed over
/// client_random ++ server_random ++ params.
fn writeServerKeyExchange(
    writer: *Writer,
    key: EcdsaP256.KeyPair,
    client_random: [32]u8,
    server_random: [32]u8,
    point: [P256_POINT_LENGTH]u8,
) Error!void {
    var signed: [64 + SKE_PARAMS_LENGTH]u8 = undefined;
    @memcpy(signed[0..32], &client_random);
    @memcpy(signed[32..64], &server_random);
    signed[64] = CURVE_TYPE_NAMED;
    std.mem.writeInt(u16, signed[65..67], @intFromEnum(NamedGroup.SECP256R1), .big);
    signed[67] = P256_POINT_LENGTH;
    @memcpy(signed[68..], &point);

    const signature = key.sign(&signed, null) catch |err| switch (err) {
        else => return Error.Tlz_Tls12Connection_SignFailed,
    };
    var der_buf: [EcdsaP256.Signature.der_encoded_length_max]u8 = undefined;

    writer.writeU8(@intFromEnum(HandshakeType.SERVER_KEY_EXCHANGE));
    const header = writer.placeU24();
    writer.writeBytes(signed[64..]);
    writer.writeU16(@intFromEnum(SignatureScheme.ECDSA_SECP256R1_SHA256));
    const sig_len = writer.placeU16();
    writer.writeBytes(signature.toDer(&der_buf));
    writer.patchU16(sig_len);
    writer.patchU24(header);
}

fn serverFinishInner(
    state: *State,
    client_key_exchange: []const u8,
    client_finished_record: []const u8,
    out: []u8,
) Inner!FinishResult {
    var reader: Reader = .{ .buf = client_key_exchange };
    if (try reader.readU8() != @intFromEnum(HandshakeType.CLIENT_KEY_EXCHANGE)) {
        return Error.Tlz_Tls12Connection_UnexpectedMessage;
    }

    _ = try reader.readU24();
    const point_len = try reader.readU8();
    const client_point = try reader.readBytes(point_len);

    state.transcript.update(client_key_exchange);

    const pre_master = try ecdheSharedX(state.server_eph_scalar, client_point);
    const master = prf.masterSecret(&pre_master, state.client_random, state.server_random);
    const km = prf.keyMaterial(master, state.client_random, state.server_random);

    // The client Finished is sealed under the client key at sequence 0, over CH..CKE
    const expected = prf.finishedFromHash(
        master,
        "client finished",
        state.transcript.current(),
    );
    var cf_plain: [64]u8 = undefined;
    const client_finished = try record.deprotect(
        &cf_plain,
        client_finished_record,
        km.client_write_key,
        km.client_write_iv,
        0,
    );

    if (client_finished.len < FINISHED_MESSAGE_LENGTH) {
        return Error.Tlz_Tls12Connection_UnexpectedMessage;
    }

    if (client_finished[0] != @intFromEnum(HandshakeType.FINISHED)) {
        return Error.Tlz_Tls12Connection_UnexpectedMessage;
    }

    if (!std.mem.eql(u8, client_finished[4..FINISHED_MESSAGE_LENGTH], &expected)) {
        return Error.Tlz_Tls12Connection_ClientFinishedMismatch;
    }

    state.transcript.update(client_finished);

    // The server Finished covers CH..client Finished
    const server_vd = prf.finishedFromHash(
        master,
        "server finished",
        state.transcript.current(),
    );
    var fin_msg: [FINISHED_MESSAGE_LENGTH]u8 = undefined;
    fin_msg[0] = @intFromEnum(HandshakeType.FINISHED);
    fin_msg[1] = 0;
    fin_msg[2] = 0;
    fin_msg[3] = prf.VERIFY_DATA_LENGTH;
    @memcpy(fin_msg[4..], &server_vd);

    // ChangeCipherSpec (plaintext), then the encrypted Finished
    var writer: Writer = .{ .buf = out };
    writer.writeU8(@intFromEnum(ContentType.CHANGE_CIPHER_SPEC));
    writer.writeU16(handshake.VERSION_TLS_1_2);
    writer.writeU16(1);
    writer.writeU8(1);

    const encrypted = record.protect(
        out[CCS_RECORD_LENGTH..],
        &fin_msg,
        @intFromEnum(ContentType.HANDSHAKE),
        km.server_write_key,
        km.server_write_iv,
        0,
    );

    return .{
        .to_send = out[0 .. CCS_RECORD_LENGTH + encrypted.len],
        .connection = .{
            .km = km,
        },
    };
}

// --------------------------------------------------------- //
// Public:

pub const HandshakeOptions = @import("connection/HandshakeOptions.zig");
pub const State = @import("connection/State.zig");
pub const Flight1 = @import("connection/Flight1.zig");
pub const FinishResult = @import("connection/FinishResult.zig");
pub const Connection = @import("connection/Connection.zig");

pub const Error = error{
    Tlz_Tls12Connection_ClientHelloInvalid,
    Tlz_Tls12Connection_UnexpectedMessage,
    Tlz_Tls12Connection_ClientFinishedMismatch,
    Tlz_Tls12Connection_Truncated,
    Tlz_Tls12Connection_BadKeyShare,
    Tlz_Tls12Connection_SignFailed,
    Tlz_Tls12Connection_BadRecord,
    Tlz_Tls12Connection_AuthenticationFailed,
};

/// Phase 1: ClientHello -> ServerHello, Certificate, ServerKeyExchange,
/// ServerHelloDone, as one plaintext handshake record.
///
/// Usage:
/// ```zig
/// const flight = try tls12.connection.serverFlight1(opts, client_hello, &flight_buf);
/// var state = flight.state;
///
/// // send flight.to_send, read ClientKeyExchange and the client Finished record
///
/// var done = try tls12.connection.serverFinish(&state, cke_msg, fin_rec, &out);
/// // send done.to_send, then use done.connection
/// ```
///
/// Param:
/// opts - HandshakeOptions (identity and randomness)
/// client_hello - []const u8 (the ClientHello handshake message, header included)
/// out - []u8 (where the flight is written, sized for the certificate plus about 300)
///
/// Return:
/// - Flight1 (`to_send` is a view into `out`)
/// - Error.Tlz_Tls12Connection_ClientHelloInvalid when the ClientHello does not parse
/// - Error.Tlz_Tls12Connection_BadKeyShare when the ephemeral seed reduces to zero
/// - Error.Tlz_Tls12Connection_SignFailed when the ServerKeyExchange cannot be signed
pub fn serverFlight1(opts: HandshakeOptions, client_hello: []const u8, out: []u8) Error!Flight1 {
    const hello = switch (handshake.parseClientHello(client_hello)) {
        .ok => |parsed| parsed,
        .alert => return Error.Tlz_Tls12Connection_ClientHelloInvalid,
    };

    var state: State = .{
        .client_random = hello.random,
        .server_random = opts.server_random,
        .server_eph_scalar = reduceP256Scalar(opts.server_eph_secret),
        .transcript = .init(),
    };
    if (hello.offers_tls13) version.applyDowngradeSentinel(&state.server_random, .TLS_1_2);

    state.transcript.update(client_hello);

    if (opts.alpn_prefs.len > 0) {
        if (hello.alpn) |client_alpn| {
            state.alpn = extensions.negotiateAlpn(client_alpn, opts.alpn_prefs);
        }
    }

    const server_point = P256.basePoint.mul(state.server_eph_scalar, .big) catch |err| {
        return switch (err) {
            else => Error.Tlz_Tls12Connection_BadKeyShare,
        };
    };

    var writer: Writer = .{ .buf = out };
    writer.writeU8(@intFromEnum(ContentType.HANDSHAKE));
    writer.writeU16(handshake.VERSION_TLS_1_2);
    const rec_len = writer.placeU16();
    const body_start = writer.len;

    writeServerHello(&writer, state.server_random, hello.session_id, state.alpn);
    writeCertificate(&writer, opts.certificate_der);
    try writeServerKeyExchange(
        &writer,
        opts.signing_key,
        state.client_random,
        state.server_random,
        server_point.toUncompressedSec1(),
    );
    writer.writeU8(@intFromEnum(HandshakeType.SERVER_HELLO_DONE));
    writer.writeU24(0);

    state.transcript.update(writer.buf[body_start..writer.len]);
    writer.patchU16(rec_len);

    return .{
        .to_send = writer.slice(),
        .state = state,
    };
}

/// Phase 2: ClientKeyExchange plus the encrypted client Finished -> derive the keys,
/// check the client Finished, emit ChangeCipherSpec plus the encrypted server
/// Finished.
///
/// Param:
/// state - *State (from `serverFlight1`, the transcript advances)
/// client_key_exchange - []const u8 (the ClientKeyExchange message, header included)
/// client_finished_record - []const u8 (the encrypted client Finished record)
/// out - []u8 (at least 6 + 16 + `record.RECORD_OVERHEAD` bytes)
///
/// Return:
/// - FinishResult (`to_send` is a view into `out`)
/// - Error.Tlz_Tls12Connection_UnexpectedMessage on a wrong message type
/// - Error.Tlz_Tls12Connection_BadKeyShare on an invalid client point
/// - Error.Tlz_Tls12Connection_AuthenticationFailed when the Finished record fails
/// - Error.Tlz_Tls12Connection_ClientFinishedMismatch when verify_data is wrong
pub fn serverFinish(
    state: *State,
    client_key_exchange: []const u8,
    client_finished_record: []const u8,
    out: []u8,
) Error!FinishResult {
    return serverFinishInner(
        state,
        client_key_exchange,
        client_finished_record,
        out,
    ) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Transcript = @import("../key_schedule/Transcript.zig");

const EC_SCALAR_HEX =
    "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c";

const DUMMY_DER = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };

const CLIENT_RANDOM: [32]u8 = @splat(0x11);

/// What the test client learns from flight 1 and derives from it.
const ClientSide = struct {
    km: prf.KeyMaterial,
    master: [prf.MASTER_LENGTH]u8,
    transcript: Transcript,
    cke: [4 + 1 + P256_POINT_LENGTH]u8,
};

fn serverKeyPair() !EcdsaP256.KeyPair {
    var scalar: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&scalar, EC_SCALAR_HEX);

    return EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(scalar));
}

fn testOptions(alpn_prefs: []const Alpn) !HandshakeOptions {
    return .{
        .certificate_der = &DUMMY_DER,
        .signing_key = try serverKeyPair(),
        .server_eph_secret = @splat(0x22),
        .server_random = @splat(0x33),
        .alpn_prefs = alpn_prefs,
    };
}

/// A minimal TLS 1.2 ClientHello. `alpn_h2` offers ["h2"], `tls13` adds
/// supported_versions with TLS 1.3.
fn buildClientHello(buf: []u8, alpn_h2: bool, tls13: bool) []const u8 {
    var writer: Writer = .{ .buf = buf };
    writer.writeU8(@intFromEnum(HandshakeType.CLIENT_HELLO));
    const header = writer.placeU24();
    writer.writeU16(handshake.VERSION_TLS_1_2);
    writer.writeBytes(&CLIENT_RANDOM);
    writer.writeU8(0);
    writer.writeU16(2);
    writer.writeU16(@intFromEnum(CipherSuite.ECDHE_ECDSA_AES128_GCM_SHA256));
    writer.writeU8(1);
    writer.writeU8(0);

    const exts = writer.placeU16();

    if (alpn_h2) {
        writer.writeU16(@intFromEnum(ExtensionType.APPLICATION_LAYER_PROTOCOL_NEGOTIATION));
        writer.writeU16(5);
        writer.writeU16(3);
        writer.writeU8(2);
        writer.writeBytes("h2");
    }

    if (tls13) {
        writer.writeU16(@intFromEnum(ExtensionType.SUPPORTED_VERSIONS));
        writer.writeU16(3);
        writer.writeU8(2);
        writer.writeU16(handshake.VERSION_TLS_1_3);
    }

    writer.patchU16(exts);
    writer.patchU24(header);

    return writer.slice();
}

/// Play the client: read flight 1, run ECDHE, build ClientKeyExchange.
fn clientSide(client_hello: []const u8, flight: []const u8) !ClientSide {
    const body = flight[5..];
    var reader: Reader = .{ .buf = body };
    var server_point: []const u8 = &.{};
    var server_random: [32]u8 = undefined;

    while (reader.remaining() >= 4) {
        const msg_type = try reader.readU8();
        const msg = try reader.readBytes(try reader.readU24());
        if (msg_type == @intFromEnum(HandshakeType.SERVER_HELLO)) {
            @memcpy(&server_random, msg[2..34]);
        }

        if (msg_type == @intFromEnum(HandshakeType.SERVER_KEY_EXCHANGE)) {
            server_point = msg[4 .. 4 + msg[3]];
        }
    }

    const scalar = reduceP256Scalar(@splat(0x44));
    const client_point = (try P256.basePoint.mul(scalar, .big)).toUncompressedSec1();
    const pre_master = try ecdheSharedX(scalar, server_point);
    const master = prf.masterSecret(&pre_master, CLIENT_RANDOM, server_random);

    var side: ClientSide = .{
        .km = prf.keyMaterial(master, CLIENT_RANDOM, server_random),
        .master = master,
        .transcript = .init(),
        .cke = undefined,
    };
    side.cke[0] = @intFromEnum(HandshakeType.CLIENT_KEY_EXCHANGE);
    side.cke[1] = 0;
    side.cke[2] = 0;
    side.cke[3] = 1 + P256_POINT_LENGTH;
    side.cke[4] = P256_POINT_LENGTH;
    @memcpy(side.cke[5..], &client_point);

    side.transcript.update(client_hello);
    side.transcript.update(body);
    side.transcript.update(&side.cke);

    return side;
}

fn finishedMessage(verify_data: [prf.VERIFY_DATA_LENGTH]u8) [FINISHED_MESSAGE_LENGTH]u8 {
    var msg: [FINISHED_MESSAGE_LENGTH]u8 = undefined;
    msg[0] = @intFromEnum(HandshakeType.FINISHED);
    msg[1] = 0;
    msg[2] = 0;
    msg[3] = prf.VERIFY_DATA_LENGTH;
    @memcpy(msg[4..], &verify_data);

    return msg;
}

fn clientFinishedRecord(out: []u8, side: *const ClientSide) []const u8 {
    const verify_data = prf.finishedFromHash(
        side.master,
        "client finished",
        side.transcript.current(),
    );
    const msg = finishedMessage(verify_data);

    return record.protect(out, &msg, 22, side.km.client_write_key, side.km.client_write_iv, 0);
}

test "tlz tls12: connection, serverFlight1 negotiates ALPN h2" {
    var hello_buf: [128]u8 = undefined;
    var out: [4096]u8 = undefined;
    const client_hello = buildClientHello(&hello_buf, true, false);

    const flight = try serverFlight1(try testOptions(&.{.H2}), client_hello, &out);

    try std.testing.expectEqual(Alpn.H2, flight.state.alpn.?);
}

test "tlz tls12: connection, serverFlight1 emits the ALPN h2 extension" {
    var hello_buf: [128]u8 = undefined;
    var out: [4096]u8 = undefined;
    const client_hello = buildClientHello(&hello_buf, true, false);
    const ext = [_]u8{ 0x00, 0x10, 0x00, 0x05, 0x00, 0x03, 0x02, 0x68, 0x32 };

    const flight = try serverFlight1(try testOptions(&.{.H2}), client_hello, &out);

    try std.testing.expect(std.mem.indexOf(u8, flight.to_send, &ext) != null);
}

test "tlz tls12: connection, serverFlight1 without server prefs skips ALPN" {
    var hello_buf: [128]u8 = undefined;
    var out: [4096]u8 = undefined;
    const client_hello = buildClientHello(&hello_buf, true, false);

    const flight = try serverFlight1(try testOptions(&.{}), client_hello, &out);

    try std.testing.expect(flight.state.alpn == null);
}

test "tlz tls12: connection, serverFlight1 plants the sentinel for a 1.3 client" {
    var hello_buf: [128]u8 = undefined;
    var out: [4096]u8 = undefined;
    const client_hello = buildClientHello(&hello_buf, false, true);

    const flight = try serverFlight1(try testOptions(&.{}), client_hello, &out);

    try std.testing.expectEqualSlices(
        u8,
        &version.SENTINEL_TLS_1_2,
        flight.state.server_random[24..32],
    );
}

test "tlz tls12: connection, serverFlight1 for a 1.2-only client keeps the random" {
    var hello_buf: [128]u8 = undefined;
    var out: [4096]u8 = undefined;
    const client_hello = buildClientHello(&hello_buf, false, false);
    const expected: [32]u8 = @splat(0x33);

    const flight = try serverFlight1(try testOptions(&.{}), client_hello, &out);

    try std.testing.expectEqualSlices(u8, &expected, &flight.state.server_random);
}

test "tlz tls12: connection, serverFlight1 on a truncated hello is invalid" {
    var hello_buf: [128]u8 = undefined;
    var out: [4096]u8 = undefined;
    const client_hello = buildClientHello(&hello_buf, false, false);

    try std.testing.expectError(
        Error.Tlz_Tls12Connection_ClientHelloInvalid,
        serverFlight1(try testOptions(&.{}), client_hello[0..20], &out),
    );
}

test "tlz tls12: connection, ECDHE-ECDSA handshake round trips in memory" {
    var hello_buf: [128]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var cf_buf: [128]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    var sf_plain: [64]u8 = undefined;
    const client_hello = buildClientHello(&hello_buf, false, false);

    const flight = try serverFlight1(try testOptions(&.{}), client_hello, &flight_buf);
    var state = flight.state;
    var side = try clientSide(client_hello, flight.to_send);
    const cf_rec = clientFinishedRecord(&cf_buf, &side);
    var done = try serverFinish(&state, &side.cke, cf_rec, &out_buf);

    const server_finished = try record.deprotect(
        &sf_plain,
        done.to_send[CCS_RECORD_LENGTH..],
        side.km.server_write_key,
        side.km.server_write_iv,
        0,
    );
    const cf_verify = prf.finishedFromHash(
        side.master,
        "client finished",
        side.transcript.current(),
    );
    const cf_msg = finishedMessage(cf_verify);
    side.transcript.update(&cf_msg);
    const expected = prf.finishedFromHash(
        side.master,
        "server finished",
        side.transcript.current(),
    );

    try std.testing.expectEqualSlices(u8, &expected, server_finished[4..16]);

    var app_buf: [128]u8 = undefined;
    var app_plain: [128]u8 = undefined;
    const app_rec = done.connection.writeAppData("hello over tls 1.2", &app_buf);
    const got = try record.deprotect(
        &app_plain,
        app_rec,
        side.km.server_write_key,
        side.km.server_write_iv,
        1,
    );

    try std.testing.expectEqualSlices(u8, "hello over tls 1.2", got);
}

test "tlz tls12: connection, serverFinish emits ChangeCipherSpec first" {
    var hello_buf: [128]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var cf_buf: [128]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const client_hello = buildClientHello(&hello_buf, false, false);

    const flight = try serverFlight1(try testOptions(&.{}), client_hello, &flight_buf);
    var state = flight.state;
    const side = try clientSide(client_hello, flight.to_send);
    const cf_rec = clientFinishedRecord(&cf_buf, &side);
    const done = try serverFinish(&state, &side.cke, cf_rec, &out_buf);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 20, 3, 3, 0, 1, 1 }, done.to_send[0..6]);
}

test "tlz tls12: connection, serverFinish on a wrong message type is unexpected" {
    var hello_buf: [128]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var cf_buf: [128]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const client_hello = buildClientHello(&hello_buf, false, false);

    const flight = try serverFlight1(try testOptions(&.{}), client_hello, &flight_buf);
    var state = flight.state;
    var side = try clientSide(client_hello, flight.to_send);
    const cf_rec = clientFinishedRecord(&cf_buf, &side);
    side.cke[0] = @intFromEnum(HandshakeType.FINISHED);

    try std.testing.expectError(
        Error.Tlz_Tls12Connection_UnexpectedMessage,
        serverFinish(&state, &side.cke, cf_rec, &out_buf),
    );
}

test "tlz tls12: connection, serverFinish on a truncated ClientKeyExchange is truncated" {
    var hello_buf: [128]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var cf_buf: [128]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const client_hello = buildClientHello(&hello_buf, false, false);

    const flight = try serverFlight1(try testOptions(&.{}), client_hello, &flight_buf);
    var state = flight.state;
    const side = try clientSide(client_hello, flight.to_send);
    const cf_rec = clientFinishedRecord(&cf_buf, &side);

    try std.testing.expectError(
        Error.Tlz_Tls12Connection_Truncated,
        serverFinish(&state, side.cke[0..20], cf_rec, &out_buf),
    );
}

test "tlz tls12: connection, serverFinish on an invalid client point is a bad key share" {
    var hello_buf: [128]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var cf_buf: [128]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const client_hello = buildClientHello(&hello_buf, false, false);

    const flight = try serverFlight1(try testOptions(&.{}), client_hello, &flight_buf);
    var state = flight.state;
    var side = try clientSide(client_hello, flight.to_send);
    const cf_rec = clientFinishedRecord(&cf_buf, &side);
    @memset(side.cke[6..], 0xFF);

    try std.testing.expectError(
        Error.Tlz_Tls12Connection_BadKeyShare,
        serverFinish(&state, &side.cke, cf_rec, &out_buf),
    );
}

test "tlz tls12: connection, serverFinish on a tampered Finished record fails" {
    var hello_buf: [128]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var cf_buf: [128]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const client_hello = buildClientHello(&hello_buf, false, false);

    const flight = try serverFlight1(try testOptions(&.{}), client_hello, &flight_buf);
    var state = flight.state;
    const side = try clientSide(client_hello, flight.to_send);
    const cf_rec = clientFinishedRecord(&cf_buf, &side);
    cf_buf[cf_rec.len - 1] ^= 0x01;

    try std.testing.expectError(
        Error.Tlz_Tls12Connection_AuthenticationFailed,
        serverFinish(&state, &side.cke, cf_rec, &out_buf),
    );
}

test "tlz tls12: connection, serverFinish on wrong verify_data is a mismatch" {
    var hello_buf: [128]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var cf_buf: [128]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const client_hello = buildClientHello(&hello_buf, false, false);

    const flight = try serverFlight1(try testOptions(&.{}), client_hello, &flight_buf);
    var state = flight.state;
    const side = try clientSide(client_hello, flight.to_send);
    const wrong = finishedMessage(@splat(0));
    const cf_rec = record.protect(
        &cf_buf,
        &wrong,
        22,
        side.km.client_write_key,
        side.km.client_write_iv,
        0,
    );

    try std.testing.expectError(
        Error.Tlz_Tls12Connection_ClientFinishedMismatch,
        serverFinish(&state, &side.cke, cf_rec, &out_buf),
    );
}

