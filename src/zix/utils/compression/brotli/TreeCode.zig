//! ZIX utils compression brotli TreeCode
//!
//! ### file: src/zix/utils/compression/brotli/TreeCode.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! One prefix code built by the encoder: code length and code per symbol.
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

/// Code length per symbol, 0 means absent.
lengths: []u8,
/// Canonical code per symbol, valid where lengths is not 0.
codes: []u16,
/// Number of symbols with a non-zero frequency.
present: usize,
/// The last present symbol, the whole code when present <= 1.
single: u16,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Whether the code is a single symbol written in the simple form (no bits per use).
///
/// Return:
/// - bool
pub fn isSingle(self: *const Self) bool {
    return self.present <= 1;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression brotli: TreeCode, one present symbol is single" {
    var lengths = [_]u8{ 0, 0 };
    var codes = [_]u16{ 0, 0 };
    const tree: Self = .{
        .lengths = &lengths,
        .codes = &codes,
        .present = 1,
        .single = 1,
    };

    try std.testing.expect(tree.isSingle());
}

test "zix utils compression brotli: TreeCode, two present symbols is not single" {
    var lengths = [_]u8{ 1, 1 };
    var codes = [_]u16{ 0, 1 };
    const tree: Self = .{
        .lengths = &lengths,
        .codes = &codes,
        .present = 2,
        .single = 1,
    };

    try std.testing.expect(!tree.isSingle());
}

