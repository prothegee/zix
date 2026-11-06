//! ZIX Http1 ChunkedFrame
//!
//! ### file: src/zix/tcp/http1/ChunkedFrame.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! What a walk of the chunk framing found.
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

const ChunkedStop = @import("chunk.zig").ChunkedStop;

const std = @import("std");

// --------------------------------------------------------- //
// Fields:

len: usize = 0,
consumed: usize = 0,
stop: ChunkedStop,

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: ChunkedFrame, carries the walk result" {
    const frame: @This() = .{ .len = 5, .consumed = 15, .stop = .COMPLETE };

    try std.testing.expectEqual(@as(usize, 5), frame.len);
    try std.testing.expectEqual(@as(usize, 15), frame.consumed);
    try std.testing.expectEqual(ChunkedStop.COMPLETE, frame.stop);
}

test "zix http1: ChunkedFrame, defaults to an unfinished walk" {
    const frame: @This() = .{ .stop = .NEED_MORE };

    try std.testing.expectEqual(@as(usize, 0), frame.len);
    try std.testing.expectEqual(@as(usize, 0), frame.consumed);
}

