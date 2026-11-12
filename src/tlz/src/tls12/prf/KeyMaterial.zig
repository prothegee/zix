//! TLZ tls12 prf KeyMaterial
//!
//! ### file: src/tlz/src/tls12/prf/KeyMaterial.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The AES-128-GCM write keys and implicit IVs cut out of the TLS 1.2 key_block
//! (RFC 5246 6.3, RFC 5288).
//!
//! ### note:
//!
//! GCM has no MAC keys, so the key_block is 40 bytes: two 16-byte keys, then two
//! 4-byte salts. The IV here is the salt only, the explicit nonce travels per record.
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

client_write_key: [KEY_LENGTH]u8,
server_write_key: [KEY_LENGTH]u8,
client_write_iv: [SALT_LENGTH]u8,
server_write_iv: [SALT_LENGTH]u8,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// AES-128 key length.
pub const KEY_LENGTH = 16;

/// Implicit GCM salt length (RFC 5288 3).
pub const SALT_LENGTH = 4;

/// Bytes of key_block one AES-128-GCM connection consumes.
pub const BLOCK_LENGTH = 2 * KEY_LENGTH + 2 * SALT_LENGTH;

/// Split a key_block in RFC 5246 6.3 order: client key, server key, client IV,
/// server IV.
///
/// Param:
/// block - [BLOCK_LENGTH]u8 (the PRF "key expansion" output)
///
/// Return:
/// - Self
pub fn fromBlock(block: [BLOCK_LENGTH]u8) Self {
    var km: Self = undefined;
    @memcpy(&km.client_write_key, block[0..16]);
    @memcpy(&km.server_write_key, block[16..32]);
    @memcpy(&km.client_write_iv, block[32..36]);
    @memcpy(&km.server_write_iv, block[36..40]);

    return km;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz tls12 prf: KeyMaterial, fromBlock follows the RFC 5246 order" {
    var block: [BLOCK_LENGTH]u8 = undefined;
    for (&block, 0..) |*byte, i| byte.* = @intCast(i);

    const km = fromBlock(block);

    try std.testing.expectEqual(@as(u8, 0), km.client_write_key[0]);
    try std.testing.expectEqual(@as(u8, 16), km.server_write_key[0]);
    try std.testing.expectEqual(@as(u8, 32), km.client_write_iv[0]);
    try std.testing.expectEqual(@as(u8, 39), km.server_write_iv[3]);
}

test "tlz tls12 prf: KeyMaterial, block length is 40 bytes" {
    try std.testing.expectEqual(@as(usize, 40), BLOCK_LENGTH);
}

