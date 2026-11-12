//! TLZ client
//!
//! ### file: src/tlz/src/client.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLS 1.3 client handshake (RFC 8446), sans-I/O, in two phases: `start` builds the
//! ClientHello, `finish` reads the server flight and returns the client Finished
//! plus a ClientConnection.
//!
//! ### note:
//!
//! Offers X25519 only, with ecdsa_secp256r1_sha256 and ed25519. `finish` checks the
//! server CertificateVerify and Finished. Chain and host name trust is the caller's
//! step through `FinishResult.verifyServerCert`.
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
const Reader = @import("wire/Reader.zig");
const Writer = @import("wire/Writer.zig");
const record = @import("record.zig");
const handshake = @import("handshake.zig");
const key_schedule = @import("key_schedule.zig");
const certificate = @import("crypto/certificate.zig");
const der_guard = @import("crypto/der_guard.zig");
const Transcript = @import("key_schedule/Transcript.zig");
const ServerHelloParsed = @import("client/ServerHelloParsed.zig");
const Alpn = @import("alpn.zig").Alpn;
const HandshakeType = @import("handshake/handshake_type.zig").HandshakeType;
const ExtensionType = @import("extension_type.zig").ExtensionType;
const SignatureScheme = @import("signature_scheme.zig").SignatureScheme;
const NamedGroup = @import("named_group.zig").NamedGroup;
const CipherSuite = @import("cipher_suite.zig").CipherSuite;

const X25519 = std.crypto.dh.X25519;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Ed25519 = std.crypto.sign.Ed25519;
const Secret = key_schedule.Secret;
const HASH_LENGTH = key_schedule.HASH_LENGTH;

// --------------------------------------------------------- //
// Private:

/// Decrypt buffer for the encrypted server flight.
const SERVER_FLIGHT_BUF: usize = 4096;

/// Record content types the server flight carries.
const CONTENT_TYPE_CCS: u8 = 20;
const CONTENT_TYPE_HANDSHAKE: u8 = 22;
const CONTENT_TYPE_APPLICATION_DATA: u8 = 23;

/// The finish path: this module's own errors plus the reader and the record layer.
const Inner = Error || Reader.Error || record.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_WireReader_Truncated => Error.Tlz_Client_Truncated,
        error.Tlz_Record_Overflow => Error.Tlz_Client_RecordOverflow,
        error.Tlz_Record_BadMac => Error.Tlz_Client_BadRecordMac,
        error.Tlz_Record_Decode => Error.Tlz_Client_Decode,
        error.Tlz_Client_UnexpectedRecord,
        error.Tlz_Client_NotServerHello,
        error.Tlz_Client_NoServerKeyShare,
        error.Tlz_Client_BadKeyShare,
        error.Tlz_Client_ServerFinishedMismatch,
        error.Tlz_Client_CertificateTooLarge,
        error.Tlz_Client_CertificateMalformed,
        error.Tlz_Client_UnsupportedSignatureScheme,
        error.Tlz_Client_SignatureFailed,
        error.Tlz_Client_Truncated,
        error.Tlz_Client_RecordOverflow,
        error.Tlz_Client_BadRecordMac,
        error.Tlz_Client_Decode,
        => |own| own,
    };
}

/// Read one record header of the wanted type and return its body.
fn readRecord(reader: *Reader, content_type: u8) Inner![]const u8 {
    if (try reader.readU8() != content_type) return Error.Tlz_Client_UnexpectedRecord;

    _ = try reader.readU16();
    const len = try reader.readU16();

    return reader.readBytes(len);
}

/// The end-entity certificate DER out of a TLS 1.3 Certificate body (RFC 8446 4.4.2).
fn leafCertDer(cert_msg: []const u8) Inner![]const u8 {
    var reader: Reader = .{ .buf = cert_msg };
    const context_len = try reader.readU8();
    _ = try reader.readBytes(context_len);
    _ = try reader.readU24();

    const cert_len = try reader.readU24();

    return reader.readBytes(cert_len);
}

