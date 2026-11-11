//! ZIX Http2 mux conn_outcome
//!
//! ### file: src/zix/tcp/http2/mux/conn_outcome.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What a mux connection asks its dispatch worker to do after one event.
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

/// The verdict after a readable event or a ring recv.
pub const ConnOutcome = enum {
    /// Keep the fd armed and wait for more bytes.
    keep_alive,
    /// Close the fd: the peer left, broke the protocol, or a write failed.
    close,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 mux: conn_outcome, keep_alive and close are distinct" {
    try std.testing.expect(ConnOutcome.keep_alive != ConnOutcome.close);
}

