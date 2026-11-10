//! ZIX utils static install result
//!
//! ### file: src/zix/utils/static/install_result.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What StaticCacheRegistry.install did, so the caller can report it through
//! its own logger.
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

/// Outcome of one install call.
pub const InstallResult = enum {
    /// ttl_ms was 0, so caching stays off.
    DISABLED,
    /// This call built the shared table.
    INSTALLED,
    /// A table already existed with the same settings.
    ALREADY_INSTALLED,
    /// A table already existed with different settings, and it was kept.
    MISMATCHED,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils static: install_result, has four outcomes" {
    try std.testing.expectEqual(@as(usize, 4), std.enums.values(InstallResult).len);
}

test "zix utils static: install_result, outcomes are distinct" {
    try std.testing.expect(InstallResult.INSTALLED != InstallResult.MISMATCHED);
    try std.testing.expect(InstallResult.DISABLED != InstallResult.ALREADY_INSTALLED);
}

