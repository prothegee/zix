//! TLZ tls12 client
//!
//! ### file: src/tlz/src/tls12/client.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLS 1.2 client handshake (RFC 5246, RFC 5288, ECDHE-ECDSA), sans-I/O, in two
//! phases: `start` builds the ClientHello, `finish` reads the server flight and
//! returns the client flight plus a ClientConnection.
//!
//! ### note:
//!
//! `finish` checks the ServerKeyExchange signature with the certificate key (the
//! handshake binding). Chain and host name trust is the caller's step through
//! `FinishResult.verifyServerCert`, the same split as the TLS 1.3 client.
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
const der_guard = @import("../crypto/der_guard.zig");
const prf = @import("prf.zig");
const record = @import("record.zig");
const ServerFlight = @import("client/ServerFlight.zig");
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

/// An uncompressed secp256r1 point.
const P256_POINT_LENGTH = 65;

/// A Finished message: type, u24 length, verify_data.
const FINISHED_MESSAGE_LENGTH = 4 + prf.VERIFY_DATA_LENGTH;

/// The largest ServerECDHParams the signature check accepts.
const MAX_SKE_PARAMS = 128;

/// The finish path: this module's own errors plus the wire reader.
const Inner = Error || Reader.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_WireReader_Truncated => Error.Tlz_Tls12Client_Truncated,
        error.Tlz_Tls12Client_UnexpectedRecord,
        error.Tlz_Tls12Client_IncompleteFlight,
        error.Tlz_Tls12Client_CertificateTooLarge,
        error.Tlz_Tls12Client_CertificateMalformed,
        error.Tlz_Tls12Client_SignatureFailed,
        error.Tlz_Tls12Client_BadKeyShare,
        error.Tlz_Tls12Client_Truncated,
        => |own| own,
    };
}

/// Reduce 32 random bytes to a valid P-256 scalar. fromBytes48 reduces mod n.
fn p256Scalar(seed: [32]u8) [32]u8 {
    var wide: [48]u8 = std.mem.zeroes([48]u8);
    @memcpy(wide[16..48], &seed);

    return P256.scalar.Scalar.fromBytes48(wide, .big).toBytes(.big);
}

fn writeU16Extension(writer: *Writer, ext_type: ExtensionType, value: u16) void {
    writer.writeU16(@intFromEnum(ext_type));
    writer.writeU16(4);
    writer.writeU16(2);
    writer.writeU16(value);
}

fn parseServerHello(flight: *ServerFlight, msg: []const u8) Reader.Error!void {
    var reader: Reader = .{ .buf = msg };
    _ = try reader.readU16();

    @memcpy(&flight.server_random, try reader.readBytes(32));
    flight.has_server_hello = true;
}

/// TLS 1.2 Certificate (RFC 5246 7.4.2): no request context, unlike TLS 1.3.
fn parseCertificate(flight: *ServerFlight, msg: []const u8) Reader.Error!void {
    var reader: Reader = .{ .buf = msg };
    _ = try reader.readU24();

    const cert_len = try reader.readU24();
    flight.cert_der = try reader.readBytes(cert_len);
}

/// ServerKeyExchange: curve type, named curve, point, then the signature.
fn parseServerKeyExchange(flight: *ServerFlight, msg: []const u8) Reader.Error!void {
    var reader: Reader = .{ .buf = msg };
    _ = try reader.readU8();
    _ = try reader.readU16();

    const point_len = try reader.readU8();
    flight.server_point = try reader.readBytes(point_len);
    flight.ske_params = msg[0..reader.pos];

    _ = try reader.readU16();
    const sig_len = try reader.readU16();
    flight.ske_sig = try reader.readBytes(sig_len);
}

