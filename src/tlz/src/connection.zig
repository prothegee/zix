//! TLZ connection
//!
//! ### file: src/tlz/src/connection.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLS 1.3 server handshake (RFC 8446), sans-I/O: a ClientHello in, the server
//! flight and the post-handshake Connection out. Also the HelloRetryRequest round
//! and the error to fatal alert matrix.
//!
//! ### note:
//!
//! No socket calls. The caller sends `to_send` and feeds back the client records.
//! The randoms are injected, so the flight is checked against the RFC 8448 trace in
//! the tests below.
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
const Writer = @import("wire/Writer.zig");
const record = @import("record.zig");
const alert = @import("alert.zig");
const handshake = @import("handshake.zig");
const extensions = @import("extensions.zig");
const key_schedule = @import("key_schedule.zig");
const certificate = @import("crypto/certificate.zig");
const Transcript = @import("key_schedule/Transcript.zig");
const ClientHello = @import("handshake/ClientHello.zig");
const ServerHelloParams = @import("handshake/ServerHelloParams.zig");
const KeyExchange = @import("connection/KeyExchange.zig");
const Alert = @import("alert/description.zig").Alert;
const Alpn = @import("alpn.zig").Alpn;
const NamedGroup = @import("named_group.zig").NamedGroup;

const X25519 = std.crypto.dh.X25519;
const P256 = std.crypto.ecc.P256;
const Secret = key_schedule.Secret;
const HASH_LENGTH = key_schedule.HASH_LENGTH;

// --------------------------------------------------------- //
// Private:

/// Server flight build buffer: caps the server certificate plus the flight messages.
const SERVER_FLIGHT_BUF: usize = 4096;

/// HelloRetryRequest build buffer.
const HELLO_RETRY_BUF: usize = 256;

/// The legacy ChangeCipherSpec record sent after the ServerHello (RFC 8446 D.4).
const CCS_RECORD = [_]u8{ 20, 0x03, 0x03, 0x00, 0x01, 0x01 };

/// Record content type handshake(22).
const CONTENT_TYPE_HANDSHAKE: u8 = 22;

/// Handshake type message_hash(254), the synthetic ClientHello1 stand-in.
const MESSAGE_HASH_TYPE: u8 = 0xfe;

/// The handshake paths: this module's own errors plus the CertificateVerify signer.
const Inner = Error || certificate.SignError;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_Certificate_SignFailed => error.Tlz_Connection_SignFailed,
        error.Tlz_Certificate_InvalidKey => error.Tlz_Connection_InvalidKey,
        error.Tlz_Certificate_MessageTooLong => error.Tlz_Connection_MessageTooLong,
        error.Tlz_Connection_MissingKeyShare,
        error.Tlz_Connection_BadKeyShare,
        error.Tlz_Connection_UnsupportedCipher,
        error.Tlz_Connection_UnsupportedGroup,
        error.Tlz_Connection_NoCommonSignatureScheme,
        error.Tlz_Connection_NoApplicationProtocol,
        error.Tlz_Connection_HelloRetryRequestUnsupported,
        error.Tlz_Connection_HelloRetryGroupMismatch,
        error.Tlz_Connection_UnsupportedTlsVersion,
        error.Tlz_Connection_MissingExtension,
        error.Tlz_Connection_HandshakeFailure,
        error.Tlz_Connection_IllegalParameter,
        error.Tlz_Connection_DecodeError,
        error.Tlz_Connection_SignFailed,
        error.Tlz_Connection_InvalidKey,
        error.Tlz_Connection_MessageTooLong,
        => |own| own,
    };
}

/// Map a parse or negotiation alert to the error the caller sees.
fn alertToError(desc: Alert) Error {
    @branchHint(.cold);

    return switch (desc) {
        .MISSING_EXTENSION => Error.Tlz_Connection_MissingExtension,
        .ILLEGAL_PARAMETER => Error.Tlz_Connection_IllegalParameter,
        .DECODE_ERROR => Error.Tlz_Connection_DecodeError,
        else => Error.Tlz_Connection_HandshakeFailure,
    };
}

fn parseHello(bytes: []const u8) Error!ClientHello {
    return switch (handshake.parseClientHello(bytes)) {
        .ok => |hello| hello,
        .alert => |desc| alertToError(desc),
    };
}

fn writeRecordHeader(writer: *Writer, content_type: u8, length: usize) void {
    writer.writeU8(content_type);
    writer.writeU16(handshake.VERSION_TLS_1_2);
    writer.writeU16(@intCast(length));
}

/// Reduce 32 random bytes to a valid P-256 scalar. fromBytes48 reduces mod n.
fn reduceP256Scalar(seed: [32]u8) [32]u8 {
    var wide: [48]u8 = std.mem.zeroes([48]u8);
    @memcpy(wide[16..48], &seed);

    return P256.scalar.Scalar.fromBytes48(wide, .big).toBytes(.big);
}

fn x25519Exchange(ephemeral_secret: [32]u8, client_public: []const u8) Error!KeyExchange {
    if (client_public.len != 32) return Error.Tlz_Connection_BadKeyShare;

    const server_public = X25519.recoverPublicKey(ephemeral_secret);
    const shared = X25519.scalarmult(ephemeral_secret, client_public[0..32].*) catch |err| {
        return switch (err) {
            else => Error.Tlz_Connection_BadKeyShare,
        };
    };

    var kex: KeyExchange = .{
        .server_public = undefined,
        .server_public_len = 32,
        .shared = shared,
    };
    @memcpy(kex.server_public[0..32], &server_public);

    return kex;
}

