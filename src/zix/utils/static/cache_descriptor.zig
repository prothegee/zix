//! ZIX utils static cache descriptor
//!
//! ### file: src/zix/utils/static/cache_descriptor.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! How many static cache entries the process descriptor budget allows.
//!
//! ### note:
//!
//! One entry holds up to three open files. Without this cap a large
//! public_dir_cache_max_entries could use every descriptor before the server
//! accepts a socket.
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
const builtin = @import("builtin");

// --------------------------------------------------------- //
// Private:

/// Share of the descriptor budget the table may hold.
const FD_BUDGET_DIVISOR: u64 = 4;

/// Clamp a raw descriptor limit into an entry ceiling.
///
/// Param:
/// limit - u64 (soft NOFILE limit, 0 when unknown)
///
/// Return:
/// - u32 (entry ceiling, never below FD_CEILING_MIN)
fn fromLimit(limit: u64) u32 {
    if (limit == 0) return FD_CEILING_FALLBACK;

    const budget = limit / FD_BUDGET_DIVISOR;
    const capped = @min(budget, @as(u64, std.math.maxInt(u32)));

    return @intCast(@max(FD_CEILING_MIN, capped));
}

// --------------------------------------------------------- //
// Public:

/// Entry count used when the descriptor limit cannot be read.
pub const FD_CEILING_FALLBACK: u32 = 256;

/// Smallest ceiling, so a tiny limit still leaves a usable table.
pub const FD_CEILING_MIN: u32 = 32;

/// Read the descriptor limit and return how many entries the table may hold.
///
/// Return:
/// - u32 (entry ceiling, never below FD_CEILING_MIN)
pub fn ceiling() u32 {
    if (comptime builtin.os.tag == .windows) return FD_CEILING_FALLBACK;

    const limit = std.posix.getrlimit(.NOFILE) catch |err| switch (err) {
        else => return FD_CEILING_FALLBACK,
    };

    // rlim_t is signed on the BSDs and unsigned on Linux.
    if (limit.cur <= 0) return FD_CEILING_FALLBACK;

    return fromLimit(@intCast(limit.cur));
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils static: cache_descriptor, ceiling stays at or above the floor" {
    try std.testing.expect(ceiling() >= FD_CEILING_MIN);
}

test "zix utils static: cache_descriptor, fromLimit takes a quarter" {
    try std.testing.expectEqual(@as(u32, 256), fromLimit(1024));
}

test "zix utils static: cache_descriptor, fromLimit tiny limit uses the floor" {
    try std.testing.expectEqual(FD_CEILING_MIN, fromLimit(8));
}

test "zix utils static: cache_descriptor, fromLimit unknown limit falls back" {
    try std.testing.expectEqual(FD_CEILING_FALLBACK, fromLimit(0));
}

test "zix utils static: cache_descriptor, fromLimit huge limit caps at u32 max" {
    try std.testing.expectEqual(std.math.maxInt(u32), fromLimit(std.math.maxInt(u64)));
}

