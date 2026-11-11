//! ZIX Http2 declared
//!
//! ### file: src/zix/tcp/http2/declared.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What a request's headers promise about its body length.
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

/// The content-length a request declared.
pub const Declared = union(enum) {
    /// No content-length header. The body ends where END_STREAM says it does.
    ABSENT,
    /// The exact DATA payload byte count the peer promised.
    LENGTH: u64,
    /// A content-length that can not be honoured: not a plain decimal number,
    /// or two of them disagreeing. No arriving body satisfies it.
    BROKEN,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2: declared, LENGTH carries the byte count" {
    const value: Declared = .{ .LENGTH = 42 };

    try std.testing.expectEqual(@as(u64, 42), value.LENGTH);
}

test "zix http2: declared, ABSENT and BROKEN are distinct" {
    const absent: Declared = .ABSENT;
    const broken: Declared = .BROKEN;

    try std.testing.expect(std.meta.activeTag(absent) != std.meta.activeTag(broken));
}

