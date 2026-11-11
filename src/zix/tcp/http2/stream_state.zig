//! ZIX Http2 stream_state
//!
//! ### file: src/zix/tcp/http2/stream_state.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Lifecycle state of one HTTP/2 stream (RFC 7540 section 5.1).
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

/// Server-side stream states. A zeroed stream reads as IDLE.
pub const StreamState = enum {
    IDLE,
    OPEN,
    HALF_CLOSED_REMOTE,
    CLOSED,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2: stream_state, IDLE is the zero value" {
    const zeroed = std.mem.zeroes(StreamState);

    try std.testing.expectEqual(StreamState.IDLE, zeroed);
}

test "zix http2: stream_state, tag names match the enum" {
    try std.testing.expectEqualStrings("OPEN", @tagName(StreamState.OPEN));
    try std.testing.expectEqualStrings(
        "HALF_CLOSED_REMOTE",
        @tagName(StreamState.HALF_CLOSED_REMOTE),
    );
    try std.testing.expectEqualStrings("CLOSED", @tagName(StreamState.CLOSED));
}

