//! TLZ alert description
//!
//! ### file: src/tlz/src/alert/description.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! AlertDescription values tlz sends (RFC 8446 section 6.2).
//!
//! ### note:
//!
//! Only the outbound subset is listed. Inbound alerts are read as a raw byte,
//! see `alert/Inbound.zig`.
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

/// The alert description byte on the wire.
pub const Alert = enum(u8) {
    UNEXPECTED_MESSAGE = 10,
    BAD_RECORD_MAC = 20,
    RECORD_OVERFLOW = 22,
    HANDSHAKE_FAILURE = 40,
    BAD_CERTIFICATE = 42,
    ILLEGAL_PARAMETER = 47,
    DECODE_ERROR = 50,
    DECRYPT_ERROR = 51,
    PROTOCOL_VERSION = 70,
    MISSING_EXTENSION = 109,
    UNRECOGNIZED_NAME = 112,
    NO_APPLICATION_PROTOCOL = 120,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz alert: description, record values follow RFC 8446" {
    try std.testing.expectEqual(@as(u8, 10), @intFromEnum(Alert.UNEXPECTED_MESSAGE));
    try std.testing.expectEqual(@as(u8, 20), @intFromEnum(Alert.BAD_RECORD_MAC));
    try std.testing.expectEqual(@as(u8, 22), @intFromEnum(Alert.RECORD_OVERFLOW));
}

test "tlz alert: description, handshake values follow RFC 8446" {
    try std.testing.expectEqual(@as(u8, 40), @intFromEnum(Alert.HANDSHAKE_FAILURE));
    try std.testing.expectEqual(@as(u8, 42), @intFromEnum(Alert.BAD_CERTIFICATE));
    try std.testing.expectEqual(@as(u8, 47), @intFromEnum(Alert.ILLEGAL_PARAMETER));
    try std.testing.expectEqual(@as(u8, 50), @intFromEnum(Alert.DECODE_ERROR));
    try std.testing.expectEqual(@as(u8, 51), @intFromEnum(Alert.DECRYPT_ERROR));
    try std.testing.expectEqual(@as(u8, 70), @intFromEnum(Alert.PROTOCOL_VERSION));
}

test "tlz alert: description, extension values follow RFC 8446" {
    try std.testing.expectEqual(@as(u8, 109), @intFromEnum(Alert.MISSING_EXTENSION));
    try std.testing.expectEqual(@as(u8, 112), @intFromEnum(Alert.UNRECOGNIZED_NAME));
    try std.testing.expectEqual(@as(u8, 120), @intFromEnum(Alert.NO_APPLICATION_PROTOCOL));
}

