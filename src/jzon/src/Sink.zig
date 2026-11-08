//! JZON Sink
//!
//! ### file: src/jzon/src/Sink.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Bounds-checked write cursor over a caller-owned buffer.
//!
//! ### note:
//!
//! One call is all-or-nothing: it fits whole and advances, or it fails and leaves the
//! position where it was. A sequence of calls is not: when the fourth of five writes
//! fails, the first three stay in the buffer.
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

/// The caller-owned buffer every write lands in.
buf: []u8,
/// Where the next byte goes, also the count of bytes written so far.
pos: usize,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// The only way a write can fail. Serialize never allocates, so a full buffer is
/// its whole failure surface.
pub const Error = error{
    Jzon_Sink_NoSpaceLeft,
};

/// A cursor positioned at the start of `buf`.
///
/// Usage:
/// ```zig
/// var buf: [64]u8 = undefined;
/// var sink: Sink = .init(&buf);
///
/// try sink.byte('[');
/// try sink.literal("\"ok\"");
/// try sink.byte(']');
///
/// const rendered = sink.filled();
/// ```
///
/// Param:
/// buf - []u8 (the buffer to write into, owned by the caller)
///
/// Return:
/// - Self
pub fn init(buf: []u8) Self {
    return .{
        .buf = buf,
        .pos = 0,
    };
}

/// How many bytes have been written.
///
/// Return:
/// - usize
pub fn written(self: Self) usize {
    return self.pos;
}

/// How many bytes are still free.
///
/// Return:
/// - usize
pub fn remaining(self: Self) usize {
    return self.buf.len - self.pos;
}

/// The region written so far.
///
/// Return:
/// - []const u8 (a view into the caller's buffer)
pub fn filled(self: Self) []const u8 {
    return self.buf[0..self.pos];
}

/// Drop everything written and start over at the front of the buffer.
///
/// Return:
/// - void
pub fn reset(self: *Self) void {
    self.pos = 0;
}

/// Write one byte.
///
/// Param:
/// value - u8 (the byte to write)
///
/// Return:
/// - void
/// - Error.Jzon_Sink_NoSpaceLeft when the buffer is full
pub fn byte(self: *Self, value: u8) Error!void {
    if (self.pos == self.buf.len) return Error.Jzon_Sink_NoSpaceLeft;

    self.buf[self.pos] = value;
    self.pos += 1;
}

/// Write a run of bytes.
///
/// Param:
/// source - []const u8 (the bytes to copy in)
///
/// Return:
/// - void
/// - Error.Jzon_Sink_NoSpaceLeft when the run does not fit whole
pub fn bytes(self: *Self, source: []const u8) Error!void {
    if (source.len > self.remaining()) return Error.Jzon_Sink_NoSpaceLeft;

    @memcpy(self.buf[self.pos..][0..source.len], source);
    self.pos += source.len;
}

/// Write a compile-time known run of bytes.
///
/// Note:
/// - The length is known at the call site, so the bound folds to one compare and
///   the copy to a fixed-size move. A generated emitter uses this for its baked
///   key literals.
///
/// Param:
/// text - []const u8 (comptime, the bytes to copy in)
///
/// Return:
/// - void
/// - Error.Jzon_Sink_NoSpaceLeft when the run does not fit whole
pub fn literal(self: *Self, comptime text: []const u8) Error!void {
    if (text.len > self.remaining()) return Error.Jzon_Sink_NoSpaceLeft;

    self.buf[self.pos..][0..text.len].* = text[0..text.len].*;
    self.pos += text.len;
}

/// Take `len` bytes of room and hand the region back to be filled directly.
///
/// Note:
/// - The position advances on return, so the caller owns filling all of it.
///
/// Param:
/// len - usize (how many bytes to take)
///
/// Return:
/// - []u8 (the reserved region)
/// - Error.Jzon_Sink_NoSpaceLeft when that many bytes are not free
pub fn reserve(self: *Self, len: usize) Error![]u8 {
    if (len > self.remaining()) return Error.Jzon_Sink_NoSpaceLeft;

    const region = self.buf[self.pos..][0..len];
    self.pos += len;

    return region;
}

/// The unwritten tail, for a writer that reports its own length afterwards.
///
/// Note:
/// - Pair every call with `commit`, or the bytes written into the tail are lost.
///
/// Return:
/// - []u8 (the free region, from the position to the end of the buffer)
pub fn tail(self: Self) []u8 {
    return self.buf[self.pos..];
}