fn parseFlight(body: []const u8) Inner!ServerFlight {
    var flight: ServerFlight = .{};
    var reader: Reader = .{ .buf = body };

    while (reader.remaining() >= 4) {
        const msg_type = try reader.readU8();
        const msg = try reader.readBytes(try reader.readU24());

        switch (msg_type) {
            @intFromEnum(HandshakeType.SERVER_HELLO) => try parseServerHello(&flight, msg),
            @intFromEnum(HandshakeType.CERTIFICATE) => try parseCertificate(&flight, msg),
            @intFromEnum(HandshakeType.SERVER_KEY_EXCHANGE) => {
                try parseServerKeyExchange(&flight, msg);
            },
            else => {},
        }
    }

    if (!flight.isComplete()) return Error.Tlz_Tls12Client_IncompleteFlight;

    return flight;
}

/// Check the ServerKeyExchange ECDSA signature over client_random ++ server_random ++
/// params, made with the certificate key (RFC 5246 7.4.3).
fn verifyServerKeyExchange(flight: *const ServerFlight, client_random: [32]u8) Error!void {
    if (flight.ske_params.len > MAX_SKE_PARAMS) return Error.Tlz_Tls12Client_BadKeyShare;

    if (!der_guard.isSafeCertificate(flight.cert_der)) {
        return Error.Tlz_Tls12Client_CertificateMalformed;
    }

    const cert: std.crypto.Certificate = .{
        .buffer = flight.cert_der,
        .index = 0,
    };
    const parsed = cert.parse() catch |err| switch (err) {
        else => return Error.Tlz_Tls12Client_CertificateMalformed,
    };
    const public_key = EcdsaP256.PublicKey.fromSec1(parsed.pubKey()) catch |err| switch (err) {
        else => return Error.Tlz_Tls12Client_CertificateMalformed,
    };
    const signature = EcdsaP256.Signature.fromDer(flight.ske_sig) catch |err| switch (err) {
        else => return Error.Tlz_Tls12Client_SignatureFailed,
    };

    var signed: [64 + MAX_SKE_PARAMS]u8 = undefined;
    const signed_len = 64 + flight.ske_params.len;
    @memcpy(signed[0..32], &client_random);
    @memcpy(signed[32..64], &flight.server_random);
    @memcpy(signed[64..signed_len], flight.ske_params);

    signature.verify(signed[0..signed_len], public_key) catch |err| switch (err) {
        else => return Error.Tlz_Tls12Client_SignatureFailed,
    };
}

