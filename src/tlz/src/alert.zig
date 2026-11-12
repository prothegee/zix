//! TLZ alert
//!
//! ### file: src/tlz/src/alert.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Builds a fatal alert as a plaintext TLS record (RFC 8446 section 6), for the
//! failures that happen before any handshake key exists.
//!
//! ### note:
//!
//! Post-handshake fatal alerts are encrypted through the record layer instead.
//! In TLS 1.3 the level byte is legacy, every alert built here is fatal.
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
const Alert = @import("alert/description.zig").Alert;

// --------------------------------------------------------- //
// Private:

/// Record content type alert(21) (RFC 8446 5.1).
const CONTENT_TYPE_ALERT: u8 = 21;

// --------------------------------------------------------- //
// Public:

/// AlertLevel warning (RFC 8446 6), legacy in TLS 1.3, kept for the wire byte.
pub const LEVEL_WARNING: u8 = 1;

/// AlertLevel fatal (RFC 8446 6), legacy in TLS 1.3, kept for the wire byte.
pub const LEVEL_FATAL: u8 = 2;

/// A fatal alert as a plaintext record: the 5-byte record header plus a 2-byte body.
pub const FATAL_RECORD_LEN: usize = 7;

/// Build a fatal alert as a plaintext TLS record.
///
/// Note:
/// - Layout: content type alert(21), legacy_record_version 0x0303, length 2,
///   then the body [level fatal(2), description].
///
/// Param:
/// buf - *[FATAL_RECORD_LEN]u8 (the destination, owned by the caller)
/// desc - Alert (the description to send)
///
/// Return:
/// - []const u8 (the whole record, a view into `buf`)
pub fn fatalRecord(buf: *[FATAL_RECORD_LEN]u8, desc: Alert) []const u8 {
    buf[0] = CONTENT_TYPE_ALERT;
    buf[1] = 0x03;
    buf[2] = 0x03;
    buf[3] = 0x00;
    buf[4] = 0x02;
    buf[5] = LEVEL_FATAL;
    buf[6] = @intFromEnum(desc);

    return buf[0..FATAL_RECORD_LEN];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz: alert, fatalRecord writes the plaintext bytes" {
    var buf: [FATAL_RECORD_LEN]u8 = undefined;

    const rec = fatalRecord(&buf, .NO_APPLICATION_PROTOCOL);

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x78 },
        rec,
    );
}

test "tlz: alert, fatalRecord fills the whole buffer" {
    var buf: [FATAL_RECORD_LEN]u8 = undefined;

    const rec = fatalRecord(&buf, .DECODE_ERROR);

    try std.testing.expectEqual(FATAL_RECORD_LEN, rec.len);
}

test "tlz: alert, fatalRecord length field matches the body" {
    var buf: [FATAL_RECORD_LEN]u8 = undefined;

    const rec = fatalRecord(&buf, .HANDSHAKE_FAILURE);
    const body_len = std.mem.readInt(u16, rec[3..5], .big);

    try std.testing.expectEqual(@as(u16, FATAL_RECORD_LEN - 5), body_len);
}

test "tlz: alert, fatalRecord level is fatal" {
    var buf: [FATAL_RECORD_LEN]u8 = undefined;

    const rec = fatalRecord(&buf, .UNEXPECTED_MESSAGE);

    try std.testing.expectEqual(LEVEL_FATAL, rec[5]);
}

test "tlz: alert, fatalRecord overwrites a reused buffer" {
    var buf: [FATAL_RECORD_LEN]u8 = undefined;

    _ = fatalRecord(&buf, .DECODE_ERROR);
    const rec = fatalRecord(&buf, .BAD_RECORD_MAC);

    try std.testing.expectEqual(@intFromEnum(Alert.BAD_RECORD_MAC), rec[6]);
}

