//! TLZ client State
//!
//! ### file: src/tlz/src/client/State.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What a client handshake carries from `start` into `finish`: the ephemeral key
//! and the running transcript.
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
const Transcript = @import("../key_schedule/Transcript.zig");

// --------------------------------------------------------- //
// Fields:

/// The X25519 ephemeral private key.
ephemeral_secret: [32]u8,
/// The transcript so far (the ClientHello after `start`).
transcript: Transcript,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz client: State, keeps the ephemeral secret" {
    const state: Self = .{
        .ephemeral_secret = @splat(0x42),
        .transcript = .init(),
    };

    try std.testing.expectEqual(@as(u8, 0x42), state.ephemeral_secret[31]);
}

test "tlz client: State, fresh transcript is the empty hash" {
    const state: Self = .{
        .ephemeral_secret = @splat(0),
        .transcript = .init(),
    };
    const empty: Transcript = .init();

    try std.testing.expectEqualSlices(u8, &empty.current(), &state.transcript.current());
}

