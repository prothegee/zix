//! ZIX http1 tls serve record
//!
//! ### file: src/zix/tcp/http1/tls_serve/Record.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One TLS record read off a blocking descriptor: its content type, the whole
//! record, and the payload after the 5 byte header.
//!
//! ### note:
//!
//! Both slices point into the caller buffer the record was read into.
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

/// The record content type byte.
content_type: u8,
/// Header plus payload.
full: []const u8,
/// Payload only.
body: []const u8,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: Record, body is the tail of full" {
    const wire = "\x17\x03\x03\x00\x02hi";
    const rec: Self = .{
        .content_type = wire[0],
        .full = wire,
        .body = wire[5..],
    };

    try std.testing.expectEqual(@as(u8, 23), rec.content_type);
    try std.testing.expectEqualStrings("hi", rec.body);
}

test "zix http1: Record, an empty payload keeps the header" {
    const wire = "\x15\x03\x03\x00\x00";
    const rec: Self = .{
        .content_type = wire[0],
        .full = wire,
        .body = wire[5..],
    };

    try std.testing.expectEqual(@as(usize, 5), rec.full.len);
    try std.testing.expectEqual(@as(usize, 0), rec.body.len);
}