fn selectedAlpnInner(ee_msg: []const u8) Reader.Error!?Alpn {
    var reader: Reader = .{ .buf = ee_msg };
    const exts_len = try reader.readU16();
    var exts: Reader = .{ .buf = try reader.readBytes(exts_len) };

    while (exts.remaining() >= 4) {
        const ext_type = try exts.readU16();
        const ext_len = try exts.readU16();
        const ext_data = try exts.readBytes(ext_len);
        const alpn_type = @intFromEnum(ExtensionType.APPLICATION_LAYER_PROTOCOL_NEGOTIATION);
        if (ext_type != alpn_type) continue;

        var alpn_reader: Reader = .{ .buf = ext_data };
        _ = try alpn_reader.readU16();
        const name_len = try alpn_reader.readU8();
        const name = try alpn_reader.readBytes(name_len);

        for (std.enums.values(Alpn)) |candidate| {
            if (std.mem.eql(u8, name, candidate.token())) return candidate;
        }

        return null;
    }

    return null;
}

/// The one ALPN protocol the server selected in EncryptedExtensions (RFC 7301).
///
/// Return:
/// - Alpn
/// - null when none was selected or the extension is malformed
fn parseSelectedAlpn(ee_msg: []const u8) ?Alpn {
    return selectedAlpnInner(ee_msg) catch |err| switch (err) {
        error.Tlz_WireReader_Truncated => null,
    };
}

fn writeU16List(writer: *Writer, ext_type: ExtensionType, values: []const u16) void {
    writer.writeU16(@intFromEnum(ext_type));
    writer.writeU16(@intCast(2 + values.len * 2));
    writer.writeU16(@intCast(values.len * 2));

    for (values) |value| writer.writeU16(value);
}

fn buildClientHello(
    out: []u8,
    client_random: [32]u8,
    client_public: [32]u8,
    alpn: []const Alpn,
) []const u8 {
    var writer: Writer = .{ .buf = out };
    writer.writeU8(@intFromEnum(HandshakeType.CLIENT_HELLO));
    const header = writer.placeU24();
    writer.writeU16(handshake.VERSION_TLS_1_2);
    writer.writeBytes(&client_random);
    writer.writeU8(0);
    writer.writeU16(2);
    writer.writeU16(@intFromEnum(CipherSuite.AES_128_GCM_SHA256));
    writer.writeU8(1);
    writer.writeU8(0);

    const exts = writer.placeU16();

    writer.writeU16(@intFromEnum(ExtensionType.SUPPORTED_VERSIONS));
    writer.writeU16(3);
    writer.writeU8(2);
    writer.writeU16(handshake.VERSION_TLS_1_3);

    writeU16List(&writer, .SIGNATURE_ALGORITHMS, &.{
        @intFromEnum(SignatureScheme.ECDSA_SECP256R1_SHA256),
        @intFromEnum(SignatureScheme.ED25519),
    });
    writeU16List(&writer, .SUPPORTED_GROUPS, &.{@intFromEnum(NamedGroup.X25519)});

    writer.writeU16(@intFromEnum(ExtensionType.KEY_SHARE));
    const ks_ext = writer.placeU16();
    const ks_list = writer.placeU16();
    writer.writeU16(@intFromEnum(NamedGroup.X25519));
    const key_exchange = writer.placeU16();
    writer.writeBytes(&client_public);
    writer.patchU16(key_exchange);
    writer.patchU16(ks_list);
    writer.patchU16(ks_ext);

    if (alpn.len > 0) {
        writer.writeU16(@intFromEnum(ExtensionType.APPLICATION_LAYER_PROTOCOL_NEGOTIATION));
        const alpn_ext = writer.placeU16();
        const alpn_list = writer.placeU16();
        for (alpn) |protocol| {
            const token = protocol.token();
            writer.writeU8(@intCast(token.len));
            writer.writeBytes(token);
        }

        writer.patchU16(alpn_list);
        writer.patchU16(alpn_ext);
    }

    writer.patchU16(exts);
    writer.patchU24(header);

    return writer.slice();
}

