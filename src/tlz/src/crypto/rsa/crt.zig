//! TLZ crypto rsa crt
//!
//! ### file: src/tlz/src/crypto/rsa/crt.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! RSASP1 through the Chinese Remainder Theorem (RFC 8017 5.1.2 second form) on
//! Montgomery limbs, for RSA-2048, RSA-3072, and RSA-4096 keys.
//!
//! ### note:
//!
//! Every step stays in fixed-width limbs: m mod p by one reduction, the two half
//! exponentiations, h = (s_p - s_q) * qInv mod p, then s = s_q + q * h with no
//! reduction (s is below n). Constant-time like `montgomery.zig`. Keys outside
//! `supports` take the std.crypto.ff path in `PrivateKey.zig`.
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
const montgomery = @import("../montgomery.zig");

const Limb = montgomery.Limb;

// --------------------------------------------------------- //
// Private:

/// CRT arithmetic for primes of `limbs` limbs.
fn Crt(comptime limbs: usize) type {
    return struct {
        const Half = montgomery.Montgomery(limbs);
        const Full = montgomery.Montgomery(2 * limbs);

        /// `m mod prime` for a 2 * limbs value below prime * R: the reduction gives
        /// m * R^-1, one multiply by R^2 undoes it.
        fn reduceWide(m: Full.Big, prime: Half.Big, n0inv: Limb, r_squared: Half.Big) Half.Big {
            var wide = m;
            const low = Half.redc(&wide, prime, n0inv);

            return Half.mul(low, r_squared, prime, n0inv);
        }

        /// `value mod prime` for a value below 2 * prime.
        fn condSub(value: Half.Big, prime: Half.Big) Half.Big {
            var reduced: Half.Big = undefined;
            const borrow = Half.subInto(&reduced, value, prime);
            const keep: Limb = if (borrow == 1) ~@as(Limb, 0) else 0;

            return Half.ctSelect(keep, value, reduced);
        }

        /// `(lhs - rhs) mod prime` for lhs and rhs below prime.
        fn subMod(lhs: Half.Big, rhs: Half.Big, prime: Half.Big) Half.Big {
            var diff: Half.Big = undefined;
            const borrow = Half.subInto(&diff, lhs, rhs);
            const mask: Limb = if (borrow == 1) ~@as(Limb, 0) else 0;
            const zero: Half.Big = std.mem.zeroes(Half.Big);

            var wrapped: Half.Big = undefined;
            _ = Half.addInto(&wrapped, diff, Half.ctSelect(mask, prime, zero));

            return wrapped;
        }

        /// `q * h + s_q` as 2 * limbs, below n so no reduction.
        fn recombine(q: Half.Big, h: Half.Big, s_q: Half.Big) Full.Big {
            var out: Full.Big = std.mem.zeroes(Full.Big);

            for (0..limbs) |i| {
                var carry: Limb = 0;
                for (0..limbs) |limb| {
                    const product = @as(u128, q[limb]) * h[i] + out[i + limb] + carry;
                    out[i + limb] = @truncate(product);
                    carry = @truncate(product >> 64);
                }

                out[i + limbs] = carry;
            }

            var low: Full.Big = std.mem.zeroes(Full.Big);
            @memcpy(low[0..limbs], &s_q);
            _ = Full.addInto(&out, out, low);

            return out;
        }

        /// One CRT half: `m ^ exp mod prime`.
        fn half(m: Full.Big, prime_be: []const u8, exp_be: []const u8) Half.Big {
            const prime = Half.fromBytes(prime_be);
            const n0inv = Half.n0Inv(prime[0]);
            const r_squared = Half.rSquaredFast(prime, n0inv);
            const m_mod = reduceWide(m, prime, n0inv, r_squared);

            return Half.modExpBig(prime, n0inv, r_squared, m_mod, exp_be);
        }

        fn rsasp(key: Factors, em: []const u8, sig: []u8) []const u8 {
            const m = Full.fromBytes(em);
            const s_p = half(m, key.p, key.dp);
            const s_q = half(m, key.q, key.dq);

            const p = Half.fromBytes(key.p);
            const q = Half.fromBytes(key.q);
            const p_n0inv = Half.n0Inv(p[0]);
            const p_r_squared = Half.rSquaredFast(p, p_n0inv);

            // h = (s_p - s_q) * qInv mod p. qInv * R in, so the multiply leaves qInv
            const qinv_mont = Half.mul(Half.fromBytes(key.qinv), p_r_squared, p, p_n0inv);
            const diff = subMod(s_p, condSub(s_q, p), p);
            const coeff_h = Half.mul(diff, qinv_mont, p, p_n0inv);

            Full.toBytes(recombine(q, coeff_h, s_q), sig);

            return sig;
        }
    };
}

