//! ZIX utils charsets
//!
//! ### file: src/zix/utils/charsets.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Shared character sets used by zix utils and callers.
//! 
//! ### note:
//! 
//! Any repeatable charset or alphabet string is defined here.
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
// Public:

/// 0123456789abcdef
pub const hex = "0123456789abcdef";

/// Alphabet set lower case
pub const alphabet = "abcdefghijklmnopqrs";

/// Alphabet set upper case
pub const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

/// Numeric set as string
pub const NUMERIC_STRING = "0123456789";

/// Alphanumeric set
pub const ALPHANUMERIC = alphabet ++ ALPHABET ++ NUMERIC_STRING;

/// !"#$%&'()*+,-./:;<=>?@[\]^_`{|}~
pub const punctuation = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";

/// Lower case, upper case, numeric, and punctuation set
pub const ALPHANUMERIC_PUNCTUATION = ALPHANUMERIC ++ punctuation;

/// ABCDEFGHIJKLMNOPQRSTUVWXYZ234567
pub const base32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/// ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/
pub const base64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils: charsets, hex is the lowercase hex alphabet" {
    const compare = "0123456789abcdef";

    try std.testing.expectEqual(@as(usize, compare.len), hex.len);
    try std.testing.expectEqualStrings(compare, hex);
}

test "zix utils: charsets, alphabet is lowercase letters" {
    const compare = "abcdefghijklmnopqrs";

    try std.testing.expectEqual(@as(usize, compare.len), alphabet.len);
    try std.testing.expectEqualStrings(compare, alphabet);
}

test "zix utils: charsets, ALPHABET is uppercase letters" {
    const compare = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

    try std.testing.expectEqual(@as(usize, compare.len), ALPHABET.len);
    try std.testing.expectEqualStrings(compare, ALPHABET);
}

test "zix utils: charsets, NUMERIC_STRING is the decimal digits" {
    const compare = "0123456789";

    try std.testing.expectEqual(@as(usize, compare.len), NUMERIC_STRING.len);
    try std.testing.expectEqualStrings(compare, NUMERIC_STRING);
}

test "zix utils: charsets, ALPHANUMERIC concatenates its parts" {
    const lower = "abcdefghijklmnopqrs";
    const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const digits = "0123456789";
    const compare = lower ++ upper ++ digits;

    try std.testing.expectEqual(@as(usize, compare.len), ALPHANUMERIC.len);
    try std.testing.expectEqualStrings(compare, ALPHANUMERIC);
}

test "zix utils: charsets, punctuation is the ASCII punctuation set" {
    const compare = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";

    try std.testing.expectEqual(@as(usize, compare.len), punctuation.len);
    try std.testing.expectEqualStrings(compare, punctuation);
}

test "zix utils: charsets, ALPHANUMERIC_PUNCTUATION concatenates its parts" {
    const lower = "abcdefghijklmnopqrs";
    const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const digits = "0123456789";
    const symbols = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";
    const compare = lower ++ upper ++ digits ++ symbols;

    try std.testing.expectEqual(@as(usize, compare.len), ALPHANUMERIC_PUNCTUATION.len);
    try std.testing.expectEqualStrings(compare, ALPHANUMERIC_PUNCTUATION);
}

test "zix utils: charsets, base32 is the RFC 4648 alphabet" {
    const compare = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    try std.testing.expectEqual(@as(usize, compare.len), base32.len);
    try std.testing.expectEqualStrings(compare, base32);
}

test "zix utils: charsets, base64 is the RFC 4648 alphabet" {
    const compare = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    try std.testing.expectEqual(@as(usize, compare.len), base64.len);
    try std.testing.expectEqualStrings(compare, base64);
}