fn verifyEcdsa(public_raw: []const u8, sig_bytes: []const u8, content: []const u8) Error!void {
    const public_key = EcdsaP256.PublicKey.fromSec1(public_raw) catch |err| switch (err) {
        else => return Error.Tlz_Client_CertificateMalformed,
    };
    const signature = EcdsaP256.Signature.fromDer(sig_bytes) catch |err| switch (err) {
        else => return Error.Tlz_Client_SignatureFailed,
    };

    signature.verify(content, public_key) catch |err| switch (err) {
        else => return Error.Tlz_Client_SignatureFailed,
    };
}

fn verifyEd25519(public_raw: []const u8, sig_bytes: []const u8, content: []const u8) Error!void {
    if (sig_bytes.len != Ed25519.Signature.encoded_length) {
        return Error.Tlz_Client_SignatureFailed;
    }

    if (public_raw.len != 32) return Error.Tlz_Client_UnsupportedSignatureScheme;

    const public_bytes = public_raw[0..32].*;
    const public_key = Ed25519.PublicKey.fromBytes(public_bytes) catch |err| switch (err) {
        else => return Error.Tlz_Client_CertificateMalformed,
    };
    const signature = Ed25519.Signature.fromBytes(sig_bytes[0..64].*);

    signature.verify(content, public_key) catch |err| switch (err) {
        else => return Error.Tlz_Client_SignatureFailed,
    };
}

/// Check the server CertificateVerify (RFC 8446 4.4.3) against the leaf key. Accepts
/// the two schemes the ClientHello offers.
fn verifyCertificateVerify(
    cert_msg: []const u8,
    certverify_msg: []const u8,
    transcript_hash: Secret,
) Inner!void {
    const cert_der = try leafCertDer(cert_msg);

    var reader: Reader = .{ .buf = certverify_msg };
    const scheme = try reader.readU16();
    const sig_len = try reader.readU16();
    const sig_bytes = try reader.readBytes(sig_len);

    const cert: std.crypto.Certificate = .{
        .buffer = cert_der,
        .index = 0,
    };
    if (!der_guard.isSafeCertificate(cert_der)) return Error.Tlz_Client_CertificateMalformed;

    const parsed = cert.parse() catch |err| switch (err) {
        else => return Error.Tlz_Client_CertificateMalformed,
    };

    var content_buf: [256]u8 = undefined;
    const content = certificate.certificateVerifyContent(&content_buf, transcript_hash);

    if (scheme == @intFromEnum(SignatureScheme.ECDSA_SECP256R1_SHA256)) {
        return verifyEcdsa(parsed.pubKey(), sig_bytes, content);
    }

    if (scheme == @intFromEnum(SignatureScheme.ED25519)) {
        return verifyEd25519(parsed.pubKey(), sig_bytes, content);
    }

    return Error.Tlz_Client_UnsupportedSignatureScheme;
}

fn parseServerHello(sh_msg: []const u8) Inner!ServerHelloParsed {
    var reader: Reader = .{ .buf = sh_msg };
    if (try reader.readU8() != @intFromEnum(HandshakeType.SERVER_HELLO)) {
        return Error.Tlz_Client_NotServerHello;
    }

    _ = try reader.readU24();
    _ = try reader.readU16();

    var out: ServerHelloParsed = undefined;
    @memcpy(&out.server_random, try reader.readBytes(32));

    const sid_len = try reader.readU8();
    _ = try reader.readBytes(sid_len);
    _ = try reader.readU16();
    _ = try reader.readU8();

    const ext_len = try reader.readU16();
    var exts: Reader = .{ .buf = try reader.readBytes(ext_len) };
    while (exts.remaining() >= 4) {
        const ext_type = try exts.readU16();
        const ext_data = try exts.readBytes(try exts.readU16());
        if (ext_type != @intFromEnum(ExtensionType.KEY_SHARE)) continue;

        var key_share: Reader = .{ .buf = ext_data };
        _ = try key_share.readU16();
        const share = try key_share.readBytes(try key_share.readU16());
        if (share.len != out.server_public.len) return Error.Tlz_Client_BadKeyShare;

        @memcpy(&out.server_public, share);

        return out;
    }

    return Error.Tlz_Client_NoServerKeyShare;
}

