//! TLZ tls12 client State
//!
//! ### file: src/tlz/src/tls12/client/State.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What the TLS 1.2 client carries from `start` into `finish`: the ephemeral scalar,
//! the client random, and the running transcript.
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
const Transcript = @import("../../key_schedule/Transcript.zig");

// --------------------------------------------------------- //
// Fields:

/// The secp256r1 ephemeral scalar, already reduced.
ephemeral_scalar: [32]u8,
client_random: [32]u8,
/// The transcript so far (the ClientHello after `start`).
transcript: Transcript,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz tls12 client: State, keeps the client random" {
    const state: Self = .{
        .ephemeral_scalar = @splat(0),
        .client_random = @splat(0x11),
        .transcript = .init(),
    };

    try std.testing.expectEqual(@as(u8, 0x11), state.client_random[31]);
}

test "tlz tls12 client: State, fresh transcript is the empty hash" {
    const state: Self = .{
        .ephemeral_scalar = @splat(0),
        .client_random = @splat(0),
        .transcript = .init(),
    };
    const empty: Transcript = .init();

    try std.testing.expectEqualSlices(u8, &empty.current(), &state.transcript.current());
}

