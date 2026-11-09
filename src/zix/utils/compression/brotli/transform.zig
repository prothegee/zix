//! ZIX utils compression brotli transform
//!
//! ### file: src/zix/utils/compression/brotli/transform.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! The 121 static dictionary word transforms (RFC 7932 sec 8, Appendix B).
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
// Private:

// Elementary transform ids, matching the RFC serialization byte values.
const IDENTITY = 0;
const FERMENT_FIRST = 1;
const FERMENT_ALL = 2;
const OMIT_FIRST_1 = 3;
const OMIT_FIRST_2 = 4;
const OMIT_FIRST_3 = 5;
const OMIT_FIRST_4 = 6;
const OMIT_FIRST_5 = 7;
const OMIT_FIRST_6 = 8;
const OMIT_FIRST_7 = 9;
const OMIT_FIRST_9 = 11;
const OMIT_LAST_1 = 12;
const OMIT_LAST_2 = 13;
const OMIT_LAST_3 = 14;
const OMIT_LAST_4 = 15;
const OMIT_LAST_5 = 16;
const OMIT_LAST_6 = 17;
const OMIT_LAST_7 = 18;
const OMIT_LAST_8 = 19;
const OMIT_LAST_9 = 20;

/// One transform: prefix + op(word) + suffix.
const Transform = struct {
    prefix: []const u8,
    op: u8,
    suffix: []const u8,
};

fn entry(prefix: []const u8, op: u8, suffix: []const u8) Transform {
    return .{
        .prefix = prefix,
        .op = op,
        .suffix = suffix,
    };
}

