//! TLZ tls12 version selected
//!
//! ### file: src/tlz/src/tls12/version/selected.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The negotiated protocol version outcome of a cross-version server.
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

/// TLS 1.3, TLS 1.2, or below 1.2 (never used, rejected).
pub const Selected = enum {
    TLS_1_3,
    TLS_1_2,
    UNSUPPORTED,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz tls12 version: selected, has three outcomes" {
    try std.testing.expectEqual(@as(usize, 3), std.enums.values(Selected).len);
}

test "tlz tls12 version: selected, names round trip" {
    try std.testing.expectEqualStrings("TLS_1_2", @tagName(Selected.TLS_1_2));
}

