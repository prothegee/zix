//! ZIX Http2 FrameHeader
//!
//! ### file: src/zix/tcp/http2/FrameHeader.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The 9-byte header in front of every HTTP/2 frame (RFC 7540 section 4.1).
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

// --------------------------------------------------------- //
// Fields:

/// Payload length in octets, the header itself not included.
length: u24,
/// Frame type, one of the FRAME_TYPE_* values in frame.zig.
frame_type: u8,
/// Frame flags, a mix of the FLAG_* values in frame.zig.
flags: u8,
/// Stream the frame belongs to. 0 means the whole connection.
stream_id: u31,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2: FrameHeader, keeps its fields" {
    const header: Self = .{
        .length = 42,
        .frame_type = 0x01,
        .flags = 0x04,
        .stream_id = 3,
    };

    try std.testing.expectEqual(@as(u24, 42), header.length);
    try std.testing.expectEqual(@as(u8, 0x01), header.frame_type);
    try std.testing.expectEqual(@as(u8, 0x04), header.flags);
    try std.testing.expectEqual(@as(u31, 3), header.stream_id);
}

test "zix http2: FrameHeader, holds the largest length and stream id" {
    const header: Self = .{
        .length = std.math.maxInt(u24),
        .frame_type = 0x00,
        .flags = 0x00,
        .stream_id = std.math.maxInt(u31),
    };

    try std.testing.expectEqual(@as(u24, 0xFF_FFFF), header.length);
    try std.testing.expectEqual(@as(u31, 0x7FFF_FFFF), header.stream_id);
}

