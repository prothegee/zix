//! TLZ tls12 client FinishResult
//!
//! ### file: src/tlz/src/tls12/client/FinishResult.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What the TLS 1.2 client `finish` produces: the client flight to send, the
//! connection, the server Finished to expect, and a copy of the server certificate.
//!
//! ### note:
//!
//! `finish` already proved the peer holds the certificate key (the
//! ServerKeyExchange signature). Trusting the certificate (chain and host name) is
//! the caller's step, through `verifyServerCert`.
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
const prf = @import("../prf.zig");
const cert_verify = @import("../../crypto/cert_verify.zig");
const ClientConnection = @import("ClientConnection.zig");
const Tls13FinishResult = @import("../../client/FinishResult.zig");

// --------------------------------------------------------- //
// Fields:

/// ClientKeyExchange, ChangeCipherSpec, and the encrypted client Finished. A view
/// into the caller's buffer.
to_send: []const u8,
/// The established connection.
connection: ClientConnection,
/// The server Finished verify_data to expect, checked by
/// `ClientConnection.verifyServerFinished`.
expected_server_finished: [prf.VERIFY_DATA_LENGTH]u8,
/// The server end-entity certificate DER, copied so it outlives `finish`.
server_cert: [MAX_SERVER_CERT_DER]u8 = undefined,
server_cert_len: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn linkError(err: cert_verify.LinkError) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_CertVerify_CertificateExpired => {
            return error.Tlz_Tls12ClientFinishResult_CertificateExpired;
        },
        error.Tlz_CertVerify_CertificateNotYetValid => {
            return error.Tlz_Tls12ClientFinishResult_CertificateNotYetValid;
        },
        error.Tlz_CertVerify_CertificateIssuerMismatch => {
            return error.Tlz_Tls12ClientFinishResult_CertificateIssuerMismatch;
        },
        error.Tlz_CertVerify_UnsupportedSignatureScheme => {
            return error.Tlz_Tls12ClientFinishResult_UnsupportedSignatureScheme;
        },
        error.Tlz_CertVerify_SignatureFailed => {
            return error.Tlz_Tls12ClientFinishResult_SignatureFailed;
        },
        error.Tlz_CertVerify_Malformed => error.Tlz_Tls12ClientFinishResult_Malformed,
        error.Tlz_CertVerify_CertificateHasUnrecognizedObjectId => {
            return error.Tlz_Tls12ClientFinishResult_CertificateHasUnrecognizedObjectId;
        },
    };
}

fn hostError(err: cert_verify.HostError) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_CertVerify_CertificateHostMismatch => {
            return error.Tlz_Tls12ClientFinishResult_CertificateHostMismatch;
        },
        error.Tlz_CertVerify_Malformed => error.Tlz_Tls12ClientFinishResult_Malformed,
        error.Tlz_CertVerify_CertificateHasUnrecognizedObjectId => {
            return error.Tlz_Tls12ClientFinishResult_CertificateHasUnrecognizedObjectId;
        },
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_Tls12ClientFinishResult_NoServerCertificate,
    Tlz_Tls12ClientFinishResult_CertificateExpired,
    Tlz_Tls12ClientFinishResult_CertificateNotYetValid,
    Tlz_Tls12ClientFinishResult_CertificateIssuerMismatch,
    Tlz_Tls12ClientFinishResult_CertificateHostMismatch,
    Tlz_Tls12ClientFinishResult_SignatureFailed,
    Tlz_Tls12ClientFinishResult_UnsupportedSignatureScheme,
    Tlz_Tls12ClientFinishResult_Malformed,
    Tlz_Tls12ClientFinishResult_CertificateHasUnrecognizedObjectId,
};

/// The largest server end-entity certificate DER kept, the same cap as TLS 1.3.
pub const MAX_SERVER_CERT_DER = Tls13FinishResult.MAX_SERVER_CERT_DER;

/// The server end-entity certificate DER.
///
/// Return:
/// - []const u8 (empty when the server sent no Certificate)
pub fn serverCertDer(self: *const Self) []const u8 {
    return self.server_cert[0..self.server_cert_len];
}

/// Trust the server certificate: chain it to `anchor_der` inside its validity
/// window (RFC 5280) and match `hostname` against its SAN (RFC 6125).
///
/// Note:
/// - For a self-signed server the anchor is that certificate, known out of band.
///
/// Param:
/// anchor_der - []const u8 (the trust anchor DER)
/// hostname - []const u8 (the host the client meant to reach)
/// now_sec - i64 (current UNIX time in seconds)
///
/// Return:
/// - void on a trusted, host-matching certificate
/// - Error.Tlz_Tls12ClientFinishResult_NoServerCertificate when none was sent
/// - Error.Tlz_Tls12ClientFinishResult_CertificateExpired, NotYetValid, IssuerMismatch
/// - Error.Tlz_Tls12ClientFinishResult_CertificateHostMismatch on another host
pub fn verifyServerCert(
    self: *const Self,
    anchor_der: []const u8,
    hostname: []const u8,
    now_sec: i64,
) Error!void {
    const der = self.serverCertDer();
    if (der.len == 0) return Error.Tlz_Tls12ClientFinishResult_NoServerCertificate;

    cert_verify.verifyCertChain(der, anchor_der, now_sec) catch |err| return linkError(err);
    cert_verify.verifyCertHostname(der, hostname) catch |err| return hostError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Self-signed CN=localhost, SAN DNS:localhost + IP:127.0.0.1,
/// valid Jun 22 2026 to Jun 19 2036.
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

fn resultWithCert(cert_der: []const u8) Self {
    var result: Self = .{
        .to_send = &.{},
        .connection = undefined,
        .expected_server_finished = @splat(0),
    };
    @memcpy(result.server_cert[0..cert_der.len], cert_der);
    result.server_cert_len = cert_der.len;

    return result;
}

test "tlz tls12 client: FinishResult, verifyServerCert trusts the self-signed fixture" {
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, FIXTURE_CERT_HEX);
    const result = resultWithCert(cert_der);

    try result.verifyServerCert(cert_der, "localhost", NOW_SEC);
}

test "tlz tls12 client: FinishResult, verifyServerCert with another host is a mismatch" {
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, FIXTURE_CERT_HEX);
    const result = resultWithCert(cert_der);

    try std.testing.expectError(
        Error.Tlz_Tls12ClientFinishResult_CertificateHostMismatch,
        result.verifyServerCert(cert_der, "evil.example", NOW_SEC),
    );
}

test "tlz tls12 client: FinishResult, verifyServerCert after notAfter is expired" {
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, FIXTURE_CERT_HEX);
    const result = resultWithCert(cert_der);

    try std.testing.expectError(
        Error.Tlz_Tls12ClientFinishResult_CertificateExpired,
        result.verifyServerCert(cert_der, "localhost", 2_200_000_000),
    );
}

test "tlz tls12 client: FinishResult, verifyServerCert without a certificate is refused" {
    var cert_buf: [512]u8 = undefined;
    const cert_der = try std.fmt.hexToBytes(&cert_buf, FIXTURE_CERT_HEX);
    const result = resultWithCert(&.{});

    try std.testing.expectError(
        Error.Tlz_Tls12ClientFinishResult_NoServerCertificate,
        result.verifyServerCert(cert_der, "localhost", NOW_SEC),
    );
}

test "tlz tls12 client: FinishResult, serverCertDer is empty by default" {
    const result = resultWithCert(&.{});

    try std.testing.expectEqual(@as(usize, 0), result.serverCertDer().len);
}

