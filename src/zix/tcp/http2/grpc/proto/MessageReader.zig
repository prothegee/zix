//! ZIX Http2 Grpc proto MessageReader
//!
//! ### file: src/zix/tcp/http2/grpc/proto/MessageReader.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Reads the fields of one protobuf message in order, one field per next call.
//!
//! ### note:
//!
//! Fields point into buf, so buf must outlive every field read from it.
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

const ProtoField = @import("ProtoField.zig");
const varint = @import("varint.zig");
const wire_type = @import("wire_type.zig");

// --------------------------------------------------------- //
// Fields:

/// The encoded message.
buf: []const u8,
/// Read position in buf.
pos: usize,

const Self = @This();

// --------------------------------------------------------- //
// Private:

const Inner = Error || varint.Error;

const I64_LEN: usize = 8;
const I32_LEN: usize = 4;
const WIRE_TYPE_MASK: u64 = 0x07;

/// Take len bytes at pos, then move pos past them.
fn takeBytes(self: *Self, len: u64) Error![]const u8 {
    if (len > self.buf.len - self.pos) return Error.ZixHttp2_GrpcMessageReader_UnexpectedEOF;

    const data_len: usize = @intCast(len);
    const data = self.buf[self.pos..][0..data_len];
    self.pos += data_len;

    return data;
}

fn takeVarint(self: *Self) Inner!u64 {
    const decoded = try varint.decodeVarint(self.buf[self.pos..]);
    self.pos += decoded.consumed;

    return decoded.value;
}

fn bytesField(field_number: u32, wire: u3, data: []const u8) ProtoField {
    return .{
        .field_number = field_number,
        .wire_type = wire,
        .payload = data,
        .value_u64 = 0,
    };
}

fn nextField(self: *Self) Inner!?ProtoField {
    if (self.pos >= self.buf.len) return null;

    const tag = try self.takeVarint();
    const wire: u3 = @intCast(tag & WIRE_TYPE_MASK);
    const number = tag >> 3;
    if (number > std.math.maxInt(u32)) {
        return Error.ZixHttp2_GrpcMessageReader_FieldNumberTooLarge;
    }

    const field_number: u32 = @intCast(number);

    switch (wire) {
        wire_type.WT_VARINT => {
            const value = try self.takeVarint();

            return .{
                .field_number = field_number,
                .wire_type = wire,
                .payload = &.{},
                .value_u64 = value,
            };
        },
        wire_type.WT_I64 => {
            return bytesField(field_number, wire, try self.takeBytes(I64_LEN));
        },
        wire_type.WT_LEN => {
            const len = try self.takeVarint();

            return bytesField(field_number, wire, try self.takeBytes(len));
        },
        wire_type.WT_I32 => {
            return bytesField(field_number, wire, try self.takeBytes(I32_LEN));
        },
        else => return Error.ZixHttp2_GrpcMessageReader_UnknownWireType,
    }
}

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixHttp2_GrpcVarint_UnexpectedEOF =>
            Error.ZixHttp2_GrpcMessageReader_UnexpectedEOF,
        error.ZixHttp2_GrpcVarint_Overflow =>
            Error.ZixHttp2_GrpcMessageReader_Overflow,
        error.ZixHttp2_GrpcVarint_BufferFull =>
            Error.ZixHttp2_GrpcMessageReader_BufferFull,
        error.ZixHttp2_GrpcMessageReader_UnexpectedEOF =>
            Error.ZixHttp2_GrpcMessageReader_UnexpectedEOF,
        error.ZixHttp2_GrpcMessageReader_Overflow =>
            Error.ZixHttp2_GrpcMessageReader_Overflow,
        error.ZixHttp2_GrpcMessageReader_BufferFull =>
            Error.ZixHttp2_GrpcMessageReader_BufferFull,
        error.ZixHttp2_GrpcMessageReader_UnknownWireType =>
            Error.ZixHttp2_GrpcMessageReader_UnknownWireType,
        error.ZixHttp2_GrpcMessageReader_FieldNumberTooLarge =>
            Error.ZixHttp2_GrpcMessageReader_FieldNumberTooLarge,
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc proto MessageReader error
pub const Error = error {
    ZixHttp2_GrpcMessageReader_UnexpectedEOF,
    ZixHttp2_GrpcMessageReader_Overflow,
    ZixHttp2_GrpcMessageReader_BufferFull,
    ZixHttp2_GrpcMessageReader_UnknownWireType,
    ZixHttp2_GrpcMessageReader_FieldNumberTooLarge,
};

/// Start reading at the first field of buf.
///
/// Param:
/// buf - []const u8 (one encoded message, without the gRPC 5-byte prefix)
///
/// Return:
/// - Self
pub fn init(buf: []const u8) Self {
    return .{
        .buf = buf,
        .pos = 0,
    };
}

