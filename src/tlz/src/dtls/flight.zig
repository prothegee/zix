//! TLZ dtls flight
//!
//! ### file: src/tlz/src/dtls/flight.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! DTLS handshake retransmission (RFC 6347 4.2.4 and 4.2.4.1): the timeout policy,
//! plus the `Timer` and `Flight` records that apply it.
//!
//! ### note:
//!
//! Nothing below DTLS retransmits, so the handshake carries its own timer and
//! resends whole flights.
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

pub const State = @import("flight/state.zig").State;
pub const TimeoutAction = @import("flight/timeout_action.zig").TimeoutAction;
pub const Timer = @import("flight/Timer.zig");
pub const Flight = @import("flight/Flight.zig");

/// First retransmission delay (RFC 6347 4.2.4.1). One second, the RFC 6298 minimum,
/// chosen over the default of three because a handshake is latency-sensitive.
pub const INITIAL_TIMEOUT_MS: u64 = 1000;

/// Ceiling on the doubling (RFC 6347 4.2.4.1, the RFC 6298 maximum).
pub const MAX_TIMEOUT_MS: u64 = 60000;

/// Retransmissions before a handshake is declared dead.
///
/// Note:
/// - RFC 6347 sets no limit, so this is a local choice: 6 retransmissions is
///   1 + 2 + 4 + 8 + 16 + 32, about 63 seconds of trying.
pub const DEFAULT_MAX_RETRANSMITS: usize = 6;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls: flight, INITIAL_TIMEOUT_MS is one second" {
    try std.testing.expectEqual(@as(u64, 1000), INITIAL_TIMEOUT_MS);
}

test "tlz dtls: flight, MAX_TIMEOUT_MS is above the initial delay" {
    try std.testing.expect(MAX_TIMEOUT_MS > INITIAL_TIMEOUT_MS);
}

test "tlz dtls: flight, DEFAULT_MAX_RETRANSMITS gives about a minute of tries" {
    var total: u64 = 0;
    var delay: u64 = INITIAL_TIMEOUT_MS;

    for (0..DEFAULT_MAX_RETRANSMITS) |_| {
        total += delay;
        delay = @min(delay * 2, MAX_TIMEOUT_MS);
    }

    try std.testing.expectEqual(@as(u64, 63000), total);
}

