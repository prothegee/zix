//! TLZ handshake type
//!
//! ### file: src/tlz/src/handshake/handshake_type.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLS 1.3 handshake message type identifiers (RFC 8446 section 4).
//!
//! ### note:
//!
//! The enum is non-exhaustive, so an unknown message type from a peer still decodes.
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

/// The msg_type byte of a handshake message.
pub const HandshakeType = enum(u8) {
    CLIENT_HELLO = 1,
    SERVER_HELLO = 2,
    ENCRYPTED_EXTENSIONS = 8,
    CERTIFICATE = 11,
    CERTIFICATE_REQUEST = 13,
    CERTIFICATE_VERIFY = 15,
    FINISHED = 20,
    _,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz handshake: handshake_type, hello values follow RFC 8446" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(HandshakeType.CLIENT_HELLO));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(HandshakeType.SERVER_HELLO));
    try std.testing.expectEqual(
        @as(u8, 8),
        @intFromEnum(HandshakeType.ENCRYPTED_EXTENSIONS),
    );
}

test "tlz handshake: handshake_type, authentication values follow RFC 8446" {
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(HandshakeType.CERTIFICATE));
    try std.testing.expectEqual(
        @as(u8, 13),
        @intFromEnum(HandshakeType.CERTIFICATE_REQUEST),
    );
    try std.testing.expectEqual(
        @as(u8, 15),
        @intFromEnum(HandshakeType.CERTIFICATE_VERIFY),
    );
    try std.testing.expectEqual(@as(u8, 20), @intFromEnum(HandshakeType.FINISHED));
}

test "tlz handshake: handshake_type, unknown value round trips" {
    const unknown: HandshakeType = @enumFromInt(0x18);

    try std.testing.expectEqual(@as(u8, 0x18), @intFromEnum(unknown));
}

