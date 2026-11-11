//! ZIX Http2 hpack DynamicTable
//!
//! ### file: src/zix/tcp/http2/hpack/DynamicTable.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The HPACK dynamic table of one connection (RFC 7541 section 2.3.2).
//!
//! ### note:
//!
//! Entry bytes live in the table's own buffer, never in a caller scratch, so an
//! entry stays valid when the per-stream scratch is reused. Entries are stored
//! oldest at the lowest address, which keeps compaction a forward copy.
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
const Header = @import("Header.zig");

// --------------------------------------------------------- //
// Fields:

/// Entries, newest first: entries[0] is HPACK dynamic index 1.
entries: [MAX_ENTRIES]Header = undefined,
/// Number of live entries.
count: usize = 0,
/// HPACK size of the live entries (name + value + 32 each).
size: usize = 0,
/// Backing bytes for every entry name and value.
buf: [BUF_LEN]u8 = undefined,
/// First free byte in buf.
buf_pos: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Fixed per-entry overhead in the HPACK size (RFC 7541 section 4.1).
const ENTRY_OVERHEAD: usize = 32;
const MAX_ENTRIES: usize = 128;
const BUF_LEN: usize = 8192;

/// HPACK size of one entry.
fn entrySize(name: []const u8, value: []const u8) usize {
    return name.len + value.len + ENTRY_OVERHEAD;
}

/// Copy bytes to the end of buf and return the stored slice.
fn store(self: *Self, bytes: []const u8) []const u8 {
    const dst = self.buf[self.buf_pos..][0..bytes.len];
    @memcpy(dst, bytes);
    self.buf_pos += bytes.len;

    return dst;
}

/// Move one stored slice down to new_pos and return the moved slice.
fn moveDown(self: *Self, bytes: []const u8, new_pos: usize) []const u8 {
    const dst = self.buf[new_pos..][0..bytes.len];
    std.mem.copyForwards(u8, dst, bytes);

    return dst;
}

/// Repack the live entries at the start of buf, oldest first.
fn compact(self: *Self) void {
    var new_pos: usize = 0;
    var index: usize = self.count;

    while (index > 0) {
        index -= 1;
        const entry = &self.entries[index];

        entry.name = self.moveDown(entry.name, new_pos);
        new_pos += entry.name.len;
        entry.value = self.moveDown(entry.value, new_pos);
        new_pos += entry.value.len;
    }

    self.buf_pos = new_pos;
}

// --------------------------------------------------------- //
// Public:

/// Look up an entry by HPACK dynamic index.
///
/// Param:
/// index - usize (1 is the newest entry)
///
/// Return:
/// - Header when the index is live
/// - null when the index is 0 or past the last entry
pub fn get(self: *const Self, index: usize) ?Header {
    if (index == 0 or index > self.count) return null;

    return self.entries[index - 1];
}

/// Drop the oldest entries until the table size is at or below target.
///
/// Param:
/// target - usize (size limit in HPACK octets)
///
/// Return:
/// - void
pub fn evictTo(self: *Self, target: usize) void {
    while (self.count > 0 and self.size > target) {
        const oldest = self.entries[self.count - 1];
        self.size -= entrySize(oldest.name, oldest.value);
        self.count -= 1;
    }

    if (self.count == 0) self.buf_pos = 0;
}

