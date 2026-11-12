//! TLZ cipher suite
//!
//! ### file: src/tlz/src/cipher_suite.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLS cipher suite identifiers (RFC 8446 section B.4, RFC 5289).
//!
//! ### note:
//!
//! One enum spans TLS 1.2 and 1.3, so a single config list can name both. The enum
//! is non-exhaustive, so an unknown suite from a peer still decodes.
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

/// The cipher suite code point on the wire.
pub const CipherSuite = enum(u16) {
    AES_128_GCM_SHA256 = 0x1301,
    AES_256_GCM_SHA384 = 0x1302,
    CHACHA20_POLY1305_SHA256 = 0x1303,
    /// TLS 1.2 ECDHE-ECDSA-AES128-GCM-SHA256 (RFC 5289), the TLS 1.2 floor suite.
    ECDHE_ECDSA_AES128_GCM_SHA256 = 0xc02b,
    _,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz: cipher_suite, TLS 1.3 values follow RFC 8446" {
    try std.testing.expectEqual(@as(u16, 0x1301), @intFromEnum(CipherSuite.AES_128_GCM_SHA256));
    try std.testing.expectEqual(@as(u16, 0x1302), @intFromEnum(CipherSuite.AES_256_GCM_SHA384));
    try std.testing.expectEqual(
        @as(u16, 0x1303),
        @intFromEnum(CipherSuite.CHACHA20_POLY1305_SHA256),
    );
}

test "tlz: cipher_suite, TLS 1.2 value follows RFC 5289" {
    try std.testing.expectEqual(
        @as(u16, 0xc02b),
        @intFromEnum(CipherSuite.ECDHE_ECDSA_AES128_GCM_SHA256),
    );
}

test "tlz: cipher_suite, unknown value round trips" {
    const unknown: CipherSuite = @enumFromInt(0x00ff);

    try std.testing.expectEqual(@as(u16, 0x00ff), @intFromEnum(unknown));
}