/// secp256r1 ECDHE: the shared secret is the X coordinate (RFC 8446 7.4.2).
fn p256Exchange(ephemeral_secret: [32]u8, client_public: []const u8) Error!KeyExchange {
    const scalar = reduceP256Scalar(ephemeral_secret);

    const server_point = P256.basePoint.mul(scalar, .big) catch |err| switch (err) {
        else => return Error.Tlz_Connection_BadKeyShare,
    };
    const client_point = P256.fromSec1(client_public) catch |err| switch (err) {
        else => return Error.Tlz_Connection_BadKeyShare,
    };
    const shared_point = client_point.mul(scalar, .big) catch |err| switch (err) {
        else => return Error.Tlz_Connection_BadKeyShare,
    };

    return .{
        .server_public = server_point.toUncompressedSec1(),
        .server_public_len = 65,
        .shared = shared_point.affineCoordinates().x.toBytes(.big),
    };
}

/// Run the server side of ECDHE for the negotiated group (RFC 8446 7.4).
fn computeKeyExchange(
    group: NamedGroup,
    ephemeral_secret: [32]u8,
    client_public: []const u8,
) Error!KeyExchange {
    return switch (group) {
        .X25519 => x25519Exchange(ephemeral_secret, client_public),
        .SECP256R1 => p256Exchange(ephemeral_secret, client_public),
        else => Error.Tlz_Connection_UnsupportedGroup,
    };
}

/// The client key share for the negotiated group.
fn clientShare(hello: *const ClientHello, group: NamedGroup) Error![]const u8 {
    return switch (group) {
        .X25519 => hello.x25519_share orelse Error.Tlz_Connection_MissingKeyShare,
        .SECP256R1 => hello.secp256r1_share orelse Error.Tlz_Connection_MissingKeyShare,
        else => Error.Tlz_Connection_UnsupportedGroup,
    };
}

/// Select one ALPN protocol when the server has prefs and the client offered a list.
/// No overlap is the no_application_protocol condition (RFC 7301 3.2).
fn selectAlpn(opts: HandshakeOptions, hello: *const ClientHello) Error!?Alpn {
    if (opts.alpn_prefs.len == 0) return null;

    const client_alpn = hello.alpn orelse return null;

    return extensions.negotiateAlpn(client_alpn, opts.alpn_prefs) orelse {
        return Error.Tlz_Connection_NoApplicationProtocol;
    };
}

/// Write one message into the flight and fold it into the transcript.
fn appendMessage(flight: *Writer, transcript: *Transcript, message: []const u8) void {
    flight.len += message.len;
    transcript.update(message);
}

/// Build the encrypted flight: EncryptedExtensions, an optional CertificateRequest,
/// Certificate, CertificateVerify, Finished.
fn buildFlight(
    flight: *Writer,
    opts: HandshakeOptions,
    selected_alpn: ?Alpn,
    server_finished_key: Secret,
    transcript: *Transcript,
) Inner!void {
    const encrypted_extensions = extensions.buildEncryptedExtensions(flight.buf[flight.len..], .{
        .alpn_selected = selected_alpn,
    });
    appendMessage(flight, transcript, encrypted_extensions);

    if (opts.request_client_cert) {
        const cert_request = certificate.buildCertificateRequest(flight.buf[flight.len..]);
        appendMessage(flight, transcript, cert_request);
    }

    const cert_msg = certificate.buildCertificate(
        flight.buf[flight.len..],
        opts.certificate_der,
    );
    appendMessage(flight, transcript, cert_msg);

    const server_cert_verify = try certificate.buildCertificateVerify(
        flight.buf[flight.len..],
        opts.signing_key,
        transcript.current(),
        opts.pss_salt,
    );
    appendMessage(flight, transcript, server_cert_verify);

    const finished = certificate.buildFinished(
        flight.buf[flight.len..],
        server_finished_key,
        transcript.current(),
    );
    appendMessage(flight, transcript, finished);
}

