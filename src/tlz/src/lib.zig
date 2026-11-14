//! TLZ
//! TLS, DTLS, and certificates on pure std.crypto.
//!
//! ### file: src/tlz/src/lib.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLZ library entry: the version truth and the public exports.
//!
//! ### note:
//!
//! Tests run through `test.zig`, not through this file. Add a new source file there,
//! or its in-file tests never run.
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
const tlz_options = @import("tlz_options");

const alert = @import("alert.zig");
const cert_verify = @import("crypto/cert_verify.zig");
const connection = @import("connection.zig");
const context = @import("context.zig");
const record = @import("record.zig");
const std_rsa_verify = @import("crypto/std_rsa_verify.zig");

// --------------------------------------------------------- //
// Private:

fn getVersionString() []const u8 {
    return std.fmt.comptimePrint("{d}.{d}.{d}", .{
        VERSION.MAJOR,
        VERSION.MINOR,
        VERSION.PATCH,
    });
}

// --------------------------------------------------------- //
// Public:

/// THE ONLY SOURCE OF TRUTH for TLZ SEMVER.
///
/// Note:
/// - The values come from `src/tlz/build.zig.zon` through the build options.
/// - Do not create in other place
pub const VERSION = struct {
    pub const MAJOR: usize = tlz_options.version_major;
    pub const MINOR: usize = tlz_options.version_minor;
    pub const PATCH: usize = tlz_options.version_patch;
};

/// THE ONLY SOURCE OF TRUTH for TLZ string version, for example `0.1.0`.
///
/// Note:
/// - Do not create in other place
pub const VERSION_STRING = getVersionString();

/// One server-side TLS 1.3 connection after the handshake (sans-I/O record seal and open).
pub const Connection = connection.Connection;

/// The inputs of a server-side TLS 1.3 handshake.
pub const HandshakeOptions = connection.HandshakeOptions;

/// The server signing key (ECDSA P-256, Ed25519, or RSA), matching the certificate key type.
pub const SigningKey = @import("crypto/certificate/signing_key.zig").SigningKey;

/// Server-side TLS context: the loaded cert and key plus the validated policy.
/// Built once with `Context.init`, then shared by pointer.
pub const Context = context.Context;

/// The TLS protocol versions a `Context` can allow.
pub const Version = context.Version;

/// The curve set implemented here, the secure default for `Context.Config`.
pub const DEFAULT_CURVES = context.DEFAULT_CURVES;

/// The cipher suite set implemented here, the secure default for `Context.Config`.
pub const DEFAULT_CIPHERS = context.DEFAULT_CIPHERS;

/// What a finished server handshake hands back: the connection, the flight to send,
/// and the negotiated ALPN.
pub const HandshakeResult = connection.HandshakeResult;

/// Run the server-side TLS 1.3 handshake on one ClientHello.
pub const serverHandshake = connection.serverHandshake;

/// HelloRetryRequest (RFC 8446 4.1.4): build the HRR when the client group has no
/// key_share (null means no retry is needed).
pub const serverHelloRetry = connection.serverHelloRetry;

/// Resume the handshake on the second ClientHello, after a HelloRetryRequest.
pub const serverHandshakeAfterRetry = connection.serverHandshakeAfterRetry;

/// The state kept between a HelloRetryRequest and the second ClientHello.
pub const RetryState = connection.RetryState;

/// The HelloRetryRequest bytes plus the state to resume with.
pub const RetryFlight = connection.RetryFlight;

/// Map a handshake error to the alert to send (null means no alert).
pub const alertForError = connection.alertForError;

/// Write the fatal alert record for a handshake error (null means no alert).
pub const alertRecordForError = connection.alertRecordForError;

/// Client-side TLS 1.3 handshake: start, finish, and a sans-I/O `ClientConnection`.
pub const Client = @import("client.zig");

/// Client-side TLS 1.2 handshake: start, finish, and a sans-I/O `ClientConnection`.
pub const Client12 = @import("tls12/client.zig");

/// Server-side TLS 1.2 handshake (RFC 5246, ECDHE-ECDSA): `serverFlight1` answers the
/// ClientHello, `serverFinish` completes it into a 1.2 `Connection`.
pub const Server12 = @import("tls12/connection.zig");

