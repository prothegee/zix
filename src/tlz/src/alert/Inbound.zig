//! TLZ alert Inbound
//!
//! ### file: src/tlz/src/alert/Inbound.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A parsed alert from the peer (RFC 8446 section 6): the level byte plus the
//! description byte, and how to classify it.
//!
//! ### note:
//!
//! In TLS 1.3 the level is advisory. Classification keys on the description only.
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
// Fields:

/// The legacy level byte (1 warning, 2 fatal).
level: u8,
/// The raw description byte, kept raw so an unknown value still parses.
description: u8,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// The only way a parse can fail: the body is not exactly 2 bytes.
pub const Error = error{
    Tlz_AlertInbound_DecodeError,
};

/// close_notify (RFC 8446 6.1): a clean closure.
pub const DESC_CLOSE_NOTIFY: u8 = 0;

/// user_canceled (RFC 8446 6.1): a warning the peer may send before close_notify.
pub const DESC_USER_CANCELED: u8 = 90;

/// Parse an alert body: the plaintext record payload, or the decrypted inner
/// content of a protected alert record.
///
/// Param:
/// body - []const u8 (exactly the 2 alert bytes, level then description)
///
/// Return:
/// - Self
/// - Error.Tlz_AlertInbound_DecodeError when the body is not exactly 2 bytes
pub fn parse(body: []const u8) Error!Self {
    if (body.len != 2) return Error.Tlz_AlertInbound_DecodeError;

    return .{
        .level = body[0],
        .description = body[1],
    };
}

/// The peer closed its write side. No more data follows from it.
///
/// Return:
/// - bool
pub fn isCloseNotify(self: Self) bool {
    return self.description == DESC_CLOSE_NOTIFY;
}

/// Every alert except close_notify and user_canceled is fatal in TLS 1.3:
/// the connection is closed and its keys dropped (RFC 8446 6).
///
/// Return:
/// - bool
pub fn isFatal(self: Self) bool {
    return self.description != DESC_CLOSE_NOTIFY and
        self.description != DESC_USER_CANCELED;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Alert = @import("description.zig").Alert;
const LEVEL_WARNING = @import("../alert.zig").LEVEL_WARNING;
const LEVEL_FATAL = @import("../alert.zig").LEVEL_FATAL;

test "tlz alert: Inbound, parse keeps level and description" {
    const inbound = try parse(&[_]u8{ LEVEL_FATAL, 47 });

    try std.testing.expectEqual(LEVEL_FATAL, inbound.level);
    try std.testing.expectEqual(@as(u8, 47), inbound.description);
}

test "tlz alert: Inbound, close_notify is a clean closure" {
    const inbound = try parse(&[_]u8{ LEVEL_WARNING, DESC_CLOSE_NOTIFY });

    try std.testing.expect(inbound.isCloseNotify());
}

test "tlz alert: Inbound, close_notify is not fatal" {
    const inbound = try parse(&[_]u8{ LEVEL_WARNING, DESC_CLOSE_NOTIFY });

    try std.testing.expect(!inbound.isFatal());
}

test "tlz alert: Inbound, handshake_failure is fatal" {
    const inbound = try parse(&[_]u8{
        LEVEL_FATAL,
        @intFromEnum(Alert.HANDSHAKE_FAILURE),
    });

    try std.testing.expect(inbound.isFatal());
    try std.testing.expect(!inbound.isCloseNotify());
}

test "tlz alert: Inbound, user_canceled is not fatal" {
    const inbound = try parse(&[_]u8{ LEVEL_WARNING, DESC_USER_CANCELED });

    try std.testing.expect(!inbound.isFatal());
}

test "tlz alert: Inbound, unknown description is fatal" {
    const inbound = try parse(&[_]u8{ LEVEL_WARNING, 0xff });

    try std.testing.expect(inbound.isFatal());
}

test "tlz alert: Inbound, fatal level does not change close_notify" {
    const inbound = try parse(&[_]u8{ LEVEL_FATAL, DESC_CLOSE_NOTIFY });

    try std.testing.expect(!inbound.isFatal());
}

test "tlz alert: Inbound, body of one byte is malformed" {
    try std.testing.expectError(Error.Tlz_AlertInbound_DecodeError, parse(&[_]u8{0x01}));
}

test "tlz alert: Inbound, body of three bytes is malformed" {
    try std.testing.expectError(
        Error.Tlz_AlertInbound_DecodeError,
        parse(&[_]u8{ 1, 2, 3 }),
    );
}

test "tlz alert: Inbound, empty body is malformed" {
    try std.testing.expectError(Error.Tlz_AlertInbound_DecodeError, parse(&.{}));
}

