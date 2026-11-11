//! ZIX Http2 Grpc window
//!
//! ### file: src/zix/tcp/http2/grpc/window.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Receive window sizes the gRPC server advertises and replenishes.
//!
//! ### note:
//!
//! The windows are large on purpose: a small unary or streaming body never
//! needs a WINDOW_UPDATE per DATA frame.
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

/// Stream receive window advertised in SETTINGS, in bytes. A body past this
/// on one stream stalls, since no stream WINDOW_UPDATE is sent.
pub const STREAM_WINDOW_SIZE: u32 = 16 * 1024 * 1024;

/// One-time connection window bump sent after the peer SETTINGS, in bytes.
pub const CONN_WINDOW_BUMP: u31 = 1 << 30;

/// Inbound DATA bytes after which the connection window is replenished.
pub const CONN_REPLENISH_THRESHOLD: usize = 1 << 29;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 grpc: window, stream window is 16 MiB" {
    try std.testing.expectEqual(@as(u32, 16_777_216), STREAM_WINDOW_SIZE);
}

test "zix http2 grpc: window, stream window fits the RFC9113 max" {
    try std.testing.expect(STREAM_WINDOW_SIZE <= std.math.maxInt(u31));
}

test "zix http2 grpc: window, connection bump is 1 GiB" {
    try std.testing.expectEqual(@as(u31, 1_073_741_824), CONN_WINDOW_BUMP);
}

test "zix http2 grpc: window, replenish threshold is below the bump" {
    try std.testing.expect(CONN_REPLENISH_THRESHOLD < CONN_WINDOW_BUMP);
}

