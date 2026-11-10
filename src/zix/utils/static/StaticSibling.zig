//! ZIX utils static sibling
//!
//! ### file: src/zix/utils/static/StaticSibling.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A precompressed sibling file (for example `app.js.br`) and the coding it
//! holds.
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
const Encoding = @import("../http/encoding.zig").Encoding;

// --------------------------------------------------------- //
// Fields:

/// Coding the sibling file holds.
encoding: Encoding,
/// Suffix added to the identity path, dot included.
suffix: []const u8,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Siblings probed at insert, in server preference order.
pub const ALL = [_]Self{
    .{
        .encoding = .BR,
        .suffix = ".br",
    },
    .{
        .encoding = .GZIP,
        .suffix = ".gz",
    },
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils static: StaticSibling, brotli comes first" {
    try std.testing.expectEqual(Encoding.BR, ALL[0].encoding);
    try std.testing.expectEqualStrings(".br", ALL[0].suffix);
}

test "zix utils static: StaticSibling, gzip comes second" {
    try std.testing.expectEqual(Encoding.GZIP, ALL[1].encoding);
    try std.testing.expectEqualStrings(".gz", ALL[1].suffix);
}

test "zix utils static: StaticSibling, no identity or deflate sibling" {
    for (ALL) |sibling| {
        try std.testing.expect(sibling.encoding != .IDENTITY);
        try std.testing.expect(sibling.encoding != .DEFLATE);
    }
}

