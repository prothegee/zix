//! TLZ tls12 connection State
//!
//! ### file: src/tlz/src/tls12/connection/State.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What the TLS 1.2 server carries from flight 1 into finish: the randoms, the
//! ephemeral scalar, the running transcript, and the selected ALPN.
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
const Alpn = @import("../../alpn.zig").Alpn;

// --------------------------------------------------------- //
// Fields:

client_random: [32]u8,
/// The ServerHello random as sent, with the downgrade sentinel when planted.
server_random: [32]u8,
/// The secp256r1 ephemeral scalar, already reduced.
server_eph_scalar: [32]u8,
/// The handshake transcript, ClientHello through ServerHelloDone after flight 1.
transcript: Transcript,
/// The ALPN protocol selected, null when ALPN was not used.
alpn: ?Alpn = null,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz tls12 connection: State, ALPN defaults to null" {
    const state: Self = .{
        .client_random = @splat(0),
        .server_random = @splat(0),
        .server_eph_scalar = @splat(0),
        .transcript = .init(),
    };

    try std.testing.expect(state.alpn == null);
}

test "tlz tls12 connection: State, fresh transcript is the empty hash" {
    const state: Self = .{
        .client_random = @splat(0),
        .server_random = @splat(0),
        .server_eph_scalar = @splat(0),
        .transcript = .init(),
    };
    const empty: Transcript = .init();

    try std.testing.expectEqualSlices(u8, &empty.current(), &state.transcript.current());
}

