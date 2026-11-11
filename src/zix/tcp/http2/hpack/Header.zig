//! ZIX Http2 hpack Header
//!
//! ### file: src/zix/tcp/http2/hpack/Header.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One HPACK header field: a name and a value. Also the shape of a table entry.
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
// Fields:

/// Header name, lowercase on the wire.
name: []const u8,
/// Header value.
value: []const u8,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 hpack: Header, keeps its fields" {
    const header: Self = .{
        .name = ":method",
        .value = "GET",
    };

    try std.testing.expectEqualStrings(":method", header.name);
    try std.testing.expectEqualStrings("GET", header.value);
}

test "zix http2 hpack: Header, holds an empty value" {
    const header: Self = .{
        .name = ":authority",
        .value = "",
    };

    try std.testing.expectEqual(@as(usize, 0), header.value.len);
}

