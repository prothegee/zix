//! Zix charsets for utility and their of truth.
//!
//! Note:
//! - Any repeatable charsets or strings will use from here.

const std = @import("std");

// --------------------------------------------------------- //

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

/// abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~
pub const ALPHANUMERIC_PUNCTUATION = ALPHANUMERIC ++ punctuation;

// --------------------------------------------------------- //
// --------------------------------------------------------- //

// alphabet: check correctness and correct length
test "zix charsets: alphabet check" {
    const compare = "abcdefghijklmnopqrs";

    try std.testing.expectEqual(@as(usize, compare.len), alphabet.len);
    try std.testing.expectEqualStrings(compare, alphabet);
}

// ALPHABET: check correctness and correct length
test "zix charsets: ALPHABET check" {
    const compare = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

    try std.testing.expectEqual(@as(usize, compare.len), ALPHABET.len);
    try std.testing.expectEqualStrings(compare, ALPHABET);
}

// NUMERIC_STRING: check correctness and correct length
test "zix charsets: NUMERIC_STRING check" {
    const compare = "0123456789";

    try std.testing.expectEqual(@as(usize, compare.len), NUMERIC_STRING.len);
    try std.testing.expectEqualStrings(compare, NUMERIC_STRING);
}

// ALPHANUMERIC: check correctness and correct length
test "zix charsets: ALPHANUMERIC check" {
    const set1 = "abcdefghijklmnopqrs";
    const set2 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const set3 = "0123456789";
    const compare = set1 ++ set2 ++ set3;

    try std.testing.expectEqual(@as(usize, compare.len), ALPHANUMERIC.len);
    try std.testing.expectEqualStrings(compare, ALPHANUMERIC);
}

// punctuation: check correctness and correct length
test "zix charsets: punctuation check" {
    const compare = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";

    try std.testing.expectEqual(@as(usize, compare.len), punctuation.len);
    try std.testing.expectEqualStrings(compare, punctuation);
}

// ALPHANUMERIC_PUNCTUATION: check correctness and correct length
test "zix charsets: ALPHANUMERIC_PUNCTUATION check" {
    const set1 = "abcdefghijklmnopqrs";
    const set2 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const set3 = "0123456789";
    const set4 = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";
    const compare = set1 ++ set2 ++ set3 ++ set4;

    try std.testing.expectEqual(@as(usize, compare.len), ALPHANUMERIC_PUNCTUATION.len);
    try std.testing.expectEqualStrings(compare, ALPHANUMERIC_PUNCTUATION);
}
