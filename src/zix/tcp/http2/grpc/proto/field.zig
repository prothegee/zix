//! ZIX Http2 Grpc proto field
//!
//! ### file: src/zix/tcp/http2/grpc/proto/field.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Encode one protobuf field (tag plus value): string, int32, and double.
//! Also decodes a double payload.
//!
//! ### note:
//!
//! A negative int32 encodes as a 10-byte varint (sign-extended to 64 bits), same as protobuf.
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

const varint = @import("varint.zig");
const wire_type = @import("wire_type.zig");

// --------------------------------------------------------- //
// Private:

const Inner = Error || varint.Error;

/// Size of a WT_I64 payload.
const I64_LEN: usize = 8;

/// Field tag: field number in the high bits, wire type in the low 3 bits.
fn tagOf(field_number: u32, wire: u3) u64 {
    return (@as(u64, field_number) << 3) | wire;
}

fn writeString(field_number: u32, str: []const u8, buf: []u8) Inner!usize {
    var pos = try varint.encodeVarint(buf, tagOf(field_number, wire_type.WT_LEN));
    pos += try varint.encodeVarint(buf[pos..], @as(u64, str.len));

    if (str.len > buf.len - pos) return Error.ZixHttp2_GrpcField_BufferFull;

    @memcpy(buf[pos..][0..str.len], str);

    return pos + str.len;
}

fn writeInt32(field_number: u32, val: i32, buf: []u8) Inner!usize {
    const pos = try varint.encodeVarint(buf, tagOf(field_number, wire_type.WT_VARINT));
    const value_len = try varint.encodeVarint(buf[pos..], @bitCast(@as(i64, val)));

    return pos + value_len;
}

fn writeDouble(field_number: u32, val: f64, buf: []u8) Inner!usize {
    const pos = try varint.encodeVarint(buf, tagOf(field_number, wire_type.WT_I64));
    if (I64_LEN > buf.len - pos) return Error.ZixHttp2_GrpcField_BufferFull;

    const bits: u64 = @bitCast(val);
    std.mem.writeInt(u64, buf[pos..][0..I64_LEN], bits, .little);

    return pos + I64_LEN;
}

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixHttp2_GrpcVarint_UnexpectedEOF => Error.ZixHttp2_GrpcField_UnexpectedEOF,
        error.ZixHttp2_GrpcVarint_Overflow => Error.ZixHttp2_GrpcField_Overflow,
        error.ZixHttp2_GrpcVarint_BufferFull => Error.ZixHttp2_GrpcField_BufferFull,
        error.ZixHttp2_GrpcField_UnexpectedEOF => Error.ZixHttp2_GrpcField_UnexpectedEOF,
        error.ZixHttp2_GrpcField_Overflow => Error.ZixHttp2_GrpcField_Overflow,
        error.ZixHttp2_GrpcField_BufferFull => Error.ZixHttp2_GrpcField_BufferFull,
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc proto field error
pub const Error = error {
    ZixHttp2_GrpcField_UnexpectedEOF,
    ZixHttp2_GrpcField_Overflow,
    ZixHttp2_GrpcField_BufferFull,
};

/// Encode a WT_LEN field (string or bytes) at the start of buf.
///
/// Param:
/// field_number - u32 (field number from the .proto definition)
/// str - []const u8 (the bytes to encode)
/// buf - []u8 (destination)
///
/// Return:
/// - usize (bytes written)
/// - error.ZixHttp2_GrpcField_BufferFull when buf is too small
pub fn encodeString(field_number: u32, str: []const u8, buf: []u8) Error!usize {
    return writeString(field_number, str, buf) catch |err| innerError(err);
}

/// Encode a WT_VARINT field (int32) at the start of buf.
///
/// Param:
/// field_number - u32 (field number from the .proto definition)
/// val - i32 (the value to encode)
/// buf - []u8 (destination)
///
/// Return:
/// - usize (bytes written)
/// - error.ZixHttp2_GrpcField_BufferFull when buf is too small
pub fn encodeInt32(field_number: u32, val: i32, buf: []u8) Error!usize {
    return writeInt32(field_number, val, buf) catch |err| innerError(err);
}

