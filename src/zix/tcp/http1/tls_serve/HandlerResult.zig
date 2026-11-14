//! ZIX http1 tls serve handler result
//!
//! ### file: src/zix/tcp/http1/tls_serve/HandlerResult.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One handler outcome over TLS: the plaintext response still staged, or the
//! streamed flag when the handler took the streaming path.
//!
//! ### note:
//!
//! When streamed is true the response already left through the TLS stream sink,
//! so bytes is empty.
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

/// The staged response tail, sent after anything the spill already carried.
bytes: []const u8,
/// The handler streamed (beginStream or WebSocket.serveTls).
streamed: bool = false,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: HandlerResult, defaults to buffered" {
    const result: Self = .{ .bytes = "ok" };

    try std.testing.expect(!result.streamed);
    try std.testing.expectEqualStrings("ok", result.bytes);
}

test "zix http1: HandlerResult, streamed carries no bytes" {
    const result: Self = .{
        .bytes = "",
        .streamed = true,
    };

    try std.testing.expect(result.streamed);
    try std.testing.expectEqual(@as(usize, 0), result.bytes.len);
}

