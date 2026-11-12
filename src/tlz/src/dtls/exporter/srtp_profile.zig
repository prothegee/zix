//! TLZ dtls exporter srtp_profile
//!
//! ### file: src/tlz/src/dtls/exporter/srtp_profile.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! SRTP protection profiles negotiated by the use_srtp extension (RFC 5764 4.1.2).
//!
//! ### note:
//!
//! The enum is open: an unregistered number reads back as itself, so a selection can
//! pass over it instead of the whole hello failing to parse.
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

/// One SRTP protection profile, as its 2-byte wire value.
pub const SrtpProfile = enum(u16) {
    SRTP_AES128_CM_HMAC_SHA1_80 = 0x0001,
    SRTP_AES128_CM_HMAC_SHA1_32 = 0x0002,
    SRTP_NULL_HMAC_SHA1_80 = 0x0005,
    SRTP_NULL_HMAC_SHA1_32 = 0x0006,
    _,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls exporter: srtp_profile, AES128 values follow RFC 5764" {
    try std.testing.expectEqual(
        @as(u16, 0x0001),
        @intFromEnum(SrtpProfile.SRTP_AES128_CM_HMAC_SHA1_80),
    );
    try std.testing.expectEqual(
        @as(u16, 0x0002),
        @intFromEnum(SrtpProfile.SRTP_AES128_CM_HMAC_SHA1_32),
    );
}

test "tlz dtls exporter: srtp_profile, NULL values follow RFC 5764" {
    try std.testing.expectEqual(
        @as(u16, 0x0005),
        @intFromEnum(SrtpProfile.SRTP_NULL_HMAC_SHA1_80),
    );
    try std.testing.expectEqual(
        @as(u16, 0x0006),
        @intFromEnum(SrtpProfile.SRTP_NULL_HMAC_SHA1_32),
    );
}

test "tlz dtls exporter: srtp_profile, unknown value round trips" {
    const unknown: SrtpProfile = @enumFromInt(0xFFFF);

    try std.testing.expectEqual(@as(u16, 0xFFFF), @intFromEnum(unknown));
}