/// The messages of the decrypted server flight, plus the transcript snapshots the
/// CertificateVerify and Finished checks need.
const FlightMessages = struct {
    ee_msg: []const u8 = &.{},
    cert_msg: []const u8 = &.{},
    certverify_msg: []const u8 = &.{},
    finished_vd: []const u8 = &.{},
    through_cert: Secret = undefined,
    before_finished: Transcript,
};

/// Fold each inner message into the transcript and keep the ones `finish` checks.
fn walkFlight(transcript: *Transcript, flight: []const u8) Inner!FlightMessages {
    var messages: FlightMessages = .{
        .before_finished = transcript.*,
    };

    var reader: Reader = .{ .buf = flight };
    while (reader.remaining() >= 4) {
        const msg_start = reader.pos;
        const msg_type = try reader.readU8();
        const msg_body = try reader.readBytes(try reader.readU24());

        switch (msg_type) {
            @intFromEnum(HandshakeType.ENCRYPTED_EXTENSIONS) => messages.ee_msg = msg_body,
            @intFromEnum(HandshakeType.CERTIFICATE) => messages.cert_msg = msg_body,
            @intFromEnum(HandshakeType.CERTIFICATE_VERIFY) => messages.certverify_msg = msg_body,
            @intFromEnum(HandshakeType.FINISHED) => {
                messages.before_finished = transcript.*;
                messages.finished_vd = msg_body;
            },
            else => {},
        }

        transcript.update(flight[msg_start..reader.pos]);

        // The CertificateVerify content is the hash through the Certificate
        if (msg_type == @intFromEnum(HandshakeType.CERTIFICATE)) {
            messages.through_cert = transcript.current();
        }
    }

    return messages;
}

