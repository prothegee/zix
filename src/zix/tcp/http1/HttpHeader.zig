//! ZIX Http1 header
//!
//! ### file: src/zix/tcp/http1/HttpHeader.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! One response header name and value.
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

name: []const u8,
value: []const u8,

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: HttpHeader, holds a name and value" {
    const header: @This() = .{ .name = "Content-Type", .value = "text/plain" };

    try std.testing.expectEqualStrings("Content-Type", header.name);
    try std.testing.expectEqualStrings("text/plain", header.value);
}

test "zix http1: HttpHeader, accepts an empty value" {
    const header: @This() = .{ .name = "X-Empty", .value = "" };

    try std.testing.expectEqualStrings("X-Empty", header.name);
    try std.testing.expectEqual(@as(usize, 0), header.value.len);
}

