//! ZIX utils compression level
//!
//! ### file: src/zix/utils/compression/level.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Compression effort shared by every codec.
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
// Public:

/// Compression effort, forwarded to the codec.
pub const Level = enum(u8) {
    /// Fastest, lowest ratio. For low-latency response paths.
    FASTEST,
    /// Balanced default.
    DEFAULT,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression: Level, has two efforts" {
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(Level).@"enum".field_names.len);
}

test "zix utils compression: Level, FASTEST comes before DEFAULT" {
    try std.testing.expect(@intFromEnum(Level.FASTEST) < @intFromEnum(Level.DEFAULT));
}

