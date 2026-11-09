//! ZIX utils compression brotli dictionary
//!
//! ### file: src/zix/utils/compression/brotli/dictionary.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! The brotli static dictionary (RFC 7932 sec 8, Appendix A): word layout and
//! dictionary reference lookup.
//! 
//! ### note:
//! 
//! The bytes come from the brotli_dictionary.bin import, which build.zig
//! generates with dictionary_gen.zig.
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
const transform = @import("transform.zig");

// --------------------------------------------------------- //
// Private:

/// Bit depth of the word count per length (Appendix A). Lengths below 4 have none.
const NDBITS = [25]u5{
    0,  0,  0,  0,  10, 10, 11, 11, 10, 10, 10, 10, 10,
    9,  9,  8,  7,  7,  8,  7,  7,  6,  6,  5,  5,
};

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_BrotliDictionary_Malformed,
};

/// The embedded static dictionary bytes.
pub const DICT: []const u8 = @embedFile("brotli_dictionary.bin");

/// Shortest dictionary word.
pub const MIN_WORD_LEN: usize = 4;

/// Longest dictionary word.
pub const MAX_WORD_LEN: usize = 24;

/// Byte offset into DICT of the first word of each length (sec 8).
/// DOFFSET[25] is the dictionary size.
pub const DOFFSET = blk: {
    var offsets: [26]u32 = undefined;
    offsets[0] = 0;

    for (0..25) |len| {
        const nwords: u32 = if (len < MIN_WORD_LEN) 0 else (@as(u32, 1) << NDBITS[len]);
        offsets[len + 1] = offsets[len] + @as(u32, @intCast(len)) * nwords;
    }

    break :blk offsets;
};

/// Number of words of a length.
///
/// Param:
/// length - usize (word length)
///
/// Return:
/// - u32 (0 below MIN_WORD_LEN)
pub fn numWords(length: usize) u32 {
    return if (length < MIN_WORD_LEN) 0 else (@as(u32, 1) << NDBITS[length]);
}

/// Resolve a dictionary reference (sec 8) into out.
///
/// Param:
/// length - u32 (copy length, the word length)
/// distance - u32 (distance past max_allowed)
/// max_allowed - u32 (largest backward distance at this point)
/// out - []u8 (destination, at least transform.MAX_OUTPUT_LEN)
///
/// Return:
/// - usize (bytes written)
/// - Error.ZixUtils_BrotliDictionary_Malformed on a bad length or transform
pub fn word(length: u32, distance: u32, max_allowed: u32, out: []u8) Error!usize {
    if (length < MIN_WORD_LEN or length > MAX_WORD_LEN) {
        return Error.ZixUtils_BrotliDictionary_Malformed;
    }

    const word_id = distance - (max_allowed + 1);
    const index = word_id % numWords(length);
    const transform_id = word_id >> NDBITS[length];
    if (transform_id >= transform.TRANSFORM_COUNT) {
        return Error.ZixUtils_BrotliDictionary_Malformed;
    }

    const offset = DOFFSET[length] + index * length;
    const base = DICT[offset .. offset + length];

    return transform.apply(transform_id, base, out);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression brotli: dictionary, size matches the RFC" {
    try std.testing.expectEqual(@as(usize, 122784), DICT.len);
    try std.testing.expectEqual(@as(u32, 122784), DOFFSET[25]);
}

test "zix utils compression brotli: dictionary, numWords is zero below 4" {
    try std.testing.expectEqual(@as(u32, 0), numWords(3));
    try std.testing.expectEqual(@as(u32, 1024), numWords(4));
}

test "zix utils compression brotli: dictionary, word 0 of length 4 is time" {
    var out: [transform.MAX_OUTPUT_LEN]u8 = undefined;
    const written = try word(4, 1, 0, &out);

    try std.testing.expectEqualStrings("time", out[0..written]);
}

test "zix utils compression brotli: dictionary, short length is malformed" {
    var out: [transform.MAX_OUTPUT_LEN]u8 = undefined;

    try std.testing.expectError(Error.ZixUtils_BrotliDictionary_Malformed, word(3, 1, 0, &out));
}

test "zix utils compression brotli: dictionary, long length is malformed" {
    var out: [transform.MAX_OUTPUT_LEN]u8 = undefined;

    try std.testing.expectError(Error.ZixUtils_BrotliDictionary_Malformed, word(25, 1, 0, &out));
}

test "zix utils compression brotli: dictionary, transform past the table is malformed" {
    var out: [transform.MAX_OUTPUT_LEN]u8 = undefined;
    const distance: u32 = (@as(u32, 121) << 10) + 1;

    try std.testing.expectError(
        Error.ZixUtils_BrotliDictionary_Malformed,
        word(4, distance, 0, &out),
    );
}

