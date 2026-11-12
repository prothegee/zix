//! TLZ crypto rsa
//!
//! ### file: src/tlz/src/crypto/rsa.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! RSA signing primitives (RFC 8017): the EMSA-PKCS1-v1_5 and EMSA-PSS encodings,
//! MGF1, RSASP1, and the CRT half exponentiation.
//!
//! ### note:
//!
//! std verifies RSA but cannot sign. The key record that drives these primitives
//! is `rsa/PrivateKey.zig`. The CRT halves run the constant-time Montgomery modexp
//! for RSA-2048/3072/4096 primes, `std.crypto.ff` for any other width.
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

const Sha256 = std.crypto.hash.sha2.Sha256;

// --------------------------------------------------------- //
// Private:

/// DigestInfo DER prefix for SHA-256 (RFC 8017 9.2). T is this prefix then the hash.
const SHA256_DIGESTINFO_PREFIX = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
    0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
    0x00, 0x04, 0x20,
};

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_Rsa_InvalidKey,
    Tlz_Rsa_MessageTooLong,
};

/// SHA-256 output width.
pub const HASH_LEN = Sha256.digest_length;

/// Salt length for rsa_pss_rsae_sha256 (equals the hash length).
pub const PSS_SALT_LEN = HASH_LEN;

/// Largest supported modulus (RSA-4096). Smaller keys use a prefix of each buffer.
pub const MAX_MODULUS_BITS = 4096;

/// Largest supported modulus in bytes, also the largest signature.
pub const MAX_MODULUS_LEN = MAX_MODULUS_BITS / 8;

/// Largest CRT factor (a prime, half the modulus). p, q, dP, dQ, qInv all fit.
pub const MAX_PRIME_LEN = MAX_MODULUS_LEN / 2;

/// The modular arithmetic type every primitive runs on.
pub const Modulus = std.crypto.ff.Modulus(MAX_MODULUS_BITS);

/// Encode a SHA-256 digest as EMSA-PKCS1-v1_5 (RFC 8017 9.2):
/// EM = 0x00 || 0x01 || PS || 0x00 || T, PS at least eight 0xff bytes.
///
/// Param:
/// digest - [HASH_LEN]u8 (the message hash)
/// em - []u8 (the encoded message, exactly the modulus length)
///
/// Return:
/// - void
/// - Error.Tlz_Rsa_MessageTooLong when `em` is too short for the padding
pub fn emsaPkcs1V15(digest: [HASH_LEN]u8, em: []u8) Error!void {
    const t_len = SHA256_DIGESTINFO_PREFIX.len + HASH_LEN;
    if (em.len < t_len + 11) return Error.Tlz_Rsa_MessageTooLong;

    @memset(em, 0xff);
    em[0] = 0x00;
    em[1] = 0x01;
    em[em.len - t_len - 1] = 0x00;

    const prefix_at = em.len - t_len;
    @memcpy(em[prefix_at..][0..SHA256_DIGESTINFO_PREFIX.len], &SHA256_DIGESTINFO_PREFIX);
    @memcpy(em[em.len - HASH_LEN ..][0..HASH_LEN], &digest);
}

/// Encode a message as EMSA-PSS with SHA-256 and MGF1 (RFC 8017 9.1.1).
///
/// Note:
/// - M' = eight 0x00 || mHash || salt, H = Hash(M'), DB = PS || 0x01 || salt masked
///   with MGF1(H), the top bits cleared, then EM = maskedDB || H || 0xbc.
///
/// Param:
/// message - []const u8 (the bytes to sign, hashed here)
/// salt - [PSS_SALT_LEN]u8 (the caller's random salt)
/// em_bits - usize (modulus bits - 1)
/// em - []u8 (the encoded message, ceil(em_bits / 8) bytes)
///
/// Return:
/// - void
/// - Error.Tlz_Rsa_MessageTooLong when `em` is too short for hash and salt
pub fn emsaPssEncode(
    message: []const u8,
    salt: [PSS_SALT_LEN]u8,
    em_bits: usize,
    em: []u8,
) Error!void {
    const em_len = em.len;
    if (em_len < HASH_LEN + PSS_SALT_LEN + 2) return Error.Tlz_Rsa_MessageTooLong;

    var m_hash: [HASH_LEN]u8 = undefined;
    Sha256.hash(message, &m_hash, .{});

    var h_input: [8 + HASH_LEN + PSS_SALT_LEN]u8 = undefined;
    @memset(h_input[0..8], 0x00);
    @memcpy(h_input[8..][0..HASH_LEN], &m_hash);
    @memcpy(h_input[8 + HASH_LEN ..][0..PSS_SALT_LEN], &salt);

    var hash: [HASH_LEN]u8 = undefined;
    Sha256.hash(&h_input, &hash, .{});

    const db_len = em_len - HASH_LEN - 1;
    const db = em[0..db_len];
    @memset(db, 0x00);
    db[db_len - PSS_SALT_LEN - 1] = 0x01;
    @memcpy(db[db_len - PSS_SALT_LEN ..][0..PSS_SALT_LEN], &salt);

    var db_mask: [MAX_MODULUS_LEN]u8 = undefined;
    mgf1(&hash, db_mask[0..db_len]);
    for (db, 0..) |*byte, i| byte.* ^= db_mask[i];

    const clear_bits = 8 * em_len - em_bits;
    db[0] &= @as(u8, 0xff) >> @intCast(clear_bits);

    @memcpy(em[db_len..][0..HASH_LEN], &hash);
    em[em_len - 1] = 0xbc;
}

