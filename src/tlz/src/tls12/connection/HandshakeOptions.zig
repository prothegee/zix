//! TLZ tls12 connection HandshakeOptions
//!
//! ### file: src/tlz/src/tls12/connection/HandshakeOptions.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What the TLS 1.2 server handshake needs from the caller: the identity and the
//! per-connection randomness.
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
const Alpn = @import("../../alpn.zig").Alpn;

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

// --------------------------------------------------------- //
// Fields:

/// The end-entity certificate DER, borrowed.
certificate_der: []const u8,
/// The ServerKeyExchange signing key (ECDSA P-256).
signing_key: EcdsaP256.KeyPair,
/// The secp256r1 ephemeral seed, reduced to a scalar internally.
server_eph_secret: [32]u8,
/// The ServerHello random.
server_random: [32]u8,
/// Server ALPN preference order (RFC 7301). Empty disables ALPN.
alpn_prefs: []const Alpn = &.{},

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz tls12 connection: HandshakeOptions, ALPN is off by default" {
    const opts: Self = .{
        .certificate_der = &.{},
        .signing_key = undefined,
        .server_eph_secret = @splat(0),
        .server_random = @splat(0),
    };

    try std.testing.expectEqual(@as(usize, 0), opts.alpn_prefs.len);
}

test "tlz tls12 connection: HandshakeOptions, keeps the ALPN order" {
    const opts: Self = .{
        .certificate_der = &.{},
        .signing_key = undefined,
        .server_eph_secret = @splat(0),
        .server_random = @splat(0),
        .alpn_prefs = &.{
            .H2,
            .HTTP_1_1,
        },
    };

    try std.testing.expectEqual(Alpn.H2, opts.alpn_prefs[0]);
}

