//! ZIX Http1 parsed head
//!
//! ### file: src/zix/tcp/http1/ParsedHead.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Zero-copy view of a parsed HTTP/1 request head.
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

const HeaderSpan = @import("HeaderSpan.zig");

const std = @import("std");

// --------------------------------------------------------- //
// Fields:

path: []const u8,
query: []const u8,
method: []const u8,
keep_alive: bool,
raw_headers: []const u8,
version_minor: u8,
content_length: u64,
chunked_request: bool,
expect_continue: bool,
accept_encoding: HeaderSpan = .{},

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: ParsedHead, defaults accept encoding to unscanned" {
    const head: @This() = .{
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

    try std.testing.expectEqual(HeaderSpan.SPAN_UNSCANNED, head.accept_encoding.off);
    try std.testing.expect(head.keep_alive);
}

test "zix http1: ParsedHead, carries an absent accept encoding" {
    const head: @This() = .{
        .path = "/x",
        .query = "",
        .method = "HEAD",
        .keep_alive = false,
        .raw_headers = "",
        .version_minor = 0,
        .content_length = 12,
        .chunked_request = true,
        .expect_continue = true,
        .accept_encoding = .{ .off = HeaderSpan.SPAN_ABSENT, .len = 0 },
    };

    try std.testing.expectEqual(HeaderSpan.SPAN_ABSENT, head.accept_encoding.off);
    try std.testing.expectEqual(@as(u64, 12), head.content_length);
    try std.testing.expect(head.chunked_request);
    try std.testing.expect(head.expect_continue);
}

