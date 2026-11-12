//! TLZ crypto DerReader
//!
//! ### file: src/tlz/src/crypto/DerReader.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Minimal DER cursor for private key documents: tags, short and two-byte lengths,
//! and INTEGER magnitudes (ITU-T X.690).
//!
//! ### note:
//!
//! Only what key loading needs. A length longer than two bytes is refused, so a
//! key document is capped at 64 KiB per element. Full X.509 parsing is std's job.
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

/// The DER bytes being read, owned by the caller.
buf: []const u8,
/// Where the next read starts.
pos: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// The only way a read can fail: the DER is not what was expected.
pub const Error = error{
    Tlz_DerReader_Malformed,
};

/// DER tag INTEGER.
pub const TAG_INTEGER: u8 = 0x02;

/// DER tag OCTET STRING.
pub const TAG_OCTET_STRING: u8 = 0x04;

/// DER tag SEQUENCE (constructed).
pub const TAG_SEQUENCE: u8 = 0x30;

/// Read one byte.
///
/// Return:
/// - u8
/// - Error.Tlz_DerReader_Malformed when no byte is left
pub fn readByte(self: *Self) Error!u8 {
    if (self.pos >= self.buf.len) return Error.Tlz_DerReader_Malformed;

    const value = self.buf[self.pos];
    self.pos += 1;

    return value;
}

/// Read one tag byte and check it.
///
/// Param:
/// tag - u8 (the tag the next byte must be)
///
/// Return:
/// - void
/// - Error.Tlz_DerReader_Malformed when the tag differs or no byte is left
pub fn expectTag(self: *Self, tag: u8) Error!void {
    if (try self.readByte() != tag) return Error.Tlz_DerReader_Malformed;
}

/// Read a length: short form, or long form with one or two length bytes.
///
/// Return:
/// - usize
/// - Error.Tlz_DerReader_Malformed on an indefinite or over-long length
pub fn readLen(self: *Self) Error!usize {
    const first = try self.readByte();
    if (first < 0x80) return first;

    const count = first & 0x7f;
    if (count == 0 or count > 2) return Error.Tlz_DerReader_Malformed;

    var len: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) len = (len << 8) | try self.readByte();

    return len;
}

/// Move past `len` bytes.
///
/// Param:
/// len - usize (how many bytes to skip)
///
/// Return:
/// - void
/// - Error.Tlz_DerReader_Malformed when fewer than `len` bytes are left
pub fn skip(self: *Self, len: usize) Error!void {
    if (self.pos + len > self.buf.len) return Error.Tlz_DerReader_Malformed;

    self.pos += len;
}

/// Read a run of bytes without copying.
///
/// Param:
/// len - usize (how many bytes to read)
///
/// Return:
/// - []const u8 (a view into the caller's buffer)
/// - Error.Tlz_DerReader_Malformed when fewer than `len` bytes are left
pub fn readBytes(self: *Self, len: usize) Error![]const u8 {
    if (self.pos + len > self.buf.len) return Error.Tlz_DerReader_Malformed;

    const view = self.buf[self.pos .. self.pos + len];
    self.pos += len;

    return view;
}

/// Skip one tagged element: check its tag, then move past its content.
///
/// Param:
/// tag - u8 (the tag the element must carry)
///
/// Return:
/// - void
/// - Error.Tlz_DerReader_Malformed on a wrong tag or truncated content
pub fn skipElement(self: *Self, tag: u8) Error!void {
    try self.expectTag(tag);

    try self.skip(try self.readLen());
}

/// Read an INTEGER and return its big-endian magnitude, leading 0x00 padding
/// stripped (one byte is always kept).
///
/// Return:
/// - []const u8 (a view into the caller's buffer)
/// - Error.Tlz_DerReader_Malformed on a wrong tag or truncated content
pub fn readInteger(self: *Self) Error![]const u8 {
    try self.expectTag(TAG_INTEGER);

    const len = try self.readLen();
    var content = try self.readBytes(len);
    while (content.len > 1 and content[0] == 0x00) content = content[1..];

    return content;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz crypto: DerReader, readLen reads the short form" {
    var reader: Self = .{ .buf = &[_]u8{0x7f} };

    try std.testing.expectEqual(@as(usize, 0x7f), try reader.readLen());
}

test "tlz crypto: DerReader, readLen reads a two-byte long form" {
    var reader: Self = .{ .buf = &[_]u8{ 0x82, 0x01, 0x23 } };

    try std.testing.expectEqual(@as(usize, 0x0123), try reader.readLen());
}

test "tlz crypto: DerReader, readLen refuses the indefinite form" {
    var reader: Self = .{ .buf = &[_]u8{0x80} };

    try std.testing.expectError(Error.Tlz_DerReader_Malformed, reader.readLen());
}

test "tlz crypto: DerReader, readLen refuses three length bytes" {
    var reader: Self = .{ .buf = &[_]u8{ 0x83, 0x01, 0x00, 0x00 } };

    try std.testing.expectError(Error.Tlz_DerReader_Malformed, reader.readLen());
}

test "tlz crypto: DerReader, expectTag on a wrong tag is malformed" {
    var reader: Self = .{ .buf = &[_]u8{TAG_OCTET_STRING} };

    try std.testing.expectError(Error.Tlz_DerReader_Malformed, reader.expectTag(TAG_SEQUENCE));
}

test "tlz crypto: DerReader, readInteger strips leading zero padding" {
    var reader: Self = .{ .buf = &[_]u8{ TAG_INTEGER, 0x03, 0x00, 0x00, 0x81 } };

    try std.testing.expectEqualSlices(u8, &[_]u8{0x81}, try reader.readInteger());
}

test "tlz crypto: DerReader, readInteger keeps a single zero byte" {
    var reader: Self = .{ .buf = &[_]u8{ TAG_INTEGER, 0x01, 0x00 } };

    try std.testing.expectEqualSlices(u8, &[_]u8{0x00}, try reader.readInteger());
}

test "tlz crypto: DerReader, readBytes past the end is malformed" {
    var reader: Self = .{ .buf = &[_]u8{ 1, 2 } };

    try std.testing.expectError(Error.Tlz_DerReader_Malformed, reader.readBytes(3));
}

test "tlz crypto: DerReader, skipElement moves past the content" {
    var reader: Self = .{ .buf = &[_]u8{ TAG_SEQUENCE, 0x02, 0xaa, 0xbb, 0x05 } };

    try reader.skipElement(TAG_SEQUENCE);

    try std.testing.expectEqual(@as(u8, 0x05), try reader.readByte());
}

test "tlz crypto: DerReader, readByte on empty input is malformed" {
    var reader: Self = .{ .buf = &.{} };

    try std.testing.expectError(Error.Tlz_DerReader_Malformed, reader.readByte());
}

