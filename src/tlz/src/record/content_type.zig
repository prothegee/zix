//! TLZ record content type
//!
//! ### file: src/tlz/src/record/content_type.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Record content types (RFC 8446 section 5.1).
//!
//! ### note:
//!
//! A protected record always carries application_data(23) on the wire. The real
//! type travels inside the AEAD as the inner content type. The enum is
//! non-exhaustive, so an unknown inner type still decodes.
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

/// The content type byte of a record.
pub const ContentType = enum(u8) {
    CHANGE_CIPHER_SPEC = 20,
    ALERT = 21,
    HANDSHAKE = 22,
    APPLICATION_DATA = 23,
    _,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz record: content_type, values follow RFC 8446" {
    try std.testing.expectEqual(@as(u8, 20), @intFromEnum(ContentType.CHANGE_CIPHER_SPEC));
    try std.testing.expectEqual(@as(u8, 21), @intFromEnum(ContentType.ALERT));
    try std.testing.expectEqual(@as(u8, 22), @intFromEnum(ContentType.HANDSHAKE));
    try std.testing.expectEqual(@as(u8, 23), @intFromEnum(ContentType.APPLICATION_DATA));
}

test "tlz record: content_type, unknown value round trips" {
    const unknown: ContentType = @enumFromInt(0x18);

    try std.testing.expectEqual(@as(u8, 0x18), @intFromEnum(unknown));
}

