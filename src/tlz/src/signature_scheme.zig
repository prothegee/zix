//! TLZ signature scheme
//!
//! ### file: src/tlz/src/signature_scheme.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Signature scheme identifiers (RFC 8446 section 4.2.3).
//!
//! ### note:
//!
//! The enum is non-exhaustive, so an unknown scheme in a peer list still decodes.
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

// --------------------------------------------------------- //
// Public:

/// The signature scheme code point on the wire.
pub const SignatureScheme = enum(u16) {
    RSA_PKCS1_SHA256 = 0x0401,
    ECDSA_SECP256R1_SHA256 = 0x0403,
    RSA_PSS_RSAE_SHA256 = 0x0804,
    ED25519 = 0x0807,
    _,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz: signature_scheme, RSA values follow RFC 8446" {
    try std.testing.expectEqual(
        @as(u16, 0x0401),
        @intFromEnum(SignatureScheme.RSA_PKCS1_SHA256),
    );
    try std.testing.expectEqual(
        @as(u16, 0x0804),
        @intFromEnum(SignatureScheme.RSA_PSS_RSAE_SHA256),
    );
}

test "tlz: signature_scheme, ECDSA and EdDSA values follow RFC 8446" {
    try std.testing.expectEqual(
        @as(u16, 0x0403),
        @intFromEnum(SignatureScheme.ECDSA_SECP256R1_SHA256),
    );
    try std.testing.expectEqual(@as(u16, 0x0807), @intFromEnum(SignatureScheme.ED25519));
}

test "tlz: signature_scheme, unknown value round trips" {
    const unknown: SignatureScheme = @enumFromInt(0x0203);

    try std.testing.expectEqual(@as(u16, 0x0203), @intFromEnum(unknown));
}

