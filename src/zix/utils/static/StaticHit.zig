//! ZIX utils static hit
//!
//! ### file: src/zix/utils/static/StaticHit.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A pinned static cache hit: the open file, its size, and the 200 header to
//! replay.
//!
//! ### note:
//!
//! Every hit must go back through StaticCache.release, or its slot can never
//! expire. The file is shared by every worker: read it positionally or hand it
//! to sendfile, never seek it.
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

/// Index of the pinned slot, needed by release.
slot: u32,
/// Open file of the chosen variant.
file: std.Io.File,
/// Size of the chosen variant in bytes.
size: u64,
/// Prerendered "HTTP/1.1 200 OK" header, ready to write.
header: []const u8,
/// MIME type, always from the identity name.
content_type: []const u8,
/// Coding of the chosen variant.
encoding: Encoding,
/// Resident bytes of the chosen variant. Set only by acquireMapped, valid
/// until release.
bytes: ?[]const u8 = null,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils static: StaticHit, bytes default to null" {
    const hit: Self = .{
        .slot = 3,
        .file = undefined,
        .size = 10,
        .header = "",
        .content_type = "text/plain",
        .encoding = .IDENTITY,
    };

    try std.testing.expect(hit.bytes == null);
    try std.testing.expectEqual(@as(u32, 3), hit.slot);
}

test "zix utils static: StaticHit, keeps the chosen encoding" {
    const hit: Self = .{
        .slot = 0,
        .file = undefined,
        .size = 0,
        .header = "",
        .content_type = "application/javascript",
        .encoding = .BR,
    };

    try std.testing.expectEqual(Encoding.BR, hit.encoding);
}