/// Verify the leaf certificate chains to the trust anchor and is time-valid (RFC 5280).
pub const verifyCertChain = cert_verify.verifyCertChain;

/// Verify the certificate SAN (or CN when there is no SAN) matches a host (RFC 6125).
pub const verifyCertHostname = cert_verify.verifyCertHostname;

/// Verify the certificate covers a host by a DNS SAN or an IPv4 SAN.
pub const verifyCertIdentity = cert_verify.verifyCertIdentity;

/// Verify a [leaf, intermediate, ...] chain to an anchor (RFC 5280 6.1), with the cA,
/// keyCertSign, pathLen, and critical extension checks.
pub const verifyChain = cert_verify.verifyChain;

/// Decode one PEM block into DER.
pub const pemToDer = @import("crypto/pem.zig").pemToDer;

/// Check an RSA-PSS signature with the std verifier (RFC 8017 8.1.2).
pub const verifyRsaPss = std_rsa_verify.verifyPss;

/// Check an RSA PKCS#1 v1.5 signature with the std verifier (RFC 8017 8.2.2).
pub const verifyRsaPkcs1v15 = std_rsa_verify.verifyPkcs1v15;

/// False on a Zig whose std PSS verifier is broken. True on every supported toolchain.
pub const STD_PSS_VERIFY_USABLE = std_rsa_verify.PSS_USABLE;

/// The ALPN protocols the handshake can negotiate.
pub const Alpn = @import("alpn.zig").Alpn;

/// The TLS alert descriptions (RFC 8446 6).
pub const Alert = @import("alert/description.zig").Alert;

/// The byte length of one plaintext fatal alert record.
pub const FATAL_RECORD_LEN = alert.FATAL_RECORD_LEN;

/// One received alert. `isCloseNotify` and `isFatal` decide if the close is clean.
pub const AlertInbound = @import("alert/Inbound.zig");

/// Parse a received alert body into an `AlertInbound`.
pub const parseInboundAlert = AlertInbound.parse;

/// The TLS record content types.
pub const ContentType = @import("record/content_type.zig").ContentType;

/// The TLS cipher suites.
pub const CipherSuite = @import("cipher_suite.zig").CipherSuite;

/// The TLS named groups (curves).
pub const NamedGroup = @import("named_group.zig").NamedGroup;

/// The largest plaintext one record carries.
pub const MAX_PLAINTEXT = record.MAX_PLAINTEXT;

/// The size of a buffer that holds one full record on the wire.
pub const MAX_RECORD_WIRE = record.MAX_RECORD_WIRE;

/// The sealed output length for a given plaintext length.
pub const sealedLen = record.sealedLen;

/// DTLS 1.2 (RFC 6347), sans-I/O: the caller owns the datagram socket and the timers.
pub const Dtls = struct {
    /// Server-side handshake: HelloVerifyRequest, server flight, and finish.
    pub const Server = @import("dtls/connection.zig");

    /// Client-side handshake: hello with and without cookie, then finish.
    pub const Client = @import("dtls/client.zig");

    /// The record layer: header codec, record iterator, protect and deprotect.
    pub const record = @import("dtls/record.zig");

    /// The handshake layer: message header, fragments, and reassembly.
    pub const handshake = @import("dtls/handshake.zig");

    /// ClientHello and HelloVerifyRequest bodies.
    pub const hello = @import("dtls/hello.zig");

    /// The stateless cookie signer for HelloVerifyRequest.
    pub const cookie = @import("dtls/cookie.zig");

    /// The retransmission timer and flight state.
    pub const flight = @import("dtls/flight.zig");

    /// The keying material exporter, with the SRTP keys for DTLS-SRTP.
    pub const exporter = @import("dtls/exporter.zig");

    /// The use_srtp extension (RFC 5764).
    pub const use_srtp = @import("dtls/use_srtp.zig");
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz: VERSION_STRING, matches the semver fields" {
    var buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{
        VERSION.MAJOR,
        VERSION.MINOR,
        VERSION.PATCH,
    });

    try std.testing.expectEqualStrings(expected, VERSION_STRING);
}

