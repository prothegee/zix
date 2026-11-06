//! ZIX Http1 parse result
//!
//! ### file: src/zix/tcp/http1/ParseResult.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Parsed request head plus the body offset that follows it.
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

const ParsedHead = @import("ParsedHead.zig");

const std = @import("std");

// --------------------------------------------------------- //
// Fields:

head: ParsedHead,
body_offset: usize,

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: ParseResult, carries the head and offset" {
    const head: ParsedHead = .{
        .path = "/",
        .query = "",
        .method = "GET",
        .keep_alive = true,
        .raw_headers = "",
        .version_minor = 1,
        .content_length = 0,
        .chunked_request = false,
        .expect_continue = false,
    };
    const result: @This() = .{ .head = head, .body_offset = 20 };

    try std.testing.expectEqual(@as(usize, 20), result.body_offset);
    try std.testing.expectEqualStrings("GET", result.head.method);
}

test "zix http1: ParseResult, body offset points past the head" {
    const head: ParsedHead = .{
        .path = "/x",
        .query = "a=1",
        .method = "POST",
        .keep_alive = false,
        .raw_headers = "",
        .version_minor = 0,
        .content_length = 8,
        .chunked_request = false,
        .expect_continue = true,
    };
    const result: @This() = .{ .head = head, .body_offset = 40 };

    try std.testing.expectEqual(@as(usize, 40), result.body_offset);
    try std.testing.expectEqualStrings("a=1", result.head.query);
}