/// MGF1 mask generation with SHA-256 (RFC 8017 B.2.1).
///
/// Param:
/// seed - []const u8 (the mask seed)
/// out - []u8 (filled with the mask, any length)
///
/// Return:
/// - void
pub fn mgf1(seed: []const u8, out: []u8) void {
    var counter: u32 = 0;
    var pos: usize = 0;

    while (pos < out.len) : (counter += 1) {
        var counter_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &counter_bytes, counter, .big);

        var digest: [HASH_LEN]u8 = undefined;
        var hasher = Sha256.init(.{});
        hasher.update(seed);
        hasher.update(&counter_bytes);
        hasher.final(&digest);

        const take = @min(HASH_LEN, out.len - pos);
        @memcpy(out[pos..][0..take], digest[0..take]);
        pos += take;
    }
}

/// RSASP1 (RFC 8017 5.2.1): sig = em ^ d mod n, written as k bytes.
///
/// Param:
/// n_bytes - []const u8 (the modulus, big-endian)
/// d_bytes - []const u8 (the private exponent, big-endian)
/// em - []const u8 (the encoded message, below n)
/// sig - []u8 (the signature, exactly k bytes)
///
/// Return:
/// - []const u8 (`sig`)
/// - Error.Tlz_Rsa_InvalidKey when a value does not fit the modulus
pub fn rsasp1(
    n_bytes: []const u8,
    d_bytes: []const u8,
    em: []const u8,
    sig: []u8,
) Error![]const u8 {
    const modulus = Modulus.fromBytes(n_bytes, .big) catch |err| switch (err) {
        else => return Error.Tlz_Rsa_InvalidKey,
    };

    return rsasp1WithModulus(modulus, d_bytes, em, sig);
}

/// RSASP1 against an already-parsed modulus, so the PSS path parses n once.
///
/// Param:
/// modulus - Modulus (the parsed n)
/// d_bytes - []const u8 (the private exponent, big-endian)
/// em - []const u8 (the encoded message, below n)
/// sig - []u8 (the signature, exactly k bytes)
///
/// Return:
/// - []const u8 (`sig`)
/// - Error.Tlz_Rsa_InvalidKey when a value does not fit the modulus
pub fn rsasp1WithModulus(
    modulus: Modulus,
    d_bytes: []const u8,
    em: []const u8,
    sig: []u8,
) Error![]const u8 {
    const m_fe = Modulus.Fe.fromBytes(modulus, em, .big) catch |err| switch (err) {
        else => return Error.Tlz_Rsa_InvalidKey,
    };
    const s_fe = modulus.powWithEncodedExponent(m_fe, d_bytes, .big) catch |err| switch (err) {
        else => return Error.Tlz_Rsa_InvalidKey,
    };

    s_fe.toBytes(sig, .big) catch |err| switch (err) {
        else => return Error.Tlz_Rsa_InvalidKey,
    };

    return sig;
}