/// Read the next field.
///
/// Return:
/// - ?ProtoField (null at the end of the message)
/// - error.ZixHttp2_GrpcMessageReader_UnexpectedEOF when a field is cut short
/// - error.ZixHttp2_GrpcMessageReader_Overflow when a varint does not fit a u64
/// - error.ZixHttp2_GrpcMessageReader_UnknownWireType on wire type 3, 4, 6, or 7
/// - error.ZixHttp2_GrpcMessageReader_FieldNumberTooLarge when the number does not fit a u32
pub fn next(self: *Self) Error!?ProtoField {
    return self.nextField() catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const field = @import("field.zig");

test "zix http2 grpc proto: MessageReader, empty buf returns null" {
    var reader = Self.init(&.{});

    try std.testing.expect((try reader.next()) == null);
}

test "zix http2 grpc proto: MessageReader, reads a string field" {
    var buf: [64]u8 = undefined;
    const len = try field.encodeString(1, "hello", &buf);
    var reader = Self.init(buf[0..len]);

    const got = (try reader.next()).?;

    try std.testing.expectEqual(@as(u32, 1), got.field_number);
    try std.testing.expectEqual(wire_type.WT_LEN, got.wire_type);
    try std.testing.expectEqualStrings("hello", got.payload);
    try std.testing.expect((try reader.next()) == null);
}

test "zix http2 grpc proto: MessageReader, reads a varint field" {
    var buf: [16]u8 = undefined;
    const len = try field.encodeInt32(3, 150, &buf);
    var reader = Self.init(buf[0..len]);

    const got = (try reader.next()).?;

    try std.testing.expectEqual(@as(u32, 3), got.field_number);
    try std.testing.expectEqual(wire_type.WT_VARINT, got.wire_type);
    try std.testing.expectEqual(@as(u64, 150), got.value_u64);
}

test "zix http2 grpc proto: MessageReader, reads a double field" {
    var buf: [16]u8 = undefined;
    const len = try field.encodeDouble(2, -6.2, &buf);
    var reader = Self.init(buf[0..len]);

    const got = (try reader.next()).?;

    try std.testing.expectEqual(wire_type.WT_I64, got.wire_type);
    try std.testing.expectEqual(@as(f64, -6.2), field.decodeDouble(got.payload[0..8]));
}

test "zix http2 grpc proto: MessageReader, reads an I32 field" {
    const src = [_]u8{ 0x0D, 0x01, 0x02, 0x03, 0x04 };
    var reader = Self.init(&src);

    const got = (try reader.next()).?;

    try std.testing.expectEqual(wire_type.WT_I32, got.wire_type);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04 }, got.payload);
}

test "zix http2 grpc proto: MessageReader, reads fields in order" {
    var buf: [64]u8 = undefined;
    var len = try field.encodeString(1, "a", &buf);
    len += try field.encodeInt32(2, 7, buf[len..]);
    var reader = Self.init(buf[0..len]);

    const first = (try reader.next()).?;
    const second = (try reader.next()).?;

    try std.testing.expectEqual(@as(u32, 1), first.field_number);
    try std.testing.expectEqual(@as(u32, 2), second.field_number);
    try std.testing.expect((try reader.next()) == null);
}

test "zix http2 grpc proto: MessageReader, LEN past the buf is UnexpectedEOF" {
    const src = [_]u8{ 0x0A, 0x05, 'h', 'i' };
    var reader = Self.init(&src);

    const result = reader.next();

    try std.testing.expectError(Error.ZixHttp2_GrpcMessageReader_UnexpectedEOF, result);
}

test "zix http2 grpc proto: MessageReader, max u64 LEN is UnexpectedEOF" {
    const src = [_]u8{ 0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
    var reader = Self.init(&src);

    const result = reader.next();

    try std.testing.expectError(Error.ZixHttp2_GrpcMessageReader_UnexpectedEOF, result);
}

test "zix http2 grpc proto: MessageReader, short I64 is UnexpectedEOF" {
    const src = [_]u8{ 0x09, 0x01, 0x02 };
    var reader = Self.init(&src);

    const result = reader.next();

    try std.testing.expectError(Error.ZixHttp2_GrpcMessageReader_UnexpectedEOF, result);
}

test "zix http2 grpc proto: MessageReader, short I32 is UnexpectedEOF" {
    const src = [_]u8{ 0x0D, 0x01 };
    var reader = Self.init(&src);

    const result = reader.next();

    try std.testing.expectError(Error.ZixHttp2_GrpcMessageReader_UnexpectedEOF, result);
}

test "zix http2 grpc proto: MessageReader, cut varint value is UnexpectedEOF" {
    const src = [_]u8{ 0x08, 0x80 };
    var reader = Self.init(&src);

    const result = reader.next();

    try std.testing.expectError(Error.ZixHttp2_GrpcMessageReader_UnexpectedEOF, result);
}

test "zix http2 grpc proto: MessageReader, group wire type is UnknownWireType" {
    const src = [_]u8{0x0B};
    var reader = Self.init(&src);

    const result = reader.next();

    try std.testing.expectError(Error.ZixHttp2_GrpcMessageReader_UnknownWireType, result);
}

test "zix http2 grpc proto: MessageReader, tag past 64 bits is Overflow" {
    const src = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F };
    var reader = Self.init(&src);

    const result = reader.next();

    try std.testing.expectError(Error.ZixHttp2_GrpcMessageReader_Overflow, result);
}

test "zix http2 grpc proto: MessageReader, field number past u32 is FieldNumberTooLarge" {
    var buf: [varint.MAX_LEN]u8 = undefined;
    const tag: u64 = (@as(u64, std.math.maxInt(u32)) + 1) << 3;
    const len = try varint.encodeVarint(&buf, tag);
    var reader = Self.init(buf[0..len]);

    const result = reader.next();

    try std.testing.expectError(
        Error.ZixHttp2_GrpcMessageReader_FieldNumberTooLarge,
        result,
    );
}

