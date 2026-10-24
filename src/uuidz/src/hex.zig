//! uuidz charsets for utility and their of truth.
//!
//! Note:
//! - Any repeatable charsets or strings will use from here.

const std = @import("std");

// --------------------------------------------------------- //

/// 0123456789abcdef
pub const hex = "0123456789abcdef";

// --------------------------------------------------------- //
// --------------------------------------------------------- //

// hex: check correctness and correct length
test "zix charsets: hex" {
    const compare = "0123456789abcdef";

    try std.testing.expectEqual(@as(usize, compare.len), hex.len);
    try std.testing.expectEqualStrings(compare, hex);
}