fn finishInner(state: *State, server_flight1: []const u8, out: []u8) Inner!FinishResult {
    // The flight is one handshake record: SH, Certificate, ServerKeyExchange, SHD
    var reader: Reader = .{ .buf = server_flight1 };
    if (try reader.readU8() != @intFromEnum(ContentType.HANDSHAKE)) {
        return Error.Tlz_Tls12Client_UnexpectedRecord;
    }

    _ = try reader.readU16();
    const body = try reader.readBytes(try reader.readU16());

    state.transcript.update(body);

    const flight = try parseFlight(body);
    try verifyServerKeyExchange(&flight, state.client_random);

    if (flight.cert_der.len > MAX_SERVER_CERT_DER) {
        return Error.Tlz_Tls12Client_CertificateTooLarge;
    }

    // ECDHE -> pre_master -> master_secret -> key material
    const client_point = P256.basePoint.mul(state.ephemeral_scalar, .big) catch |err| {
        return switch (err) {
            else => Error.Tlz_Tls12Client_BadKeyShare,
        };
    };
    const server_point = P256.fromSec1(flight.server_point) catch |err| switch (err) {
        else => return Error.Tlz_Tls12Client_BadKeyShare,
    };
    const shared = server_point.mul(state.ephemeral_scalar, .big) catch |err| switch (err) {
        else => return Error.Tlz_Tls12Client_BadKeyShare,
    };
    const pre_master = shared.affineCoordinates().x.toBytes(.big);
    const master = prf.masterSecret(&pre_master, state.client_random, flight.server_random);
    const km = prf.keyMaterial(master, state.client_random, flight.server_random);

    var cke_msg: [4 + 1 + P256_POINT_LENGTH]u8 = undefined;
    cke_msg[0] = @intFromEnum(HandshakeType.CLIENT_KEY_EXCHANGE);
    cke_msg[1] = 0;
    cke_msg[2] = 0;
    cke_msg[3] = 1 + P256_POINT_LENGTH;
    cke_msg[4] = P256_POINT_LENGTH;
    @memcpy(cke_msg[5..], &client_point.toUncompressedSec1());
    state.transcript.update(&cke_msg);

    // The client Finished covers CH..CKE
    const client_vd = prf.finishedFromHash(
        master,
        "client finished",
        state.transcript.current(),
    );
    var cf_msg: [FINISHED_MESSAGE_LENGTH]u8 = undefined;
    cf_msg[0] = @intFromEnum(HandshakeType.FINISHED);
    cf_msg[1] = 0;
    cf_msg[2] = 0;
    cf_msg[3] = prf.VERIFY_DATA_LENGTH;
    @memcpy(cf_msg[4..], &client_vd);
    state.transcript.update(&cf_msg);

    // The server Finished the client expects covers CH..client Finished
    const expected_server = prf.finishedFromHash(
        master,
        "server finished",
        state.transcript.current(),
    );

    // ClientKeyExchange (plaintext), ChangeCipherSpec, the encrypted client Finished
    var writer: Writer = .{ .buf = out };
    writer.writeU8(@intFromEnum(ContentType.HANDSHAKE));
    writer.writeU16(handshake.VERSION_TLS_1_2);
    writer.writeU16(cke_msg.len);
    writer.writeBytes(&cke_msg);
    writer.writeU8(@intFromEnum(ContentType.CHANGE_CIPHER_SPEC));
    writer.writeU16(handshake.VERSION_TLS_1_2);
    writer.writeU16(1);
    writer.writeU8(1);

    const fin_rec = record.protect(
        out[writer.len..],
        &cf_msg,
        @intFromEnum(ContentType.HANDSHAKE),
        km.client_write_key,
        km.client_write_iv,
        0,
    );

    var result: FinishResult = .{
        .to_send = out[0 .. writer.len + fin_rec.len],
        .connection = .{
            .km = km,
        },
        .expected_server_finished = expected_server,
    };
    @memcpy(result.server_cert[0..flight.cert_der.len], flight.cert_der);
    result.server_cert_len = flight.cert_der.len;

    return result;
}

// --------------------------------------------------------- //
// Public:

pub const HandshakeOptions = @import("client/HandshakeOptions.zig");
pub const State = @import("client/State.zig");
pub const StartResult = @import("client/StartResult.zig");
pub const FinishResult = @import("client/FinishResult.zig");
pub const ClientConnection = @import("client/ClientConnection.zig");

pub const Error = error{
    Tlz_Tls12Client_UnexpectedRecord,
    Tlz_Tls12Client_IncompleteFlight,
    Tlz_Tls12Client_CertificateTooLarge,
    Tlz_Tls12Client_CertificateMalformed,
    Tlz_Tls12Client_SignatureFailed,
    Tlz_Tls12Client_BadKeyShare,
    Tlz_Tls12Client_Truncated,
};

/// The largest server end-entity certificate DER `finish` keeps.
pub const MAX_SERVER_CERT_DER = FinishResult.MAX_SERVER_CERT_DER;