fn finishInner(state: *State, server_flight: []const u8, out: []u8) Inner!FinishResult {
    var reader: Reader = .{ .buf = server_flight };

    const sh_msg = try readRecord(&reader, CONTENT_TYPE_HANDSHAKE);
    const server_hello = try parseServerHello(sh_msg);
    state.transcript.update(sh_msg);

    _ = try readRecord(&reader, CONTENT_TYPE_CCS);

    const flight_pos = reader.pos;
    _ = try readRecord(&reader, CONTENT_TYPE_APPLICATION_DATA);
    const flight_record = server_flight[flight_pos..reader.pos];

    // Handshake key schedule from the transcript through ServerHello, as the server runs it
    const secret = state.ephemeral_secret;
    const server_public = server_hello.server_public;
    const ecdhe = X25519.scalarmult(secret, server_public) catch |err| switch (err) {
        else => return Error.Tlz_Client_BadKeyShare,
    };

    const zero = std.mem.zeroes(Secret);
    const empty_hash = Transcript.init().current();
    const early = key_schedule.HkdfSha256.extract(&zero, &zero);
    const derived = key_schedule.deriveSecret(early, "derived", empty_hash);
    const handshake_secret = key_schedule.HkdfSha256.extract(&derived, &ecdhe);

    const ch_sh = state.transcript.current();
    const server_hs_traffic = key_schedule.deriveSecret(handshake_secret, "s hs traffic", ch_sh);
    const client_hs_traffic = key_schedule.deriveSecret(handshake_secret, "c hs traffic", ch_sh);

    var server_hs_key: [record.KEY_LENGTH]u8 = undefined;
    var server_hs_iv: [record.IV_LENGTH]u8 = undefined;
    var client_hs_key: [record.KEY_LENGTH]u8 = undefined;
    var client_hs_iv: [record.IV_LENGTH]u8 = undefined;
    key_schedule.expandLabel(&server_hs_key, server_hs_traffic, "key", "");
    key_schedule.expandLabel(&server_hs_iv, server_hs_traffic, "iv", "");
    key_schedule.expandLabel(&client_hs_key, client_hs_traffic, "key", "");
    key_schedule.expandLabel(&client_hs_iv, client_hs_traffic, "iv", "");

    var flight_plain: [SERVER_FLIGHT_BUF]u8 = undefined;
    const opened = try record.deprotect(
        &flight_plain,
        flight_record,
        server_hs_key,
        server_hs_iv,
        0,
    );
    if (opened.inner_type != .HANDSHAKE) return Error.Tlz_Client_UnexpectedRecord;

    const messages = try walkFlight(&state.transcript, opened.data);

    // The peer signed the transcript with the leaf key (RFC 8446 4.4.3)
    try verifyCertificateVerify(
        messages.cert_msg,
        messages.certverify_msg,
        messages.through_cert,
    );

    const server_finished_key = certificate.finishedKey(server_hs_traffic);
    const expected = certificate.finishedVerifyData(
        server_finished_key,
        messages.before_finished.current(),
    );
    if (!std.mem.eql(u8, messages.finished_vd, &expected)) {
        return Error.Tlz_Client_ServerFinishedMismatch;
    }

    // Application key schedule from the transcript through the server Finished
    const full = state.transcript.current();
    const derived_master = key_schedule.deriveSecret(handshake_secret, "derived", empty_hash);
    const master = key_schedule.HkdfSha256.extract(&derived_master, &zero);
    const server_ap = key_schedule.deriveSecret(master, "s ap traffic", full);
    const client_ap = key_schedule.deriveSecret(master, "c ap traffic", full);

    var conn: ClientConnection = .{
        .client_app_key = undefined,
        .client_app_iv = undefined,
        .server_app_key = undefined,
        .server_app_iv = undefined,
    };
    key_schedule.expandLabel(&conn.server_app_key, server_ap, "key", "");
    key_schedule.expandLabel(&conn.server_app_iv, server_ap, "iv", "");
    key_schedule.expandLabel(&conn.client_app_key, client_ap, "key", "");
    key_schedule.expandLabel(&conn.client_app_iv, client_ap, "iv", "");

    // The client Finished, encrypted under the client handshake key at sequence 0
    var finished_buf: [4 + HASH_LENGTH]u8 = undefined;
    const client_finished_key = certificate.finishedKey(client_hs_traffic);
    const finished_msg = certificate.buildFinished(&finished_buf, client_finished_key, full);
    const client_finished = record.protect(
        out,
        finished_msg,
        .HANDSHAKE,
        client_hs_key,
        client_hs_iv,
        0,
    );

    // Copy the leaf out of the decrypted flight, a stack buffer that dies with finish
    const leaf = try leafCertDer(messages.cert_msg);
    if (leaf.len > MAX_SERVER_CERT_DER) return Error.Tlz_Client_CertificateTooLarge;

    var result: FinishResult = .{
        .client_finished = client_finished,
        .connection = conn,
        .alpn = parseSelectedAlpn(messages.ee_msg),
    };
    @memcpy(result.server_cert[0..leaf.len], leaf);
    result.server_cert_len = leaf.len;

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
    Tlz_Client_UnexpectedRecord,
    Tlz_Client_NotServerHello,
    Tlz_Client_NoServerKeyShare,
    Tlz_Client_BadKeyShare,
    Tlz_Client_ServerFinishedMismatch,
    Tlz_Client_CertificateTooLarge,
    Tlz_Client_CertificateMalformed,
    Tlz_Client_UnsupportedSignatureScheme,
    Tlz_Client_SignatureFailed,
    Tlz_Client_Truncated,
    Tlz_Client_RecordOverflow,
    Tlz_Client_BadRecordMac,
    Tlz_Client_Decode,
};

/// The largest server end-entity certificate DER `finish` keeps.
pub const MAX_SERVER_CERT_DER = FinishResult.MAX_SERVER_CERT_DER;

