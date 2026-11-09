//! ZIX utils cache entry
//!
//! ### file: src/zix/utils/cache/CacheEntry.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One registered response cache and the generation it was built in.
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
const ResponseCache = @import("ResponseCache.zig");

// --------------------------------------------------------- //
// Fields:

/// The registered cache, heap allocated and owned by the registry.
resp_cache: *ResponseCache,
/// The generation the cache was built in.
generation: u64,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils cache: CacheEntry, keeps the cache and generation" {
    var resp_cache: ResponseCache = undefined;

    const entry: Self = .{
        .resp_cache = &resp_cache,
        .generation = 3,
    };

    try std.testing.expectEqual(&resp_cache, entry.resp_cache);
    try std.testing.expectEqual(@as(u64, 3), entry.generation);
}

test "zix utils cache: CacheEntry, holds the max generation" {
    var resp_cache: ResponseCache = undefined;

    const entry: Self = .{
        .resp_cache = &resp_cache,
        .generation = std.math.maxInt(u64),
    };

    try std.testing.expectEqual(std.math.maxInt(u64), entry.generation);
}

