//! ZIX http1 websocket pump result
//!
//! ### file: src/zix/tcp/http1/websocket/WsPumpResult.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Outcome of one pump pass over a connection read buffer.
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

/// Bytes used from the front of the data (whole frames only).
consumed: usize,
/// The connection must close (close frame, frame too large, or failed write).
close: bool,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1 websocket: WsPumpResult, keeps consumed and close" {
    const result: Self = .{
        .consumed = 7,
        .close = true,
    };

    try std.testing.expectEqual(@as(usize, 7), result.consumed);
    try std.testing.expect(result.close);
}

