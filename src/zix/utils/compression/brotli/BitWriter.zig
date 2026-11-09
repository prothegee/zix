//! ZIX utils compression brotli BitWriter
//!
//! ### file: src/zix/utils/compression/brotli/BitWriter.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Growable bit writer for the brotli encoder (RFC 7932 sec 1.5.1): integer fields
//! LSB first, prefix codes MSB first.
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

/// Bytes written so far. The last byte may be partial.
bytes: std.ArrayList(u8) = .empty,
/// Next bit inside the last byte, 0 means a new byte starts.
bit_pos: u3 = 0,

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn appendError(err: std.mem.Allocator.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.OutOfMemory => Error.ZixUtils_BrotliBitWriter_OutOfMemory,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_BrotliBitWriter_OutOfMemory,
};

/// Free the written bytes.
///
/// Param:
/// allocator - std.mem.Allocator (the one used to write)
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.bytes.deinit(allocator);
}

/// Append one bit.
///
/// Param:
/// allocator - std.mem.Allocator (grows the buffer)
/// bit - u1 (bit to append)
///
/// Return:
/// - void
/// - Error.ZixUtils_BrotliBitWriter_OutOfMemory when the buffer cannot grow
pub fn writeBit(self: *Self, allocator: std.mem.Allocator, bit: u1) Error!void {
    if (self.bit_pos == 0) {
        self.bytes.append(allocator, 0) catch |err| return appendError(err);
    }

    const last = self.bytes.items.len - 1;
    self.bytes.items[last] |= @as(u8, bit) << self.bit_pos;
    self.bit_pos +%= 1;
}

/// Append an n-bit integer, least significant bit first.
///
/// Param:
/// allocator - std.mem.Allocator (grows the buffer)
/// value - u32 (integer to append)
/// n - u6 (bit count, at most 32)
///
/// Return:
/// - void
/// - Error.ZixUtils_BrotliBitWriter_OutOfMemory when the buffer cannot grow
pub fn writeInt(self: *Self, allocator: std.mem.Allocator, value: u32, n: u6) Error!void {
    var i: u6 = 0;
    while (i < n) : (i += 1) {
        try self.writeBit(allocator, @truncate(value >> @intCast(i)));
    }
}

/// Append an n-bit prefix code, most significant bit first.
///
/// Param:
/// allocator - std.mem.Allocator (grows the buffer)
/// value - u32 (code to append)
/// n - u6 (bit count, at most 32)
///
/// Return:
/// - void
/// - Error.ZixUtils_BrotliBitWriter_OutOfMemory when the buffer cannot grow
pub fn writeCode(self: *Self, allocator: std.mem.Allocator, value: u32, n: u6) Error!void {
    var i: u6 = n;
    while (i > 0) {
        i -= 1;
        try self.writeBit(allocator, @truncate(value >> @intCast(i)));
    }
}

/// Pad to the next byte boundary with zero bits.
pub fn alignToByte(self: *Self) void {
    self.bit_pos = 0;
}

/// Append whole bytes. Valid only right after alignToByte.
///
/// Param:
/// allocator - std.mem.Allocator (grows the buffer)
/// data - []const u8 (bytes to append)
///
/// Return:
/// - void
/// - Error.ZixUtils_BrotliBitWriter_OutOfMemory when the buffer cannot grow
pub fn writeBytes(self: *Self, allocator: std.mem.Allocator, data: []const u8) Error!void {
    self.bytes.appendSlice(allocator, data) catch |err| return appendError(err);
}

/// Hand over the written bytes.
///
/// Param:
/// allocator - std.mem.Allocator (the one used to write)
///
/// Return:
/// - []u8 (owned by the caller)
/// - Error.ZixUtils_BrotliBitWriter_OutOfMemory when the shrink fails
pub fn toOwnedSlice(self: *Self, allocator: std.mem.Allocator) Error![]u8 {
    return self.bytes.toOwnedSlice(allocator) catch |err| return appendError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression brotli: BitWriter, writeInt packs low bit first" {
    var writer: Self = .{};
    defer writer.deinit(std.testing.allocator);

    try writer.writeInt(std.testing.allocator, 0b101, 3);

    try std.testing.expectEqualSlices(u8, &.{0b101}, writer.bytes.items);
}

test "zix utils compression brotli: BitWriter, writeCode packs high bit first" {
    var writer: Self = .{};
    defer writer.deinit(std.testing.allocator);

    try writer.writeCode(std.testing.allocator, 0b110, 3);

    try std.testing.expectEqualSlices(u8, &.{0b011}, writer.bytes.items);
}

test "zix utils compression brotli: BitWriter, writeInt crosses a byte" {
    var writer: Self = .{};
    defer writer.deinit(std.testing.allocator);

    try writer.writeInt(std.testing.allocator, 0x1ff, 9);

    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x01 }, writer.bytes.items);
}

test "zix utils compression brotli: BitWriter, alignToByte then writeBytes" {
    var writer: Self = .{};
    defer writer.deinit(std.testing.allocator);

    try writer.writeBit(std.testing.allocator, 1);
    writer.alignToByte();
    try writer.writeBytes(std.testing.allocator, "ab");

    try std.testing.expectEqualSlices(u8, &.{ 0x01, 'a', 'b' }, writer.bytes.items);
}

test "zix utils compression brotli: BitWriter, toOwnedSlice hands over the bytes" {
    var writer: Self = .{};
    defer writer.deinit(std.testing.allocator);

    try writer.writeInt(std.testing.allocator, 0xab, 8);
    const owned = try writer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(owned);

    try std.testing.expectEqualSlices(u8, &.{0xab}, owned);
    try std.testing.expectEqual(@as(usize, 0), writer.bytes.items.len);
}

test "zix utils compression brotli: BitWriter, failing allocator is out of memory" {
    var writer: Self = .{};

    try std.testing.expectError(
        Error.ZixUtils_BrotliBitWriter_OutOfMemory,
        writer.writeBit(std.testing.failing_allocator, 1),
    );
}

