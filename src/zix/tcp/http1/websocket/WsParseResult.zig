//! ZIX http1 websocket parse result
//!
//! ### file: src/zix/tcp/http1/websocket/WsParseResult.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What one frame parse returns: the frame and the bytes it used.
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
const WsFrame = @import("WsFrame.zig");

// --------------------------------------------------------- //
// Fields:

/// The parsed frame.
frame: WsFrame,
/// Bytes used from the front of the source buffer (header plus payload).
consumed: usize,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1 websocket: WsParseResult, keeps frame and consumed" {
    const result: Self = .{
        .frame = .{
            .fin = true,
            .opcode = .binary,
            .payload = "abc",
        },
        .consumed = 5,
    };

    try std.testing.expectEqual(@as(usize, 5), result.consumed);
    try std.testing.expectEqualStrings("abc", result.frame.payload);
}

