//! TLZ wire Reader
//!
//! ### file: src/tlz/src/wire/Reader.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Bounds-checked cursor over a byte slice, for the TLS presentation language
//! (RFC 8446 section 3). Every read is big-endian.
//!
//! ### note:
//!
//! A read past the end returns an error and leaves `pos` where it was.
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

/// The bytes being read, owned by the caller.
buf: []const u8,
/// Where the next read starts.
pos: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// The only way a read can fail: not enough bytes left.
pub const Error = error{
    Tlz_WireReader_Truncated,
};

/// Read one byte.
///
/// Return:
/// - u8
/// - Error.Tlz_WireReader_Truncated when no byte is left
pub fn readU8(self: *Self) Error!u8 {
    if (self.pos + 1 > self.buf.len) return Error.Tlz_WireReader_Truncated;

    const value = self.buf[self.pos];
    self.pos += 1;

    return value;
}

/// Read a big-endian u16.
///
/// Return:
/// - u16
/// - Error.Tlz_WireReader_Truncated when fewer than 2 bytes are left
pub fn readU16(self: *Self) Error!u16 {
    if (self.pos + 2 > self.buf.len) return Error.Tlz_WireReader_Truncated;

    const value = std.mem.readInt(u16, self.buf[self.pos..][0..2], .big);
    self.pos += 2;

    return value;
}

/// Read a big-endian u24 (the handshake message length), widened to u32.
///
/// Return:
/// - u32
/// - Error.Tlz_WireReader_Truncated when fewer than 3 bytes are left
pub fn readU24(self: *Self) Error!u32 {
    if (self.pos + 3 > self.buf.len) return Error.Tlz_WireReader_Truncated;

    const bytes = self.buf[self.pos..][0..3];
    self.pos += 3;

    return (@as(u32, bytes[0]) << 16) | (@as(u32, bytes[1]) << 8) | bytes[2];
}

/// Read a run of bytes without copying.
///
/// Param:
/// len - usize (how many bytes to read)
///
/// Return:
/// - []const u8 (a view into the caller's buffer)
/// - Error.Tlz_WireReader_Truncated when fewer than `len` bytes are left
pub fn readBytes(self: *Self, len: usize) Error![]const u8 {
    if (self.pos + len > self.buf.len) return Error.Tlz_WireReader_Truncated;

    const view = self.buf[self.pos .. self.pos + len];
    self.pos += len;

    return view;
}

/// How many bytes are still unread.
///
/// Return:
/// - usize
pub fn remaining(self: *const Self) usize {
    return self.buf.len - self.pos;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz wire: Reader, reads big-endian integers in order" {
    const bytes = [_]u8{ 0xaa, 0x11, 0x22, 0x01, 0x02, 0x03 };
    var reader: Self = .{ .buf = &bytes };

    try std.testing.expectEqual(@as(u8, 0xaa), try reader.readU8());
    try std.testing.expectEqual(@as(u16, 0x1122), try reader.readU16());
    try std.testing.expectEqual(@as(u32, 0x010203), try reader.readU24());
    try std.testing.expectEqual(@as(usize, 0), reader.remaining());
}

test "tlz wire: Reader, readBytes returns a view and advances" {
    const bytes = [_]u8{ 1, 2, 3, 4 };
    var reader: Self = .{ .buf = &bytes };

    const view = try reader.readBytes(3);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, view);
    try std.testing.expectEqual(@as(usize, 1), reader.remaining());
}

test "tlz wire: Reader, readBytes of zero on empty input succeeds" {
    var reader: Self = .{ .buf = &.{} };

    const view = try reader.readBytes(0);

    try std.testing.expectEqual(@as(usize, 0), view.len);
}

test "tlz wire: Reader, readU8 on empty input is truncated" {
    var reader: Self = .{ .buf = &.{} };

    try std.testing.expectError(Error.Tlz_WireReader_Truncated, reader.readU8());
}

test "tlz wire: Reader, readU16 with one byte left is truncated" {
    const bytes = [_]u8{0x01};
    var reader: Self = .{ .buf = &bytes };

    try std.testing.expectError(Error.Tlz_WireReader_Truncated, reader.readU16());
}

test "tlz wire: Reader, readU24 with two bytes left is truncated" {
    const bytes = [_]u8{ 0x01, 0x02 };
    var reader: Self = .{ .buf = &bytes };

    try std.testing.expectError(Error.Tlz_WireReader_Truncated, reader.readU24());
}

test "tlz wire: Reader, readBytes past the end is truncated" {
    const bytes = [_]u8{ 1, 2 };
    var reader: Self = .{ .buf = &bytes };

    try std.testing.expectError(Error.Tlz_WireReader_Truncated, reader.readBytes(3));
}

test "tlz wire: Reader, failed read keeps the position" {
    const bytes = [_]u8{ 0x01, 0x02 };
    var reader: Self = .{ .buf = &bytes };

    _ = try reader.readU8();
    try std.testing.expectError(Error.Tlz_WireReader_Truncated, reader.readU16());

    try std.testing.expectEqual(@as(usize, 1), reader.pos);
}

