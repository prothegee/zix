//! TLZ tls12 prf
//!
//! ### file: src/tlz/src/tls12/prf.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLS 1.2 PRF and key schedule (RFC 5246 5, 6.3, 7.4.9): master_secret, key_block,
//! and Finished verify_data, all on the HMAC-SHA256 PRF.
//!
//! ### note:
//!
//! Distinct from the TLS 1.3 HKDF schedule in `key_schedule.zig`. Only the SHA-256
//! suites are covered.
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

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

// --------------------------------------------------------- //
// Private:

const MAC_LENGTH = HmacSha256.mac_length;

/// The label plus seed buffer: a short label and two 32-byte randoms fit.
const LABEL_SEED_MAX = 256;

/// P_SHA256(secret, seed) (RFC 5246 5): A(0) = seed, A(i) = HMAC(secret, A(i-1)),
/// output = HMAC(secret, A(1) ++ seed) ++ HMAC(secret, A(2) ++ seed) ++ ...
fn pSha256(out: []u8, secret: []const u8, seed: []const u8) void {
    var chain: [MAC_LENGTH]u8 = undefined;
    HmacSha256.create(&chain, seed, secret);

    var offset: usize = 0;
    while (offset < out.len) {
        var block: [MAC_LENGTH]u8 = undefined;
        var ctx = HmacSha256.init(secret);
        ctx.update(&chain);
        ctx.update(seed);
        ctx.final(&block);

        const take = @min(MAC_LENGTH, out.len - offset);
        @memcpy(out[offset .. offset + take], block[0..take]);
        offset += take;

        if (offset < out.len) {
            var next: [MAC_LENGTH]u8 = undefined;
            HmacSha256.create(&next, &chain, secret);
            chain = next;
        }
    }
}

// --------------------------------------------------------- //
// Public:

pub const KeyMaterial = @import("prf/KeyMaterial.zig");

/// master_secret length (RFC 5246 8.1).
pub const MASTER_LENGTH = 48;

/// Finished verify_data length (RFC 5246 7.4.9).
pub const VERIFY_DATA_LENGTH = 12;

/// TLS 1.2 PRF for the SHA-256 suites (RFC 5246 5): P_SHA256(secret, label ++ seed).
///
/// Note:
/// - `label.len + seed.len` must fit 256 bytes. Every caller in tlz passes a short
///   label and at most two 32-byte randoms.
///
/// Param:
/// out - []u8 (filled completely)
/// secret - []const u8 (the PRF secret)
/// label - []const u8 (the ASCII label)
/// seed - []const u8 (the seed after the label)
///
/// Return:
/// - void
pub fn prf(out: []u8, secret: []const u8, label: []const u8, seed: []const u8) void {
    var label_seed: [LABEL_SEED_MAX]u8 = undefined;
    @memcpy(label_seed[0..label.len], label);
    @memcpy(label_seed[label.len .. label.len + seed.len], seed);

    pSha256(out, secret, label_seed[0 .. label.len + seed.len]);
}

/// master_secret = PRF(pre_master, "master secret", client_random ++ server_random)
/// (RFC 5246 8.1).
///
/// Param:
/// pre_master - []const u8 (the ECDHE shared X coordinate)
/// client_random - [32]u8
/// server_random - [32]u8
///
/// Return:
/// - [MASTER_LENGTH]u8
pub fn masterSecret(
    pre_master: []const u8,
    client_random: [32]u8,
    server_random: [32]u8,
) [MASTER_LENGTH]u8 {
    var seed: [64]u8 = undefined;
    @memcpy(seed[0..32], &client_random);
    @memcpy(seed[32..64], &server_random);

    var out: [MASTER_LENGTH]u8 = undefined;
    prf(&out, pre_master, "master secret", &seed);

    return out;
}

/// AES-128-GCM key material from key_block = PRF(master, "key expansion",
/// server_random ++ client_random) (RFC 5246 6.3).
///
/// Note:
/// - The seed puts server_random first here, the reverse of `masterSecret`.
///
/// Param:
/// master - [MASTER_LENGTH]u8 (the master_secret)
/// client_random - [32]u8
/// server_random - [32]u8
///
/// Return:
/// - KeyMaterial
pub fn keyMaterial(
    master: [MASTER_LENGTH]u8,
    client_random: [32]u8,
    server_random: [32]u8,
) KeyMaterial {
    var seed: [64]u8 = undefined;
    @memcpy(seed[0..32], &server_random);
    @memcpy(seed[32..64], &client_random);

    var block: [KeyMaterial.BLOCK_LENGTH]u8 = undefined;
    prf(&block, &master, "key expansion", &seed);

    return KeyMaterial.fromBlock(block);
}

