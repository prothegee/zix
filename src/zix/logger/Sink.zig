//! ZIX Logger Sink
//!
//! ### file: src/zix/logger/Sink.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Double-buffered byte accumulator for one logger destination.
//!
//! ### note:
//!
//! `pending != 0` means the flush thread owns the inactive buffer and may be
//! inside a write on it. Nothing may swap, rotate, or free while that holds.
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

/// The buffer pair. Empty slices when the destination is disabled.
bufs: [2][]u8 = .{ &.{}, &.{} },
/// Which buffer producers append into.
active: u1 = 0,
/// Bytes already in `bufs[active]`.
fill: usize = 0,
/// Bytes in `bufs[active ^ 1]` waiting to be written. Zero means idle.
pending: usize = 0,
/// How many times a producer had to wait because both buffers were busy.
stalls: u64 = 0,
/// Lines appended since the sink was created.
lines: u64 = 0,
/// Batches written out since the sink was created.
writes: u64 = 0,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// ZIX Logger Sink error
pub const Error = error{
    ZixLogger_Sink_OutOfMemory,
};

/// Allocate the buffer pair.
///
/// Param:
/// each - usize (bytes per buffer, so the pair costs twice this)
///
/// Return:
/// - void
/// - Error.ZixLogger_Sink_OutOfMemory when either allocation fails
pub fn alloc(self: *Self, allocator: std.mem.Allocator, each: usize) Error!void {
    self.bufs[0] = allocator.alloc(u8, each) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixLogger_Sink_OutOfMemory,
    };
    errdefer allocator.free(self.bufs[0]);

    self.bufs[1] = allocator.alloc(u8, each) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixLogger_Sink_OutOfMemory,
    };
}

pub fn free(self: *Self, allocator: std.mem.Allocator) void {
    for (&self.bufs) |*buf| {
        if (buf.len == 0) continue;

        allocator.free(buf.*);
        buf.* = &.{};
    }
}

/// Whether this destination has buffers at all.
pub fn enabled(self: *const Self) bool {
    return self.bufs[0].len > 0;
}

/// Bytes one buffer holds.
pub fn capacity(self: *const Self) usize {
    return self.bufs[0].len;
}

/// Copy one record plus its newline into the active buffer.
///
/// Return:
/// - true when the whole record went in
/// - false when the active buffer has no room for it
pub fn tryAppend(self: *Self, line: []const u8) bool {
    const needed = line.len + 1;
    const buf = self.bufs[self.active];
    if (self.fill + needed > buf.len) return false;

    @memcpy(buf[self.fill..][0..line.len], line);
    self.fill += line.len;
    buf[self.fill] = '\n';
    self.fill += 1;
    self.lines += 1;

    return true;
}

/// Whether a record could ever fit in an empty buffer.
pub fn couldEverFit(self: *const Self, line: []const u8) bool {
    return line.len + 1 <= self.bufs[0].len;
}

/// Hand the active buffer over and start filling the other one.
/// The caller has already checked that `pending == 0`.
pub fn swap(self: *Self) void {
    self.pending = self.fill;
    self.active ^= 1;
    self.fill = 0;
}

/// The bytes the flush thread is to write. Empty when nothing is pending.
pub fn pendingBytes(self: *const Self) []const u8 {
    if (self.pending == 0) return &.{};

    return self.bufs[self.active ^ 1][0..self.pending];
}

/// Nothing buffered and nothing in flight.
pub fn isIdle(self: *const Self) bool {
    return self.fill == 0 and self.pending == 0;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix logger: Sink, disabled sink allocates nothing" {
    var sink = Self{};

    try std.testing.expect(!sink.enabled());
    try std.testing.expectEqual(@as(usize, 0), sink.capacity());
    try std.testing.expect(sink.isIdle());
}

test "zix logger: Sink, tryAppend copies the record and its newline" {
    var sink = Self{};
    try sink.alloc(std.testing.allocator, 64);
    defer sink.free(std.testing.allocator);

    try std.testing.expect(sink.tryAppend("first"));
    try std.testing.expect(sink.tryAppend("second"));

    try std.testing.expectEqualStrings(
        "first\nsecond\n",
        sink.bufs[sink.active][0..sink.fill],
    );
    try std.testing.expectEqual(@as(u64, 2), sink.lines);
}

test "zix logger: Sink, tryAppend refuses a record that does not fit" {
    var sink = Self{};
    try sink.alloc(std.testing.allocator, 16);
    defer sink.free(std.testing.allocator);

    try std.testing.expect(sink.tryAppend("0123456789"));
    const before = sink.fill;

    try std.testing.expect(!sink.tryAppend("0123456789"));
    try std.testing.expectEqual(before, sink.fill);
    try std.testing.expectEqualStrings(
        "0123456789\n",
        sink.bufs[sink.active][0..sink.fill],
    );
}

test "zix logger: Sink, couldEverFit separates full from impossible" {
    var sink = Self{};
    try sink.alloc(std.testing.allocator, 16);
    defer sink.free(std.testing.allocator);

    try std.testing.expect(sink.couldEverFit("012345678901234"));
    try std.testing.expect(!sink.couldEverFit("0123456789012345"));
}

test "zix logger: Sink, swap hands over the filled buffer" {
    var sink = Self{};
    try sink.alloc(std.testing.allocator, 64);
    defer sink.free(std.testing.allocator);

    try std.testing.expect(sink.tryAppend("handed over"));
    const was_active = sink.active;

    sink.swap();

    try std.testing.expectEqual(was_active ^ 1, sink.active);
    try std.testing.expectEqual(@as(usize, 0), sink.fill);
    try std.testing.expectEqualStrings("handed over\n", sink.pendingBytes());
    try std.testing.expect(!sink.isIdle());
}

test "zix logger: Sink, buffers stay independent after a swap" {
    var sink = Self{};
    try sink.alloc(std.testing.allocator, 64);
    defer sink.free(std.testing.allocator);

    try std.testing.expect(sink.tryAppend("pending line"));
    sink.swap();

    try std.testing.expect(sink.tryAppend("live line"));
    try std.testing.expectEqualStrings("pending line\n", sink.pendingBytes());
    try std.testing.expectEqualStrings(
        "live line\n",
        sink.bufs[sink.active][0..sink.fill],
    );
}

test "zix logger: Sink, pendingBytes empties when the write is done" {
    var sink = Self{};
    try sink.alloc(std.testing.allocator, 32);
    defer sink.free(std.testing.allocator);

    try std.testing.expect(sink.tryAppend("done"));
    sink.swap();
    sink.pending = 0;

    try std.testing.expectEqual(@as(usize, 0), sink.pendingBytes().len);
    try std.testing.expect(sink.isIdle());
}

