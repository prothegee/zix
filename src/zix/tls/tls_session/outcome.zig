//! ZIX tls session outcome
//!
//! ### file: src/zix/tls/tls_session/outcome.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What one feed of ciphertext produced, for the dispatch loop to act on.
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

/// The result kind of one feed.
pub const Outcome = enum {
    /// Records consumed. Send to_send, hand plaintext to the engine.
    OK,
    /// The handshake just completed. The connection is now established.
    ESTABLISHED,
    /// The session must close. Send to_send, then close.
    CLOSE,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix tls: outcome, has three results" {
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(Outcome).@"enum".field_names.len);
}

test "zix tls: outcome, CLOSE differs from OK" {
    const outcome: Outcome = .CLOSE;

    try std.testing.expect(outcome != .OK);
}

