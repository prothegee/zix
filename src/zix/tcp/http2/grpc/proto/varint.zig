//! ZIX Http2 Grpc proto varint
//!
//! ### file: src/zix/tcp/http2/grpc/proto/varint.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Protobuf unsigned varint encode and decode (7 value bits per byte, low bits first).
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

const CONTINUATION_BITS: u6 = 7;
const CONTINUATION_FLAG: u8 = 0x80;
const PAYLOAD_MASK: u8 = 0x7F;

/// Shift of the 10th byte. Only bit 0 of that byte still fits a u64.
const LAST_SHIFT: u6 = 63;

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc proto varint error
pub const Error = error {
    ZixHttp2_GrpcVarint_UnexpectedEOF,
    ZixHttp2_GrpcVarint_Overflow,
    ZixHttp2_GrpcVarint_BufferFull,
};

/// Longest varint for a u64.
pub const MAX_LEN: usize = 10;

/// One decoded varint.
pub const Decoded = struct {
    /// The decoded value.
    value: u64,
    /// Bytes read from the input.
    consumed: usize,
};

/// Encode value as an unsigned varint at the start of buf.
///
/// Note:
/// - On BufferFull, buf may hold a partial varint.
///
/// Param:
/// buf - []u8 (destination)
/// value - u64 (the value to encode)
///
/// Return:
/// - usize (bytes written)
/// - error.ZixHttp2_GrpcVarint_BufferFull when buf is too small
pub fn encodeVarint(buf: []u8, value: u64) Error!usize {
    var rem = value;
    var pos: usize = 0;

    while (rem >= CONTINUATION_FLAG) {
        if (pos >= buf.len) return Error.ZixHttp2_GrpcVarint_BufferFull;

        buf[pos] = @as(u8, @intCast(rem & PAYLOAD_MASK)) | CONTINUATION_FLAG;
        pos += 1;
        rem >>= CONTINUATION_BITS;
    }

    if (pos >= buf.len) return Error.ZixHttp2_GrpcVarint_BufferFull;

    buf[pos] = @intCast(rem);

    return pos + 1;
}

/// Decode one unsigned varint from the start of buf.
///
/// Param:
/// buf - []const u8 (input, may hold more bytes after the varint)
///
/// Return:
/// - Decoded (value and bytes consumed)
/// - error.ZixHttp2_GrpcVarint_UnexpectedEOF when buf ends mid-varint
/// - error.ZixHttp2_GrpcVarint_Overflow when the value does not fit a u64
pub fn decodeVarint(buf: []const u8) Error!Decoded {
    var value: u64 = 0;
    var shift: u6 = 0;
    var pos: usize = 0;

    while (pos < buf.len) {
        const byte = buf[pos];
        pos += 1;

        const bits: u64 = byte & PAYLOAD_MASK;
        if (shift == LAST_SHIFT and bits > 1) return Error.ZixHttp2_GrpcVarint_Overflow;

        value |= bits << shift;
        if ((byte & CONTINUATION_FLAG) == 0) {
            return .{
                .value = value,
                .consumed = pos,
            };
        }

        if (shift == LAST_SHIFT) return Error.ZixHttp2_GrpcVarint_Overflow;

        shift += CONTINUATION_BITS;
    }

    return Error.ZixHttp2_GrpcVarint_UnexpectedEOF;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 grpc proto: varint, 1 encodes to one byte" {
    var buf: [MAX_LEN]u8 = undefined;

    const len = try encodeVarint(&buf, 1);

    try std.testing.expectEqualSlices(u8, &[_]u8{0x01}, buf[0..len]);
}

test "zix http2 grpc proto: varint, 300 encodes to two bytes" {
    var buf: [MAX_LEN]u8 = undefined;

    const len = try encodeVarint(&buf, 300);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAC, 0x02 }, buf[0..len]);
}

test "zix http2 grpc proto: varint, max u64 encodes to MAX_LEN bytes" {
    var buf: [MAX_LEN]u8 = undefined;

    const len = try encodeVarint(&buf, std.math.maxInt(u64));

    try std.testing.expectEqual(MAX_LEN, len);
}

test "zix http2 grpc proto: varint, round trips across sizes" {
    const values = [_]u64{ 0, 1, 127, 128, 300, 16_383, 16_384, 1 << 32, std.math.maxInt(u64) };

    for (values) |value| {
        var buf: [MAX_LEN]u8 = undefined;
        const len = try encodeVarint(&buf, value);

        const decoded = try decodeVarint(buf[0..len]);

        try std.testing.expectEqual(value, decoded.value);
        try std.testing.expectEqual(len, decoded.consumed);
    }
}

test "zix http2 grpc proto: varint, decode stops at the first final byte" {
    const src = [_]u8{ 0xAC, 0x02, 0xFF };

    const decoded = try decodeVarint(&src);

    try std.testing.expectEqual(@as(u64, 300), decoded.value);
    try std.testing.expectEqual(@as(usize, 2), decoded.consumed);
}

test "zix http2 grpc proto: varint, encode into empty buf is BufferFull" {
    var buf: [0]u8 = undefined;

    const result = encodeVarint(&buf, 0);

    try std.testing.expectError(Error.ZixHttp2_GrpcVarint_BufferFull, result);
}

test "zix http2 grpc proto: varint, encode past the buf is BufferFull" {
    var buf: [1]u8 = undefined;

    const result = encodeVarint(&buf, 300);

    try std.testing.expectError(Error.ZixHttp2_GrpcVarint_BufferFull, result);
}

test "zix http2 grpc proto: varint, decode on empty input is UnexpectedEOF" {
    const result = decodeVarint(&[_]u8{});

    try std.testing.expectError(Error.ZixHttp2_GrpcVarint_UnexpectedEOF, result);
}

test "zix http2 grpc proto: varint, truncated input is UnexpectedEOF" {
    const result = decodeVarint(&[_]u8{ 0x80, 0x80 });

    try std.testing.expectError(Error.ZixHttp2_GrpcVarint_UnexpectedEOF, result);
}

test "zix http2 grpc proto: varint, 10th byte past bit 0 is Overflow" {
    const src = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02 };

    const result = decodeVarint(&src);

    try std.testing.expectError(Error.ZixHttp2_GrpcVarint_Overflow, result);
}

test "zix http2 grpc proto: varint, 11 bytes is Overflow" {
    const src = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x81, 0x00 };

    const result = decodeVarint(&src);

    try std.testing.expectError(Error.ZixHttp2_GrpcVarint_Overflow, result);
}

