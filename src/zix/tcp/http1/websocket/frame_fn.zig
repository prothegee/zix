//! ZIX http1 websocket frame callback
//!
//! ### file: src/zix/tcp/http1/websocket/frame_fn.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Callback type the engine calls for each text or binary frame of an
//! engine-owned WebSocket.
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

/// Per-frame callback for an engine-owned WebSocket connection.
///
/// Note:
/// - Called for text and binary frames only. Ping is auto-ponged and close is
///   auto-echoed by the engine.
/// - opcode is the raw byte. Use `@enumFromInt` to read it as `Opcode`.
/// - payload is valid only during the call.
///
/// Param:
/// fd - std.posix.fd_t (the connection, reply with WebSocket.sendFD)
/// opcode - u8 (frame opcode)
/// payload - []const u8 (unmasked payload)
pub const WsFrameFn = *const fn (fd: std.posix.fd_t, opcode: u8, payload: []const u8) void;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

threadlocal var test_seen_len: usize = 0;

fn testOnFrame(_: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    test_seen_len = payload.len + opcode;
}

test "zix http1 websocket: frame_fn, a plain function coerces" {
    const on_frame: WsFrameFn = testOnFrame;

    on_frame(0, 1, "abc");

    try std.testing.expectEqual(@as(usize, 4), test_seen_len);
}

