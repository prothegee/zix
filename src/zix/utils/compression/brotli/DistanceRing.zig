//! ZIX utils compression brotli DistanceRing
//!
//! ### file: src/zix/utils/compression/brotli/DistanceRing.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! The four most recent backward distances (RFC 7932 sec 4).
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

/// Index 0 is the last distance, index 3 the fourth to last.
dist: [4]u32 = .{ 4, 11, 15, 16 },

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Push a new last distance and drop the oldest.
///
/// Param:
/// value - u32 (backward distance)
pub fn push(self: *Self, value: u32) void {
    self.dist[3] = self.dist[2];
    self.dist[2] = self.dist[1];
    self.dist[1] = self.dist[0];
    self.dist[0] = value;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression brotli: DistanceRing, starts at the RFC values" {
    const ring: Self = .{};

    try std.testing.expectEqualSlices(u32, &.{ 4, 11, 15, 16 }, &ring.dist);
}

test "zix utils compression brotli: DistanceRing, push shifts and drops the oldest" {
    var ring: Self = .{};
    ring.push(100);

    try std.testing.expectEqualSlices(u32, &.{ 100, 4, 11, 15 }, &ring.dist);
}