/// Phase 1: build the ClientHello and start the transcript.
///
/// Usage:
/// ```zig
/// const started = try tlz.Client.start(.{
///     .client_random = client_random,
///     .ephemeral_secret = ephemeral_secret,
///     .alpn = &.{.H2},
/// }, &hello_buf);
/// var state = started.state;
///
/// // send started.client_hello in a handshake record, read the server flight
///
/// var finished = try tlz.Client.finish(&state, server_flight, &finished_buf);
/// try finished.verifyServerCert(anchor_der, "example.com", now_sec);
/// ```
///
/// Param:
/// opts - HandshakeOptions (randoms and ALPN offer)
/// out - []u8 (where the ClientHello is written)
///
/// Return:
/// - StartResult (`client_hello` is a view into `out`)
/// - never fails today. The error union keeps `try start(...)` callers stable.
pub fn start(opts: HandshakeOptions, out: []u8) Error!StartResult {
    const client_public = X25519.recoverPublicKey(opts.ephemeral_secret);
    const client_hello = buildClientHello(out, opts.client_random, client_public, opts.alpn);

    var state: State = .{
        .ephemeral_secret = opts.ephemeral_secret,
        .transcript = .init(),
    };
    state.transcript.update(client_hello);

    return .{
        .client_hello = client_hello,
        .state = state,
    };
}

/// Phase 2: read the server flight (ServerHello, ChangeCipherSpec, the encrypted
/// flight), check the server CertificateVerify and Finished, and build the client
/// Finished.
///
/// Param:
/// state - *State (from `start`, the transcript advances)
/// server_flight - []const u8 (the three server records, back to back)
/// out - []u8 (where the client Finished record is written)
///
/// Return:
/// - FinishResult
/// - Error.Tlz_Client_UnexpectedRecord or NotServerHello on a wrong record
/// - Error.Tlz_Client_SignatureFailed when the CertificateVerify fails
/// - Error.Tlz_Client_ServerFinishedMismatch when the server Finished fails
pub fn finish(state: *State, server_flight: []const u8, out: []u8) Error!FinishResult {
    return finishInner(state, server_flight, out) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const connection = @import("connection.zig");
const builtin = @import("builtin");

const EC_SCALAR_HEX =
    "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c";

/// Self-signed CN=localhost, SAN DNS:localhost + IP:127.0.0.1. Its key is the
/// EC_SCALAR_HEX scalar, so the server CertificateVerify verifies against it.
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

fn serverKeyPair() !EcdsaP256.KeyPair {
    var scalar: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&scalar, EC_SCALAR_HEX);

    return EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(scalar));
}

fn serverOptions(cert_der: []const u8, alpn_prefs: []const Alpn) !connection.HandshakeOptions {
    return .{
        .certificate_der = cert_der,
        .signing_key = .{ .ecdsa_p256 = try serverKeyPair() },
        .ephemeral_secret = @splat(0x99),
        .server_random = @splat(0x55),
        .alpn_prefs = alpn_prefs,
    };
}

fn readExactFd(fd: std.posix.fd_t, buf: []u8) !void {
    var done: usize = 0;

    while (done < buf.len) {
        const rc = std.os.linux.read(fd, buf[done..].ptr, buf.len - done);
        if (std.posix.errno(rc) != .SUCCESS) return error.ReadFailed;
        if (rc == 0) return error.EndOfStream;

        done += rc;
    }
}

fn readRecordFd(fd: std.posix.fd_t, buf: []u8) ![]const u8 {
    try readExactFd(fd, buf[0..5]);

    const len = std.mem.readInt(u16, buf[3..5], .big);
    try readExactFd(fd, buf[5 .. 5 + len]);

    return buf[0 .. 5 + len];
}

fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    var done: usize = 0;

    while (done < bytes.len) {
        const rc = std.os.linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (std.posix.errno(rc) != .SUCCESS) return error.WriteFailed;

        done += rc;
    }
}

