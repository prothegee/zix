//! TLZ tls12 connection Flight1
//!
//! ### file: src/tlz/src/tls12/connection/Flight1.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What `serverFlight1` produces: the plaintext server flight to send and the State
//! `serverFinish` needs.
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
const State = @import("State.zig");

// --------------------------------------------------------- //
// Fields:

/// One handshake record: ServerHello, Certificate, ServerKeyExchange,
/// ServerHelloDone. A view into the caller's buffer.
to_send: []const u8,
/// Carried into `serverFinish`.
state: State,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz tls12 connection: Flight1, keeps the bytes to send" {
    const flight: Self = .{
        .to_send = "flight",
        .state = undefined,
    };

    try std.testing.expectEqualStrings("flight", flight.to_send);
}

test "tlz tls12 connection: Flight1, empty flight has no bytes" {
    const flight: Self = .{
        .to_send = &.{},
        .state = undefined,
    };

    try std.testing.expectEqual(@as(usize, 0), flight.to_send.len);
}

