//! ZIX Http2 UpgradeHead
//!
//! ### file: src/zix/tcp/http2/UpgradeHead.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What an accepted h2c upgrade request carries into stream 1.
//!
//! ### note:
//!
//! - Every slice borrows the buffers the caller passed to upgrade.accept, so
//!   the head is valid only while those buffers live.
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

/// Method from the HTTP/1.1 request line.
method: []const u8,
/// Request target from the HTTP/1.1 request line, query included.
path: []const u8,
/// Decoded HTTP2-Settings payload, 6 bytes per parameter. Empty when the
/// header is absent or not valid base64url.
settings: []const u8 = "",

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2: UpgradeHead, settings defaults to empty" {
    const head: Self = .{
        .method = "GET",
        .path = "/",
    };

    try std.testing.expectEqualStrings("GET", head.method);
    try std.testing.expectEqual(@as(usize, 0), head.settings.len);
}

