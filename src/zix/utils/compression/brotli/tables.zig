//! ZIX utils compression brotli tables
//!
//! ### file: src/zix/utils/compression/brotli/tables.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Shared RFC 7932 code tables: alphabet sizes, insert and copy length codes,
//! block count codes, and the insert-and-copy cell map (sec 5, 6).
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

/// Per cell (cmd >> 6): base insert code (sec 5).
const CELL_INSERT_BASE = [_]u8{ 0, 0, 0, 0, 8, 8, 0, 16, 8, 16, 16 };

/// Per cell (cmd >> 6): base copy code (sec 5).
const CELL_COPY_BASE = [_]u8{ 0, 8, 0, 8, 0, 8, 16, 0, 16, 8, 16 };

/// Cell per (insert band, copy band), each band 0..2 for codes 0..7, 8..15, 16..23.
/// Every cell here carries an explicit distance (cmd >= 128).
const CELL_BY_BAND = [3][3]u16{
    .{ 2, 3, 6 },
    .{ 4, 5, 8 },
    .{ 7, 9, 10 },
};

// --------------------------------------------------------- //
// Public:

/// MLEN caps at 2^24 (sec 9.2), so one meta-block carries at most 16 MiB.
pub const MAX_META_BLOCK_LEN: usize = 1 << 24;

/// Longest prefix code length (sec 3.2).
pub const MAX_CODE_LEN = 15;

/// Largest prefix alphabet slot count (insert-and-copy is 704).
pub const MAX_SYMBOLS = 1024;

/// Insert-and-copy length alphabet size.
pub const COMMAND_ALPHABET: usize = 704;

/// Distance alphabet size with NPOSTFIX=0 and NDIRECT=0: 16 + 0 + (48 << 0).
pub const DISTANCE_ALPHABET: usize = 64;

/// Literal alphabet size.
pub const LITERAL_ALPHABET: usize = 256;

/// Extra bits per insert length code (sec 5).
pub const INSERT_LEN_EXTRA = [_]u6{
    0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3,
    4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24,
};

/// Base value per insert length code (sec 5).
pub const INSERT_LEN_BASE = [_]u32{
    0,   1,   2,   3,   4,   5,    6,    8,    10,   14,   18,    26,
    34,  50,  66,  98,  130, 194,  322,  578,  1090, 2114, 6210,  22594,
};

/// Extra bits per copy length code (sec 5).
pub const COPY_LEN_EXTRA = [_]u6{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2,
    3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24,
};

/// Base value per copy length code (sec 5).
pub const COPY_LEN_BASE = [_]u32{
    2,   3,   4,   5,   6,   7,    8,    9,    10,   12,   14,   18,
    22,  30,  38,  54,  70,  102,  134,  198,  326,  582,  1094, 2118,
};

/// Base value per block count code (sec 6).
pub const BLOCK_COUNT_BASE = [_]u32{
    1,    5,    9,    13,   17,   25,   33,    41,    49,
    65,   81,   97,   113,  145,  177,  209,   241,   305,
    369,  497,  753,  1265, 2289, 4337, 8433,  16625,
};

/// Extra bits per block count code (sec 6).
pub const BLOCK_COUNT_EXTRA = [_]u6{
    2, 2, 2, 2, 3, 3, 3, 3, 4,
    4, 4, 4, 5, 5, 5, 5, 6, 6,
    7, 8, 9, 10, 11, 12, 13, 24,
};

/// One insert-and-copy command split into its parts (sec 5).
pub const InsertCopy = struct {
    insert_code: u8,
    copy_code: u8,
    /// True for cells 0 and 1 (cmd < 128): reuse the last distance.
    distance_zero: bool,
};

/// Smallest bit width that addresses every symbol of the alphabet (sec 3.4).
///
/// Param:
/// alphabet_size - usize (symbol count)
///
/// Return:
/// - u6
pub fn alphabetBits(alphabet_size: usize) u6 {
    if (alphabet_size <= 1) return 0;

    return @intCast(32 - @clz(@as(u32, @intCast(alphabet_size - 1))));
}