/// The transform list in RFC order (Appendix B).
const TRANSFORMS = [_]Transform{
    entry("", IDENTITY, ""),
    entry("", IDENTITY, " "),
    entry(" ", IDENTITY, " "),
    entry("", OMIT_FIRST_1, ""),
    entry("", FERMENT_FIRST, " "),
    entry("", IDENTITY, " the "),
    entry(" ", IDENTITY, ""),
    entry("s ", IDENTITY, " "),
    entry("", IDENTITY, " of "),
    entry("", FERMENT_FIRST, ""),
    entry("", IDENTITY, " and "),
    entry("", OMIT_FIRST_2, ""),
    entry("", OMIT_LAST_1, ""),
    entry(", ", IDENTITY, " "),
    entry("", IDENTITY, ", "),
    entry(" ", FERMENT_FIRST, " "),
    entry("", IDENTITY, " in "),
    entry("", IDENTITY, " to "),
    entry("e ", IDENTITY, " "),
    entry("", IDENTITY, "\""),
    entry("", IDENTITY, "."),
    entry("", IDENTITY, "\">"),
    entry("", IDENTITY, "\n"),
    entry("", OMIT_LAST_3, ""),
    entry("", IDENTITY, "]"),
    entry("", IDENTITY, " for "),
    entry("", OMIT_FIRST_3, ""),
    entry("", OMIT_LAST_2, ""),
    entry("", IDENTITY, " a "),
    entry("", IDENTITY, " that "),
    entry(" ", FERMENT_FIRST, ""),
    entry("", IDENTITY, ". "),
    entry(".", IDENTITY, ""),
    entry(" ", IDENTITY, ", "),
    entry("", OMIT_FIRST_4, ""),
    entry("", IDENTITY, " with "),
    entry("", IDENTITY, "'"),
    entry("", IDENTITY, " from "),
    entry("", IDENTITY, " by "),
    entry("", OMIT_FIRST_5, ""),
    entry("", OMIT_FIRST_6, ""),
    entry(" the ", IDENTITY, ""),
    entry("", OMIT_LAST_4, ""),
    entry("", IDENTITY, ". The "),
    entry("", FERMENT_ALL, ""),
    entry("", IDENTITY, " on "),
    entry("", IDENTITY, " as "),
    entry("", IDENTITY, " is "),
    entry("", OMIT_LAST_7, ""),
    entry("", OMIT_LAST_1, "ing "),
    entry("", IDENTITY, "\n\t"),
    entry("", IDENTITY, ":"),
    entry(" ", IDENTITY, ". "),
    entry("", IDENTITY, "ed "),
    entry("", OMIT_FIRST_9, ""),
    entry("", OMIT_FIRST_7, ""),
    entry("", OMIT_LAST_6, ""),
    entry("", IDENTITY, "("),
    entry("", FERMENT_FIRST, ", "),
    entry("", OMIT_LAST_8, ""),
    entry("", IDENTITY, " at "),
    entry("", IDENTITY, "ly "),
    entry(" the ", IDENTITY, " of "),
    entry("", OMIT_LAST_5, ""),
    entry("", OMIT_LAST_9, ""),
    entry(" ", FERMENT_FIRST, ", "),
    entry("", FERMENT_FIRST, "\""),
    entry(".", IDENTITY, "("),
    entry("", FERMENT_ALL, " "),
    entry("", FERMENT_FIRST, "\">"),
    entry("", IDENTITY, "=\""),
    entry(" ", IDENTITY, "."),
    entry(".com/", IDENTITY, ""),
    entry(" the ", IDENTITY, " of the "),
    entry("", FERMENT_FIRST, "'"),
    entry("", IDENTITY, ". This "),
    entry("", IDENTITY, ","),
    entry(".", IDENTITY, " "),
    entry("", FERMENT_FIRST, "("),
    entry("", FERMENT_FIRST, "."),
    entry("", IDENTITY, " not "),
    entry(" ", IDENTITY, "=\""),
    entry("", IDENTITY, "er "),
    entry(" ", FERMENT_ALL, " "),
    entry("", IDENTITY, "al "),
    entry(" ", FERMENT_ALL, ""),
    entry("", IDENTITY, "='"),
    entry("", FERMENT_ALL, "\""),
    entry("", FERMENT_FIRST, ". "),
    entry(" ", IDENTITY, "("),
    entry("", IDENTITY, "ful "),
    entry(" ", FERMENT_FIRST, ". "),
    entry("", IDENTITY, "ive "),
    entry("", IDENTITY, "less "),
    entry("", FERMENT_ALL, "'"),
    entry("", IDENTITY, "est "),
    entry(" ", FERMENT_FIRST, "."),
    entry("", FERMENT_ALL, "\">"),
    entry(" ", IDENTITY, "='"),
    entry("", FERMENT_FIRST, ","),
    entry("", IDENTITY, "ize "),
    entry("", FERMENT_ALL, "."),
    entry("\xc2\xa0", IDENTITY, ""),
    entry(" ", IDENTITY, ","),
    entry("", FERMENT_FIRST, "=\""),
    entry("", FERMENT_ALL, "=\""),
    entry("", IDENTITY, "ous "),
    entry("", FERMENT_ALL, ", "),
    entry("", FERMENT_FIRST, "='"),
    entry(" ", FERMENT_FIRST, ","),
    entry(" ", FERMENT_ALL, "=\""),
    entry(" ", FERMENT_ALL, ", "),
    entry("", FERMENT_ALL, ","),
    entry("", FERMENT_ALL, "("),
    entry("", FERMENT_ALL, ". "),
    entry(" ", FERMENT_ALL, "."),
    entry("", FERMENT_ALL, "='"),
    entry(" ", FERMENT_ALL, ". "),
    entry(" ", FERMENT_FIRST, "=\""),
    entry(" ", FERMENT_ALL, "='"),
    entry(" ", FERMENT_FIRST, "='"),
};

/// Ferment one position: upper-case ASCII, or flip a bit in the next byte of a 2-
/// or 3-byte UTF-8 sequence.
///
/// Param:
/// word - []u8 (word being transformed)
/// pos - usize (position to ferment)
///
/// Return:
/// - usize (bytes consumed)
fn ferment(word: []u8, pos: usize) usize {
    if (word[pos] < 192) {
        if (word[pos] >= 97 and word[pos] <= 122) word[pos] ^= 32;

        return 1;
    }

    if (word[pos] < 224) {
        if (pos + 1 < word.len) word[pos + 1] ^= 32;

        return 2;
    }

    if (pos + 2 < word.len) word[pos + 2] ^= 5;

    return 3;
}

fn fermentFirst(word: []u8) void {
    if (word.len > 0) _ = ferment(word, 0);
}

fn fermentAll(word: []u8) void {
    var pos: usize = 0;
    while (pos < word.len) pos += ferment(word, pos);
}

// --------------------------------------------------------- //
// Public:

/// Number of transforms (sec 8).
pub const TRANSFORM_COUNT: usize = TRANSFORMS.len;

/// Longest output of one transform: prefix, a 24-byte word, and suffix.
pub const MAX_OUTPUT_LEN: usize = 38;

