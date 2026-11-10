//! ZIX http1 websocket pending promotion
//!
//! ### file: src/zix/tcp/http1/websocket/pending.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Carries a WebSocket promotion from the handler to the engine on the same
//! thread.
//!
//! ### note:
//!
//! A threadlocal: WebSocket.serve sets it during the handler, and the engine
//! takes it right after the handler returns, on the same thread.
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
const WebSocketPending = @import("WebSocketPending.zig");
const WsFrameFn = @import("frame_fn.zig").WsFrameFn;

// --------------------------------------------------------- //
// Private:

threadlocal var tl_pending: ?WebSocketPending = null;

// --------------------------------------------------------- //
// Public:

/// Ask the engine to promote fd to a WebSocket after the handler returns.
///
/// Param:
/// fd - std.posix.fd_t (the upgraded connection)
/// on_frame - WsFrameFn (callback for each text or binary frame)
pub fn request(fd: std.posix.fd_t, on_frame: WsFrameFn) void {
    tl_pending = .{
        .fd = fd,
        .on_frame = on_frame,
    };
}

/// Take and clear the promotion of the current thread.
///
/// Return:
/// - WebSocketPending when a handler asked for one
/// - null otherwise
pub fn take() ?WebSocketPending {
    const pending = tl_pending;
    tl_pending = null;

    return pending;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testOnFrame(_: std.posix.fd_t, _: u8, _: []const u8) void {}

test "zix http1 websocket: pending, take is null without a request" {
    _ = take();

    try std.testing.expect(take() == null);
}

test "zix http1 websocket: pending, take returns the request" {
    request(7, testOnFrame);

    const pending = take().?;

    try std.testing.expectEqual(@as(std.posix.fd_t, 7), pending.fd);
}

test "zix http1 websocket: pending, take clears the request" {
    request(7, testOnFrame);
    _ = take();

    try std.testing.expect(take() == null);
}

test "zix http1 websocket: pending, a second request replaces the first" {
    request(7, testOnFrame);
    request(9, testOnFrame);

    try std.testing.expectEqual(@as(std.posix.fd_t, 9), take().?.fd);
}