/// Finished verify_data from a transcript hash (RFC 5246 7.4.9):
/// PRF(master, label, hash)[0..12].
///
/// Param:
/// master - [MASTER_LENGTH]u8 (the master_secret)
/// label - []const u8 ("server finished" or "client finished")
/// transcript_hash - [32]u8 (SHA-256 over the handshake messages so far)
///
/// Return:
/// - [VERIFY_DATA_LENGTH]u8
pub fn finishedFromHash(
    master: [MASTER_LENGTH]u8,
    label: []const u8,
    transcript_hash: [32]u8,
) [VERIFY_DATA_LENGTH]u8 {
    var out: [VERIFY_DATA_LENGTH]u8 = undefined;
    prf(&out, &master, label, &transcript_hash);

    return out;
}

/// Finished verify_data over the raw handshake message bytes (hashes them first).
///
/// Param:
/// master - [MASTER_LENGTH]u8 (the master_secret)
/// label - []const u8 ("server finished" or "client finished")
/// transcript - []const u8 (the handshake messages so far, back to back)
///
/// Return:
/// - [VERIFY_DATA_LENGTH]u8
pub fn finished(
    master: [MASTER_LENGTH]u8,
    label: []const u8,
    transcript: []const u8,
) [VERIFY_DATA_LENGTH]u8 {
    var hash: [32]u8 = undefined;
    Sha256.hash(transcript, &hash, .{});

    return finishedFromHash(master, label, hash);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const KAT_SECRET_HEX = "9bbe436ba940f017b17652849a71db35";
const KAT_SEED_HEX = "a0ba9f936cda311827a6f796ffd5198c";
const KAT_OUT_HEX =
    "e3f229ba727be17b8d122620557cd453c2aab21d07c3d495329b52d4e61edb5a6b301791e90d" ++
    "35c9c9a46b4e14baf9af0fa022f7077def17abfd3797c0564bab4fbc91666e9def9b97fce34f79" ++
    "6789baa48082d122ee42c5a72e5a5110fff70187347b66";

test "tlz tls12: prf, matches the 100-byte known-answer vector" {
    var secret: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&secret, KAT_SECRET_HEX);
    var seed: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&seed, KAT_SEED_HEX);
    var expected: [100]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, KAT_OUT_HEX);
    var out: [100]u8 = undefined;

    prf(&out, &secret, "test label", &seed);

    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "tlz tls12: prf, shorter output is a prefix of the longer one" {
    var secret: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&secret, KAT_SECRET_HEX);
    var seed: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&seed, KAT_SEED_HEX);
    var long: [100]u8 = undefined;
    var short: [33]u8 = undefined;

    prf(&long, &secret, "test label", &seed);
    prf(&short, &secret, "test label", &seed);

    try std.testing.expectEqualSlices(u8, long[0..33], &short);
}

test "tlz tls12: prf, empty output writes nothing" {
    var out: [0]u8 = undefined;

    prf(&out, "secret", "label", "seed");
}

test "tlz tls12: prf, keyMaterial splits client and server keys" {
    const pre_master: [32]u8 = @splat(0x5A);
    const master = masterSecret(&pre_master, @splat(0xAA), @splat(0xBB));

    const km = keyMaterial(master, @splat(0xAA), @splat(0xBB));

    try std.testing.expect(!std.mem.eql(u8, &km.client_write_key, &km.server_write_key));
}

test "tlz tls12: prf, masterSecret depends on the random order" {
    const pre_master: [32]u8 = @splat(0x5A);

    const forward = masterSecret(&pre_master, @splat(0xAA), @splat(0xBB));
    const swapped = masterSecret(&pre_master, @splat(0xBB), @splat(0xAA));

    try std.testing.expect(!std.mem.eql(u8, &forward, &swapped));
}

test "tlz tls12: prf, finished is deterministic" {
    const master: [MASTER_LENGTH]u8 = @splat(0x01);

    const first = finished(master, "server finished", "transcript");
    const second = finished(master, "server finished", "transcript");

    try std.testing.expectEqualSlices(u8, &first, &second);
}

test "tlz tls12: prf, finished label separates client and server" {
    const master: [MASTER_LENGTH]u8 = @splat(0x01);

    const server = finished(master, "server finished", "transcript");
    const client = finished(master, "client finished", "transcript");

    try std.testing.expect(!std.mem.eql(u8, &server, &client));
}

test "tlz tls12: prf, finished equals finishedFromHash over the SHA-256" {
    const master: [MASTER_LENGTH]u8 = @splat(0x02);
    var hash: [32]u8 = undefined;
    Sha256.hash("transcript", &hash, .{});

    const direct = finished(master, "client finished", "transcript");
    const from_hash = finishedFromHash(master, "client finished", hash);

    try std.testing.expectEqualSlices(u8, &direct, &from_hash);
}

