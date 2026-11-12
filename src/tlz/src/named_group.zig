//! TLZ named group
//!
//! ### file: src/tlz/src/named_group.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Key exchange group identifiers (RFC 8446 section 4.2.7).
//!
//! ### note:
//!
//! The enum is non-exhaustive, so an unknown group from a peer still decodes.
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

/// The named group code point on the wire.
pub const NamedGroup = enum(u16) {
    SECP256R1 = 0x0017,
    X25519 = 0x001d,
    _,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz: named_group, values follow RFC 8446" {
    try std.testing.expectEqual(@as(u16, 0x0017), @intFromEnum(NamedGroup.SECP256R1));
    try std.testing.expectEqual(@as(u16, 0x001d), @intFromEnum(NamedGroup.X25519));
}

test "tlz: named_group, unknown value round trips" {
    const unknown: NamedGroup = @enumFromInt(0x0100);

    try std.testing.expectEqual(@as(u16, 0x0100), @intFromEnum(unknown));
}

