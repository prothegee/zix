//! TLZ crypto cert_verify
//!
//! ### file: src/tlz/src/crypto/cert_verify.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Peer certificate checks: does the chain reach the trust anchor inside its
//! validity window (RFC 5280), and does the identity match the host (RFC 6125).
//!
//! ### note:
//!
//! The two checks are split on purpose: a client-auth server has no host name to
//! check. Built on std.crypto.Certificate. A self-signed anchor is its own issuer,
//! so `verifyCertChain(leaf, leaf, now)` validates a self-signed leaf.
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
const PathConstraints = @import("cert_verify/PathConstraints.zig");
const der_guard = @import("der_guard.zig");

const Certificate = std.crypto.Certificate;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

// --------------------------------------------------------- //
// Private:

fn parseError(err: Certificate.ParseError) ParseError {
    @branchHint(.cold);

    return switch (err) {
        error.CertificateHasUnrecognizedObjectId => {
            return error.Tlz_CertVerify_CertificateHasUnrecognizedObjectId;
        },
        error.CertificateFieldHasInvalidLength,
        error.CertificateFieldHasWrongDataType,
        error.CertificateHasInvalidBitString,
        error.CertificateTimeInvalid,
        error.UnsupportedCertificateVersion,
        => error.Tlz_CertVerify_Malformed,
    };
}

fn linkError(err: Certificate.Parsed.VerifyError) LinkError {
    @branchHint(.cold);

    return switch (err) {
        error.CertificateExpired => error.Tlz_CertVerify_CertificateExpired,
        error.CertificateNotYetValid => error.Tlz_CertVerify_CertificateNotYetValid,
        error.CertificateIssuerMismatch => error.Tlz_CertVerify_CertificateIssuerMismatch,
        error.CertificateSignatureAlgorithmUnsupported,
        error.CertificateSignatureAlgorithmMismatch,
        error.CertificateSignatureUnsupportedBitCount,
        error.CertificateSignatureNamedCurveUnsupported,
        => error.Tlz_CertVerify_UnsupportedSignatureScheme,
        error.CertificateSignatureInvalid,
        error.CertificateSignatureInvalidLength,
        error.CertificatePublicKeyInvalid,
        => error.Tlz_CertVerify_SignatureFailed,
        error.CertificateFieldHasInvalidLength,
        error.CertificateFieldHasWrongDataType,
        => error.Tlz_CertVerify_Malformed,
    };
}

fn hostError(err: Certificate.Parsed.VerifyHostNameError) HostError {
    @branchHint(.cold);

    return switch (err) {
        error.CertificateHostMismatch => error.Tlz_CertVerify_CertificateHostMismatch,
        error.CertificateFieldHasInvalidLength => error.Tlz_CertVerify_Malformed,
    };
}

/// Parse one certificate. The DER is checked first, std's reader has no bounds check.
fn parseDer(der: []const u8) ParseError!Certificate.Parsed {
    if (!der_guard.isSafeCertificate(der)) return error.Tlz_CertVerify_Malformed;

    const certificate: Certificate = .{
        .buffer = der,
        .index = 0,
    };

    return certificate.parse() catch |err| parseError(err);
}

fn pathConstraints(der: []const u8) Error!PathConstraints {
    return PathConstraints.parse(der) catch |err| switch (err) {
        error.Tlz_CertVerifyPathConstraints_Malformed => error.Tlz_CertVerify_Malformed,
    };
}

/// Parse a dotted-quad IPv4 literal (e.g. "127.0.0.1").
///
/// Return:
/// - [4]u8 (the address bytes)
/// - null when `host` is not an IPv4 literal
fn parseIp4Literal(host: []const u8) ?[4]u8 {
    const addr = std.Io.net.IpAddress.parse(host, 0) catch |err| switch (err) {
        else => return null,
    };

    return switch (addr) {
        .ip4 => |ip4| ip4.bytes,
        else => null,
    };
}