/// The ServerHello, flight, and key schedule from a transcript already seeded with
/// the ClientHello (or the HelloRetryRequest round).
fn completeHandshake(
    opts: HandshakeOptions,
    hello: *const ClientHello,
    negotiated: ServerHelloParams,
    transcript: *Transcript,
    out: []u8,
) Inner!HandshakeResult {
    // The key schedule is SHA-256 / AES-128-GCM only, negotiate never picks another
    if (negotiated.cipher != .AES_128_GCM_SHA256) return Error.Tlz_Connection_UnsupportedCipher;

    // The client must have offered the key's scheme (RFC 8446 4.4.2.2, 4.4.3)
    if (!hello.offersSignatureScheme(opts.signing_key.scheme())) {
        return Error.Tlz_Connection_NoCommonSignatureScheme;
    }

    const selected_alpn = try selectAlpn(opts, hello);
    const share = try clientShare(hello, negotiated.group);
    const kex = try computeKeyExchange(negotiated.group, opts.ephemeral_secret, share);

    // ServerHello as a plaintext handshake record, then the legacy ChangeCipherSpec
    var writer: Writer = .{ .buf = out };
    const server_hello = handshake.serializeServerHello(
        writer.buf[writer.len + 5 ..],
        &opts.server_random,
        hello.session_id,
        .{
            .cipher = negotiated.cipher,
            .group = negotiated.group,
            .key_exchange = kex.serverPublic(),
        },
    );
    transcript.update(server_hello);
    writeRecordHeader(&writer, CONTENT_TYPE_HANDSHAKE, server_hello.len);
    writer.len += server_hello.len;
    writer.writeBytes(&CCS_RECORD);

    // Handshake key schedule from the transcript through ServerHello
    const zero = std.mem.zeroes(Secret);
    const empty_hash = Transcript.init().current();
    const early = key_schedule.HkdfSha256.extract(&zero, &zero);
    const derived = key_schedule.deriveSecret(early, "derived", empty_hash);
    const handshake_secret = key_schedule.HkdfSha256.extract(&derived, &kex.shared);

    const ch_sh = transcript.current();
    const server_hs_traffic = key_schedule.deriveSecret(handshake_secret, "s hs traffic", ch_sh);
    const client_hs_traffic = key_schedule.deriveSecret(handshake_secret, "c hs traffic", ch_sh);

    var server_hs_key: [record.KEY_LENGTH]u8 = undefined;
    var server_hs_iv: [record.IV_LENGTH]u8 = undefined;
    var connection: Connection = undefined;
    key_schedule.expandLabel(&server_hs_key, server_hs_traffic, "key", "");
    key_schedule.expandLabel(&server_hs_iv, server_hs_traffic, "iv", "");
    key_schedule.expandLabel(&connection.client_hs_key, client_hs_traffic, "key", "");
    key_schedule.expandLabel(&connection.client_hs_iv, client_hs_traffic, "iv", "");
    connection.client_finished_key = certificate.finishedKey(client_hs_traffic);

    var flight_buf: [SERVER_FLIGHT_BUF]u8 = undefined;
    var flight: Writer = .{ .buf = &flight_buf };
    const server_finished_key = certificate.finishedKey(server_hs_traffic);
    try buildFlight(&flight, opts, selected_alpn, server_finished_key, transcript);

    const flight_record = record.protect(
        writer.buf[writer.len..],
        flight.slice(),
        .HANDSHAKE,
        server_hs_key,
        server_hs_iv,
        0,
    );
    writer.len += flight_record.len;

    // Application key schedule from the transcript through the server Finished
    connection.handshake_transcript = transcript.*;
    const through_finished = transcript.current();
    const derived_master = key_schedule.deriveSecret(handshake_secret, "derived", empty_hash);
    const master = key_schedule.HkdfSha256.extract(&derived_master, &zero);
    const server_ap = key_schedule.deriveSecret(master, "s ap traffic", through_finished);
    const client_ap = key_schedule.deriveSecret(master, "c ap traffic", through_finished);
    key_schedule.expandLabel(&connection.server_app_key, server_ap, "key", "");
    key_schedule.expandLabel(&connection.server_app_iv, server_ap, "iv", "");
    key_schedule.expandLabel(&connection.client_app_key, client_ap, "key", "");
    key_schedule.expandLabel(&connection.client_app_iv, client_ap, "iv", "");
    connection.client_hs_seq = 0;
    connection.server_app_seq = 0;
    connection.client_app_seq = 0;

    return .{
        .connection = connection,
        .to_send = writer.slice(),
        .alpn = selected_alpn,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Connection = @import("connection/Connection.zig");
pub const HandshakeOptions = @import("connection/HandshakeOptions.zig");
pub const HandshakeResult = @import("connection/HandshakeResult.zig");
pub const RetryState = @import("connection/RetryState.zig");
pub const RetryFlight = @import("connection/RetryFlight.zig");

pub const Error = error{
    Tlz_Connection_MissingKeyShare,
    Tlz_Connection_BadKeyShare,
    Tlz_Connection_UnsupportedCipher,
    Tlz_Connection_UnsupportedGroup,
    Tlz_Connection_NoCommonSignatureScheme,
    Tlz_Connection_NoApplicationProtocol,
    Tlz_Connection_HelloRetryRequestUnsupported,
    Tlz_Connection_HelloRetryGroupMismatch,
    Tlz_Connection_UnsupportedTlsVersion,
    Tlz_Connection_MissingExtension,
    Tlz_Connection_HandshakeFailure,
    Tlz_Connection_IllegalParameter,
    Tlz_Connection_DecodeError,
    Tlz_Connection_SignFailed,
    Tlz_Connection_InvalidKey,
    Tlz_Connection_MessageTooLong,
};

/// Drive the server side of a TLS 1.3 handshake from one ClientHello.
///
/// Param:
/// opts - HandshakeOptions (identity, randoms, policy)
/// client_hello - []const u8 (the ClientHello message, without the record header)
/// out - []u8 (where the server flight is written)
///
/// Return:
/// - HandshakeResult (`to_send` is a view into `out`)
/// - Error.Tlz_Connection_HelloRetryRequestUnsupported when a retry is needed. Call
///   `serverHelloRetry` first to handle that round.
/// - Error.Tlz_Connection_UnsupportedTlsVersion when TLS 1.3 is not offered
/// - any other Error member, see `alertForError` for the alert to send
pub fn serverHandshake(
    opts: HandshakeOptions,
    client_hello: []const u8,
    out: []u8,
) Error!HandshakeResult {
    const hello = try parseHello(client_hello);

    const negotiated = switch (handshake.negotiate(&hello, &.{}, opts.group_prefs)) {
        .server_hello => |params| params,
        .hello_retry_request => return Error.Tlz_Connection_HelloRetryRequestUnsupported,
        .legacy_version => return Error.Tlz_Connection_UnsupportedTlsVersion,
        .alert => |desc| return alertToError(desc),
    };

    var transcript: Transcript = .init();
    transcript.update(client_hello);

    return completeHandshake(opts, &hello, negotiated, &transcript, out) catch |err| {
        return innerError(err);
    };
}

/// Emit a HelloRetryRequest (RFC 8446 4.1.4) when the client picked a supported
/// group without a key share for it.
///
/// Note:
/// - ClientHello1 is replaced in the transcript by a synthetic message_hash message
///   wrapping Hash(ClientHello1) (RFC 8446 4.4.1).
///
/// Param:
/// opts - HandshakeOptions (identity, randoms, policy)
/// client_hello1 - []const u8 (the first ClientHello message)
/// out - []u8 (where the HelloRetryRequest record and a ChangeCipherSpec go)
///
/// Return:
/// - RetryFlight (send `to_send`, keep `state` for the second ClientHello)
/// - null when no retry is needed, so the caller runs `serverHandshake`
/// - Error.Tlz_Connection_UnsupportedTlsVersion or a parse error
pub fn serverHelloRetry(
    opts: HandshakeOptions,
    client_hello1: []const u8,
    out: []u8,
) Error!?RetryFlight {
    const hello = try parseHello(client_hello1);

    const group = switch (handshake.negotiate(&hello, &.{}, opts.group_prefs)) {
        .hello_retry_request => |requested| requested,
        .server_hello => return null,
        .legacy_version => return Error.Tlz_Connection_UnsupportedTlsVersion,
        .alert => |desc| return alertToError(desc),
    };

    var hrr_buf: [HELLO_RETRY_BUF]u8 = undefined;
    const hrr = handshake.serializeHelloRetryRequest(
        &hrr_buf,
        hello.session_id,
        .AES_128_GCM_SHA256,
        group,
    );

    var writer: Writer = .{ .buf = out };
    writeRecordHeader(&writer, CONTENT_TYPE_HANDSHAKE, hrr.len);
    writer.writeBytes(hrr);
    writer.writeBytes(&CCS_RECORD);

    var first_hello: Transcript = .init();
    first_hello.update(client_hello1);

    var synthetic: [4 + HASH_LENGTH]u8 = undefined;
    synthetic[0] = MESSAGE_HASH_TYPE;
    synthetic[1] = 0;
    synthetic[2] = 0;
    synthetic[3] = @intCast(HASH_LENGTH);
    @memcpy(synthetic[4..], &first_hello.current());

    var transcript: Transcript = .init();
    transcript.update(&synthetic);
    transcript.update(hrr);

    return .{
        .to_send = writer.slice(),
        .state = .{
            .opts = opts,
            .transcript = transcript,
            .group = group,
        },
    };
}

/// Resume the handshake on the second ClientHello. Only one retry is allowed
/// (RFC 8446 4.1.4).
///
/// Param:
/// state - RetryState (from `serverHelloRetry`)
/// client_hello2 - []const u8 (the second ClientHello message)
/// out - []u8 (where the server flight is written)
///
/// Return:
/// - HandshakeResult (`to_send` is a view into `out`)
/// - Error.Tlz_Connection_HelloRetryRequestUnsupported when the key share is still missing
/// - Error.Tlz_Connection_HelloRetryGroupMismatch when another group is used
pub fn serverHandshakeAfterRetry(
    state: RetryState,
    client_hello2: []const u8,
    out: []u8,
) Error!HandshakeResult {
    const hello = try parseHello(client_hello2);

    const negotiated = switch (handshake.negotiate(&hello, &.{}, state.opts.group_prefs)) {
        .server_hello => |params| params,
        .hello_retry_request => return Error.Tlz_Connection_HelloRetryRequestUnsupported,
        .legacy_version => return Error.Tlz_Connection_UnsupportedTlsVersion,
        .alert => |desc| return alertToError(desc),
    };
    if (negotiated.group != state.group) return Error.Tlz_Connection_HelloRetryGroupMismatch;

    var transcript = state.transcript;
    transcript.update(client_hello2);

    return completeHandshake(state.opts, &hello, negotiated, &transcript, out) catch |err| {
        return innerError(err);
    };
}

/// The condition to fatal alert matrix (RFC 8446 6): the alert the server sends
/// before closing on a handshake failure.
///
/// Param:
/// err - Error (from `serverHandshake`, `serverHelloRetry`, or `serverHandshakeAfterRetry`)
///
/// Return:
/// - Alert
/// - null when no alert is defined (close silently)
pub fn alertForError(err: Error) ?Alert {
    return switch (err) {
        error.Tlz_Connection_NoApplicationProtocol => .NO_APPLICATION_PROTOCOL,
        error.Tlz_Connection_MissingExtension => .MISSING_EXTENSION,
        error.Tlz_Connection_DecodeError => .DECODE_ERROR,
        error.Tlz_Connection_UnsupportedTlsVersion => .PROTOCOL_VERSION,
        error.Tlz_Connection_IllegalParameter,
        error.Tlz_Connection_MissingKeyShare,
        error.Tlz_Connection_BadKeyShare,
        => .ILLEGAL_PARAMETER,
        error.Tlz_Connection_HandshakeFailure,
        error.Tlz_Connection_UnsupportedCipher,
        error.Tlz_Connection_UnsupportedGroup,
        error.Tlz_Connection_HelloRetryRequestUnsupported,
        error.Tlz_Connection_NoCommonSignatureScheme,
        => .HANDSHAKE_FAILURE,
        error.Tlz_Connection_HelloRetryGroupMismatch,
        error.Tlz_Connection_SignFailed,
        error.Tlz_Connection_InvalidKey,
        error.Tlz_Connection_MessageTooLong,
        => null,
    };
}

/// Build the plaintext fatal alert record for a handshake failure. These failures
/// happen before the handshake keys exist, so the alert goes in the clear.
///
/// Param:
/// buf - *[alert.FATAL_RECORD_LEN]u8 (the destination)
/// err - Error (the handshake failure)
///
/// Return:
/// - []const u8 (the alert record, a view into `buf`)
/// - null when no alert is defined
pub fn alertRecordForError(buf: *[alert.FATAL_RECORD_LEN]u8, err: Error) ?[]const u8 {
    const desc = alertForError(err) orelse return null;

    return alert.fatalRecord(buf, desc);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Reader = @import("wire/Reader.zig");
const cert_verify = @import("crypto/cert_verify.zig");
const HandshakeType = @import("handshake/handshake_type.zig").HandshakeType;
const ExtensionType = @import("extension_type.zig").ExtensionType;
const SignatureScheme = @import("signature_scheme.zig").SignatureScheme;
const CipherSuite = @import("cipher_suite.zig").CipherSuite;

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

/// The RFC 8448 simple 1-RTT ClientHello.
const RFC8448_CLIENT_HELLO_HEX =
    "010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece70000" ++
    "06130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d00" ++
    "17001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e" ++
    "435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603" ++
    "020308040805080604010501060102010402050206020202002d00020101001c00024001";

/// The RFC 8448 simple 1-RTT ServerHello.
const RFC8448_SERVER_HELLO_HEX =
    "020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e269280013" ++
    "0100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b0" ++
    "4e751f0f002b00020304";

const RFC8448_EPHEMERAL_HEX =
    "b1580eeadf6dd589b8ef4f2d5652578cc810e9980191ec8d058308cea216a21e";
const RFC8448_SERVER_RANDOM_HEX =
    "a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e26928";
const RFC8448_HS_KEY_HEX = "3fce516009c21727d0f2e4e86ee403bc";
const RFC8448_HS_IV_HEX = "5d313eb2671276ee13000b30";
const EC_SCALAR_HEX =
    "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c";

/// Self-signed CN=localhost, SAN DNS:localhost + IP:127.0.0.1. Its key is the
/// EC_SCALAR_HEX scalar, so it plays both the server and the client certificate.
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

const DUMMY_DER = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };

/// About 2027-01, inside the fixture validity window.
const NOW_SEC: i64 = 1_800_000_000;

fn fromHex(comptime len: usize, comptime hex: []const u8) ![len]u8 {
    var out: [len]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, hex);

    return out;
}

fn fixtureKeyPair() !EcdsaP256.KeyPair {
    const scalar = try fromHex(32, EC_SCALAR_HEX);

    return EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(scalar));
}

