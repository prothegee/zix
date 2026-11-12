//! TLZ dtls handshake message_type
//!
//! ### file: src/tlz/src/dtls/handshake/message_type.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Handshake message types DTLS 1.2 can carry (RFC 5246 7.4, plus RFC 6347 4.2.1).
//!
//! ### note:
//!
//! Kept apart from the TLS 1.3 `HandshakeType`: DTLS 1.2 sends HELLO_REQUEST and
//! HELLO_VERIFY_REQUEST, which a TLS 1.3 handshake has to reject.
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

/// The msg_type byte of a DTLS 1.2 handshake message.
pub const MessageType = enum(u8) {
    HELLO_REQUEST = 0,
    CLIENT_HELLO = 1,
    SERVER_HELLO = 2,
    /// DTLS only (RFC 6347 4.2.1).
    HELLO_VERIFY_REQUEST = 3,
    CERTIFICATE = 11,
    SERVER_KEY_EXCHANGE = 12,
    CERTIFICATE_REQUEST = 13,
    SERVER_HELLO_DONE = 14,
    CERTIFICATE_VERIFY = 15,
    CLIENT_KEY_EXCHANGE = 16,
    FINISHED = 20,
    _,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls handshake: message_type, hello values follow RFC 6347" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(MessageType.HELLO_REQUEST));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(MessageType.CLIENT_HELLO));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(MessageType.SERVER_HELLO));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(MessageType.HELLO_VERIFY_REQUEST));
}

test "tlz dtls handshake: message_type, key exchange values follow RFC 5246" {
    try std.testing.expectEqual(@as(u8, 12), @intFromEnum(MessageType.SERVER_KEY_EXCHANGE));
    try std.testing.expectEqual(@as(u8, 14), @intFromEnum(MessageType.SERVER_HELLO_DONE));
    try std.testing.expectEqual(@as(u8, 16), @intFromEnum(MessageType.CLIENT_KEY_EXCHANGE));
    try std.testing.expectEqual(@as(u8, 20), @intFromEnum(MessageType.FINISHED));
}

test "tlz dtls handshake: message_type, unknown value round trips" {
    const unknown: MessageType = @enumFromInt(0x42);

    try std.testing.expectEqual(@as(u8, 0x42), @intFromEnum(unknown));
}

