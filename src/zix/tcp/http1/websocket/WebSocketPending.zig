//! ZIX http1 websocket pending
//!
//! ### file: src/zix/tcp/http1/websocket/WebSocketPending.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A WebSocket promotion asked by a handler: the connection and its frame
//! callback.
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
const WsFrameFn = @import("frame_fn.zig").WsFrameFn;

// --------------------------------------------------------- //
// Fields:

/// The upgraded connection.
fd: std.posix.fd_t,
/// Callback for each text or binary frame.
on_frame: WsFrameFn,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testOnFrame(_: std.posix.fd_t, _: u8, _: []const u8) void {}

test "zix http1 websocket: WebSocketPending, keeps fd and callback" {
    const pending: Self = .{
        .fd = 3,
        .on_frame = testOnFrame,
    };

    try std.testing.expectEqual(@as(std.posix.fd_t, 3), pending.fd);
    try std.testing.expect(pending.on_frame == @as(WsFrameFn, testOnFrame));
}