/// Options matching the RFC 8448 trace server randoms.
fn traceOptions(certificate_der: []const u8, request_client_cert: bool) !HandshakeOptions {
    return .{
        .certificate_der = certificate_der,
        .signing_key = .{ .ecdsa_p256 = try fixtureKeyPair() },
        .ephemeral_secret = try fromHex(32, RFC8448_EPHEMERAL_HEX),
        .server_random = try fromHex(32, RFC8448_SERVER_RANDOM_HEX),
        .request_client_cert = request_client_cert,
    };
}

/// Skip one record header and return the record body.
fn readRecordBody(reader: *Reader, content_type: u8) ![]const u8 {
    try std.testing.expectEqual(content_type, try reader.readU8());
    _ = try reader.readU16();

    const len = try reader.readU16();

    return reader.readBytes(len);
}

/// Build a client CertificateVerify message signed over `transcript_hash`.
fn clientCertificateVerify(
    buf: []u8,
    key_pair: EcdsaP256.KeyPair,
    transcript_hash: Secret,
) ![]const u8 {
    var content_buf: [160]u8 = undefined;
    const content = certificate.clientCertificateVerifyContent(&content_buf, transcript_hash);
    const signature = try key_pair.sign(content, null);
    var der_buf: [EcdsaP256.Signature.der_encoded_length_max]u8 = undefined;

    var writer: Writer = .{ .buf = buf };
    writer.writeU8(@intFromEnum(HandshakeType.CERTIFICATE_VERIFY));
    const header = writer.placeU24();
    writer.writeU16(@intFromEnum(SignatureScheme.ECDSA_SECP256R1_SHA256));
    const sig_field = writer.placeU16();
    writer.writeBytes(signature.toDer(&der_buf));
    writer.patchU16(sig_field);
    writer.patchU24(header);

    return writer.slice();
}

