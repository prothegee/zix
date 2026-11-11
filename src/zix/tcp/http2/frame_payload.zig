//! ZIX Http2 frame_payload
//!
//! ### file: src/zix/tcp/http2/frame_payload.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Strip padding and priority from a HEADERS or DATA frame payload.
//!
//! ### note:
//!
//! n/a
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
const frame = @import("frame.zig");

// --------------------------------------------------------- //
// Private:

/// Bytes a HEADERS PRIORITY block takes: stream dependency plus weight.
const PRIORITY_LEN: usize = 5;

// --------------------------------------------------------- //
// Public:

/// The header block of a HEADERS frame, with padding and priority removed.
///
/// Param:
/// flags - u8 (the frame flags)
/// payload - []const u8 (the whole frame payload)
///
/// Return:
/// - ?[]const u8 (null when the padding runs past the payload)
pub fn headerBlock(flags: u8, payload: []const u8) ?[]const u8 {
    var offset: usize = 0;
    var pad_len: usize = 0;

    if ((flags & frame.FLAG_PADDED) != 0 and payload.len > 0) {
        pad_len = payload[0];
        offset = 1;
    }
    if ((flags & frame.FLAG_PRIORITY) != 0 and offset + PRIORITY_LEN <= payload.len) {
        offset += PRIORITY_LEN;
    }
    if (pad_len + offset > payload.len) return null;

    return payload[offset .. payload.len - pad_len];
}

/// The data of a DATA frame, with padding removed.
///
/// Param:
/// flags - u8 (the frame flags)
/// payload - []const u8 (the whole frame payload)
///
/// Return:
/// - ?[]const u8 (null when the padding runs past the payload)
pub fn dataBlock(flags: u8, payload: []const u8) ?[]const u8 {
    var data = payload;
    var pad_len: usize = 0;

    if ((flags & frame.FLAG_PADDED) != 0 and data.len > 0) {
        pad_len = data[0];
        data = data[1..];
    }
    if (pad_len > data.len) return null;

    return data[0 .. data.len - pad_len];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2: frame_payload, headerBlock strips padding and priority" {
    const payload = [_]u8{ 2, 0, 0, 0, 1, 16, 'a', 'b', 0, 0 };
    const flags = frame.FLAG_PADDED | frame.FLAG_PRIORITY;

    try std.testing.expectEqualStrings("ab", headerBlock(flags, &payload).?);
}

test "zix http2: frame_payload, headerBlock without flags returns the payload" {
    const payload = "abc";

    try std.testing.expectEqualStrings("abc", headerBlock(0, payload).?);
}

test "zix http2: frame_payload, headerBlock padding past the payload is malformed" {
    const payload = [_]u8{ 9, 'a' };

    try std.testing.expect(headerBlock(frame.FLAG_PADDED, &payload) == null);
}

test "zix http2: frame_payload, headerBlock empty padded payload is empty" {
    try std.testing.expectEqualStrings("", headerBlock(frame.FLAG_PADDED, "").?);
}

test "zix http2: frame_payload, dataBlock strips padding" {
    const payload = [_]u8{ 1, 'x', 'y', 0 };

    try std.testing.expectEqualStrings("xy", dataBlock(frame.FLAG_PADDED, &payload).?);
}

test "zix http2: frame_payload, dataBlock without flags returns the payload" {
    try std.testing.expectEqualStrings("xy", dataBlock(0, "xy").?);
}

test "zix http2: frame_payload, dataBlock padding past the payload is malformed" {
    const payload = [_]u8{ 5, 'x' };

    try std.testing.expect(dataBlock(frame.FLAG_PADDED, &payload) == null);
}

