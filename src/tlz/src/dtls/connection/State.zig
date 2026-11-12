//! TLZ dtls connection State
//!
//! ### file: src/tlz/src/dtls/connection/State.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Carried from the DTLS server flight into the finish: the randoms, the ephemeral
//! scalar, the running transcript, and where the record sequence has reached.
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
const SrtpProfile = @import("../exporter/srtp_profile.zig").SrtpProfile;

const Sha256 = std.crypto.hash.sha2.Sha256;

// --------------------------------------------------------- //
// Fields:

client_random: [32]u8,
server_random: [32]u8,
server_eph_scalar: [32]u8,
/// SHA-256 over every handshake message, each with its unfragmented DTLS header.
transcript: Sha256,
/// Next record sequence number in epoch 0.
next_record_seq: u48,
/// What use_srtp settled on, or null when neither side asked for media. The finish
/// exports keys for exactly this profile.
srtp_profile: ?SrtpProfile = null,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls connection: State, starts with no SRTP profile" {
    const state: Self = .{
        .client_random = @splat(0x11),
        .server_random = @splat(0x33),
        .server_eph_scalar = @splat(0x22),
        .transcript = Sha256.init(.{}),
        .next_record_seq = 1,
    };

    try std.testing.expectEqual(@as(?SrtpProfile, null), state.srtp_profile);
    try std.testing.expectEqual(@as(u48, 1), state.next_record_seq);
}