/// The server side of the socketpair test: one handshake, one request, one reply.
const SocketServer = struct {
    fd: std.posix.fd_t,
    cert: []const u8,

    fn run(self: SocketServer) void {
        // Best effort: the client side asserts the outcome, a server failure shows
        // up there as a short read
        self.serveOnce() catch |err| switch (err) {
            else => {},
        };
        _ = std.os.linux.close(self.fd);
    }

    fn serveOnce(self: SocketServer) !void {
        var hello_buf: [4096]u8 = undefined;
        const hello_rec = try readRecordFd(self.fd, &hello_buf);
        var out: [4096]u8 = undefined;
        var result = try connection.serverHandshake(
            try serverOptions(self.cert, &.{}),
            hello_rec[5..],
            &out,
        );
        try writeAllFd(self.fd, result.to_send);

        var finished_buf: [256]u8 = undefined;
        try result.connection.verifyClientFinished(try readRecordFd(self.fd, &finished_buf));

        var request_buf: [4096]u8 = undefined;
        var request_plain: [4096]u8 = undefined;
        const request_rec = try readRecordFd(self.fd, &request_buf);
        _ = try result.connection.readAppData(request_rec, &request_plain);

        var reply_buf: [4096]u8 = undefined;
        const reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi";
        try writeAllFd(self.fd, result.connection.writeAppData(reply, &reply_buf));
    }
};

test "tlz: client, handshake against the tlz server in memory" {
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, FIXTURE_CERT_HEX);
    var hello_buf: [512]u8 = undefined;
    var server_out: [4096]u8 = undefined;
    var finished_buf: [128]u8 = undefined;

    const started = try start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
        .alpn = &.{.H2},
    }, &hello_buf);
    var state = started.state;
    var server = try connection.serverHandshake(
        try serverOptions(cert_der, &.{.H2}),
        started.client_hello,
        &server_out,
    );
    var finished = try finish(&state, server.to_send, &finished_buf);

    try std.testing.expectEqual(Alpn.H2, finished.alpn.?);
    try std.testing.expectEqualSlices(u8, cert_der, finished.serverCertDer());
    try finished.verifyServerCert(cert_der, "localhost", NOW_SEC);
    try server.connection.verifyClientFinished(finished.client_finished);
}

test "tlz: client, application data flows both ways after the handshake" {
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, FIXTURE_CERT_HEX);
    var hello_buf: [512]u8 = undefined;
    var server_out: [4096]u8 = undefined;
    var finished_buf: [128]u8 = undefined;
    const started = try start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
    }, &hello_buf);
    var state = started.state;
    var server = try connection.serverHandshake(
        try serverOptions(cert_der, &.{}),
        started.client_hello,
        &server_out,
    );
    var finished = try finish(&state, server.to_send, &finished_buf);
    var c2s_buf: [256]u8 = undefined;
    var s2c_buf: [256]u8 = undefined;
    var server_in: [256]u8 = undefined;
    var client_in: [256]u8 = undefined;

    const c2s = finished.connection.writeAppData("ping from client", &c2s_buf);
    const s2c = server.connection.writeAppData("pong from server", &s2c_buf);

    try std.testing.expectEqualSlices(
        u8,
        "ping from client",
        try server.connection.readAppData(c2s, &server_in),
    );
    try std.testing.expectEqualSlices(
        u8,
        "pong from server",
        try finished.connection.readAppData(s2c, &client_in),
    );
}

test "tlz: client, no ALPN offered gives no ALPN selected" {
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, FIXTURE_CERT_HEX);
    var hello_buf: [512]u8 = undefined;
    var server_out: [4096]u8 = undefined;
    var finished_buf: [128]u8 = undefined;
    const started = try start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
    }, &hello_buf);
    var state = started.state;
    const server = try connection.serverHandshake(
        try serverOptions(cert_der, &.{.H2}),
        started.client_hello,
        &server_out,
    );

    const finished = try finish(&state, server.to_send, &finished_buf);

    try std.testing.expect(finished.alpn == null);
}

test "tlz: client, tampered server flight fails" {
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, FIXTURE_CERT_HEX);
    var hello_buf: [512]u8 = undefined;
    var server_out: [4096]u8 = undefined;
    var finished_buf: [128]u8 = undefined;
    const started = try start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
    }, &hello_buf);
    var state = started.state;
    const server = try connection.serverHandshake(
        try serverOptions(cert_der, &.{}),
        started.client_hello,
        &server_out,
    );
    server_out[server.to_send.len - 1] ^= 0x01;

    try std.testing.expectError(
        Error.Tlz_Client_BadRecordMac,
        finish(&state, server.to_send, &finished_buf),
    );
}