/// Phase 1: build the ClientHello (ECDHE-ECDSA-AES128-GCM, secp256r1) and start the
/// transcript.
///
/// Usage:
/// ```zig
/// const started = tls12.client.start(.{
///     .client_random = client_random,
///     .ephemeral_secret = ephemeral_secret,
/// }, &hello_buf);
/// var state = started.state;
///
/// // send started.client_hello in a handshake record, read the server flight 1
///
/// const done = try tls12.client.finish(&state, server_flight1, &out);
/// try done.verifyServerCert(anchor_der, "example.com", now_sec);
///
/// // send done.to_send, read the server CCS + Finished record
///
/// try done.connection.verifyServerFinished(fin_rec, done.expected_server_finished);
/// ```
///
/// Param:
/// opts - HandshakeOptions (randoms)
/// out - []u8 (where the ClientHello is written, 128 bytes is enough)
///
/// Return:
/// - StartResult (`client_hello` is a view into `out`)
pub fn start(opts: HandshakeOptions, out: []u8) StartResult {
    var writer: Writer = .{ .buf = out };
    writer.writeU8(@intFromEnum(HandshakeType.CLIENT_HELLO));
    const header = writer.placeU24();
    writer.writeU16(handshake.VERSION_TLS_1_2);
    writer.writeBytes(&opts.client_random);
    writer.writeU8(0);
    writer.writeU16(2);
    writer.writeU16(@intFromEnum(CipherSuite.ECDHE_ECDSA_AES128_GCM_SHA256));
    writer.writeU8(1);
    writer.writeU8(0);

    const exts = writer.placeU16();
    writeU16Extension(
        &writer,
        .SIGNATURE_ALGORITHMS,
        @intFromEnum(SignatureScheme.ECDSA_SECP256R1_SHA256),
    );
    writeU16Extension(&writer, .SUPPORTED_GROUPS, @intFromEnum(NamedGroup.SECP256R1));
    writer.writeU16(@intFromEnum(ExtensionType.EC_POINT_FORMATS));
    writer.writeU16(2);
    writer.writeU8(1);
    writer.writeU8(0);
    writer.patchU16(exts);
    writer.patchU24(header);

    const client_hello = writer.slice();

    var state: State = .{
        .ephemeral_scalar = p256Scalar(opts.ephemeral_secret),
        .client_random = opts.client_random,
        .transcript = .init(),
    };
    state.transcript.update(client_hello);

    return .{
        .client_hello = client_hello,
        .state = state,
    };
}

/// Phase 2: read the server flight, check the ServerKeyExchange signature, and build
/// the client flight plus the server Finished to expect.
///
/// Param:
/// state - *State (from `start`, the transcript advances)
/// server_flight1 - []const u8 (the one server handshake record, header included)
/// out - []u8 (where the client flight is written, 256 bytes is enough)
///
/// Return:
/// - FinishResult (`to_send` is a view into `out`)
/// - Error.Tlz_Tls12Client_UnexpectedRecord when the record is not a handshake
/// - Error.Tlz_Tls12Client_IncompleteFlight when a needed message is missing
/// - Error.Tlz_Tls12Client_SignatureFailed when the ServerKeyExchange signature fails
/// - Error.Tlz_Tls12Client_BadKeyShare on an invalid server point
pub fn finish(state: *State, server_flight1: []const u8, out: []u8) Error!FinishResult {
    return finishInner(state, server_flight1, out) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const server = @import("connection.zig");

const EC_SCALAR_HEX =
    "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c";

/// Self-signed CN=localhost, SAN DNS:localhost + IP:127.0.0.1. Its key is the
/// EC_SCALAR_HEX scalar, so the ServerKeyExchange verifies against it.
const FIXTURE_CERT_HEX =
    "308201d43082017ba00302010202147a26ee491f091ac7c914f4a810c1ece713402574300a06082a" ++
    "8648ce3d040302302a3112301006035504030c096c6f63616c686f737431143012060355040a0c0b" ++
    "7a69782d746c732d706f63301e170d3236303632323132353432305a170d33363036313931323534" ++
    "32305a302a3112301006035504030c096c6f63616c686f737431143012060355040a0c0b7a69782d" ++
    "746c732d706f633059301306072a8648ce3d020106082a8648ce3d03010703420004c2a0121b298a" ++
    "c9cd389200e78d94e7bde1cc7cd8074795fab4f919799d40fdc231c5a90990ac8c6166ae472f33f7" ++
    "4fced097f2edb7b8a1974be66a4ab07f253ba37f307d301d0603551d0e04160414c34e1d0a36a439" ++
    "47709b539e16dd0213aa4196aa301f0603551d23041830168014c34e1d0a36a43947709b539e16dd" ++
    "0213aa4196aa300f0603551d130101ff040530030101ff301a0603551d110413301182096c6f6361" ++
    "6c686f737487047f000001300e0603551d0f0101ff040403020780300a06082a8648ce3d04030203" ++
    "4700304402200b012f119db9b95d990bc482cb63e8f81e337a08634904e4caf513dc10c8aa830220" ++
    "2fdfe79ff6d5403e753ddf2aa52671923b8a2c28126bcbf196bd6fb7ecbcb14e";

/// About 2027-01, inside the fixture validity window.
const NOW_SEC: i64 = 1_800_000_000;

const TEST_OPTIONS: HandshakeOptions = .{
    .client_random = @splat(0x11),
    .ephemeral_secret = @splat(0x42),
};

/// The client wire output split into its parts.
const ClientFlight = struct {
    cke_msg: []const u8,
    fin_record: []const u8,
};

fn serverOptions(cert_der: []const u8) !server.HandshakeOptions {
    var scalar: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&scalar, EC_SCALAR_HEX);
    const secret_key = try EcdsaP256.SecretKey.fromBytes(scalar);

    return .{
        .certificate_der = cert_der,
        .signing_key = try EcdsaP256.KeyPair.fromSecretKey(secret_key),
        .server_eph_secret = @splat(0x22),
        .server_random = @splat(0x33),
    };
}

