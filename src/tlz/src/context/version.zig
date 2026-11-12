//! TLZ context version
//!
//! ### file: src/tlz/src/context/version.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The TLS version floor and ceiling a context allows: TLS 1.2 and TLS 1.3.
//!
//! ### note:
//!
//! TLS 1.0 and 1.1 are deprecated (RFC 8996) and never offered. The values order
//! numerically, so `min <= max` is a plain integer compare.
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

/// One TLS version a context can allow.
pub const Version = enum(u8) {
    TLS_1_2 = 0x12,
    TLS_1_3 = 0x13,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz context: version, TLS 1.2 orders below TLS 1.3" {
    try std.testing.expect(@intFromEnum(Version.TLS_1_2) < @intFromEnum(Version.TLS_1_3));
}

test "tlz context: version, values name the minor version" {
    try std.testing.expectEqual(@as(u8, 0x12), @intFromEnum(Version.TLS_1_2));
    try std.testing.expectEqual(@as(u8, 0x13), @intFromEnum(Version.TLS_1_3));
}