/// Seal one client handshake message under the connection's client handshake key.
fn sealClientHandshake(
    out: []u8,
    message: []const u8,
    conn: *const Connection,
    seq: u64,
) []const u8 {
    return record.protect(out, message, .HANDSHAKE, conn.client_hs_key, conn.client_hs_iv, seq);
}

/// A ClientHello offering X25519 and secp256r1, with key shares only for the groups
/// passed in. A null share is offered without a key share, the HRR trigger.
fn buildHrrClientHello(
    buf: []u8,
    x25519_share: ?[]const u8,
    secp_share: ?[]const u8,
) []const u8 {
    var writer: Writer = .{ .buf = buf };
    writer.writeU8(@intFromEnum(HandshakeType.CLIENT_HELLO));
    const header = writer.placeU24();
    writer.writeU16(handshake.VERSION_TLS_1_2);
    writer.writeBytes(&std.mem.zeroes([32]u8));
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
    writer.writeU16(@intFromEnum(ExtensionType.SIGNATURE_ALGORITHMS));
    writer.writeU16(4);
    writer.writeU16(2);
    writer.writeU16(@intFromEnum(SignatureScheme.ECDSA_SECP256R1_SHA256));
    writer.writeU16(@intFromEnum(ExtensionType.SUPPORTED_GROUPS));
    writer.writeU16(6);
    writer.writeU16(4);
    writer.writeU16(@intFromEnum(NamedGroup.X25519));
    writer.writeU16(@intFromEnum(NamedGroup.SECP256R1));

    writer.writeU16(@intFromEnum(ExtensionType.KEY_SHARE));
    const ks_ext = writer.placeU16();
    const ks_list = writer.placeU16();
    if (x25519_share) |share| {
        writer.writeU16(@intFromEnum(NamedGroup.X25519));
        writer.writeU16(@intCast(share.len));
        writer.writeBytes(share);
    }

    if (secp_share) |share| {
        writer.writeU16(@intFromEnum(NamedGroup.SECP256R1));
        writer.writeU16(@intCast(share.len));
        writer.writeBytes(share);
    }

    writer.patchU16(ks_list);
    writer.patchU16(ks_ext);
    writer.patchU16(exts);
    writer.patchU24(header);

    return writer.slice();
}

