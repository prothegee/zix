//! TLZ connection HandshakeMessage
//!
//! ### file: src/tlz/src/connection/HandshakeMessage.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One handshake message inside a decrypted record: the full bytes the transcript
//! hashes, and the body the message parsers read.
//!
//! ### note:
//!
//! Both slices are views into the decrypted record.
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

/// Type, length, and body: what the transcript hashes.
full: []const u8,
/// The body alone.
body: []const u8,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz connection: HandshakeMessage, body is the tail of full" {
    const bytes = [_]u8{ 20, 0, 0, 2, 0xaa, 0xbb };
    const message: Self = .{
        .full = &bytes,
        .body = bytes[4..],
    };

    try std.testing.expectEqual(message.full.len - 4, message.body.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xbb }, message.body);
}

test "tlz connection: HandshakeMessage, empty body is allowed" {
    const bytes = [_]u8{ 20, 0, 0, 0 };
    const message: Self = .{
        .full = &bytes,
        .body = bytes[4..],
    };

    try std.testing.expectEqual(@as(usize, 0), message.body.len);
}

