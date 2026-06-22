//! TLS 1.3 alerts (RFC 8446 section 6).
//!
//! Note:
//! - The fatal alert descriptions raised by the handshake and extension layers, plus the plaintext
//!   alert record builder for the pre-handshake-key failures. In TLS 1.3 the level byte is legacy
//!   (these are all fatal), so only the description is modeled here.

const std = @import("std");

/// AlertLevel (RFC 8446 6): legacy in 1.3 (all these are fatal), kept for the wire byte.
pub const level_warning: u8 = 1;
pub const level_fatal: u8 = 2;

const content_type_alert: u8 = 21;

/// A fatal alert as a plaintext record is 7 bytes: the 5-byte record header + a 2-byte body.
pub const fatal_record_len: usize = 7;

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

/// Build a fatal alert as a plaintext TLS record: content_type alert(21), legacy_record_version
/// 0x0303, a 2-byte body [level fatal(2), description]. This is the form for the pre-handshake-key
/// failures (a ClientHello rejected before the handshake keys exist), where the alert goes on the
/// wire in the clear. Post-handshake fatal alerts are encrypted through the record layer instead.
pub fn fatalRecord(buf: *[fatal_record_len]u8, desc: Alert) []const u8 {
    buf[0] = content_type_alert;
    buf[1] = 0x03;
    buf[2] = 0x03;
    buf[3] = 0x00;
    buf[4] = 0x02;
    buf[5] = level_fatal;
    buf[6] = @intFromEnum(desc);

    return buf[0..fatal_record_len];
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: Alert, wire values" {
    try std.testing.expectEqual(@as(u8, 47), @intFromEnum(Alert.ILLEGAL_PARAMETER));
    try std.testing.expectEqual(@as(u8, 109), @intFromEnum(Alert.MISSING_EXTENSION));
    try std.testing.expectEqual(@as(u8, 120), @intFromEnum(Alert.NO_APPLICATION_PROTOCOL));
}

test "zix test: Alert, fatalRecord plaintext bytes" {
    var buf: [fatal_record_len]u8 = undefined;
    const rec = fatalRecord(&buf, .NO_APPLICATION_PROTOCOL);

    // 15 03 03 00 02 02 78: alert(21), 0x0303, len 2, fatal(2), no_application_protocol(120).
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x78 }, rec);
}
