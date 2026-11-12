//! TLZ tls12 client HandshakeOptions
//!
//! ### file: src/tlz/src/tls12/client/HandshakeOptions.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The per-connection randomness the TLS 1.2 client handshake needs.
//!
//! ### note:
//!
//! The randomness is fresh in production and fixed in tests.
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
// Fields:

/// The ClientHello random.
client_random: [32]u8,
/// The secp256r1 ephemeral seed, reduced to a scalar internally.
ephemeral_secret: [32]u8,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz tls12 client: HandshakeOptions, keeps the client random" {
    const opts: Self = .{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
    };

    try std.testing.expectEqual(@as(u8, 0x11), opts.client_random[0]);
}

test "tlz tls12 client: HandshakeOptions, keeps the ephemeral seed" {
    const opts: Self = .{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
    };

    try std.testing.expectEqual(@as(u8, 0x42), opts.ephemeral_secret[31]);
}

