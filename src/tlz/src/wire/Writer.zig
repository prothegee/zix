//! TLZ wire Writer
//!
//! ### file: src/tlz/src/wire/Writer.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Appends big-endian TLS fields into a caller buffer, with deferred length
//! patching for nested vectors (RFC 8446 section 3).
//!
//! ### note:
//!
//! Writes are not bounds-checked. The caller sizes `buf` for the whole message
//! up front. A `place` call reserves a length field, the matching `patch` call
//! fills it once the body is written.
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

/// The buffer every write lands in, owned by the caller.
buf: []u8,
/// Where the next byte goes, also the count of bytes written so far.
len: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Store a u24 big-endian at `index`.
///
/// Param:
/// buf - []u8 (the destination)
/// index - usize (where the 3 bytes start)
/// value - u32 (only the low 24 bits are written)
///
/// Return:
/// - void
fn storeU24(buf: []u8, index: usize, value: u32) void {
    buf[index] = @intCast((value >> 16) & 0xff);
    buf[index + 1] = @intCast((value >> 8) & 0xff);
    buf[index + 2] = @intCast(value & 0xff);
}

// --------------------------------------------------------- //
// Public:

/// Write one byte.
///
/// Param:
/// value - u8 (the byte to write)
///
/// Return:
/// - void
pub fn writeU8(self: *Self, value: u8) void {
    self.buf[self.len] = value;
    self.len += 1;
}

/// Write a big-endian u16.
///
/// Param:
/// value - u16 (the value to write)
///
/// Return:
/// - void
pub fn writeU16(self: *Self, value: u16) void {
    std.mem.writeInt(u16, self.buf[self.len..][0..2], value, .big);
    self.len += 2;
}

/// Write a big-endian u24.
///
/// Param:
/// value - u32 (only the low 24 bits are written)
///
/// Return:
/// - void
pub fn writeU24(self: *Self, value: u32) void {
    storeU24(self.buf, self.len, value);
    self.len += 3;
}

/// Write a run of bytes.
///
/// Param:
/// bytes - []const u8 (the bytes to copy in)
///
/// Return:
/// - void
pub fn writeBytes(self: *Self, bytes: []const u8) void {
    @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
    self.len += bytes.len;
}

/// Reserve a u16 length field.
///
/// Return:
/// - usize (the marker to hand to `patchU16` once the body is written)
pub fn placeU16(self: *Self) usize {
    const marker = self.len;
    self.writeU16(0);

    return marker;
}

/// Fill a reserved u16 length field with the body length written since.
///
/// Param:
/// marker - usize (the value `placeU16` returned)
///
/// Return:
/// - void
pub fn patchU16(self: *Self, marker: usize) void {
    const body_len: u16 = @intCast(self.len - marker - 2);

    std.mem.writeInt(u16, self.buf[marker..][0..2], body_len, .big);
}

/// Reserve a u24 length field (the handshake message header length).
///
/// Return:
/// - usize (the marker to hand to `patchU24` once the body is written)
pub fn placeU24(self: *Self) usize {
    const marker = self.len;
    self.writeU24(0);

    return marker;
}

/// Fill a reserved u24 length field with the body length written since.
///
/// Param:
/// marker - usize (the value `placeU24` returned)
///
/// Return:
/// - void
pub fn patchU24(self: *Self, marker: usize) void {
    const body_len: u32 = @intCast(self.len - marker - 3);

    storeU24(self.buf, marker, body_len);
}

/// The region written so far.
///
/// Return:
/// - []const u8 (a view into the caller's buffer)
pub fn slice(self: *const Self) []const u8 {
    return self.buf[0..self.len];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Reader = @import("Reader.zig");

test "tlz wire: Writer, writes big-endian integers in order" {
    var buf: [6]u8 = undefined;
    var writer: Self = .{ .buf = &buf };

    writer.writeU8(0xaa);
    writer.writeU16(0x1122);
    writer.writeU24(0x010203);

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0xaa, 0x11, 0x22, 0x01, 0x02, 0x03 },
        writer.slice(),
    );
}

test "tlz wire: Writer, placeU16 and patchU16 frame a nested vector" {
    var buf: [16]u8 = undefined;
    var writer: Self = .{ .buf = &buf };

    writer.writeU8(0xaa);
    const vector = writer.placeU16();
    writer.writeU16(0x1122);
    writer.writeU8(0x33);
    writer.patchU16(vector);

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0xaa, 0x00, 0x03, 0x11, 0x22, 0x33 },
        writer.slice(),
    );
}

test "tlz wire: Writer, placeU24 and patchU24 frame a handshake body" {
    var buf: [16]u8 = undefined;
    var writer: Self = .{ .buf = &buf };

    writer.writeU8(0x01);
    const body = writer.placeU24();
    writer.writeBytes("abcd");
    writer.patchU24(body);

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x01, 0x00, 0x00, 0x04, 'a', 'b', 'c', 'd' },
        writer.slice(),
    );
}

test "tlz wire: Writer, empty vector patches to zero length" {
    var buf: [4]u8 = undefined;
    var writer: Self = .{ .buf = &buf };

    const vector = writer.placeU16();
    writer.patchU16(vector);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00 }, writer.slice());
}

test "tlz wire: Writer, writeU24 drops bits above 24" {
    var buf: [3]u8 = undefined;
    var writer: Self = .{ .buf = &buf };

    writer.writeU24(0xff123456);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x56 }, writer.slice());
}

test "tlz wire: Writer, output reads back through Reader" {
    var buf: [16]u8 = undefined;
    var writer: Self = .{ .buf = &buf };

    writer.writeU8(0xaa);
    const vector = writer.placeU16();
    writer.writeU16(0x1122);
    writer.writeU8(0x33);
    writer.patchU16(vector);

    var reader: Reader = .{ .buf = writer.slice() };

    try std.testing.expectEqual(@as(u8, 0xaa), try reader.readU8());
    try std.testing.expectEqual(@as(u16, 3), try reader.readU16());
    try std.testing.expectEqual(@as(u16, 0x1122), try reader.readU16());
    try std.testing.expectEqual(@as(u8, 0x33), try reader.readU8());
    try std.testing.expectError(Reader.Error.Tlz_WireReader_Truncated, reader.readU8());
}

