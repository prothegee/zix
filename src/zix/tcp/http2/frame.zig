//! ZIX Http2 frame
//!
//! ### file: src/zix/tcp/http2/frame.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! HTTP/2 frame constants and the frame header codec (no I/O).
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
const FrameHeader = @import("FrameHeader.zig");

// --------------------------------------------------------- //
// Private:

/// Mask that clears the reserved top bit of the stream id (RFC 7540 section 4.1).
const STREAM_ID_MASK: u32 = 0x7FFF_FFFF;

// --------------------------------------------------------- //
// Public:

/// Client connection preface (RFC 7540 section 3.5).
pub const PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// Frame header length in octets: 3 length + 1 type + 1 flags + 4 stream id.
pub const FRAME_HEADER_LEN: usize = 9;

pub const FRAME_TYPE_DATA: u8 = 0x00;
pub const FRAME_TYPE_HEADERS: u8 = 0x01;
pub const FRAME_TYPE_PRIORITY: u8 = 0x02;
pub const FRAME_TYPE_RST_STREAM: u8 = 0x03;
pub const FRAME_TYPE_SETTINGS: u8 = 0x04;
pub const FRAME_TYPE_PUSH_PROMISE: u8 = 0x05;
pub const FRAME_TYPE_PING: u8 = 0x06;
pub const FRAME_TYPE_GOAWAY: u8 = 0x07;
pub const FRAME_TYPE_WINDOW_UPDATE: u8 = 0x08;
pub const FRAME_TYPE_CONTINUATION: u8 = 0x09;

pub const FLAG_END_STREAM: u8 = 0x01;
pub const FLAG_END_HEADERS: u8 = 0x04;
pub const FLAG_PADDED: u8 = 0x08;
pub const FLAG_PRIORITY: u8 = 0x20;
/// Same bit as FLAG_END_STREAM, used on SETTINGS and PING frames.
pub const FLAG_ACK: u8 = 0x01;

pub const ERR_NO_ERROR: u32 = 0x00;
pub const ERR_PROTOCOL_ERROR: u32 = 0x01;
pub const ERR_INTERNAL_ERROR: u32 = 0x02;
pub const ERR_FLOW_CONTROL_ERROR: u32 = 0x03;
pub const ERR_SETTINGS_TIMEOUT: u32 = 0x04;
pub const ERR_STREAM_CLOSED: u32 = 0x05;
pub const ERR_FRAME_SIZE_ERROR: u32 = 0x06;
pub const ERR_REFUSED_STREAM: u32 = 0x07;
pub const ERR_CANCEL: u32 = 0x08;
pub const ERR_COMPRESSION_ERROR: u32 = 0x09;
pub const ERR_CONNECT_ERROR: u32 = 0x0a;
pub const ERR_ENHANCE_YOUR_CALM: u32 = 0x0b;
pub const ERR_INADEQUATE_SECURITY: u32 = 0x0c;
pub const ERR_HTTP_1_1_REQUIRED: u32 = 0x0d;

pub const SETTINGS_HEADER_TABLE_SIZE: u16 = 0x01;
pub const SETTINGS_ENABLE_PUSH: u16 = 0x02;
pub const SETTINGS_MAX_CONCURRENT_STREAMS: u16 = 0x03;
pub const SETTINGS_INITIAL_WINDOW_SIZE: u16 = 0x04;
pub const SETTINGS_MAX_FRAME_SIZE: u16 = 0x05;
pub const SETTINGS_MAX_HEADER_LIST_SIZE: u16 = 0x06;

/// Octets per SETTINGS parameter: 2 id + 4 value.
pub const SETTINGS_PARAM_LEN: usize = 6;

/// Default initial flow-control window (RFC 7540 section 6.9.2).
pub const DEFAULT_INITIAL_WINDOW: u32 = 65535;
/// Default SETTINGS_MAX_FRAME_SIZE (RFC 7540 section 6.5.2).
pub const DEFAULT_MAX_FRAME_SIZE: u32 = 16384;

/// Parse a 9-byte frame header. No I/O.
///
/// Note:
/// - The reserved top bit of the stream id is dropped, as RFC 7540 section 4.1 asks.
///
/// Param:
/// buf - *const [FRAME_HEADER_LEN]u8 (the raw header bytes)
///
/// Return:
/// - FrameHeader
pub fn parseFrameHeader(buf: *const [FRAME_HEADER_LEN]u8) FrameHeader {
    const length: u24 = std.mem.readInt(u24, buf[0..3], .big);
    const raw_stream_id: u32 = std.mem.readInt(u32, buf[5..9], .big);

    return .{
        .length = length,
        .frame_type = buf[3],
        .flags = buf[4],
        .stream_id = @intCast(raw_stream_id & STREAM_ID_MASK),
    };
}

/// Encode a frame header into 9 bytes. No I/O.
///
/// Param:
/// buf - *[FRAME_HEADER_LEN]u8 (destination)
/// header - FrameHeader (the header to encode)
///
/// Return:
/// - void
pub fn encodeFrameHeader(buf: *[FRAME_HEADER_LEN]u8, header: FrameHeader) void {
    std.mem.writeInt(u24, buf[0..3], header.length, .big);
    buf[3] = header.frame_type;
    buf[4] = header.flags;
    std.mem.writeInt(u32, buf[5..9], header.stream_id, .big);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2: frame, PREFACE is the 24-byte client preface" {
    try std.testing.expect(std.mem.startsWith(u8, PREFACE, "PRI"));
    try std.testing.expectEqual(@as(usize, 24), PREFACE.len);
}