test "tlz: connection, RFC 8448 ServerHello record is byte exact" {
    const client_hello = try fromHex(196, RFC8448_CLIENT_HELLO_HEX);
    const expected = try fromHex(90, RFC8448_SERVER_HELLO_HEX);
    var out: [4096]u8 = undefined;

    const result = try serverHandshake(try traceOptions(&DUMMY_DER, false), &client_hello, &out);

    var reader: Reader = .{ .buf = result.to_send };
    try std.testing.expectEqualSlices(u8, &expected, try readRecordBody(&reader, 22));
    try std.testing.expectEqualSlices(u8, &[_]u8{0x01}, try readRecordBody(&reader, 20));
}

test "tlz: connection, RFC 8448 flight decrypts to EE, Certificate, CertVerify, Finished" {
    const client_hello = try fromHex(196, RFC8448_CLIENT_HELLO_HEX);
    var out: [4096]u8 = undefined;
    var plain: [4096]u8 = undefined;

    const result = try serverHandshake(try traceOptions(&DUMMY_DER, false), &client_hello, &out);

    var reader: Reader = .{ .buf = result.to_send };
    _ = try readRecordBody(&reader, 22);
    _ = try readRecordBody(&reader, 20);
    const flight_start = reader.pos;
    _ = try readRecordBody(&reader, 23);

    const opened = try record.deprotect(
        &plain,
        result.to_send[flight_start..reader.pos],
        try fromHex(16, RFC8448_HS_KEY_HEX),
        try fromHex(12, RFC8448_HS_IV_HEX),
        0,
    );

    var flight: Reader = .{ .buf = opened.data };
    for ([_]u8{ 8, 11, 15, 20 }) |want| {
        try std.testing.expectEqual(want, try flight.readU8());
        _ = try flight.readBytes(try flight.readU24());
    }

    try std.testing.expectEqual(@as(usize, 0), flight.remaining());
}

test "tlz: connection, secp256r1 shared secret is symmetric" {
    const peer_point = try P256.basePoint.mul(reduceP256Scalar(@splat(0x22)), .big);
    const peer_public = peer_point.toUncompressedSec1();

    const kex_a = try computeKeyExchange(.SECP256R1, @splat(0x11), &peer_public);
    const kex_b = try computeKeyExchange(.SECP256R1, @splat(0x22), kex_a.serverPublic());

    try std.testing.expectEqual(@as(usize, 65), kex_a.server_public_len);
    try std.testing.expectEqualSlices(u8, &kex_a.shared, &kex_b.shared);
}

test "tlz: connection, X25519 key share of the wrong length is a bad key share" {
    try std.testing.expectError(
        Error.Tlz_Connection_BadKeyShare,
        computeKeyExchange(.X25519, @splat(0x11), &[_]u8{ 1, 2, 3 }),
    );
}

test "tlz: connection, secp256r1 key share off the curve is a bad key share" {
    var bogus: [65]u8 = @splat(0xAB);
    bogus[0] = 0x04;

    try std.testing.expectError(
        Error.Tlz_Connection_BadKeyShare,
        computeKeyExchange(.SECP256R1, @splat(0x11), &bogus),
    );
}

test "tlz: connection, unknown group is unsupported" {
    try std.testing.expectError(
        Error.Tlz_Connection_UnsupportedGroup,
        computeKeyExchange(@enumFromInt(0x0100), @splat(0x11), &.{}),
    );
}

test "tlz: connection, serverHandshake negotiates secp256r1 from a P-256 only hello" {
    const client_point = try P256.basePoint.mul(reduceP256Scalar(@splat(0x33)), .big);
    const client_public = client_point.toUncompressedSec1();
    var hello_buf: [512]u8 = undefined;
    const client_hello = buildHrrClientHello(&hello_buf, null, &client_public);
    var opts = try traceOptions(&DUMMY_DER, false);
    opts.group_prefs = &.{.SECP256R1};
    var out: [4096]u8 = undefined;

    const result = try serverHandshake(opts, client_hello, &out);

    var reader: Reader = .{ .buf = result.to_send };
    const server_hello = try readRecordBody(&reader, 22);
    const key_share = [_]u8{ 0x00, 0x33, 0x00, 0x45, 0x00, 0x17, 0x00, 0x41, 0x04 };
    try std.testing.expect(std.mem.find(u8, server_hello, &key_share) != null);
}

test "tlz: connection, garbage ClientHello is a decode error" {
    var out: [256]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_Connection_DecodeError,
        serverHandshake(try traceOptions(&DUMMY_DER, false), &[_]u8{ 1, 0, 0 }, &out),
    );
}

test "tlz: connection, client without TLS 1.3 is an unsupported version" {
    var client_hello = try fromHex(196, RFC8448_CLIENT_HELLO_HEX);
    client_hello[146] = 0x03;
    client_hello[147] = 0x03;
    var out: [4096]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_Connection_UnsupportedTlsVersion,
        serverHandshake(try traceOptions(&DUMMY_DER, false), &client_hello, &out),
    );
}