test "tlz: client, flight that does not start with a handshake record is unexpected" {
    var hello_buf: [512]u8 = undefined;
    var finished_buf: [128]u8 = undefined;
    const started = try start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
    }, &hello_buf);
    var state = started.state;
    const flight = [_]u8{ 21, 3, 3, 0, 2, 2, 40 };

    try std.testing.expectError(
        Error.Tlz_Client_UnexpectedRecord,
        finish(&state, &flight, &finished_buf),
    );
}

test "tlz: client, empty flight is truncated" {
    var hello_buf: [512]u8 = undefined;
    var finished_buf: [128]u8 = undefined;
    const started = try start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
    }, &hello_buf);
    var state = started.state;

    try std.testing.expectError(Error.Tlz_Client_Truncated, finish(&state, &.{}, &finished_buf));
}

test "tlz: client, ServerHello without a key share is refused" {
    var server_hello: [44]u8 = @splat(0);
    server_hello[0] = @intFromEnum(HandshakeType.SERVER_HELLO);
    server_hello[3] = 40;
    server_hello[4] = 0x03;
    server_hello[5] = 0x03;
    server_hello[39] = 0x13;
    server_hello[40] = 0x01;

    try std.testing.expectError(
        Error.Tlz_Client_NoServerKeyShare,
        parseServerHello(&server_hello),
    );
}

test "tlz: client, parseSelectedAlpn on garbage is null" {
    try std.testing.expect(parseSelectedAlpn(&[_]u8{ 0x00, 0x09, 0x00 }) == null);
}

test "tlz: client, ClientHello offers TLS 1.3 and ALPN" {
    var hello_buf: [512]u8 = undefined;

    const started = try start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
        .alpn = &.{ .H2, .HTTP_1_1 },
    }, &hello_buf);
    const parsed = handshake.parseClientHello(started.client_hello);

    try std.testing.expect(parsed == .ok);
    try std.testing.expect(parsed.ok.offers_tls13);
    try std.testing.expect(parsed.ok.hasKeyShare(.X25519));
    try std.testing.expect(parsed.ok.alpn != null);
}

test "tlz: client, handshake over a socketpair with real fds" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;

    const linux = std.os.linux;
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, FIXTURE_CERT_HEX);
    var pair: [2]std.posix.fd_t = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair);
    try std.testing.expect(std.posix.errno(rc) == .SUCCESS);
    const client_fd = pair[0];
    defer _ = linux.close(client_fd);

    const server: SocketServer = .{
        .fd = pair[1],
        .cert = cert_der,
    };
    const thread = try std.Thread.spawn(.{}, SocketServer.run, .{server});
    defer thread.join();

    var hello_buf: [512]u8 = undefined;
    const started = try start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
    }, &hello_buf);
    var state = started.state;
    var hello_rec: [600]u8 = undefined;
    hello_rec[0] = CONTENT_TYPE_HANDSHAKE;
    std.mem.writeInt(u16, hello_rec[1..3], handshake.VERSION_TLS_1_2, .big);
    std.mem.writeInt(u16, hello_rec[3..5], @intCast(started.client_hello.len), .big);
    @memcpy(hello_rec[5 .. 5 + started.client_hello.len], started.client_hello);
    try writeAllFd(client_fd, hello_rec[0 .. 5 + started.client_hello.len]);

    var flight_buf: [4096]u8 = undefined;
    var flight_len: usize = 0;
    for (0..3) |_| flight_len += (try readRecordFd(client_fd, flight_buf[flight_len..])).len;

    var finished_buf: [256]u8 = undefined;
    var finished = try finish(&state, flight_buf[0..flight_len], &finished_buf);
    try writeAllFd(client_fd, finished.client_finished);

    var request_buf: [256]u8 = undefined;
    const request = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try writeAllFd(client_fd, finished.connection.writeAppData(request, &request_buf));

    var reply_rec: [4096]u8 = undefined;
    var reply_plain: [4096]u8 = undefined;
    const reply = try finished.connection.readAppData(
        try readRecordFd(client_fd, &reply_rec),
        &reply_plain,
    );

    try std.testing.expect(std.mem.find(u8, reply, "200 OK") != null);
}

