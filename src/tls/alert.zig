//! TLS 1.3 alerts (RFC 8446 section 6).
//!
//! Note:
//! - The fatal alert descriptions raised by the handshake and extension layers. In TLS 1.3 the
//!   level byte is legacy (these are all fatal), so only the description is modeled here. The
//!   full alert record codec and the condition -> alert matrix land with Layer A.

const std = @import("std");

/// AlertDescription (RFC 8446 6.2), the subset zix raises.
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

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: Alert, wire values" {
    try std.testing.expectEqual(@as(u8, 47), @intFromEnum(Alert.ILLEGAL_PARAMETER));
    try std.testing.expectEqual(@as(u8, 109), @intFromEnum(Alert.MISSING_EXTENSION));
    try std.testing.expectEqual(@as(u8, 120), @intFromEnum(Alert.NO_APPLICATION_PROTOCOL));
}