test "zix http2: frame, type values follow RFC 7540" {
    try std.testing.expectEqual(@as(u8, 0x00), FRAME_TYPE_DATA);
    try std.testing.expectEqual(@as(u8, 0x01), FRAME_TYPE_HEADERS);
    try std.testing.expectEqual(@as(u8, 0x04), FRAME_TYPE_SETTINGS);
    try std.testing.expectEqual(@as(u8, 0x08), FRAME_TYPE_WINDOW_UPDATE);
    try std.testing.expectEqual(@as(u8, 0x09), FRAME_TYPE_CONTINUATION);
}

test "zix http2: frame, flag values follow RFC 7540" {
    try std.testing.expectEqual(@as(u8, 0x01), FLAG_END_STREAM);
    try std.testing.expectEqual(@as(u8, 0x04), FLAG_END_HEADERS);
    try std.testing.expectEqual(@as(u8, 0x08), FLAG_PADDED);
    try std.testing.expectEqual(@as(u8, 0x20), FLAG_PRIORITY);
    try std.testing.expectEqual(@as(u8, 0x01), FLAG_ACK);
}

test "zix http2: frame, error code values follow RFC 7540" {
    const codes = [_]u32{
        ERR_NO_ERROR,
        ERR_PROTOCOL_ERROR,
        ERR_INTERNAL_ERROR,
        ERR_FLOW_CONTROL_ERROR,
        ERR_SETTINGS_TIMEOUT,
        ERR_STREAM_CLOSED,
        ERR_FRAME_SIZE_ERROR,
        ERR_REFUSED_STREAM,
        ERR_CANCEL,
        ERR_COMPRESSION_ERROR,
        ERR_CONNECT_ERROR,
        ERR_ENHANCE_YOUR_CALM,
        ERR_INADEQUATE_SECURITY,
        ERR_HTTP_1_1_REQUIRED,
    };

    for (codes, 0..) |code, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), code);
    }
}

test "zix http2: frame, settings id values follow RFC 7540" {
    try std.testing.expectEqual(@as(u16, 0x01), SETTINGS_HEADER_TABLE_SIZE);
    try std.testing.expectEqual(@as(u16, 0x02), SETTINGS_ENABLE_PUSH);
    try std.testing.expectEqual(@as(u16, 0x03), SETTINGS_MAX_CONCURRENT_STREAMS);
    try std.testing.expectEqual(@as(u16, 0x04), SETTINGS_INITIAL_WINDOW_SIZE);
    try std.testing.expectEqual(@as(u16, 0x05), SETTINGS_MAX_FRAME_SIZE);
    try std.testing.expectEqual(@as(u16, 0x06), SETTINGS_MAX_HEADER_LIST_SIZE);
}

test "zix http2: frame, header round trips" {
    const header: FrameHeader = .{
        .length = 42,
        .frame_type = FRAME_TYPE_HEADERS,
        .flags = FLAG_END_HEADERS,
        .stream_id = 3,
    };
    var buf: [FRAME_HEADER_LEN]u8 = undefined;

    encodeFrameHeader(&buf, header);
    const got = parseFrameHeader(&buf);

    try std.testing.expectEqual(header, got);
}

test "zix http2: frame, header encodes big endian" {
    var buf: [FRAME_HEADER_LEN]u8 = undefined;

    encodeFrameHeader(&buf, .{
        .length = 0x010203,
        .frame_type = FRAME_TYPE_DATA,
        .flags = FLAG_END_STREAM,
        .stream_id = 0x01020304,
    });

    const want = [_]u8{ 0x01, 0x02, 0x03, 0x00, 0x01, 0x01, 0x02, 0x03, 0x04 };
    try std.testing.expectEqualSlices(u8, &want, &buf);
}

test "zix http2: frame, header with the largest length and stream id round trips" {
    const header: FrameHeader = .{
        .length = std.math.maxInt(u24),
        .frame_type = 0xFF,
        .flags = 0xFF,
        .stream_id = std.math.maxInt(u31),
    };
    var buf: [FRAME_HEADER_LEN]u8 = undefined;

    encodeFrameHeader(&buf, header);

    try std.testing.expectEqual(header, parseFrameHeader(&buf));
}

test "zix http2: frame, malformed header with the reserved bit set drops it" {
    const buf = [_]u8{ 0x00, 0x00, 0x00, FRAME_TYPE_PING, 0x00, 0x80, 0x00, 0x00, 0x05 };

    const got = parseFrameHeader(&buf);

    try std.testing.expectEqual(@as(u31, 5), got.stream_id);
}

test "zix http2: frame, unknown frame type passes through" {
    const buf = [_]u8{ 0x00, 0x00, 0x01, 0xEE, 0x00, 0x00, 0x00, 0x00, 0x01 };

    const got = parseFrameHeader(&buf);

    try std.testing.expectEqual(@as(u8, 0xEE), got.frame_type);
    try std.testing.expectEqual(@as(u24, 1), got.length);
}

