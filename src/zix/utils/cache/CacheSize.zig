//! ZIX utils cache size
//!
//! ### file: src/zix/utils/cache/CacheSize.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! How large one response cache is: its slot count and per-slot byte cap.
//!
//! ### note:
//!
//! Each server builds this from its own config, so the cache does not depend
//! on any one protocol.
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

/// Slot count, rounded down to a power of two by the cache. 0 counts as 1.
max_entries: u32,
/// A value larger than this many bytes is not stored. 0 counts as 1.
max_value_bytes: u32,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils cache: CacheSize, keeps the slot count and value cap" {
    const size: Self = .{
        .max_entries = 256,
        .max_value_bytes = 16 * 1024,
    };

    try std.testing.expectEqual(@as(u32, 256), size.max_entries);
    try std.testing.expectEqual(@as(u32, 16 * 1024), size.max_value_bytes);
}

test "zix utils cache: CacheSize, keeps zero values as given" {
    const size: Self = .{
        .max_entries = 0,
        .max_value_bytes = 0,
    };

    try std.testing.expectEqual(@as(u32, 0), size.max_entries);
    try std.testing.expectEqual(@as(u32, 0), size.max_value_bytes);
}

