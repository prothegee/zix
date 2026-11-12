//! TLZ connection KeyExchange
//!
//! ### file: src/tlz/src/connection/KeyExchange.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The ephemeral ECDHE result of one handshake: the server public key for the
//! ServerHello key_share and the 32-byte shared secret.
//!
//! ### note:
//!
//! The public key is 32 bytes for X25519 and 65 bytes (uncompressed) for
//! secp256r1, so `server_public_len` says how much of the buffer is set.
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

/// The server public key, the first `server_public_len` bytes are set.
server_public: [65]u8,
server_public_len: usize,
/// The ECDHE shared secret.
shared: [32]u8,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// The server public key bytes for the ServerHello key_share.
///
/// Return:
/// - []const u8
pub fn serverPublic(self: *const Self) []const u8 {
    return self.server_public[0..self.server_public_len];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz connection: KeyExchange, serverPublic returns the X25519 width" {
    const kex: Self = .{
        .server_public = @splat(0x11),
        .server_public_len = 32,
        .shared = @splat(0),
    };

    try std.testing.expectEqual(@as(usize, 32), kex.serverPublic().len);
}

test "tlz connection: KeyExchange, serverPublic returns the secp256r1 width" {
    const kex: Self = .{
        .server_public = @splat(0x04),
        .server_public_len = 65,
        .shared = @splat(0),
    };

    try std.testing.expectEqual(@as(usize, 65), kex.serverPublic().len);
}

