//! ZIX utils http range
//!
//! ### file: src/zix/utils/http/Range.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A byte range resolved against a known length, inclusive on both ends.
//!
//! ### note:
//!
//! A Range is always satisfiable: start <= end < length.
//! Build it through range_header.resolve, not by hand.
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

/// First byte of the range.
start: u64,
/// Last byte of the range, inclusive.
end: u64,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Bytes the range covers.
///
/// Return:
/// - u64 (end - start + 1)
pub fn length(self: Self) u64 {
    return self.end - self.start + 1;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils http: Range, length counts both ends" {
    const range: Self = .{
        .start = 2,
        .end = 5,
    };

    try std.testing.expectEqual(@as(u64, 4), range.length());
}

test "zix utils http: Range, a single byte has length 1" {
    const range: Self = .{
        .start = 7,
        .end = 7,
    };

    try std.testing.expectEqual(@as(u64, 1), range.length());
}

test "zix utils http: Range, a full u64 span does not overflow" {
    const range: Self = .{
        .start = 1,
        .end = std.math.maxInt(u64),
    };

    try std.testing.expectEqual(std.math.maxInt(u64), range.length());
}

