//! ZIX utils compression brotli BitReader
//!
//! ### file: src/zix/utils/compression/brotli/BitReader.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! LSB-first bit reader over a brotli stream (RFC 7932 sec 1.5.1).
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

/// The whole compressed stream.
bytes: []const u8,
/// Next byte to read.
byte_pos: usize = 0,
/// Next bit inside bytes[byte_pos], 0 is the lowest bit.
bit_pos: u3 = 0,

const Self = @This();

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_BrotliBitReader_Truncated,
};

/// Start a reader at the first bit of bytes.
///
/// Param:
/// bytes - []const u8 (compressed stream)
///
/// Return:
/// - Self
pub fn init(bytes: []const u8) Self {
    return .{
        .bytes = bytes,
    };
}

/// Read one bit.
///
/// Return:
/// - u1
/// - Error.ZixUtils_BrotliBitReader_Truncated past the end
pub fn readBit(self: *Self) Error!u1 {
    if (self.byte_pos >= self.bytes.len) return Error.ZixUtils_BrotliBitReader_Truncated;

    const bit: u1 = @truncate(self.bytes[self.byte_pos] >> self.bit_pos);
    if (self.bit_pos == 7) {
        self.bit_pos = 0;
        self.byte_pos += 1;
    } else {
        self.bit_pos += 1;
    }

    return bit;
}

/// Read an n-bit integer, least significant bit first.
///
/// Param:
/// n - u6 (bit count, at most 32)
///
/// Return:
/// - u32
/// - Error.ZixUtils_BrotliBitReader_Truncated past the end
pub fn readBits(self: *Self, n: u6) Error!u32 {
    var value: u32 = 0;
    var i: u6 = 0;
    while (i < n) : (i += 1) {
        value |= @as(u32, try self.readBit()) << @intCast(i);
    }

    return value;
}

/// Skip to the next byte boundary.
pub fn alignToByte(self: *Self) void {
    if (self.bit_pos != 0) {
        self.bit_pos = 0;
        self.byte_pos += 1;
    }
}

/// Take n whole bytes. Valid only right after alignToByte.
///
/// Param:
/// n - usize (byte count)
///
/// Return:
/// - []const u8 (borrowed from the stream)
/// - Error.ZixUtils_BrotliBitReader_Truncated past the end
pub fn readBytes(self: *Self, n: usize) Error![]const u8 {
    if (self.byte_pos + n > self.bytes.len) return Error.ZixUtils_BrotliBitReader_Truncated;

    const slice = self.bytes[self.byte_pos .. self.byte_pos + n];
    self.byte_pos += n;

    return slice;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression brotli: BitReader, reads bits low first" {
    var reader = init(&.{0b0000_0110});

    try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
}

test "zix utils compression brotli: BitReader, readBits crosses a byte" {
    var reader = init(&.{ 0xff, 0x01 });

    try std.testing.expectEqual(@as(u32, 0x1ff), try reader.readBits(9));
}

test "zix utils compression brotli: BitReader, readBits zero reads nothing" {
    var reader = init(&.{});

    try std.testing.expectEqual(@as(u32, 0), try reader.readBits(0));
}

test "zix utils compression brotli: BitReader, readBit past the end is truncated" {
    var reader = init(&.{});

    try std.testing.expectError(Error.ZixUtils_BrotliBitReader_Truncated, reader.readBit());
}

test "zix utils compression brotli: BitReader, alignToByte skips the rest of a byte" {
    var reader = init(&.{ 0x01, 0xab });

    _ = try reader.readBit();
    reader.alignToByte();

    try std.testing.expectEqualSlices(u8, &.{0xab}, try reader.readBytes(1));
}

test "zix utils compression brotli: BitReader, alignToByte on a boundary stays" {
    var reader = init(&.{0xcd});

    reader.alignToByte();

    try std.testing.expectEqual(@as(usize, 0), reader.byte_pos);
}

test "zix utils compression brotli: BitReader, readBytes past the end is truncated" {
    var reader = init(&.{0x01});

    try std.testing.expectError(Error.ZixUtils_BrotliBitReader_Truncated, reader.readBytes(2));
}