// --------------------------------------------------------- //
// Public:

/// The CRT factors of a two-prime key, big-endian, leading zeros stripped.
pub const Factors = struct {
    p: []const u8,
    q: []const u8,
    dp: []const u8,
    dq: []const u8,
    qinv: []const u8,
};

/// The key has a fixed-width fast path: both primes are 128, 192, or 256 bytes
/// (RSA-2048, 3072, 4096) with the top bit set, qInv fits a prime, and the encoded
/// message fits the modulus.
///
/// Param:
/// key - Factors (the CRT factors)
/// em_len - usize (the encoded message length)
///
/// Return:
/// - bool
pub fn supports(key: Factors, em_len: usize) bool {
    const prime_len = key.p.len;
    const width_ok = prime_len == 128 or prime_len == 192 or prime_len == 256;
    if (!width_ok or key.q.len != prime_len) return false;
    if (key.p[0] & 0x80 == 0 or key.q[0] & 0x80 == 0) return false;

    return key.qinv.len <= prime_len and em_len <= 2 * prime_len;
}

/// RSASP1 via CRT: `sig = em ^ d mod n`, written as `2 * prime_len` bytes.
///
/// Note:
/// - Call `supports` first. The result is only defined for a supported key.
///
/// Param:
/// key - Factors (the CRT factors)
/// em - []const u8 (the encoded message, below n)
/// sig - []u8 (exactly 2 * prime_len bytes, the modulus length)
///
/// Return:
/// - []const u8 (`sig`)
pub fn rsasp(key: Factors, em: []const u8, sig: []u8) []const u8 {
    return switch (key.p.len) {
        128 => Crt(16).rsasp(key, em, sig),
        192 => Crt(24).rsasp(key, em, sig),
        else => Crt(32).rsasp(key, em, sig),
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pem = @import("../pem.zig");
const rsa = @import("../rsa.zig");
const PrivateKey = @import("PrivateKey.zig");
const std_rsa_verify = @import("../std_rsa_verify.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const StdRsa = std.crypto.Certificate.rsa;

/// A deterministic RSA-2048 PKCS#8 key (openssl genpkey).
const RSA_2048_PEM =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDiK/ullhGBT/Mj
    \\s1cQ3b7xqIAtHwMjuTxnUne42qU3cUrEeH2/jWjXjEeBMBqt8TYp1FVpDg+u2DGU
    \\Jada+rtFsPVZkD/07HUGXYfya6hwdwOqwjm+fdI+jIIpM+N1t6Ln+eV75GIu8KEr
    \\uRQVTsR3Rz8uMcIN/apvXP1Tus2Y2ZIhAKX9vk2DvL6+7gCLzK0wJmdQ34aGEw89
    \\MRfQLVmTpFvZSJ2B81dxY+IdgbshiZbbn76pzdH4TvxIOwDpUxW16qY7VXZErMtR
    \\S9jnavMpIB1sTkZLKZyIkowWqeeVWIQG85RreOwiEYywRUYnhI44YBxf0Xmgr1x6
    \\CnJ3atxDAgMBAAECggEACaafz9KF/7MWKG1UJ0OXDL/IbGR44VLbqXsC4c/uod2D
    \\N7v+fah+k0gImxIe6VI0IffOBzQS5j6SawRqTj8Js7EX3xEBMaXPXoyqKuV+JAJo
    \\FSbBiQfca0/alACDUbgayvRGXxGBQQiCkBePLFOWnZJcN0/nPGqZFbRtmN+NO1rk
    \\zTD46uKfBAFMKZLbWrK8plECMfea5h+/ysnfhpZXv5nAXuPY6cvwgDTZvphQdB4l
    \\4mjAtuI6oEYUL4CVga1NE57vC02RxJBwylmxznJyJcRdLl52kSgOMU3xV9isrrZT
    \\88s9Ds5ZxtGqaWUmbF+pHW1wxzTmJhrCXxEGtsrmAQKBgQD5u1KiuTlPnnVgIRfT
    \\thzF5pBp6Ynwbw/Q0SMkF/E7yxkPDdLWMY43WIikRj9IyfDnIRxdGEBkprF7/Sm/
    \\ehGVGRDNNT3eRaZ04jLP/EbksO9hF49ro/FlHSaaVrDSAsW3F8HBp8NQC9Sgpdlf
    \\XwnxZsP35wpISF1hWV5be0yWAQKBgQDn2UYCjGCRFdBNdsqxbgGemPBu60/U0leE
    \\T8xg42jN6tO2j0vesKp83NFcAl71NYh7rl8G+WnFJ3DgrjrFAPbTa6VJdnNnpjV+
    \\3o2CSqSTAReFM2khRIZodCbQ3Ad/6P00RnahpciBemQsQKeyGRMrhrkBZbiPIWch
    \\LgBIniOaQwKBgGcmxsVL+K44Z4cjZDIgoNXlnHUC7+UOGtxH5ln8QbpO87TSIuoy
    \\YeneeeJQ2cb5EraFaK/TWpW4fMsYEOx0QVrylYwNl9Z9snnJDO/35liD9PyHvMfb
    \\WdRILC/H6xVz67Lq7y9MWlJv8I3Cs3y/Rt4dcoitOAQPT/Lr9RuYXFQBAoGBAM0U
    \\QXsrlJeBRhnfQ/eiKMiS28ohVyIXVNZyh4QEY8YRO2g2ZJP8jTGZWY8bgcdArRNJ
    \\8ECJCegctRnow49TBQGKLFBI+Ffsi1FHpsBjKiPmSVnHWezVYlaut07z8aZQ/vfo
    \\hDMEI9Fz43vJTQyaZXyQ1MDJq3DfyQtuV03ko/VlAoGBAJiRuT9T8EQO0gJoaS6g
    \\W/+g7A+JUZnqIrCiL9JAaWzOy4TdKtEgbDQsLH1NfVclcnti5C/6wlCqvPcSQtF/
    \\ZGgEuI4ajyq60Un5tOiB1rbJ5sahSLgpM21Ph6kkC6nxTuKfRPpu1+L92SFZBFrX
    \\sIWllpzoV5pFqYoMGir8MZfp
    \\-----END PRIVATE KEY-----
;

/// A deterministic RSA-3072 PKCS#8 key (openssl genpkey).
const RSA_3072_PEM =
    \\-----BEGIN PRIVATE KEY-----
    \\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
    \\IAfTfyG8PQufI3LxN7tWqvo=
    \\-----END PRIVATE KEY-----
;

/// A deterministic RSA-4096 PKCS#8 key (openssl genpkey).
const RSA_4096_PEM =
    \\-----BEGIN PRIVATE KEY-----
    \\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
    \\TSV5doYq6iDARzgCgXNii6WY25uZ5g==
    \\-----END PRIVATE KEY-----
;

fn loadKey(comptime key_pem: []const u8) !PrivateKey {
    var der_buf: [4096]u8 = undefined;
    const der = try pem.pemToDer(&der_buf, key_pem);

    return PrivateKey.fromDer(der, true);
}

fn factorsOf(key: *const PrivateKey) Factors {
    return .{
        .p = key.primeP(),
        .q = key.primeQ(),
        .dp = key.expDp(),
        .dq = key.expDq(),
        .qinv = key.coeffQinv(),
    };
}

/// PSS-encode a message for `key_pem`, sign it here, and verify it with std.
fn expectStdVerifies(comptime modulus_len: usize, comptime key_pem: []const u8) !void {
    const key = try loadKey(key_pem);
    const salt: [rsa.PSS_SALT_LEN]u8 = @splat(0x5a);
    var em_buf: [modulus_len]u8 = undefined;
    const em_bits = modulus_len * 8 - @clz(key.modulus()[0]) - 1;
    const em = em_buf[0 .. (em_bits + 7) / 8];
    try rsa.emsaPssEncode("tlz crt", salt, em_bits, em);
    var sig: [modulus_len]u8 = undefined;

    try std.testing.expect(supports(factorsOf(&key), em.len));
    _ = rsasp(factorsOf(&key), em, &sig);

    const public_key = try StdRsa.PublicKey.fromBytes(&[_]u8{ 0x01, 0x00, 0x01 }, key.modulus());
    try std_rsa_verify.verifyPss(modulus_len, &sig, "tlz crt", public_key, Sha256);
}

test "tlz crypto rsa: crt, RSA-2048 signature equals the plain m^d path" {
    const key = try loadKey(RSA_2048_PEM);
    var em: [256]u8 = undefined;
    for (&em, 0..) |*byte, i| byte.* = @truncate(i *% 31 + 7);
    em[0] = 0x01;
    var fast: [256]u8 = undefined;
    var plain: [256]u8 = undefined;

    _ = rsasp(factorsOf(&key), &em, &fast);
    _ = try rsa.rsasp1(key.modulus(), key.privateExponent(), &em, &plain);

    try std.testing.expectEqualSlices(u8, &plain, &fast);
}

test "tlz crypto rsa: crt, RSA-2048 PSS signature verifies with std" {
    try expectStdVerifies(256, RSA_2048_PEM);
}

test "tlz crypto rsa: crt, RSA-3072 PSS signature verifies with std" {
    try expectStdVerifies(384, RSA_3072_PEM);
}

test "tlz crypto rsa: crt, RSA-4096 PSS signature verifies with std" {
    try expectStdVerifies(512, RSA_4096_PEM);
}

test "tlz crypto rsa: crt, supports the three fixed widths" {
    const key = try loadKey(RSA_3072_PEM);

    try std.testing.expect(supports(factorsOf(&key), 384));
}

test "tlz crypto rsa: crt, prime without the top bit is not supported" {
    const prime: [128]u8 = @splat(0x7f);
    const factors: Factors = .{
        .p = &prime,
        .q = &prime,
        .dp = &prime,
        .dq = &prime,
        .qinv = &prime,
    };

    try std.testing.expect(!supports(factors, 256));
}

test "tlz crypto rsa: crt, other prime width is not supported" {
    const prime: [96]u8 = @splat(0xff);
    const factors: Factors = .{
        .p = &prime,
        .q = &prime,
        .dp = &prime,
        .dq = &prime,
        .qinv = &prime,
    };

    try std.testing.expect(!supports(factors, 192));
}

test "tlz crypto rsa: crt, encoded message wider than the modulus is not supported" {
    const key = try loadKey(RSA_2048_PEM);

    try std.testing.expect(!supports(factorsOf(&key), 257));
}

test "tlz crypto rsa: crt, subMod wraps a negative difference" {
    const Math = Crt(16);
    var prime: Math.Half.Big = @splat(0);
    prime[0] = 97;
    var lhs: Math.Half.Big = @splat(0);
    lhs[0] = 5;
    var rhs: Math.Half.Big = @splat(0);
    rhs[0] = 9;

    const result = Math.subMod(lhs, rhs, prime);

    try std.testing.expectEqual(@as(Limb, 93), result[0]);
    try std.testing.expectEqual(@as(Limb, 0), result[1]);
}

test "tlz crypto rsa: crt, condSub reduces only at or above the prime" {
    const Math = Crt(16);
    var prime: Math.Half.Big = @splat(0);
    prime[0] = 97;
    var below: Math.Half.Big = @splat(0);
    below[0] = 96;
    var above: Math.Half.Big = @splat(0);
    above[0] = 100;

    try std.testing.expectEqual(@as(Limb, 96), Math.condSub(below, prime)[0]);
    try std.testing.expectEqual(@as(Limb, 3), Math.condSub(above, prime)[0]);
}

test "tlz crypto rsa: crt, recombine is q * h + s_q" {
    const Math = Crt(16);
    var q: Math.Half.Big = @splat(0);
    q[0] = ~@as(Limb, 0);
    var coeff_h: Math.Half.Big = @splat(0);
    coeff_h[0] = 2;
    var s_q: Math.Half.Big = @splat(0);
    s_q[0] = 3;

    const result = Math.recombine(q, coeff_h, s_q);

    try std.testing.expectEqual(@as(Limb, 1), result[0]);
    try std.testing.expectEqual(@as(Limb, 2), result[1]);
}

