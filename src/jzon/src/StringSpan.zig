//! JZON StringSpan
//!
//! ### file: src/jzon/src/StringSpan.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A located JSON string token: the bytes between the quotes, plus whether any of
//! them are part of an escape sequence.
//!
//! ### note:
//!
//! `raw` is undecoded and points into the document. When `escaped` is false it is
//! already the string value, which is what lets a parser borrow it instead of copying.
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

/// The bytes between the quotes, undecoded, borrowed from the document.
raw: []const u8,
/// True when `raw` holds at least one backslash escape.
escaped: bool,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "jzon: StringSpan, raw points into the document" {
    const document = "\"order\"";
    const span: Self = .{
        .raw = document[1..6],
        .escaped = false,
    };

    try std.testing.expectEqualStrings("order", span.raw);
    try std.testing.expectEqual(@intFromPtr(document.ptr) + 1, @intFromPtr(span.raw.ptr));
}

test "jzon: StringSpan, escaped span keeps the backslash undecoded" {
    const span: Self = .{
        .raw = "a\\nb",
        .escaped = true,
    };

    try std.testing.expectEqual(@as(usize, 4), span.raw.len);
    try std.testing.expect(span.escaped);
}

test "jzon: StringSpan, empty token has zero length" {
    const span: Self = .{
        .raw = "",
        .escaped = false,
    };

    try std.testing.expectEqual(@as(usize, 0), span.raw.len);
    try std.testing.expect(!span.escaped);
}

