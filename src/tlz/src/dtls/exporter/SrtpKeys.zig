//! TLZ dtls exporter SrtpKeys
//!
//! ### file: src/tlz/src/dtls/exporter/SrtpKeys.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The four SRTP master values RFC 5764 4.2 splits the exported bytes into, in wire
//! order: client key, server key, client salt, server salt.
//!
//! ### note:
//!
//! Each side encrypts with its own write key and decrypts with the peer's. A server
//! sending media uses server_write_*, and reads the client's stream with
//! client_write_*.
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

client_write_key: [MASTER_KEY_LEN]u8,
server_write_key: [MASTER_KEY_LEN]u8,
client_write_salt: [MASTER_SALT_LEN]u8,
server_write_salt: [MASTER_SALT_LEN]u8,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// SRTP master key length for the AES-128 profiles, 128 bits (RFC 5764 4.1.2).
pub const MASTER_KEY_LEN: usize = 16;

/// SRTP master salt length for the AES-128 profiles, 112 bits (RFC 5764 4.1.2).
pub const MASTER_SALT_LEN: usize = 14;

/// Bytes of exporter output the split consumes.
pub const MATERIAL_LEN: usize = 2 * (MASTER_KEY_LEN + MASTER_SALT_LEN);

/// Split exporter output in RFC 5764 4.2 order.
///
/// Param:
/// material - [MATERIAL_LEN]u8 (the exporter output for "EXTRACTOR-dtls_srtp")
///
/// Return:
/// - Self
pub fn fromMaterial(material: [MATERIAL_LEN]u8) Self {
    const salts_at = 2 * MASTER_KEY_LEN;

    return .{
        .client_write_key = material[0..MASTER_KEY_LEN].*,
        .server_write_key = material[MASTER_KEY_LEN..salts_at].*,
        .client_write_salt = material[salts_at..][0..MASTER_SALT_LEN].*,
        .server_write_salt = material[salts_at + MASTER_SALT_LEN ..][0..MASTER_SALT_LEN].*,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls exporter: SrtpKeys, fromMaterial splits key key salt salt" {
    var material: [MATERIAL_LEN]u8 = undefined;
    for (&material, 0..) |*byte, i| byte.* = @intCast(i);

    const keys = fromMaterial(material);

    try std.testing.expectEqualSlices(u8, material[0..16], &keys.client_write_key);
    try std.testing.expectEqualSlices(u8, material[16..32], &keys.server_write_key);
    try std.testing.expectEqualSlices(u8, material[32..46], &keys.client_write_salt);
    try std.testing.expectEqualSlices(u8, material[46..60], &keys.server_write_salt);
}

test "tlz dtls exporter: SrtpKeys, MATERIAL_LEN is 60 bytes" {
    try std.testing.expectEqual(@as(usize, 60), MATERIAL_LEN);
}

