//! ZIX Http1 ChunkedRead
//!
//! ### file: src/zix/tcp/http1/ChunkedRead.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Result of reading a chunked body off a socket.
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
received: u64 = 0,
leftover_off: usize = 0,
leftover: usize = 0,
stop: ChunkedStop,

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: ChunkedRead, carries the decode result" {
    const read: @This() = .{
        .len = 5,
        .received = 15,
        .leftover_off = 15,
        .leftover = 3,
        .stop = .COMPLETE,
    };

    try std.testing.expectEqual(@as(usize, 5), read.len);
    try std.testing.expectEqual(@as(u64, 15), read.received);
    try std.testing.expectEqual(@as(usize, 3), read.leftover);
    try std.testing.expectEqual(ChunkedStop.COMPLETE, read.stop);
}

test "zix http1: ChunkedRead, defaults to no leftover" {
    const read: @This() = .{ .stop = .NEED_MORE };

    try std.testing.expectEqual(@as(usize, 0), read.leftover);
    try std.testing.expectEqual(@as(usize, 0), read.leftover_off);
}