/// Apply transform transform_id to a base word, writing prefix + T(word) + suffix.
///
/// Param:
/// transform_id - usize (0..TRANSFORM_COUNT - 1)
/// base - []const u8 (dictionary word, at most 24 bytes)
/// out - []u8 (destination, at least MAX_OUTPUT_LEN)
///
/// Return:
/// - usize (bytes written)
pub fn apply(transform_id: usize, base: []const u8, out: []u8) usize {
    const transform = TRANSFORMS[transform_id];

    var n: usize = 0;
    @memcpy(out[n..][0..transform.prefix.len], transform.prefix);
    n += transform.prefix.len;

    var word: [MAX_OUTPUT_LEN]u8 = undefined;
    @memcpy(word[0..base.len], base);

    var mid_start: usize = 0;
    var mid_len: usize = base.len;
    if (transform.op == FERMENT_FIRST) {
        fermentFirst(word[0..mid_len]);
    } else if (transform.op == FERMENT_ALL) {
        fermentAll(word[0..mid_len]);
    } else if (transform.op >= OMIT_FIRST_1 and transform.op <= OMIT_FIRST_9) {
        const omit = transform.op - OMIT_FIRST_1 + 1;
        if (omit >= mid_len) {
            mid_len = 0;
        } else {
            mid_start = omit;
            mid_len -= omit;
        }
    } else if (transform.op >= OMIT_LAST_1 and transform.op <= OMIT_LAST_9) {
        const omit = transform.op - OMIT_LAST_1 + 1;
        mid_len = if (omit >= mid_len) 0 else mid_len - omit;
    }

    @memcpy(out[n..][0..mid_len], word[mid_start .. mid_start + mid_len]);
    n += mid_len;

    @memcpy(out[n..][0..transform.suffix.len], transform.suffix);
    n += transform.suffix.len;

    return n;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn applyText(transform_id: usize, base: []const u8, out: []u8) []const u8 {
    return out[0..apply(transform_id, base, out)];
}

test "zix utils compression brotli: transform, has 121 entries" {
    try std.testing.expectEqual(@as(usize, 121), TRANSFORM_COUNT);
}

test "zix utils compression brotli: transform, identity copies the word" {
    var out: [MAX_OUTPUT_LEN]u8 = undefined;

    try std.testing.expectEqualStrings("time", applyText(0, "time", &out));
}

test "zix utils compression brotli: transform, adds prefix and suffix" {
    var out: [MAX_OUTPUT_LEN]u8 = undefined;

    try std.testing.expectEqualStrings(" time ", applyText(2, "time", &out));
}

test "zix utils compression brotli: transform, ferment first upper-cases one letter" {
    var out: [MAX_OUTPUT_LEN]u8 = undefined;

    try std.testing.expectEqualStrings("Time", applyText(9, "time", &out));
}

test "zix utils compression brotli: transform, ferment all upper-cases every letter" {
    var out: [MAX_OUTPUT_LEN]u8 = undefined;

    try std.testing.expectEqualStrings("TIME", applyText(44, "time", &out));
}

test "zix utils compression brotli: transform, omit first drops leading bytes" {
    var out: [MAX_OUTPUT_LEN]u8 = undefined;

    try std.testing.expectEqualStrings("ime", applyText(3, "time", &out));
}

test "zix utils compression brotli: transform, omit last drops trailing bytes" {
    var out: [MAX_OUTPUT_LEN]u8 = undefined;

    try std.testing.expectEqualStrings("tim", applyText(12, "time", &out));
}

test "zix utils compression brotli: transform, omit past the word leaves only affixes" {
    var out: [MAX_OUTPUT_LEN]u8 = undefined;

    // Transform 54 is OmitFirst9 with no prefix or suffix.
    try std.testing.expectEqualStrings("", applyText(54, "time", &out));
}

test "zix utils compression brotli: transform, ferment flips a 2-byte UTF-8 tail" {
    var word = [_]u8{ 0xc3, 0xa9 };
    const consumed = ferment(&word, 0);

    try std.testing.expectEqual(@as(usize, 2), consumed);
    try std.testing.expectEqual(@as(u8, 0x89), word[1]);
}

test "zix utils compression brotli: transform, ferment flips a 3-byte UTF-8 tail" {
    var word = [_]u8{ 0xe0, 0xa4, 0x80 };
    const consumed = ferment(&word, 0);

    try std.testing.expectEqual(@as(usize, 3), consumed);
    try std.testing.expectEqual(@as(u8, 0x85), word[2]);
}