test "tlz: VERSION_STRING, has exactly two dots" {
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, VERSION_STRING, "."));
}

test "tlz: VERSION_STRING, has no release candidate suffix" {
    try std.testing.expect(std.mem.findScalar(u8, VERSION_STRING, '-') == null);
}

test "tlz: VERSION, is not all zero" {
    const total = VERSION.MAJOR + VERSION.MINOR + VERSION.PATCH;

    try std.testing.expect(total > 0);
}

test "tlz: exports, carry every type of the public surface" {
    const types = .{
        Connection,
        HandshakeOptions,
        SigningKey,
        Context,
        Version,
        HandshakeResult,
        RetryState,
        RetryFlight,
        Alert,
        AlertInbound,
        ContentType,
        CipherSuite,
        NamedGroup,
        Alpn,
        Client,
        Client12,
        Server12,
    };

    inline for (types) |exported| {
        try std.testing.expect(@TypeOf(exported) == type);
    }
}

test "tlz: exports, carry every function of the public surface" {
    const functions = .{
        sealedLen,
        serverHandshake,
        serverHelloRetry,
        serverHandshakeAfterRetry,
        alertForError,
        alertRecordForError,
        parseInboundAlert,
        verifyCertChain,
        verifyCertHostname,
        verifyCertIdentity,
        verifyChain,
        pemToDer,
        verifyRsaPss,
        verifyRsaPkcs1v15,
    };

    inline for (functions) |exported| {
        try std.testing.expect(@typeInfo(@TypeOf(exported)) == .@"fn");
    }
}

test "tlz: Dtls, carries every DTLS module" {
    const modules = .{
        Dtls.Server,
        Dtls.Client,
        Dtls.record,
        Dtls.handshake,
        Dtls.hello,
        Dtls.cookie,
        Dtls.flight,
        Dtls.exporter,
        Dtls.use_srtp,
    };

    inline for (modules) |exported| {
        try std.testing.expect(@TypeOf(exported) == type);
    }
}

test "tlz: Dtls, server and client agree on the cipher suite" {
    try std.testing.expectEqual(
        Dtls.Server.CIPHER_ECDHE_ECDSA_AES128_GCM_SHA256,
        Dtls.Client.CIPHER_ECDHE_ECDSA_AES128_GCM_SHA256,
    );
}

test "tlz: DEFAULT_CURVES, is not empty" {
    try std.testing.expect(DEFAULT_CURVES.len > 0);
}

test "tlz: DEFAULT_CIPHERS, is not empty" {
    try std.testing.expect(DEFAULT_CIPHERS.len > 0);
}

test "tlz: FATAL_RECORD_LEN, is one alert record" {
    try std.testing.expectEqual(@as(usize, 7), FATAL_RECORD_LEN);
}

test "tlz: STD_PSS_VERIFY_USABLE, is true on the supported toolchain" {
    try std.testing.expect(STD_PSS_VERIFY_USABLE);
}

test "tlz: MAX_PLAINTEXT, is the RFC 8446 record cap" {
    try std.testing.expectEqual(@as(usize, 1 << 14), MAX_PLAINTEXT);
}

test "tlz: MAX_RECORD_WIRE, holds the largest sealed record" {
    try std.testing.expect(MAX_RECORD_WIRE >= sealedLen(MAX_PLAINTEXT));
}

test "tlz: sealedLen, grows with the plaintext" {
    try std.testing.expect(sealedLen(1) > sealedLen(0));
}

test "tlz: parseInboundAlert, reads a fatal alert" {
    const body = [_]u8{ alert.LEVEL_FATAL, @intFromEnum(Alert.HANDSHAKE_FAILURE) };
    const inbound = try parseInboundAlert(&body);

    try std.testing.expect(inbound.isFatal());
}

test "tlz: parseInboundAlert, short body is a decode error" {
    const body = [_]u8{alert.LEVEL_FATAL};

    try std.testing.expectError(
        AlertInbound.Error.Tlz_AlertInbound_DecodeError,
        parseInboundAlert(&body),
    );
}

