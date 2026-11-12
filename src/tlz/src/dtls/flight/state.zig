//! TLZ dtls flight state
//!
//! ### file: src/tlz/src/dtls/flight/state.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The four DTLS handshake transmission states (RFC 6347 4.2.4).
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

/// Handshake transmission state (RFC 6347 4.2.4).
pub const State = enum {
    /// Building the next flight.
    PREPARING,
    /// The flight is buffered and going out.
    SENDING,
    /// The flight is out, waiting on the peer with a timer running.
    WAITING,
    /// The handshake is done. The last flight is still kept for retransmission.
    FINISHED,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls flight: state, has the four RFC 6347 states" {
    try std.testing.expectEqual(@as(usize, 4), std.meta.fieldNames(State).len);
}

test "tlz dtls flight: state, names round trip" {
    try std.testing.expectEqualStrings("WAITING", @tagName(State.WAITING));
    try std.testing.expectEqualStrings("FINISHED", @tagName(State.FINISHED));
}