/// Split an insert-and-copy code into its insert and copy codes (sec 5).
///
/// Param:
/// cmd - u16 (insert-and-copy symbol, 0..703)
///
/// Return:
/// - InsertCopy
pub fn splitInsertCopy(cmd: u16) InsertCopy {
    const cell = cmd >> 6;

    return .{
        .insert_code = CELL_INSERT_BASE[cell] + @as(u8, @intCast((cmd >> 3) & 7)),
        .copy_code = CELL_COPY_BASE[cell] + @as(u8, @intCast(cmd & 7)),
        .distance_zero = cmd < 128,
    };
}

/// Compose an insert-and-copy symbol that carries an explicit distance (sec 5).
///
/// Param:
/// insert_code - u8 (0..23)
/// copy_code - u8 (0..23)
///
/// Return:
/// - u16
pub fn composeCommandExplicit(insert_code: u8, copy_code: u8) u16 {
    const cell = CELL_BY_BAND[insert_code / 8][copy_code / 8];

    return cell * 64 + (@as(u16, insert_code % 8) << 3) + (copy_code % 8);
}

/// Largest insert length code whose base is <= value (sec 5).
///
/// Param:
/// value - u32 (insert length)
///
/// Return:
/// - u8
pub fn selectInsertCode(value: u32) u8 {
    var code: u8 = @intCast(INSERT_LEN_BASE.len - 1);
    while (INSERT_LEN_BASE[code] > value) code -= 1;

    return code;
}

/// Largest copy length code whose base is <= value (sec 5).
///
/// Param:
/// value - u32 (copy length, at least 2)
///
/// Return:
/// - u8
pub fn selectCopyCode(value: u32) u8 {
    var code: u8 = @intCast(COPY_LEN_BASE.len - 1);
    while (COPY_LEN_BASE[code] > value) code -= 1;

    return code;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression brotli: tables, alphabetBits covers the alphabet" {
    try std.testing.expectEqual(@as(u6, 0), alphabetBits(1));
    try std.testing.expectEqual(@as(u6, 1), alphabetBits(2));
    try std.testing.expectEqual(@as(u6, 8), alphabetBits(256));
    try std.testing.expectEqual(@as(u6, 10), alphabetBits(COMMAND_ALPHABET));
}

test "zix utils compression brotli: tables, splitInsertCopy marks implicit distance" {
    try std.testing.expect(splitInsertCopy(0).distance_zero);
    try std.testing.expect(!splitInsertCopy(128).distance_zero);
}

test "zix utils compression brotli: tables, composeCommandExplicit round-trips split" {
    for (0..24) |insert_code| {
        for (0..24) |copy_code| {
            const cmd = composeCommandExplicit(@intCast(insert_code), @intCast(copy_code));
            const parts = splitInsertCopy(cmd);

            try std.testing.expectEqual(@as(u8, @intCast(insert_code)), parts.insert_code);
            try std.testing.expectEqual(@as(u8, @intCast(copy_code)), parts.copy_code);
            try std.testing.expect(!parts.distance_zero);
        }
    }
}

test "zix utils compression brotli: tables, selectInsertCode picks the last base" {
    try std.testing.expectEqual(@as(u8, 0), selectInsertCode(0));
    try std.testing.expectEqual(@as(u8, 7), selectInsertCode(9));
    try std.testing.expectEqual(@as(u8, 23), selectInsertCode(1 << 24));
}

test "zix utils compression brotli: tables, selectCopyCode picks the last base" {
    try std.testing.expectEqual(@as(u8, 0), selectCopyCode(2));
    try std.testing.expectEqual(@as(u8, 9), selectCopyCode(13));
    try std.testing.expectEqual(@as(u8, 23), selectCopyCode(16384));
}

test "zix utils compression brotli: tables, code tables have 24 entries" {
    try std.testing.expectEqual(@as(usize, 24), INSERT_LEN_BASE.len);
    try std.testing.expectEqual(@as(usize, 24), INSERT_LEN_EXTRA.len);
    try std.testing.expectEqual(@as(usize, 24), COPY_LEN_BASE.len);
    try std.testing.expectEqual(@as(usize, 24), COPY_LEN_EXTRA.len);
}

test "zix utils compression brotli: tables, block count tables have 26 entries" {
    try std.testing.expectEqual(@as(usize, 26), BLOCK_COUNT_BASE.len);
    try std.testing.expectEqual(@as(usize, 26), BLOCK_COUNT_EXTRA.len);
}