/// Insert a new entry as the newest, evicting old ones to stay within max_size.
///
/// Note:
/// - An entry larger than max_size empties the table and is not stored
///   (RFC 7541 section 4.4).
/// - When the entry slots or the byte buffer are full after eviction, the
///   entry is not stored. The decoded header itself is unaffected.
///
/// Param:
/// name - []const u8 (header name, copied)
/// value - []const u8 (header value, copied)
/// max_size - usize (current SETTINGS_HEADER_TABLE_SIZE limit)
///
/// Return:
/// - void
pub fn add(self: *Self, name: []const u8, value: []const u8, max_size: usize) void {
    const size = entrySize(name, value);
    if (size > max_size) {
        self.evictTo(0);

        return;
    }

    self.evictTo(max_size - size);
    if (self.count >= MAX_ENTRIES) return;

    const needed = name.len + value.len;
    if (self.buf_pos + needed > self.buf.len) self.compact();
    if (self.buf_pos + needed > self.buf.len) return;

    const name_copy = self.store(name);
    const value_copy = self.store(value);

    var index: usize = self.count;
    while (index > 0) : (index -= 1) self.entries[index] = self.entries[index - 1];

    self.entries[0] = .{
        .name = name_copy,
        .value = value_copy,
    };
    self.count += 1;
    self.size += size;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 hpack: DynamicTable, add makes the entry index 1" {
    var table: Self = .{};

    table.add("x-custom", "hello", 4096);

    const entry = table.get(1).?;
    try std.testing.expectEqualStrings("x-custom", entry.name);
    try std.testing.expectEqualStrings("hello", entry.value);
}

test "zix http2 hpack: DynamicTable, newest entry comes first" {
    var table: Self = .{};

    table.add("first", "1", 4096);
    table.add("second", "2", 4096);

    try std.testing.expectEqualStrings("second", table.get(1).?.name);
    try std.testing.expectEqualStrings("first", table.get(2).?.name);
}

test "zix http2 hpack: DynamicTable, size counts the 32-byte overhead" {
    var table: Self = .{};

    table.add("ab", "cd", 4096);

    try std.testing.expectEqual(@as(usize, 36), table.size);
}

test "zix http2 hpack: DynamicTable, add copies bytes into its own buffer" {
    var table: Self = .{};
    var name = "x-custom".*;

    table.add(&name, "hello", 4096);
    @memset(&name, 0);

    try std.testing.expectEqualStrings("x-custom", table.get(1).?.name);
}

test "zix http2 hpack: DynamicTable, get out of range is null" {
    var table: Self = .{};
    table.add("a", "b", 4096);

    try std.testing.expect(table.get(0) == null);
    try std.testing.expect(table.get(2) == null);
}

test "zix http2 hpack: DynamicTable, eviction drops the oldest past max_size" {
    var table: Self = .{};

    table.add("a", "1", 68);
    table.add("b", "2", 68);
    table.add("c", "3", 68);

    try std.testing.expectEqual(@as(usize, 2), table.count);
    try std.testing.expectEqualStrings("c", table.get(1).?.name);
    try std.testing.expectEqualStrings("b", table.get(2).?.name);
}

test "zix http2 hpack: DynamicTable, entry larger than max_size empties the table" {
    var table: Self = .{};
    table.add("a", "1", 4096);

    table.add("too-big", "value", 10);

    try std.testing.expectEqual(@as(usize, 0), table.count);
    try std.testing.expectEqual(@as(usize, 0), table.size);
}

test "zix http2 hpack: DynamicTable, evictTo 0 empties the table" {
    var table: Self = .{};
    table.add("a", "1", 4096);
    table.add("b", "2", 4096);

    table.evictTo(0);

    try std.testing.expectEqual(@as(usize, 0), table.count);
    try std.testing.expectEqual(@as(usize, 0), table.buf_pos);
}

test "zix http2 hpack: DynamicTable, compaction keeps surviving entries readable" {
    var table: Self = .{};
    const big: [4000]u8 = @splat('x');

    table.add("x-old", "keep", 16384);
    table.add("x-big", &big, 16384);
    table.add("x-big", &big, 16384);

    // keep only the newest entry, so the next add runs past the buffer end and compacts
    table.evictTo(entrySize("x-big", &big));
    table.add("x-new", &big, 16384);

    try std.testing.expectEqualStrings("x-new", table.get(1).?.name);
    try std.testing.expectEqualStrings("x-big", table.get(2).?.name);
    try std.testing.expectEqualSlices(u8, &big, table.get(2).?.value);
}

test "zix http2 hpack: DynamicTable, full byte buffer skips the entry" {
    var table: Self = .{};
    const big: [BUF_LEN]u8 = @splat('x');

    table.add("n", &big, std.math.maxInt(usize));

    try std.testing.expectEqual(@as(usize, 0), table.count);
}