fn splitClientFlight(to_send: []const u8) !ClientFlight {
    var reader: Reader = .{ .buf = to_send };
    _ = try reader.readU8();
    _ = try reader.readU16();
    const cke_msg = try reader.readBytes(try reader.readU16());

    _ = try reader.readU8();
    _ = try reader.readU16();
    _ = try reader.readBytes(try reader.readU16());

    return .{
        .cke_msg = cke_msg,
        .fin_record = to_send[reader.pos..],
    };
}

test "tlz tls12: client, start offers the ECDHE-ECDSA suite" {
    var hello_buf: [256]u8 = undefined;

    const started = start(TEST_OPTIONS, &hello_buf);
    const hello = switch (handshake.parseClientHello(started.client_hello)) {
        .ok => |parsed| parsed,
        .alert => return error.TestUnexpectedResult,
    };

    try std.testing.expect(hello.offersCipher(.ECDHE_ECDSA_AES128_GCM_SHA256));
    try std.testing.expect(!hello.offers_tls13);
}

test "tlz tls12: client, start folds the ClientHello into the transcript" {
    var hello_buf: [256]u8 = undefined;
    var expected: @import("../key_schedule/Transcript.zig") = .init();

    const started = start(TEST_OPTIONS, &hello_buf);
    expected.update(started.client_hello);

    try std.testing.expectEqualSlices(
        u8,
        &expected.current(),
        &started.state.transcript.current(),
    );
}

test "tlz tls12: client, handshake against the tlz 1.2 server in memory" {
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, FIXTURE_CERT_HEX);
    var hello_buf: [256]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var client_buf: [512]u8 = undefined;
    var server_out: [256]u8 = undefined;

    const started = start(TEST_OPTIONS, &hello_buf);
    var client_state = started.state;
    const flight1 = try server.serverFlight1(
        try serverOptions(cert_der),
        started.client_hello,
        &flight_buf,
    );
    var server_state = flight1.state;
    const done = try finish(&client_state, flight1.to_send, &client_buf);
    const parts = try splitClientFlight(done.to_send);
    var server_done = try server.serverFinish(
        &server_state,
        parts.cke_msg,
        parts.fin_record,
        &server_out,
    );

    try done.connection.verifyServerFinished(
        server_done.to_send[6..],
        done.expected_server_finished,
    );

    var conn = done.connection;
    var c2s_buf: [256]u8 = undefined;
    var server_in: [256]u8 = undefined;
    const c2s = conn.writeAppData("ping over tls 1.2", &c2s_buf);

    try std.testing.expectEqualSlices(
        u8,
        "ping over tls 1.2",
        try server_done.connection.readAppData(c2s, &server_in),
    );

    var s2c_buf: [256]u8 = undefined;
    var client_in: [256]u8 = undefined;
    const s2c = server_done.connection.writeAppData("pong over tls 1.2", &s2c_buf);

    try std.testing.expectEqualSlices(
        u8,
        "pong over tls 1.2",
        try conn.readAppData(s2c, &client_in),
    );
}

