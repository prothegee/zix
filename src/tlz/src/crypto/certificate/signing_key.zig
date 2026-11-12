//! TLZ crypto certificate signing_key
//!
//! ### file: src/tlz/src/crypto/certificate/signing_key.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The server CertificateVerify signing identity (RFC 8446 section 4.4.3): one key
//! of ECDSA P-256, Ed25519, or RSA, plus the wire scheme it signs with.
//!
//! ### note:
//!
//! An RSA key signs CertificateVerify with rsa_pss_rsae_sha256, the only RSA scheme
//! TLS 1.3 permits there.
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
const RsaPrivateKey = @import("../rsa/PrivateKey.zig");
const SignatureScheme = @import("../../signature_scheme.zig").SignatureScheme;

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Ed25519 = std.crypto.sign.Ed25519;

// --------------------------------------------------------- //
// Public:

/// The key the server proves its certificate with.
pub const SigningKey = union(enum) {
    ecdsa_p256: EcdsaP256.KeyPair,
    ed25519: Ed25519.KeyPair,
    rsa: RsaPrivateKey,

    /// The TLS 1.3 SignatureScheme written on the wire for this key. The client
    /// must have offered it in signature_algorithms.
    ///
    /// Return:
    /// - SignatureScheme
    pub fn scheme(self: SigningKey) SignatureScheme {
        return switch (self) {
            .ecdsa_p256 => .ECDSA_SECP256R1_SHA256,
            .ed25519 => .ED25519,
            .rsa => .RSA_PSS_RSAE_SHA256,
        };
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz crypto certificate: signing_key, ECDSA P-256 signs with ecdsa_secp256r1_sha256" {
    const key_pair = try EcdsaP256.KeyPair.generateDeterministic(@splat(0x11));
    const signing_key: SigningKey = .{ .ecdsa_p256 = key_pair };

    try std.testing.expectEqual(SignatureScheme.ECDSA_SECP256R1_SHA256, signing_key.scheme());
}

test "tlz crypto certificate: signing_key, Ed25519 signs with ed25519" {
    const key_pair = try Ed25519.KeyPair.generateDeterministic(@splat(0x42));
    const signing_key: SigningKey = .{ .ed25519 = key_pair };

    try std.testing.expectEqual(SignatureScheme.ED25519, signing_key.scheme());
}

test "tlz crypto certificate: signing_key, RSA signs with rsa_pss_rsae_sha256" {
    const signing_key: SigningKey = .{ .rsa = .{} };

    try std.testing.expectEqual(SignatureScheme.RSA_PSS_RSAE_SHA256, signing_key.scheme());
}