test "tlz: connection, selectAlpn with no overlap is no_application_protocol" {
    var opts = try traceOptions(&DUMMY_DER, false);
    opts.alpn_prefs = &.{.H2};
    var hello: ClientHello = .{
        .legacy_version = handshake.VERSION_TLS_1_2,
        .random = std.mem.zeroes([32]u8),
        .session_id = &.{},
        .cipher_suites = &.{},
    };
    hello.alpn = &[_]u8{ 0x00, 0x07, 0x06, 's', 'p', 'd', 'y', '/', '3' };

    try std.testing.expectError(
        Error.Tlz_Connection_NoApplicationProtocol,
        selectAlpn(opts, &hello),
    );
}

test "tlz: connection, selectAlpn without a client offer is null" {
    var opts = try traceOptions(&DUMMY_DER, false);
    opts.alpn_prefs = &.{.H2};
    const hello: ClientHello = .{
        .legacy_version = handshake.VERSION_TLS_1_2,
        .random = std.mem.zeroes([32]u8),
        .session_id = &.{},
        .cipher_suites = &.{},
    };

    try std.testing.expect(try selectAlpn(opts, &hello) == null);
}

test "tlz: connection, alertForError maps the RFC 8446 matrix" {
    try std.testing.expectEqual(
        Alert.NO_APPLICATION_PROTOCOL,
        alertForError(Error.Tlz_Connection_NoApplicationProtocol).?,
    );
    try std.testing.expectEqual(
        Alert.MISSING_EXTENSION,
        alertForError(Error.Tlz_Connection_MissingExtension).?,
    );
    try std.testing.expectEqual(
        Alert.PROTOCOL_VERSION,
        alertForError(Error.Tlz_Connection_UnsupportedTlsVersion).?,
    );
    try std.testing.expectEqual(
        Alert.HANDSHAKE_FAILURE,
        alertForError(Error.Tlz_Connection_HandshakeFailure).?,
    );
    try std.testing.expectEqual(
        Alert.ILLEGAL_PARAMETER,
        alertForError(Error.Tlz_Connection_MissingKeyShare).?,
    );
    try std.testing.expectEqual(
        Alert.DECODE_ERROR,
        alertForError(Error.Tlz_Connection_DecodeError).?,
    );
    try std.testing.expectEqual(
        Alert.HANDSHAKE_FAILURE,
        alertForError(Error.Tlz_Connection_NoCommonSignatureScheme).?,
    );
}

test "tlz: connection, alertForError without a defined alert is null" {
    try std.testing.expect(alertForError(Error.Tlz_Connection_SignFailed) == null);
}

test "tlz: connection, alertRecordForError builds the plaintext record" {
    var buf: [alert.FATAL_RECORD_LEN]u8 = undefined;

    const rec = alertRecordForError(&buf, Error.Tlz_Connection_MissingExtension).?;

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 109 },
        rec,
    );
}

test "tlz: connection, mTLS split flight verifies the client certificate" {
    const client_hello = try fromHex(196, RFC8448_CLIENT_HELLO_HEX);
    const key_pair = try fixtureKeyPair();
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, FIXTURE_CERT_HEX);
    var out: [4096]u8 = undefined;
    var result = try serverHandshake(try traceOptions(cert_der, true), &client_hello, &out);
    var conn = &result.connection;
    var transcript = conn.handshake_transcript;

    var cert_msg_buf: [600]u8 = undefined;
    const cert_msg = certificate.buildCertificate(&cert_msg_buf, cert_der);
    transcript.update(cert_msg);
    var verify_msg_buf: [256]u8 = undefined;
    const through_cert = transcript.current();
    const verify_msg = try clientCertificateVerify(&verify_msg_buf, key_pair, through_cert);
    transcript.update(verify_msg);

    var cert_rec_buf: [700]u8 = undefined;
    var verify_rec_buf: [320]u8 = undefined;
    const cert_rec = sealClientHandshake(&cert_rec_buf, cert_msg, conn, 0);
    const verify_rec = sealClientHandshake(&verify_rec_buf, verify_msg, conn, 1);

    var finished_buf: [64]u8 = undefined;
    var finished_rec_buf: [128]u8 = undefined;
    const finished_key = conn.client_finished_key;
    const through_verify = transcript.current();
    const finished = certificate.buildFinished(&finished_buf, finished_key, through_verify);
    const finished_rec = sealClientHandshake(&finished_rec_buf, finished, conn, 2);

    var der_buf: [512]u8 = undefined;
    const got_der = try conn.verifyClientCertFlight(cert_rec, verify_rec, &der_buf);
    try std.testing.expectEqualSlices(u8, cert_der, got_der);
    try cert_verify.verifyCertChain(got_der, got_der, NOW_SEC);
    try conn.verifyClientFinished(finished_rec);
}

test "tlz: connection, mTLS rejects a CertificateVerify over the wrong transcript" {
    const client_hello = try fromHex(196, RFC8448_CLIENT_HELLO_HEX);
    const key_pair = try fixtureKeyPair();
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, FIXTURE_CERT_HEX);
    var out: [4096]u8 = undefined;
    var result = try serverHandshake(try traceOptions(cert_der, true), &client_hello, &out);
    var conn = &result.connection;

    var cert_msg_buf: [600]u8 = undefined;
    const cert_msg = certificate.buildCertificate(&cert_msg_buf, cert_der);
    var verify_msg_buf: [256]u8 = undefined;
    const wrong_hash = conn.handshake_transcript.current();
    const verify_msg = try clientCertificateVerify(&verify_msg_buf, key_pair, wrong_hash);

    var cert_rec_buf: [700]u8 = undefined;
    var verify_rec_buf: [320]u8 = undefined;
    const cert_rec = sealClientHandshake(&cert_rec_buf, cert_msg, conn, 0);
    const verify_rec = sealClientHandshake(&verify_rec_buf, verify_msg, conn, 1);
    var der_buf: [512]u8 = undefined;

    try std.testing.expectError(
        Connection.Error.Tlz_ServerConnection_SignatureFailed,
        conn.verifyClientCertFlight(cert_rec, verify_rec, &der_buf),
    );
}

