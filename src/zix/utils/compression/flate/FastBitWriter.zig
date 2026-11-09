//! ZIX utils compression flate FastBitWriter
//!
//! ### file: src/zix/utils/compression/flate/FastBitWriter.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! LSB-first bit writer with a 64-bit accumulator for the fast gzip encoder.
//! 
//! ### note:
//! 
//! The writer does not check bounds. The caller sizes the destination with
//! flate_fast.gzipFastBound before the first put.
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

/// Pending bits, low bits first.
bit_acc: u64 = 0,
/// Number of valid bits in bit_acc.
bit_count: u6 = 0,
/// Next byte to write.
out: [*]u8,
/// First byte of the destination, for the written count.
start: [*]u8,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Start a writer at the first byte of dst.
///
/// Param:
/// dst - []u8 (destination, sized by the caller)
///
/// Return:
/// - Self
pub fn init(dst: []u8) Self {
    return .{
        .out = dst.ptr,
        .start = dst.ptr,
    };
}

/// Append a bit pattern, low bit first. Flushes 4 bytes once 32 bits are pending.
///
/// Param:
/// pattern - u32 (bits to append, low bit first)
/// bits - u6 (number of bits in pattern, at most 32)
pub inline fn put(self: *Self, pattern: u32, bits: u6) void {
    self.bit_acc |= @as(u64, pattern) << self.bit_count;
    self.bit_count += bits;

    if (self.bit_count >= 32) {
        std.mem.writeInt(u32, self.out[0..4], @truncate(self.bit_acc), .little);
        self.out += 4;
        self.bit_acc >>= 32;
        self.bit_count -= 32;
    }
}

/// Flush the pending bits and pad the last byte with zeros.
pub fn finishByteAlign(self: *Self) void {
    while (self.bit_count > 0) {
        self.out[0] = @truncate(self.bit_acc);
        self.out += 1;
        self.bit_acc >>= 8;
        self.bit_count = if (self.bit_count >= 8) self.bit_count - 8 else 0;
    }
}

/// Number of bytes flushed so far.
///
/// Return:
/// - usize
pub fn written(self: *const Self) usize {
    return @intFromPtr(self.out) - @intFromPtr(self.start);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression flate: FastBitWriter, starts empty" {
    var buf: [8]u8 = undefined;
    const writer = init(&buf);

    try std.testing.expectEqual(@as(usize, 0), writer.written());
}

test "zix utils compression flate: FastBitWriter, packs bits low first" {
    var buf: [8]u8 = @splat(0);
    var writer = init(&buf);

    writer.put(0b1, 1);
    writer.put(0b10, 2);
    writer.finishByteAlign();

    try std.testing.expectEqual(@as(usize, 1), writer.written());
    try std.testing.expectEqual(@as(u8, 0b101), buf[0]);
}

test "zix utils compression flate: FastBitWriter, flushes four bytes at 32 bits" {
    var buf: [8]u8 = @splat(0);
    var writer = init(&buf);

    writer.put(0xddccbbaa, 32);

    try std.testing.expectEqual(@as(usize, 4), writer.written());
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc, 0xdd }, buf[0..4]);
}

test "zix utils compression flate: FastBitWriter, align with nothing pending writes nothing" {
    var buf: [8]u8 = undefined;
    var writer = init(&buf);

    writer.finishByteAlign();

    try std.testing.expectEqual(@as(usize, 0), writer.written());
}

test "zix utils compression flate: FastBitWriter, carries bits past a flush" {
    var buf: [8]u8 = @splat(0);
    var writer = init(&buf);

    writer.put(0xffffffff, 30);
    writer.put(0b111, 3);
    writer.finishByteAlign();

    try std.testing.expectEqual(@as(usize, 5), writer.written());
    try std.testing.expectEqual(@as(u8, 0x01), buf[4]);
}