/// Scan a subjectAltName value for an iPAddress GeneralName ([7] = 0x87) holding
/// `ip`: the 6 bytes 0x87 0x04 then the 4 address bytes.
fn sanHasIp4(san: []const u8, ip: [4]u8) bool {
    if (san.len < 6) return false;

    var i: usize = 0;
    while (i + 6 <= san.len) : (i += 1) {
        const is_ip4_tag = san[i] == 0x87 and san[i + 1] == 0x04;
        if (is_ip4_tag and std.mem.eql(u8, san[i + 2 .. i + 6], &ip)) return true;
    }

    return false;
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_CertVerify_CertificateExpired,
    Tlz_CertVerify_CertificateNotYetValid,
    Tlz_CertVerify_CertificateIssuerMismatch,
    Tlz_CertVerify_CertificateHostMismatch,
    Tlz_CertVerify_CertificateHasUnrecognizedObjectId,
    Tlz_CertVerify_UnsupportedPeerKey,
    Tlz_CertVerify_EmptyChain,
    Tlz_CertVerify_IssuerNotCertificateAuthority,
    Tlz_CertVerify_IssuerKeyUsageForbidsSigning,
    Tlz_CertVerify_PathLenConstraintExceeded,
    Tlz_CertVerify_UnrecognizedCriticalExtension,
    Tlz_CertVerify_UnsupportedSignatureScheme,
    Tlz_CertVerify_SignatureFailed,
    Tlz_CertVerify_Malformed,
};

/// The part of Error a certificate parse can return.
pub const ParseError = error{
    Tlz_CertVerify_CertificateHasUnrecognizedObjectId,
    Tlz_CertVerify_Malformed,
};

/// The part of Error `verifyCertChain` can return.
pub const LinkError = ParseError || error{
    Tlz_CertVerify_CertificateExpired,
    Tlz_CertVerify_CertificateNotYetValid,
    Tlz_CertVerify_CertificateIssuerMismatch,
    Tlz_CertVerify_UnsupportedSignatureScheme,
    Tlz_CertVerify_SignatureFailed,
};

/// The part of Error `verifyCertHostname` and `verifyCertIdentity` can return.
pub const HostError = ParseError || error{
    Tlz_CertVerify_CertificateHostMismatch,
};

/// The part of Error `peerEcdsaP256PublicKey` can return.
pub const PeerKeyError = ParseError || error{
    Tlz_CertVerify_UnsupportedPeerKey,
};

/// Verify the end-entity certificate chains to the trust anchor and is time-valid
/// (RFC 5280). Checks issuer name, validity window, and the issuer signature.
///
/// Note:
/// - Does not check identity. Pair with `verifyCertHostname` when a host is expected.
///
/// Param:
/// end_entity_der - []const u8 (the peer leaf certificate DER)
/// trust_anchor_der - []const u8 (the anchor to chain against, DER)
/// now_sec - i64 (current UNIX time in seconds)
///
/// Return:
/// - void on a valid chain
/// - error.Tlz_CertVerify_CertificateExpired or CertificateNotYetValid
/// - error.Tlz_CertVerify_CertificateIssuerMismatch when it does not chain
/// - error.Tlz_CertVerify_SignatureFailed, UnsupportedSignatureScheme, or Malformed
pub fn verifyCertChain(
    end_entity_der: []const u8,
    trust_anchor_der: []const u8,
    now_sec: i64,
) LinkError!void {
    const end_entity = try parseDer(end_entity_der);
    const anchor = try parseDer(trust_anchor_der);

    end_entity.verify(anchor, now_sec) catch |err| return linkError(err);
}

/// Verify the certificate identity (SAN, or CN when there is no SAN) matches the
/// host (RFC 6125). DNS names only.
///
/// Param:
/// end_entity_der - []const u8 (the peer leaf certificate DER)
/// host - []const u8 (the host the caller meant to reach)
///
/// Return:
/// - void on a match
/// - error.Tlz_CertVerify_CertificateHostMismatch when nothing matches
/// - error.Tlz_CertVerify_Malformed when the certificate does not parse
pub fn verifyCertHostname(end_entity_der: []const u8, host: []const u8) HostError!void {
    const end_entity = try parseDer(end_entity_der);

    end_entity.verifyHostName(host) catch |err| return hostError(err);
}

