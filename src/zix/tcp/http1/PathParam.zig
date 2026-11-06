//! ZIX Http1 path param
//!
//! ### file: src/zix/tcp/http1/PathParam.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! One captured route parameter name and value.
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

test "zix http1: PathParam, holds a name and value" {
    const param: @This() = .{ .name = "id", .value = "42" };

    try std.testing.expectEqualStrings("id", param.name);
    try std.testing.expectEqualStrings("42", param.value);
}

test "zix http1: PathParam, accepts an empty value" {
    const param: @This() = .{ .name = "slug", .value = "" };

    try std.testing.expectEqual(@as(usize, 0), param.value.len);
}

