//! ZIX utils generator
//!
//! ### file: src/zix/utils/generator.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Random string and number generation on the worker io source.
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

const charsets = @import("charsets.zig");

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_Generator_StringLengthIsZero,
    ZixUtils_Generator_CharsetIsEmpty,
    ZixUtils_Generator_OutOfMemory,
};

/// Generate a random string from a charset.
///
/// Param:
/// length - usize (length of the generated string)
/// charset - []const u8 (set of characters to draw from)
/// io - std.Io (source of randomness)
/// allocator - std.mem.Allocator (owns the returned string, caller frees)
///
/// Return:
/// - []u8 (caller-owned random string)
/// - Error.ZixUtils_Generator_StringLengthIsZero when length is zero
/// - Error.ZixUtils_Generator_CharsetIsEmpty when charset is empty
/// - Error.ZixUtils_Generator_OutOfMemory when allocation fails
pub fn strings(
    length: usize,
    charset: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
) Error![]u8 {
    if (length == 0) return Error.ZixUtils_Generator_StringLengthIsZero;
    if (charset.len == 0) return Error.ZixUtils_Generator_CharsetIsEmpty;

    const random: std.Random.IoSource = .{ .io = io };
    const random_secure = random.interface();

    const result = allocator.alloc(u8, length) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixUtils_Generator_OutOfMemory,
    };

    for (result) |*char| {
        const index = random_secure.intRangeAtMost(usize, 0, charset.len - 1);
        char.* = charset[index];
    }

    return result;
}

/// Generate a random number in an inclusive range.
///
/// Param:
/// min - T (smallest value returned)
/// max - T (largest value returned, must be at least min)
/// io - std.Io (source of randomness)
///
/// Return:
/// - T (a value between min and max, both inclusive)
pub fn numbers(
    comptime T: type,
    min: T,
    max: T,
    io: std.Io,
) T {
    const random: std.Random.IoSource = .{ .io = io };
    const random_secure = random.interface();

    return random_secure.intRangeAtMost(T, min, max);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const StrAndLen = struct {
    str: []const u8,
    len: usize,
};

test "zix utils: generator, builds a string from each charset" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const sets = [_]StrAndLen{
        .{
            .str = charsets.alphabet,
            .len = 8,
        },
        .{
            .str = charsets.ALPHABET,
            .len = 16,
        },
        .{
            .str = charsets.NUMERIC_STRING,
            .len = 32,
        },
        .{
            .str = charsets.ALPHANUMERIC,
            .len = 64,
        },
        .{
            .str = charsets.punctuation,
            .len = 128,
        },
        .{
            .str = charsets.ALPHANUMERIC_PUNCTUATION,
            .len = 256,
        },
    };

    for (sets) |set| {
        const result = try strings(set.len, set.str, io, allocator);
        defer allocator.free(result);

        try std.testing.expectEqual(@as(usize, set.len), result.len);

        for (result) |char| {
            try std.testing.expect(std.mem.indexOfScalar(u8, set.str, char) != null);
        }
    }
}

test "zix utils: generator, rejects a zero length" {
    const io = std.testing.io;

    try std.testing.expectError(
        Error.ZixUtils_Generator_StringLengthIsZero,
        strings(0, charsets.alphabet, io, std.testing.allocator),
    );
}

test "zix utils: generator, rejects an empty charset" {
    const io = std.testing.io;

    try std.testing.expectError(
        Error.ZixUtils_Generator_CharsetIsEmpty,
        strings(8, "", io, std.testing.allocator),
    );
}

test "zix utils: generator, draws a number inside the range" {
    const io = std.testing.io;

    const case1 = numbers(u8, 1, 10, io);
    const case2 = numbers(u16, 10, 100, io);
    const case3 = numbers(u32, 100, 1000, io);
    const case4 = numbers(u64, 1000, 10000, io);
    const case5 = numbers(u128, 10000, 100000, io);

    try std.testing.expect(case1 >= 1 and case1 <= 10);
    try std.testing.expect(case2 >= 10 and case2 <= 100);
    try std.testing.expect(case3 >= 100 and case3 <= 1000);
    try std.testing.expect(case4 >= 1000 and case4 <= 10000);
    try std.testing.expect(case5 >= 10000 and case5 <= 100000);

    for (0..1_000) |i| {
        const value = numbers(usize, 1, i + 1, io);

        try std.testing.expect(value >= 1 and value <= i + 1);
    }
}

test "zix utils: generator, draws the only value in a one value range" {
    const io = std.testing.io;

    try std.testing.expectEqual(@as(u8, 7), numbers(u8, 7, 7, io));
    try std.testing.expectEqual(@as(i64, -3), numbers(i64, -3, -3, io));
}