/// Encode a WT_I64 field (double, 8 bytes little-endian) at the start of buf.
///
/// Param:
/// field_number - u32 (field number from the .proto definition)
/// val - f64 (the value to encode)
/// buf - []u8 (destination)
///
/// Return:
/// - usize (bytes written)
/// - error.ZixHttp2_GrpcField_BufferFull when buf is too small
pub fn encodeDouble(field_number: u32, val: f64, buf: []u8) Error!usize {
    return writeDouble(field_number, val, buf) catch |err| innerError(err);
}

/// Decode a double from a WT_I64 payload (8 bytes little-endian).
///
/// Param:
/// payload - *const [8]u8 (the field payload)
///
/// Return:
/// - f64
pub fn decodeDouble(payload: *const [8]u8) f64 {
    const bits = std.mem.readInt(u64, payload, .little);

    return @bitCast(bits);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 grpc proto: field, string encodes tag, length, and bytes" {
    var buf: [16]u8 = undefined;

    const len = try encodeString(1, "hi", &buf);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x02, 'h', 'i' }, buf[0..len]);
}

test "zix http2 grpc proto: field, empty string encodes a zero length" {
    var buf: [4]u8 = undefined;

    const len = try encodeString(1, "", &buf);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x00 }, buf[0..len]);
}

test "zix http2 grpc proto: field, int32 150 encodes as a varint field" {
    var buf: [16]u8 = undefined;

    const len = try encodeInt32(1, 150, &buf);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x96, 0x01 }, buf[0..len]);
}

test "zix http2 grpc proto: field, negative int32 encodes to 10 value bytes" {
    var buf: [16]u8 = undefined;

    const len = try encodeInt32(1, -1, &buf);

    try std.testing.expectEqual(@as(usize, 1 + varint.MAX_LEN), len);
}

test "zix http2 grpc proto: field, double round trips positive" {
    var buf: [16]u8 = undefined;

    const len = try encodeDouble(1, 106.8, &buf);

    try std.testing.expectEqual(@as(usize, 9), len);
    try std.testing.expectEqual(@as(u8, 0x09), buf[0]);
    try std.testing.expectEqual(@as(f64, 106.8), decodeDouble(buf[1..9]));
}

test "zix http2 grpc proto: field, double round trips negative" {
    var buf: [16]u8 = undefined;

    const len = try encodeDouble(2, -6.2, &buf);

    try std.testing.expectEqual(@as(u8, 0x11), buf[0]);
    try std.testing.expectEqual(@as(f64, -6.2), decodeDouble(buf[1..len][0..8]));
}

test "zix http2 grpc proto: field, string past the buf is BufferFull" {
    var buf: [4]u8 = undefined;

    const result = encodeString(1, "hello", &buf);

    try std.testing.expectError(Error.ZixHttp2_GrpcField_BufferFull, result);
}

test "zix http2 grpc proto: field, int32 without room for the value is BufferFull" {
    var buf: [1]u8 = undefined;

    const result = encodeInt32(1, 1, &buf);

    try std.testing.expectError(Error.ZixHttp2_GrpcField_BufferFull, result);
}

test "zix http2 grpc proto: field, double without 8 payload bytes is BufferFull" {
    var buf: [8]u8 = undefined;

    const result = encodeDouble(1, 1.0, &buf);

    try std.testing.expectError(Error.ZixHttp2_GrpcField_BufferFull, result);
}

test "zix http2 grpc proto: field, empty buf is BufferFull" {
    var buf: [0]u8 = undefined;

    const result = encodeString(1, "", &buf);

    try std.testing.expectError(Error.ZixHttp2_GrpcField_BufferFull, result);
}

