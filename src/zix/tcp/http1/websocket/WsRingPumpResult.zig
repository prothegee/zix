//! ZIX http1 websocket ring pump result
//!
//! ### file: src/zix/tcp/http1/websocket/WsRingPumpResult.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Outcome of one staged pump pass for the .URING engine.
//!
//! ### note:
//!
//! The engine sends out_buf[0..staged] as one ring send after the pass.
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
/// Bytes staged in out_buf for the caller to send.
staged: usize,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1 websocket: WsRingPumpResult, keeps staged bytes" {
    const result: Self = .{
        .consumed = 4,
        .close = false,
        .staged = 9,
    };

    try std.testing.expectEqual(@as(usize, 9), result.staged);
    try std.testing.expect(!result.close);
}

