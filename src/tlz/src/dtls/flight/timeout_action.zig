//! TLZ dtls flight timeout_action
//!
//! ### file: src/tlz/src/dtls/flight/timeout_action.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What a fired DTLS retransmission timer means for the caller.
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

/// What a fired timer means for the caller.
pub const TimeoutAction = enum {
    /// Send the buffered flight again.
    RETRANSMIT,
    /// Stop. The peer has had every allowed retransmission.
    GIVE_UP,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls flight: timeout_action, has two actions" {
    try std.testing.expectEqual(@as(usize, 2), std.meta.fieldNames(TimeoutAction).len);
}

test "tlz dtls flight: timeout_action, the actions differ" {
    try std.testing.expect(TimeoutAction.RETRANSMIT != TimeoutAction.GIVE_UP);
}

