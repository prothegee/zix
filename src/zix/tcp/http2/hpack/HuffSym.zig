//! ZIX Http2 hpack HuffSym
//!
//! ### file: src/zix/tcp/http2/hpack/HuffSym.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One HPACK Huffman code: the code bits and how many of them are used.
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

/// Code bits, right aligned.
code: u32,
/// Number of bits in code (5 to 30).
bits: u5,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 hpack: HuffSym, keeps its fields" {
    const sym: Self = .{
        .code = 0x1ff8,
        .bits = 13,
    };

    try std.testing.expectEqual(@as(u32, 0x1ff8), sym.code);
    try std.testing.expectEqual(@as(u5, 13), sym.bits);
}

test "zix http2 hpack: HuffSym, holds the longest 30-bit code" {
    const sym: Self = .{
        .code = 0x3fffffff,
        .bits = 30,
    };

    try std.testing.expectEqual(@as(u5, 30), sym.bits);
}