/// Verify the certificate covers `host` by a DNS SAN, or by an iPAddress SAN when
/// `host` is an IPv4 literal. std's host check is DNS only.
///
/// Param:
/// end_entity_der - []const u8 (the server leaf certificate DER)
/// host - []const u8 (the request authority host, no port)
///
/// Return:
/// - void when the certificate serves `host`
/// - error.Tlz_CertVerify_CertificateHostMismatch otherwise
/// - error.Tlz_CertVerify_Malformed when the certificate does not parse
pub fn verifyCertIdentity(end_entity_der: []const u8, host: []const u8) HostError!void {
    const end_entity = try parseDer(end_entity_der);

    end_entity.verifyHostName(host) catch |err| switch (err) {
        error.CertificateHostMismatch, error.CertificateFieldHasInvalidLength => {
            if (parseIp4Literal(host)) |ip| {
                if (sanHasIp4(end_entity.subjectAltName(), ip)) return;
            }

            return error.Tlz_CertVerify_CertificateHostMismatch;
        },
    };
}

/// Extract the peer ECDSA P-256 public key from its end-entity certificate. The mTLS
/// client CertificateVerify is checked against this key.
///
/// Param:
/// end_entity_der - []const u8 (the peer leaf certificate DER)
///
/// Return:
/// - EcdsaP256.PublicKey
/// - error.Tlz_CertVerify_UnsupportedPeerKey when the key is not ECDSA P-256
/// - error.Tlz_CertVerify_Malformed when the certificate does not parse
pub fn peerEcdsaP256PublicKey(end_entity_der: []const u8) PeerKeyError!EcdsaP256.PublicKey {
    const end_entity = try parseDer(end_entity_der);

    switch (end_entity.pub_key_algo) {
        .X9_62_id_ecPublicKey => |curve| {
            if (curve != .X9_62_prime256v1) return error.Tlz_CertVerify_UnsupportedPeerKey;
        },
        else => return error.Tlz_CertVerify_UnsupportedPeerKey,
    }

    return EcdsaP256.PublicKey.fromSec1(end_entity.pubKey()) catch |err| switch (err) {
        else => error.Tlz_CertVerify_UnsupportedPeerKey,
    };
}

