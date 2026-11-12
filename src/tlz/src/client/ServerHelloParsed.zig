//! TLZ client ServerHelloParsed
//!
//! ### file: src/tlz/src/client/ServerHelloParsed.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The ServerHello fields the client needs: the server random and the server
//! X25519 key share.
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

// --------------------------------------------------------- //
// Fields:

/// The 32-byte ServerHello random.
server_random: [32]u8,
/// The server X25519 public key.
server_public: [32]u8,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz client: ServerHelloParsed, keeps random and key share apart" {
    const parsed: Self = .{
        .server_random = @splat(0x55),
        .server_public = @splat(0x66),
    };

    try std.testing.expectEqual(@as(u8, 0x55), parsed.server_random[0]);
    try std.testing.expectEqual(@as(u8, 0x66), parsed.server_public[0]);
}

