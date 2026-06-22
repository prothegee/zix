//! Layer V: peer certificate verification (the trust step of mTLS).
//!
//! What:
//!   Given a peer's end-entity certificate (DER) and a trust anchor (DER), answer two
//!   separate questions a TLS handshake must ask before it trusts the peer:
//!     1. Does the cert chain to the anchor and sit inside its validity window? (RFC 5280)
//!     2. Does the cert's identity (SAN) match the host we meant to reach? (RFC 6125)
//!   These are split because a path-validation-only caller (no SNI, e.g. a client-auth
//!   server checking a client cert) must not be forced through a hostname check.
//!
//! Note:
//! - Built on std.crypto.Certificate (Parsed.verify + Parsed.verifyHostName). No C FFI.
//! - One-link chain only (end-entity verified directly against one anchor). A self-signed
//!   anchor is its own issuer, so verifyCertChain(ee, ee, ...) validates a self-signed leaf.

const std = @import("std");

const Certificate = std.crypto.Certificate;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

/// Verify the end-entity cert chains to the trust anchor and is time-valid (RFC 5280).
///
/// Note:
/// - Checks issuer-name match, validity window (now_sec), and the issuer's signature.
/// - Does NOT check identity. Pair with verifyCertHostname when a hostname is expected.
///
/// Param:
/// end_entity_der - []const u8 (the peer's leaf certificate, DER-encoded)
/// trust_anchor_der - []const u8 (the CA/anchor to chain against, DER-encoded)
/// now_sec - i64 (current UNIX time in seconds, for the validity window)
///
/// Return:
/// - void on a valid chain
/// - error.CertificateExpired / error.CertificateNotYetValid (outside validity window)
/// - error.CertificateIssuerMismatch (does not chain to the anchor)
/// - propagates std.crypto.Certificate parse/verify errors otherwise
pub fn verifyCertChain(end_entity_der: []const u8, trust_anchor_der: []const u8, now_sec: i64) !void {
    const ee = try (Certificate{ .buffer = end_entity_der, .index = 0 }).parse();
    const anchor = try (Certificate{ .buffer = trust_anchor_der, .index = 0 }).parse();

    try ee.verify(anchor, now_sec);
}

/// Verify the cert's identity (Subject Alternative Name) matches the expected host (RFC 6125).
///
/// Note:
/// - Falls back to the Common Name only when the cert carries no SAN extension.
///
/// Param:
/// end_entity_der - []const u8 (the peer's leaf certificate, DER-encoded)
/// host - []const u8 (the hostname the caller intended to reach)
///
/// Return:
/// - void on a match
/// - error.CertificateHostMismatch (no SAN/CN entry matches host)
pub fn verifyCertHostname(end_entity_der: []const u8, host: []const u8) !void {
    const ee = try (Certificate{ .buffer = end_entity_der, .index = 0 }).parse();

    try ee.verifyHostName(host);
}

/// Extract the peer's ECDSA P-256 public key from its end-entity certificate (DER). The mTLS
/// client CertificateVerify signature is checked against this key (Layer C cross-check).
///
/// Param:
/// end_entity_der - []const u8 (the peer's leaf certificate, DER-encoded)
///
/// Return:
/// - EcdsaP256.PublicKey
/// - error.UnsupportedPeerKey (cert key is not ECDSA on the P-256 / prime256v1 curve)
pub fn peerEcdsaP256PublicKey(end_entity_der: []const u8) !EcdsaP256.PublicKey {
    const ee = try (Certificate{ .buffer = end_entity_der, .index = 0 }).parse();
    switch (ee.pub_key_algo) {
        .X9_62_id_ecPublicKey => |curve| if (curve != .X9_62_prime256v1) return error.UnsupportedPeerKey,
        else => return error.UnsupportedPeerKey,
    }

    return EcdsaP256.PublicKey.fromSec1(ee.pubKey()) catch error.UnsupportedPeerKey;
}

// --------------------------------------------------------------- //
// fixture: self-signed CN=localhost, SAN DNS:localhost + IP:127.0.0.1,
// notBefore Jun 22 2026 / notAfter Jun 19 2036. Shared with client.zig.

const fixture_cert_hex = "308201d43082017ba00302010202147a26ee491f091ac7c914f4a810c1ece713402574300a06082a8648ce3d040302302a3112301006035504030c096c6f63616c686f737431143012060355040a0c0b7a69782d746c732d706f63301e170d3236303632323132353432305a170d3336303631393132353432305a302a3112301006035504030c096c6f63616c686f737431143012060355040a0c0b7a69782d746c732d706f633059301306072a8648ce3d020106082a8648ce3d03010703420004c2a0121b298ac9cd389200e78d94e7bde1cc7cd8074795fab4f919799d40fdc231c5a90990ac8c6166ae472f33f74fced097f2edb7b8a1974be66a4ab07f253ba37f307d301d0603551d0e04160414c34e1d0a36a43947709b539e16dd0213aa4196aa301f0603551d23041830168014c34e1d0a36a43947709b539e16dd0213aa4196aa300f0603551d130101ff040530030101ff301a0603551d110413301182096c6f63616c686f737487047f000001300e0603551d0f0101ff040403020780300a06082a8648ce3d040302034700304402200b012f119db9b95d990bc482cb63e8f81e337a08634904e4caf513dc10c8aa8302202fdfe79ff6d5403e753ddf2aa52671923b8a2c28126bcbf196bd6fb7ecbcb14e";

fn fixtureDer(buf: []u8) ![]const u8 {
    return std.fmt.hexToBytes(buf, fixture_cert_hex);
}

test "zix test: cert verify, self-signed chain inside validity window passes" {
    var buf: [512]u8 = undefined;
    const der = try fixtureDer(&buf);

    const now_sec: i64 = 1_800_000_000; // ~2027-01, inside notBefore (Jun 2026) .. notAfter (Jun 2036)
    try verifyCertChain(der, der, now_sec); // self-signed: anchor is the leaf itself
}

test "zix test: cert verify, before notBefore is rejected" {
    var buf: [512]u8 = undefined;
    const der = try fixtureDer(&buf);

    const too_early: i64 = 1_700_000_000; // ~2023-11, before notBefore (Jun 2026)
    try std.testing.expectError(error.CertificateNotYetValid, verifyCertChain(der, der, too_early));
}

test "zix test: cert verify, hostname SAN match and mismatch" {
    var buf: [512]u8 = undefined;
    const der = try fixtureDer(&buf);

    try verifyCertHostname(der, "localhost"); // SAN DNS:localhost
    try std.testing.expectError(error.CertificateHostMismatch, verifyCertHostname(der, "evil.example"));
}

test "zix test: cert verify, peer P-256 public key matches the fixture signing key" {
    var buf: [512]u8 = undefined;
    const der = try fixtureDer(&buf);

    const pub_key = try peerEcdsaP256PublicKey(der);

    // the fixture cert's key is the scalar reused across the tls tests; its public key must match.
    var scalar: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&scalar, "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c");
    const expected = try EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(scalar));

    try std.testing.expectEqualSlices(u8, &expected.public_key.toUncompressedSec1(), &pub_key.toUncompressedSec1());
}
