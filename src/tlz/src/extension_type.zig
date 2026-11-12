//! TLZ extension type
//!
//! ### file: src/tlz/src/extension_type.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLS extension type identifiers (RFC 8446 section 4.2).
//!
//! ### note:
//!
//! The enum is non-exhaustive, so an unknown extension from a peer still decodes
//! and can be skipped.
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

/// The extension type code point on the wire.
pub const ExtensionType = enum(u16) {
    SERVER_NAME = 0x0000,
    SUPPORTED_GROUPS = 0x000a,
    SIGNATURE_ALGORITHMS = 0x000d,
    APPLICATION_LAYER_PROTOCOL_NEGOTIATION = 0x0010,
    RECORD_SIZE_LIMIT = 0x001c,
    SUPPORTED_VERSIONS = 0x002b,
    KEY_SHARE = 0x0033,
    _,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz: extension_type, hello values follow RFC 8446" {
    try std.testing.expectEqual(@as(u16, 0x0000), @intFromEnum(ExtensionType.SERVER_NAME));
    try std.testing.expectEqual(
        @as(u16, 0x000a),
        @intFromEnum(ExtensionType.SUPPORTED_GROUPS),
    );
    try std.testing.expectEqual(
        @as(u16, 0x000d),
        @intFromEnum(ExtensionType.SIGNATURE_ALGORITHMS),
    );
    try std.testing.expectEqual(
        @as(u16, 0x002b),
        @intFromEnum(ExtensionType.SUPPORTED_VERSIONS),
    );
    try std.testing.expectEqual(@as(u16, 0x0033), @intFromEnum(ExtensionType.KEY_SHARE));
}

test "tlz: extension_type, ALPN value follows RFC 7301" {
    try std.testing.expectEqual(
        @as(u16, 0x0010),
        @intFromEnum(ExtensionType.APPLICATION_LAYER_PROTOCOL_NEGOTIATION),
    );
}

test "tlz: extension_type, record_size_limit value follows RFC 8449" {
    try std.testing.expectEqual(
        @as(u16, 0x001c),
        @intFromEnum(ExtensionType.RECORD_SIZE_LIMIT),
    );
}

test "tlz: extension_type, unknown value round trips" {
    const unknown: ExtensionType = @enumFromInt(0xfe0d);

    try std.testing.expectEqual(@as(u16, 0xfe0d), @intFromEnum(unknown));
}