test "tlz: connection, mTLS coalesced flight verifies in one record" {
    const client_hello = try fromHex(196, RFC8448_CLIENT_HELLO_HEX);
    const key_pair = try fixtureKeyPair();
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, FIXTURE_CERT_HEX);
    var out: [4096]u8 = undefined;
    var result = try serverHandshake(try traceOptions(cert_der, true), &client_hello, &out);
    var conn = &result.connection;
    var transcript = conn.handshake_transcript;

    var flight_buf: [1024]u8 = undefined;
    var flight: Writer = .{ .buf = &flight_buf };
    const cert_msg = certificate.buildCertificate(flight.buf[flight.len..], cert_der);
    appendMessage(&flight, &transcript, cert_msg);
    const through_cert = transcript.current();
    const verify_buf = flight.buf[flight.len..];
    const verify_msg = try clientCertificateVerify(verify_buf, key_pair, through_cert);
    appendMessage(&flight, &transcript, verify_msg);
    const finished = certificate.buildFinished(
        flight.buf[flight.len..],
        conn.client_finished_key,
        transcript.current(),
    );
    appendMessage(&flight, &transcript, finished);

    var flight_rec_buf: [1100]u8 = undefined;
    const flight_rec = sealClientHandshake(&flight_rec_buf, flight.slice(), conn, 0);
    var der_buf: [512]u8 = undefined;

    const got_der = try conn.verifyClientAuthFlight(flight_rec, &der_buf);

    try std.testing.expectEqualSlices(u8, cert_der, got_der);
}

test "tlz: connection, HelloRetryRequest carries the HRR random" {
    var dummy_secp: [65]u8 = @splat(0xAB);
    dummy_secp[0] = 0x04;
    var hello_buf: [512]u8 = undefined;
    const client_hello1 = buildHrrClientHello(&hello_buf, null, &dummy_secp);
    var out: [1024]u8 = undefined;

    const opts = try traceOptions(&DUMMY_DER, false);
    const retry = (try serverHelloRetry(opts, client_hello1, &out)).?;

    try std.testing.expectEqual(@as(u8, 22), retry.to_send[0]);
    try std.testing.expectEqual(@as(u8, 0x02), retry.to_send[5]);
    try std.testing.expectEqualSlices(
        u8,
        &handshake.HELLO_RETRY_REQUEST_RANDOM,
        retry.to_send[11..43],
    );
    try std.testing.expectEqual(NamedGroup.X25519, retry.state.group);
}

test "tlz: connection, second ClientHello after the retry completes" {
    var dummy_secp: [65]u8 = @splat(0xAB);
    dummy_secp[0] = 0x04;
    const client_x25519 = X25519.recoverPublicKey(@splat(0x42));
    var hello1_buf: [512]u8 = undefined;
    var hello2_buf: [512]u8 = undefined;
    const client_hello1 = buildHrrClientHello(&hello1_buf, null, &dummy_secp);
    const client_hello2 = buildHrrClientHello(&hello2_buf, &client_x25519, null);
    var out1: [1024]u8 = undefined;
    var out2: [4096]u8 = undefined;

    const opts = try traceOptions(&DUMMY_DER, false);
    const retry = (try serverHelloRetry(opts, client_hello1, &out1)).?;
    const result = try serverHandshakeAfterRetry(retry.state, client_hello2, &out2);

    try std.testing.expectEqual(@as(u8, 0x02), result.to_send[5]);
    const hrr_random = &handshake.HELLO_RETRY_REQUEST_RANDOM;
    try std.testing.expect(!std.mem.eql(u8, hrr_random, result.to_send[11..43]));
}

test "tlz: connection, second ClientHello still without the key share is refused" {
    var dummy_secp: [65]u8 = @splat(0xAB);
    dummy_secp[0] = 0x04;
    var hello_buf: [512]u8 = undefined;
    const client_hello = buildHrrClientHello(&hello_buf, null, &dummy_secp);
    var out1: [1024]u8 = undefined;
    var out2: [4096]u8 = undefined;

    const opts = try traceOptions(&DUMMY_DER, false);
    const retry = (try serverHelloRetry(opts, client_hello, &out1)).?;

    try std.testing.expectError(
        Error.Tlz_Connection_HelloRetryRequestUnsupported,
        serverHandshakeAfterRetry(retry.state, client_hello, &out2),
    );
}

test "tlz: connection, ClientHello with the key share needs no retry" {
    const client_x25519 = X25519.recoverPublicKey(@splat(0x42));
    var hello_buf: [512]u8 = undefined;
    const client_hello = buildHrrClientHello(&hello_buf, &client_x25519, null);
    var out: [1024]u8 = undefined;

    const retry = try serverHelloRetry(try traceOptions(&DUMMY_DER, false), client_hello, &out);

    try std.testing.expect(retry == null);
}

test "tlz: connection, serverHandshake that needs a retry is refused" {
    var dummy_secp: [65]u8 = @splat(0xAB);
    dummy_secp[0] = 0x04;
    var hello_buf: [512]u8 = undefined;
    const client_hello = buildHrrClientHello(&hello_buf, null, &dummy_secp);
    var out: [4096]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_Connection_HelloRetryRequestUnsupported,
        serverHandshake(try traceOptions(&DUMMY_DER, false), client_hello, &out),
    );
}