/// Accept `len` bytes written into the region `tail` returned.
///
/// Param:
/// len - usize (how many bytes were written into the tail)
///
/// Return:
/// - void
/// - Error.Jzon_Sink_NoSpaceLeft when `len` runs past the buffer
pub fn commit(self: *Self, len: usize) Error!void {
    if (len > self.remaining()) return Error.Jzon_Sink_NoSpaceLeft;

    self.pos += len;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "jzon: Sink, writes land in call order" {
    var buf: [32]u8 = undefined;
    var sink: Self = .init(&buf);

    try sink.byte('{');
    try sink.literal("\"id\":");
    try sink.bytes("42");
    try sink.byte('}');

    try std.testing.expectEqualStrings("{\"id\":42}", sink.filled());
    try std.testing.expectEqual(@as(usize, 9), sink.written());
    try std.testing.expectEqual(@as(usize, 23), sink.remaining());
}

test "jzon: Sink, reserve hands back a region the caller fills" {
    var buf: [8]u8 = undefined;
    var sink: Self = .init(&buf);

    const region = try sink.reserve(3);
    @memcpy(region, "abc");

    try std.testing.expectEqualStrings("abc", sink.filled());
    try std.testing.expectEqual(@as(usize, 5), sink.remaining());
}

test "jzon: Sink, commit takes a foreign writer's length" {
    var buf: [16]u8 = undefined;
    var sink: Self = .init(&buf);

    const printed = try std.fmt.bufPrint(sink.tail(), "{d}", .{12345});
    try sink.commit(printed.len);

    try std.testing.expectEqualStrings("12345", sink.filled());
}

test "jzon: Sink, reset drops what was written" {
    var buf: [8]u8 = undefined;
    var sink: Self = .init(&buf);

    try sink.bytes("hello");
    sink.reset();
    try sink.bytes("hi");

    try std.testing.expectEqualStrings("hi", sink.filled());
}

test "jzon: Sink, refuses a write that does not fit whole" {
    var buf: [4]u8 = undefined;
    var sink: Self = .init(&buf);

    try sink.bytes("ab");
    try std.testing.expectError(Error.Jzon_Sink_NoSpaceLeft, sink.bytes("cde"));

    // The rejected run left nothing behind, so the next write lands where the
    // failed one would have started.
    try std.testing.expectEqualStrings("ab", sink.filled());
    try sink.bytes("cd");
    try std.testing.expectEqualStrings("abcd", sink.filled());
}

test "jzon: Sink, bytes accepts an exact fit" {
    var buf: [5]u8 = undefined;
    var sink: Self = .init(&buf);

    try sink.bytes("hello");

    try std.testing.expectEqualStrings("hello", sink.filled());
    try std.testing.expectEqual(@as(usize, 0), sink.remaining());
}

test "jzon: Sink, literal accepts an exact fit" {
    var buf: [5]u8 = undefined;
    var sink: Self = .init(&buf);

    try sink.literal("hello");

    try std.testing.expectEqualStrings("hello", sink.filled());
    try std.testing.expectEqual(@as(usize, 0), sink.remaining());
}

test "jzon: Sink, one byte past the end is refused" {
    var buf: [4]u8 = undefined;

    var by_bytes: Self = .init(&buf);
    try std.testing.expectError(Error.Jzon_Sink_NoSpaceLeft, by_bytes.bytes("hello"));

    var by_literal: Self = .init(&buf);
    try std.testing.expectError(Error.Jzon_Sink_NoSpaceLeft, by_literal.literal("hello"));

    var by_byte: Self = .init(&buf);
    try by_byte.bytes("abcd");
    try std.testing.expectError(Error.Jzon_Sink_NoSpaceLeft, by_byte.byte('e'));
}

test "jzon: Sink, zero-length buffer takes only an empty run" {
    var buf: [0]u8 = undefined;
    var sink: Self = .init(&buf);

    try sink.bytes("");
    try sink.literal("");

    try std.testing.expectError(Error.Jzon_Sink_NoSpaceLeft, sink.byte('x'));
    try std.testing.expectEqual(@as(usize, 0), sink.written());
    try std.testing.expectEqual(@as(usize, 0), sink.filled().len);
}

test "jzon: Sink, refused write leaves the position untouched" {
    var buf: [8]u8 = undefined;
    var sink: Self = .init(&buf);

    try sink.bytes("abcdef");
    const before = sink.written();

    try std.testing.expectError(Error.Jzon_Sink_NoSpaceLeft, sink.bytes("ghi"));
    try std.testing.expectEqual(before, sink.written());

    try sink.bytes("gh");
    try std.testing.expectEqualStrings("abcdefgh", sink.filled());
}

test "jzon: Sink, reserve of zero takes nothing" {
    var buf: [4]u8 = undefined;
    var sink: Self = .init(&buf);

    const nothing = try sink.reserve(0);

    try std.testing.expectEqual(@as(usize, 0), nothing.len);
    try std.testing.expectEqual(@as(usize, 0), sink.written());
}

test "jzon: Sink, reserve of the whole buffer fits exactly" {
    var buf: [4]u8 = undefined;
    var sink: Self = .init(&buf);

    const whole = try sink.reserve(4);

    try std.testing.expectEqual(@as(usize, 4), whole.len);
    try std.testing.expectEqual(@as(usize, 0), sink.remaining());
}

test "jzon: Sink, reserve past the end is refused" {
    var buf: [4]u8 = undefined;
    var sink: Self = .init(&buf);

    try std.testing.expectError(Error.Jzon_Sink_NoSpaceLeft, sink.reserve(5));
    try std.testing.expectEqual(@as(usize, 0), sink.written());
}

test "jzon: Sink, commit past the end is refused" {
    var buf: [4]u8 = undefined;
    var sink: Self = .init(&buf);

    try sink.byte('a');

    try std.testing.expectError(Error.Jzon_Sink_NoSpaceLeft, sink.commit(4));
    try std.testing.expectEqual(@as(usize, 1), sink.written());

    try sink.commit(3);
    try std.testing.expectEqual(@as(usize, 0), sink.remaining());
}

test "jzon: Sink, tail shrinks as the buffer fills" {
    var buf: [4]u8 = undefined;
    var sink: Self = .init(&buf);

    try std.testing.expectEqual(@as(usize, 4), sink.tail().len);

    try sink.bytes("ab");
    try std.testing.expectEqual(@as(usize, 2), sink.tail().len);

    try sink.bytes("cd");
    try std.testing.expectEqual(@as(usize, 0), sink.tail().len);
}

