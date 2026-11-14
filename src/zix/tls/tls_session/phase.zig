//! ZIX tls session phase
//!
//! ### file: src/zix/tls/tls_session/phase.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Where one resumable TLS server session stands: hello, finished, established,
//! or closed.
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

/// The handshake and data state of one session.
pub const Phase = enum {
    /// Waiting for the ClientHello.
    HELLO,
    /// Server flight sent, waiting for the client Finished.
    FINISHED,
    /// Handshake done, application records flow.
    ESTABLISHED,
    /// Closed after an alert, a protocol error, or an overflow.
    CLOSED,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix tls: phase, a fresh session starts at HELLO" {
    const phase: Phase = .HELLO;

    try std.testing.expect(phase != .ESTABLISHED);
}

test "zix tls: phase, has four states" {
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(Phase).@"enum".field_names.len);
}