/// One CRT half on std.crypto.ff: base ^ exp mod prime. The fallback for primes
/// outside the fixed-width fast path of `rsa/crt.zig`.
///
/// Param:
/// mod - Modulus (the prime field)
/// base_fe - Modulus.Fe (the base, already reduced mod prime)
/// exp_be - []const u8 (the CRT exponent dP or dQ)
///
/// Return:
/// - Modulus.Fe (the half result)
/// - Error.Tlz_Rsa_InvalidKey when the exponentiation fails
pub fn crtHalf(mod: Modulus, base_fe: Modulus.Fe, exp_be: []const u8) Error!Modulus.Fe {
    return mod.powWithEncodedExponent(base_fe, exp_be, .big) catch |err| switch (err) {
        else => Error.Tlz_Rsa_InvalidKey,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz crypto: rsa, emsaPkcs1V15 frames the DigestInfo" {
    const digest: [HASH_LEN]u8 = @splat(0xab);
    var em: [64]u8 = undefined;

    try emsaPkcs1V15(digest, &em);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0xff }, em[0..3]);
    try std.testing.expectEqual(@as(u8, 0x00), em[64 - 51 - 1]);
    try std.testing.expectEqualSlices(u8, &SHA256_DIGESTINFO_PREFIX, em[64 - 51 .. 64 - 32]);
    try std.testing.expectEqualSlices(u8, &digest, em[64 - 32 ..]);
}

test "tlz crypto: rsa, emsaPkcs1V15 below eight padding bytes is too long" {
    const digest: [HASH_LEN]u8 = @splat(0);
    var em: [SHA256_DIGESTINFO_PREFIX.len + HASH_LEN + 10]u8 = undefined;

    try std.testing.expectError(Error.Tlz_Rsa_MessageTooLong, emsaPkcs1V15(digest, &em));
}

test "tlz crypto: rsa, emsaPssEncode ends with 0xbc" {
    const salt: [PSS_SALT_LEN]u8 = @splat(0x5a);
    var em: [256]u8 = undefined;

    try emsaPssEncode("message", salt, 2047, &em);

    try std.testing.expectEqual(@as(u8, 0xbc), em[255]);
}

test "tlz crypto: rsa, emsaPssEncode clears the top bits" {
    const salt: [PSS_SALT_LEN]u8 = @splat(0x5a);
    var em: [256]u8 = undefined;

    try emsaPssEncode("message", salt, 2041, &em);

    try std.testing.expectEqual(@as(u8, 0), em[0] & 0xfe);
}

test "tlz crypto: rsa, emsaPssEncode too short for hash and salt is too long" {
    const salt: [PSS_SALT_LEN]u8 = @splat(0);
    var em: [HASH_LEN + PSS_SALT_LEN + 1]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_Rsa_MessageTooLong,
        emsaPssEncode("message", salt, em.len * 8, &em),
    );
}

test "tlz crypto: rsa, mgf1 first block is SHA-256 of seed and counter zero" {
    var out: [HASH_LEN]u8 = undefined;
    var expected: [HASH_LEN]u8 = undefined;
    Sha256.hash("seed" ++ [_]u8{ 0, 0, 0, 0 }, &expected, .{});

    mgf1("seed", &out);

    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "tlz crypto: rsa, mgf1 fills a length that is not a block multiple" {
    var short: [HASH_LEN + 5]u8 = undefined;
    var long: [HASH_LEN * 2]u8 = undefined;

    mgf1("seed", &short);
    mgf1("seed", &long);

    try std.testing.expectEqualSlices(u8, long[0..short.len], &short);
}

test "tlz crypto: rsa, mgf1 with an empty output writes nothing" {
    var out: [0]u8 = undefined;

    mgf1("seed", &out);
}

test "tlz crypto: rsa, rsasp1 with an even modulus is an invalid key" {
    var sig: [1]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_Rsa_InvalidKey,
        rsasp1(&[_]u8{0x10}, &[_]u8{0x03}, &[_]u8{0x02}, &sig),
    );
}

test "tlz crypto: rsa, rsasp1 computes a small modexp" {
    var sig: [1]u8 = undefined;

    const result = try rsasp1(&[_]u8{33}, &[_]u8{3}, &[_]u8{2}, &sig);

    try std.testing.expectEqual(@as(u8, 8), result[0]);
}

test "tlz crypto: rsa, rsasp1 with em not below n is an invalid key" {
    var sig: [1]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_Rsa_InvalidKey,
        rsasp1(&[_]u8{33}, &[_]u8{3}, &[_]u8{40}, &sig),
    );
}