test "tlz tls12: client, finish surfaces the server certificate" {
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, FIXTURE_CERT_HEX);
    var hello_buf: [256]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var client_buf: [512]u8 = undefined;

    const started = start(TEST_OPTIONS, &hello_buf);
    var client_state = started.state;
    const flight1 = try server.serverFlight1(
        try serverOptions(cert_der),
        started.client_hello,
        &flight_buf,
    );
    const done = try finish(&client_state, flight1.to_send, &client_buf);

    try std.testing.expectEqualSlices(u8, cert_der, done.serverCertDer());
    try done.verifyServerCert(cert_der, "localhost", NOW_SEC);
}

test "tlz tls12: client, finish on a tampered ServerKeyExchange fails the signature" {
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, FIXTURE_CERT_HEX);
    var hello_buf: [256]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var client_buf: [512]u8 = undefined;

    const started = start(TEST_OPTIONS, &hello_buf);
    var client_state = started.state;
    const flight1 = try server.serverFlight1(
        try serverOptions(cert_der),
        started.client_hello,
        &flight_buf,
    );

    // The byte before ServerHelloDone is the last signature byte
    flight_buf[flight1.to_send.len - 5] ^= 0x01;

    try std.testing.expectError(
        Error.Tlz_Tls12Client_SignatureFailed,
        finish(&client_state, flight1.to_send, &client_buf),
    );
}

test "tlz tls12: client, finish on a non-handshake record is unexpected" {
    var hello_buf: [256]u8 = undefined;
    var client_buf: [512]u8 = undefined;
    const flight = [_]u8{ 23, 3, 3, 0, 0 };

    const started = start(TEST_OPTIONS, &hello_buf);
    var client_state = started.state;

    try std.testing.expectError(
        Error.Tlz_Tls12Client_UnexpectedRecord,
        finish(&client_state, &flight, &client_buf),
    );
}

test "tlz tls12: client, finish on a short record is truncated" {
    var hello_buf: [256]u8 = undefined;
    var client_buf: [512]u8 = undefined;
    const flight = [_]u8{ 22, 3, 3, 0, 9, 1 };

    const started = start(TEST_OPTIONS, &hello_buf);
    var client_state = started.state;

    try std.testing.expectError(
        Error.Tlz_Tls12Client_Truncated,
        finish(&client_state, &flight, &client_buf),
    );
}

test "tlz tls12: client, finish on a ServerHello alone is an incomplete flight" {
    var hello_buf: [256]u8 = undefined;
    var flight_buf: [128]u8 = undefined;
    var client_buf: [512]u8 = undefined;
    var writer: Writer = .{ .buf = &flight_buf };
    writer.writeU8(@intFromEnum(ContentType.HANDSHAKE));
    writer.writeU16(handshake.VERSION_TLS_1_2);
    const rec_len = writer.placeU16();
    writer.writeU8(@intFromEnum(HandshakeType.SERVER_HELLO));
    writer.writeU24(34);
    writer.writeU16(handshake.VERSION_TLS_1_2);
    writer.writeBytes(&@as([32]u8, @splat(0x33)));
    writer.patchU16(rec_len);

    const started = start(TEST_OPTIONS, &hello_buf);
    var client_state = started.state;

    try std.testing.expectError(
        Error.Tlz_Tls12Client_IncompleteFlight,
        finish(&client_state, writer.slice(), &client_buf),
    );
}

test "tlz tls12: client, finish on a malformed certificate is refused" {
    const bad_der = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };
    var hello_buf: [256]u8 = undefined;
    var flight_buf: [4096]u8 = undefined;
    var client_buf: [512]u8 = undefined;

    const started = start(TEST_OPTIONS, &hello_buf);
    var client_state = started.state;
    const flight1 = try server.serverFlight1(
        try serverOptions(&bad_der),
        started.client_hello,
        &flight_buf,
    );

    try std.testing.expectError(
        Error.Tlz_Tls12Client_CertificateMalformed,
        finish(&client_state, flight1.to_send, &client_buf),
    );
}

