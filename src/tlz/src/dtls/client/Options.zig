//! TLZ dtls client Options
//!
//! ### file: src/tlz/src/dtls/client/Options.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What a DTLS 1.2 client brings to one handshake: its random, its ephemeral seed,
//! and the fragment limit.
//!
//! ### note:
//!
//! Both values belong to exactly one handshake and are never reused, so they come
//! from the caller rather than being drawn here. That also lets a test pin them.
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
const connection = @import("../connection.zig");

// --------------------------------------------------------- //
// Fields:

client_random: [32]u8,
/// Seed for the ephemeral ECDHE scalar.
client_eph_secret: [32]u8,
/// Largest handshake fragment body this client emits.
max_fragment_len: usize = connection.DEFAULT_MAX_FRAGMENT,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls client: Options, the fragment limit defaults to the server one" {
    const options: Self = .{
        .client_random = @splat(0x11),
        .client_eph_secret = @splat(0x44),
    };

    try std.testing.expectEqual(connection.DEFAULT_MAX_FRAGMENT, options.max_fragment_len);
}

