//! ZIX Http2 hpack integer
//!
//! ### file: src/zix/tcp/http2/hpack/integer.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! HPACK prefix integer encode and decode (RFC 7541 section 5.1).
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
// Private:

/// Continuation bytes carry 7 value bits each.
const CONTINUATION_BITS: u6 = 7;
const CONTINUATION_FLAG: u8 = 0x80;
const CONTINUATION_MASK: u8 = 0x7F;

/// Past this shift a u64 can no longer hold the next 7 bits.
const MAX_SHIFT: u6 = 56;

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 hpack integer error
pub const Error = error {
    ZixHttp2_HpackInteger_UnexpectedEOF,
    ZixHttp2_HpackInteger_Overflow,
    ZixHttp2_HpackInteger_BufferFull,
};

/// Decode one prefix integer from src at pos, then move pos past it.
///
/// Param:
/// src - []const u8 (the header block)
/// pos - *usize (read position, advanced on success)
/// prefix_bits - u3 (bits of the first byte that hold the value, 1 to 7)
///
/// Return:
/// - u64 (the decoded value)
/// - error.ZixHttp2_HpackInteger_UnexpectedEOF when src ends mid-integer
/// - error.ZixHttp2_HpackInteger_Overflow when the value does not fit a u64
pub fn decodeInt(src: []const u8, pos: *usize, prefix_bits: u3) Error!u64 {
    if (pos.* >= src.len) return Error.ZixHttp2_HpackInteger_UnexpectedEOF;

    const mask: u8 = (@as(u8, 1) << prefix_bits) - 1;
    var value: u64 = src[pos.*] & mask;
    pos.* += 1;

    if (value < mask) return value;

    var shift: u6 = 0;
    while (true) {
        if (pos.* >= src.len) return Error.ZixHttp2_HpackInteger_UnexpectedEOF;

        const byte = src[pos.*];
        pos.* += 1;
        value += @as(u64, byte & CONTINUATION_MASK) << shift;

        if ((byte & CONTINUATION_FLAG) == 0) break;

        shift += CONTINUATION_BITS;
        if (shift > MAX_SHIFT) return Error.ZixHttp2_HpackInteger_Overflow;
    }

    return value;
}

/// Encode one prefix integer into buf at pos, then move pos past it.
///
/// Param:
/// buf - []u8 (destination)
/// pos - *usize (write position, advanced on success)
/// value - u64 (the value to encode)
/// prefix_bits - u3 (bits of the first byte that hold the value, 1 to 7)
/// first_byte_high - u8 (representation bits above the prefix, e.g. 0x80)
///
/// Return:
/// - void when the integer was written
/// - error.ZixHttp2_HpackInteger_BufferFull when buf has no room left
pub fn encodeInt(
    buf: []u8,
    pos: *usize,
    value: u64,
    prefix_bits: u3,
    first_byte_high: u8,
) Error!void {
    const mask: u64 = (@as(u64, 1) << prefix_bits) - 1;
    if (pos.* >= buf.len) return Error.ZixHttp2_HpackInteger_BufferFull;

    if (value < mask) {
        buf[pos.*] = first_byte_high | @as(u8, @intCast(value));
        pos.* += 1;

        return;
    }

    buf[pos.*] = first_byte_high | @as(u8, @intCast(mask));
    pos.* += 1;

    var rem = value - mask;
    while (rem >= CONTINUATION_FLAG) {
        if (pos.* >= buf.len) return Error.ZixHttp2_HpackInteger_BufferFull;

        buf[pos.*] = @as(u8, @intCast(rem & CONTINUATION_MASK)) | CONTINUATION_FLAG;
        pos.* += 1;
        rem >>= CONTINUATION_BITS;
    }

    if (pos.* >= buf.len) return Error.ZixHttp2_HpackInteger_BufferFull;

    buf[pos.*] = @intCast(rem);
    pos.* += 1;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 hpack: integer, 10 with a 5-bit prefix is one byte (RFC 7541 C.1.1)" {
    var buf: [4]u8 = undefined;
    var pos: usize = 0;

    try encodeInt(&buf, &pos, 10, 5, 0);

    try std.testing.expectEqualSlices(u8, &[_]u8{0x0A}, buf[0..pos]);
}

test "zix http2 hpack: integer, 1337 with a 5-bit prefix is three bytes (RFC 7541 C.1.2)" {
    var buf: [4]u8 = undefined;
    var pos: usize = 0;

    try encodeInt(&buf, &pos, 1337, 5, 0);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x1F, 0x9A, 0x0A }, buf[0..pos]);
}

test "zix http2 hpack: integer, decodes 1337 with a 5-bit prefix" {
    const src = [_]u8{ 0x1F, 0x9A, 0x0A };
    var pos: usize = 0;

    try std.testing.expectEqual(@as(u64, 1337), try decodeInt(&src, &pos, 5));
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "zix http2 hpack: integer, decode ignores the representation bits" {
    const src = [_]u8{0x82};
    var pos: usize = 0;

    try std.testing.expectEqual(@as(u64, 2), try decodeInt(&src, &pos, 7));
}

test "zix http2 hpack: integer, round trips across prefix sizes" {
    const values = [_]u64{ 0, 1, 30, 31, 126, 127, 128, 255, 4096, 1 << 32 };

    for (values) |value| {
        for ([_]u3{ 4, 5, 6, 7 }) |prefix_bits| {
            var buf: [16]u8 = undefined;
            var write_pos: usize = 0;
            try encodeInt(&buf, &write_pos, value, prefix_bits, 0);

            var read_pos: usize = 0;
            const got = try decodeInt(buf[0..write_pos], &read_pos, prefix_bits);

            try std.testing.expectEqual(value, got);
            try std.testing.expectEqual(write_pos, read_pos);
        }
    }
}

test "zix http2 hpack: integer, decode on empty input is UnexpectedEOF" {
    var pos: usize = 0;

    const result = decodeInt(&[_]u8{}, &pos, 5);

    try std.testing.expectError(Error.ZixHttp2_HpackInteger_UnexpectedEOF, result);
}

test "zix http2 hpack: integer, decode cut mid-continuation is UnexpectedEOF" {
    const src = [_]u8{ 0x1F, 0x9A };
    var pos: usize = 0;

    const result = decodeInt(&src, &pos, 5);

    try std.testing.expectError(Error.ZixHttp2_HpackInteger_UnexpectedEOF, result);
}

test "zix http2 hpack: integer, decode past 64 bits is Overflow" {
    const src = [_]u8{ 0x1F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
    var pos: usize = 0;

    const result = decodeInt(&src, &pos, 5);

    try std.testing.expectError(Error.ZixHttp2_HpackInteger_Overflow, result);
}

test "zix http2 hpack: integer, encode into a full buffer is BufferFull" {
    var buf: [1]u8 = undefined;
    var pos: usize = 0;

    const result = encodeInt(&buf, &pos, 1337, 5, 0);

    try std.testing.expectError(Error.ZixHttp2_HpackInteger_BufferFull, result);
}

