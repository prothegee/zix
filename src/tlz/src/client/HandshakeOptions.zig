//! TLZ client HandshakeOptions
//!
//! ### file: src/tlz/src/client/HandshakeOptions.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What the caller supplies to start one TLS 1.3 client handshake: the randoms and
//! the ALPN protocols to offer.
//!
//! ### note:
//!
//! The randoms are injected, fresh per connection in production.
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
const Alpn = @import("../alpn.zig").Alpn;

// --------------------------------------------------------- //
// Fields:

/// The ClientHello random.
client_random: [32]u8,
/// The X25519 ephemeral private key.
ephemeral_secret: [32]u8,
/// ALPN protocols to offer (RFC 7301). Empty offers no ALPN.
alpn: []const Alpn = &.{},

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz client: HandshakeOptions, ALPN defaults to empty" {
    const opts: Self = .{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
    };

    try std.testing.expectEqual(@as(usize, 0), opts.alpn.len);
}

test "tlz client: HandshakeOptions, keeps the offered ALPN" {
    const opts: Self = .{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
        .alpn = &.{.H2},
    };

    try std.testing.expectEqual(Alpn.H2, opts.alpn[0]);
}