/// Verify a certificate chain (RFC 5280 6.1): chain[0] is the end-entity, chain[i]
/// is signed by chain[i + 1], and the last one by the trust anchor.
///
/// Note:
/// - On top of std's per-link checks, every issuer must be a CA, allow keyCertSign
///   when keyUsage is present, and respect its pathLenConstraint. An unknown
///   critical extension on a path certificate is rejected.
/// - For one self-signed server, use `verifyCertChain` instead.
///
/// Param:
/// chain_der - []const []const u8 (end-entity first, then intermediates, no anchor)
/// trust_anchor_der - []const u8 (the trusted root)
/// now_sec - i64 (current UNIX time in seconds)
///
/// Return:
/// - void on a valid, constrained chain
/// - error.Tlz_CertVerify_EmptyChain when `chain_der` is empty
/// - error.Tlz_CertVerify_IssuerNotCertificateAuthority, IssuerKeyUsageForbidsSigning,
///   PathLenConstraintExceeded, or UnrecognizedCriticalExtension
/// - any LinkError of `verifyCertChain`
pub fn verifyChain(
    chain_der: []const []const u8,
    trust_anchor_der: []const u8,
    now_sec: i64,
) Error!void {
    if (chain_der.len == 0) return error.Tlz_CertVerify_EmptyChain;

    const anchor = try parseDer(trust_anchor_der);

    var index: usize = 0;
    while (index < chain_der.len) : (index += 1) {
        const subject = try parseDer(chain_der[index]);
        const at_top = index + 1 >= chain_der.len;
        const issuer_der = if (at_top) trust_anchor_der else chain_der[index + 1];
        const issuer = if (at_top) anchor else try parseDer(issuer_der);

        subject.verify(issuer, now_sec) catch |err| return linkError(err);

        const issuer_constraints = try pathConstraints(issuer_der);
        if (!issuer_constraints.is_ca) return error.Tlz_CertVerify_IssuerNotCertificateAuthority;
        if (issuer_constraints.has_key_usage and !issuer_constraints.key_cert_sign) {
            return error.Tlz_CertVerify_IssuerKeyUsageForbidsSigning;
        }

        // Intermediates strictly between this issuer and the end-entity: chain[1..index]
        if (issuer_constraints.path_len) |path_len| {
            if (index > path_len) return error.Tlz_CertVerify_PathLenConstraintExceeded;
        }

        const subject_constraints = try pathConstraints(chain_der[index]);
        if (subject_constraints.unknown_critical) {
            return error.Tlz_CertVerify_UnrecognizedCriticalExtension;
        }
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Self-signed CN=localhost, SAN DNS:localhost + IP:127.0.0.1,
/// valid Jun 22 2026 to Jun 19 2036.
/// Chain fixture (ECDSA P-256): root (CA) -> intermediate (CA, pathlen 0) -> leaf
/// (CN=localhost), valid Jun 23 2026 to Jun 20 2036.
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

const CHAIN_ROOT_HEX =
    "308201953082013ba003020102021440f79706c99a7008e5dda0815e4e311f9e702f51300a06082a" ++
    "8648ce3d04030230183116301406035504030c0d7a69782d746573742d726f6f74301e170d323630" ++
    "3632333037333630315a170d3336303632303037333630315a30183116301406035504030c0d7a69" ++
    "782d746573742d726f6f743059301306072a8648ce3d020106082a8648ce3d030107034200044a89" ++
    "ec0c129c506d9b1f92c5b28f9328a7b063556cd64c2d5802db0e64c456fc90219d78b6cfda100274" ++
    "23eb8c1c4a886bfe2bb9b4aa7cba9bd449f117f57c04a3633061301d0603551d0e04160414356f3a" ++
    "c248e3e2a8bb9bd047c5e6219aada7f020301f0603551d23041830168014356f3ac248e3e2a8bb9b" ++
    "d047c5e6219aada7f020300f0603551d130101ff040530030101ff300e0603551d0f0101ff040403" ++
    "020106300a06082a8648ce3d0403020348003045022100ea3bdd439b274a5d0ef7993a70f18d913e" ++
    "7840d669d1b44c9eb84149eb7ac08602203804ec5881841d3a734e4e1a05231c595b6f43a1ca3e6f" ++
    "0d0398004f85d0047e";

const CHAIN_INT_HEX =
    "3082019f30820146a00302010202140676b25f6c4f12ed9bb873f83a007db84e8f3846300a06082a" ++
    "8648ce3d04030230183116301406035504030c0d7a69782d746573742d726f6f74301e170d323630" ++
    "3632333037333630315a170d3336303632303037333630315a3020311e301c06035504030c157a69" ++
    "782d746573742d696e7465726d6564696174653059301306072a8648ce3d020106082a8648ce3d03" ++
    "010703420004247a6c91f8537ef15cf71670559138fdba0d2a1865b9b809fd1780e227b3a4a8d56c" ++
    "95e7c83311b76c2ab3861b7b1d4d1b535c8f67a5b1e8d32b54b38064c999a366306430120603551d" ++
    "130101ff040830060101ff020100300e0603551d0f0101ff040403020106301d0603551d0e041604" ++
    "14d699cb91497cc7f981bccaf6a632a1eee036d52b301f0603551d23041830168014356f3ac248e3" ++
    "e2a8bb9bd047c5e6219aada7f020300a06082a8648ce3d040302034700304402200a09dc44d96143" ++
    "05084cdc7081d7181a4497d0ee9787d2e5f8196fe7e50c50fd02203e97e6be1d67006729f38c15ca" ++
    "f116ec8b0be7cb4a101e1f9ecc71d52b435c71";

const CHAIN_LEAF_HEX =
    "308201ad30820152a003020102021472dd9fe9aa428ce22acbb7e6146231e66269a6c0300a06082a" ++
    "8648ce3d0403023020311e301c06035504030c157a69782d746573742d696e7465726d6564696174" ++
    "65301e170d3236303632333037333630315a170d3336303632303037333630315a30143112301006" ++
    "035504030c096c6f63616c686f73743059301306072a8648ce3d020106082a8648ce3d0301070342" ++
    "00047c1d5b1ca87efb392f68fb1c13da2edcc8d7eb0a173eb7ce23174a7009142da963143404d086" ++
    "34fd9a4552594d405fe87bf183c08b973ad1ab0089d43e1949bfa3763074300c0603551d130101ff" ++
    "04023000300e0603551d0f0101ff04040302078030140603551d11040d300b82096c6f63616c686f" ++
    "7374301d0603551d0e0416041460d9685b0a35acfaa9975e62a3d2660234a2ea07301f0603551d23" ++
    "041830168014d699cb91497cc7f981bccaf6a632a1eee036d52b300a06082a8648ce3d0403020349" ++
    "003046022100ee1b1fc48b0e3b3582d0fbcdbc146863263816e1b547f94aba57c25b28cd604d0221" ++
    "00c7cdba1f9e63e82ff9cc31e196711368fec9cf3f092b795402f99c28e45f5227";

/// About 2027-01, inside every fixture validity window.
const NOW_SEC: i64 = 1_800_000_000;

const EC_SCALAR_HEX =
    "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c";

fn fixture(buf: *[512]u8, comptime hex: []const u8) ![]const u8 {
    return std.fmt.hexToBytes(buf, hex);
}

test "tlz crypto: cert_verify, self-signed chain inside validity window passes" {
    var buf: [512]u8 = undefined;
    const der = try fixture(&buf, FIXTURE_CERT_HEX);

    try verifyCertChain(der, der, NOW_SEC);
}

test "tlz crypto: cert_verify, before notBefore is not yet valid" {
    var buf: [512]u8 = undefined;
    const der = try fixture(&buf, FIXTURE_CERT_HEX);

    try std.testing.expectError(
        Error.Tlz_CertVerify_CertificateNotYetValid,
        verifyCertChain(der, der, 1_700_000_000),
    );
}

test "tlz crypto: cert_verify, after notAfter is expired" {
    var buf: [512]u8 = undefined;
    const der = try fixture(&buf, FIXTURE_CERT_HEX);

    try std.testing.expectError(
        Error.Tlz_CertVerify_CertificateExpired,
        verifyCertChain(der, der, 2_200_000_000),
    );
}

test "tlz crypto: cert_verify, hostname SAN matches" {
    var buf: [512]u8 = undefined;
    const der = try fixture(&buf, FIXTURE_CERT_HEX);

    try verifyCertHostname(der, "localhost");
}

test "tlz crypto: cert_verify, hostname SAN mismatch is rejected" {
    var buf: [512]u8 = undefined;
    const der = try fixture(&buf, FIXTURE_CERT_HEX);

    try std.testing.expectError(
        Error.Tlz_CertVerify_CertificateHostMismatch,
        verifyCertHostname(der, "evil.example"),
    );
}

test "tlz crypto: cert_verify, identity matches the DNS SAN" {
    var buf: [512]u8 = undefined;
    const der = try fixture(&buf, FIXTURE_CERT_HEX);

    try verifyCertIdentity(der, "localhost");
}

test "tlz crypto: cert_verify, identity matches the IP SAN" {
    var buf: [512]u8 = undefined;
    const der = try fixture(&buf, FIXTURE_CERT_HEX);

    try verifyCertIdentity(der, "127.0.0.1");
}

test "tlz crypto: cert_verify, identity with another DNS name is a mismatch" {
    var buf: [512]u8 = undefined;
    const der = try fixture(&buf, FIXTURE_CERT_HEX);

    try std.testing.expectError(
        Error.Tlz_CertVerify_CertificateHostMismatch,
        verifyCertIdentity(der, "evil.example"),
    );
}

test "tlz crypto: cert_verify, identity with another IP is a mismatch" {
    var buf: [512]u8 = undefined;
    const der = try fixture(&buf, FIXTURE_CERT_HEX);

    try std.testing.expectError(
        Error.Tlz_CertVerify_CertificateHostMismatch,
        verifyCertIdentity(der, "10.0.0.1"),
    );
}

test "tlz crypto: cert_verify, peer P-256 key matches the fixture scalar" {
    var buf: [512]u8 = undefined;
    const der = try fixture(&buf, FIXTURE_CERT_HEX);
    var scalar: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&scalar, EC_SCALAR_HEX);
    const secret_key = try EcdsaP256.SecretKey.fromBytes(scalar);
    const expected = try EcdsaP256.KeyPair.fromSecretKey(secret_key);

    const public_key = try peerEcdsaP256PublicKey(der);

    try std.testing.expectEqualSlices(
        u8,
        &expected.public_key.toUncompressedSec1(),
        &public_key.toUncompressedSec1(),
    );
}

test "tlz crypto: sanHasIp4, short SAN has no IP" {
    try std.testing.expect(!sanHasIp4(&[_]u8{ 0x87, 0x04 }, .{ 127, 0, 0, 1 }));
}

test "tlz crypto: parseIp4Literal, DNS name is not an IP" {
    try std.testing.expect(parseIp4Literal("localhost") == null);
}

test "tlz crypto: cert_verify, leaf to intermediate to root validates" {
    var int_buf: [512]u8 = undefined;
    var leaf_buf: [512]u8 = undefined;
    var root_buf: [512]u8 = undefined;
    const intermediate = try fixture(&int_buf, CHAIN_INT_HEX);
    const leaf = try fixture(&leaf_buf, CHAIN_LEAF_HEX);
    const root = try fixture(&root_buf, CHAIN_ROOT_HEX);

    try verifyChain(&.{ leaf, intermediate }, root, NOW_SEC);
}

test "tlz crypto: cert_verify, chain to the wrong anchor is an issuer mismatch" {
    var int_buf: [512]u8 = undefined;
    var leaf_buf: [512]u8 = undefined;
    const intermediate = try fixture(&int_buf, CHAIN_INT_HEX);
    const leaf = try fixture(&leaf_buf, CHAIN_LEAF_HEX);

    try std.testing.expectError(
        Error.Tlz_CertVerify_CertificateIssuerMismatch,
        verifyChain(&.{ leaf, intermediate }, leaf, NOW_SEC),
    );
}

test "tlz crypto: cert_verify, chain past notAfter is expired" {
    var int_buf: [512]u8 = undefined;
    var leaf_buf: [512]u8 = undefined;
    var root_buf: [512]u8 = undefined;
    const intermediate = try fixture(&int_buf, CHAIN_INT_HEX);
    const leaf = try fixture(&leaf_buf, CHAIN_LEAF_HEX);
    const root = try fixture(&root_buf, CHAIN_ROOT_HEX);

    try std.testing.expectError(
        Error.Tlz_CertVerify_CertificateExpired,
        verifyChain(&.{ leaf, intermediate }, root, 2_200_000_000),
    );
}

test "tlz crypto: cert_verify, empty chain is rejected" {
    var root_buf: [512]u8 = undefined;
    const root = try fixture(&root_buf, CHAIN_ROOT_HEX);

    try std.testing.expectError(
        Error.Tlz_CertVerify_EmptyChain,
        verifyChain(&.{}, root, NOW_SEC),
    );
}

test "tlz crypto: cert_verify, issuer without keyCertSign is rejected" {
    var buf: [512]u8 = undefined;
    const self_signed = try fixture(&buf, FIXTURE_CERT_HEX);

    // The self-signed fixture is a CA, but its keyUsage is digitalSignature only
    try std.testing.expectError(
        Error.Tlz_CertVerify_IssuerKeyUsageForbidsSigning,
        verifyChain(&.{self_signed}, self_signed, NOW_SEC),
    );
}

test "tlz crypto: cert_verify, leaf as issuer is not a CA" {
    var leaf_buf: [512]u8 = undefined;
    var root_buf: [512]u8 = undefined;
    const leaf = try fixture(&leaf_buf, CHAIN_LEAF_HEX);
    const root = try fixture(&root_buf, CHAIN_ROOT_HEX);

    try std.testing.expectError(
        Error.Tlz_CertVerify_CertificateIssuerMismatch,
        verifyChain(&.{ root, leaf }, root, NOW_SEC),
    );
}

test "tlz crypto: cert_verify, garbage DER is malformed" {
    const garbage = [_]u8{ 0x30, 0x02, 0x01 };

    try std.testing.expectError(
        Error.Tlz_CertVerify_Malformed,
        verifyCertChain(&garbage, &garbage, NOW_SEC),
    );
}

