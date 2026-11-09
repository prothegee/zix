//! ZIX utils compression brotli DictIndex
//!
//! ### file: src/zix/utils/compression/brotli/DictIndex.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Hash index over the identity static dictionary words, chained by their first
//! four bytes, for the encoder dictionary search.
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
const dictionary = @import("dictionary.zig");

// --------------------------------------------------------- //
// Fields:

/// First entry per hash bucket, NO_ENTRY when empty.
head: []u32,
/// Next entry in the same bucket.
next: []u32,
/// Word length per entry.
word_len: []u8,
/// Word index inside its length group per entry.
word_index: []u32,
/// Byte offset into the dictionary per entry.
word_off: []u32,

const Self = @This();

// --------------------------------------------------------- //
// Private:

const HASH_BITS = 15;
const HASH_SIZE: usize = 1 << HASH_BITS;
const MAX_CHAIN: usize = 64;

fn allocError(err: std.mem.Allocator.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.OutOfMemory => Error.ZixUtils_BrotliDictIndex_OutOfMemory,
    };
}

fn hashWord(bytes: []const u8, pos: usize) usize {
    const word = std.mem.readInt(u32, bytes[pos..][0..4], .little);

    return (word *% 0x9E3779B1) >> (32 - HASH_BITS);
}

fn totalWords() usize {
    var total: usize = 0;
    for (dictionary.MIN_WORD_LEN..dictionary.MAX_WORD_LEN + 1) |len| {
        total += dictionary.numWords(len);
    }

    return total;
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_BrotliDictIndex_OutOfMemory,
};

/// Empty bucket or end of chain.
pub const NO_ENTRY: u32 = std.math.maxInt(u32);

/// Build the index.
///
/// Note:
/// - Meant for an arena. The slices are not freed one by one on error.
///
/// Param:
/// allocator - std.mem.Allocator (owns every slice, use an arena)
///
/// Return:
/// - Self
/// - Error.ZixUtils_BrotliDictIndex_OutOfMemory
pub fn build(allocator: std.mem.Allocator) Error!Self {
    const total = totalWords();

    const self: Self = .{
        .head = allocator.alloc(u32, HASH_SIZE) catch |err| return allocError(err),
        .next = allocator.alloc(u32, total) catch |err| return allocError(err),
        .word_len = allocator.alloc(u8, total) catch |err| return allocError(err),
        .word_index = allocator.alloc(u32, total) catch |err| return allocError(err),
        .word_off = allocator.alloc(u32, total) catch |err| return allocError(err),
    };
    @memset(self.head, NO_ENTRY);

    var entry: u32 = 0;
    for (dictionary.MIN_WORD_LEN..dictionary.MAX_WORD_LEN + 1) |len| {
        const words = dictionary.numWords(len);

        var index: u32 = 0;
        while (index < words) : (index += 1) {
            const offset = dictionary.DOFFSET[len] + index * @as(u32, @intCast(len));
            const bucket = hashWord(dictionary.DICT, offset);

            self.word_len[entry] = @intCast(len);
            self.word_index[entry] = index;
            self.word_off[entry] = offset;
            self.next[entry] = self.head[bucket];
            self.head[bucket] = entry;
            entry += 1;
        }
    }

    return self;
}

/// The longest identity dictionary word equal to the input at pos.
///
/// Param:
/// input - []const u8 (encoder input)
/// pos - usize (position to match)
/// best_index - *u32 (word index of the match, written when found)
///
/// Return:
/// - usize (match length, 0 when none)
pub fn longestMatch(self: Self, input: []const u8, pos: usize, best_index: *u32) usize {
    if (pos + 4 > input.len) return 0;

    var entry = self.head[hashWord(input, pos)];
    var best_len: usize = 0;
    var chain: usize = 0;
    while (entry != NO_ENTRY and chain < MAX_CHAIN) : (chain += 1) {
        const len: usize = self.word_len[entry];

        if (len > best_len and pos + len <= input.len) {
            const offset = self.word_off[entry];
            const word = dictionary.DICT[offset .. offset + len];

            if (std.mem.eql(u8, word, input[pos .. pos + len])) {
                best_len = len;
                best_index.* = self.word_index[entry];
            }
        }

        entry = self.next[entry];
    }

    return best_len;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression brotli: DictIndex, finds the first dictionary word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const index = try build(arena.allocator());

    var word_index: u32 = undefined;
    const len = index.longestMatch("time", 0, &word_index);

    try std.testing.expectEqual(@as(usize, 4), len);
    try std.testing.expectEqual(@as(u32, 0), word_index);
}

test "zix utils compression brotli: DictIndex, short tail has no match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const index = try build(arena.allocator());

    var word_index: u32 = undefined;

    try std.testing.expectEqual(@as(usize, 0), index.longestMatch("tim", 0, &word_index));
}

test "zix utils compression brotli: DictIndex, non-word has no match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const index = try build(arena.allocator());

    var word_index: u32 = undefined;

    try std.testing.expectEqual(@as(usize, 0), index.longestMatch("\x00\x01\x02\x03", 0, &word_index));
}

test "zix utils compression brotli: DictIndex, failing allocator is out of memory" {
    try std.testing.expectError(
        Error.ZixUtils_BrotliDictIndex_OutOfMemory,
        build(std.testing.failing_allocator),
    );
}

