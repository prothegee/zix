//! TLZ crypto montgomery
//!
//! ### file: src/tlz/src/crypto/montgomery.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Constant-time Montgomery arithmetic for the RSA private key operation: multiply,
//! dedicated square, reduction, and a fixed-window modular exponentiation.
//!
//! ### note:
//!
//! Constant-time by construction: fixed iteration counts, every conditional
//! subtract is a masked select, and the window table is read by a masked scan. No
//! secret value steers control flow or a memory address. On x86_64 with ADX the
//! multiply and the square run the asm of `montgomery/asm_body.zig`, elsewhere a
//! portable CIOS multiply serves both. Both give identical bytes.
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
const builtin = @import("builtin");
const asm_body = @import("montgomery/asm_body.zig");

// --------------------------------------------------------- //
// Private:

const LIMB_BITS = 64;

/// The target is x86_64 with ADX, so the dual-carry asm can be assembled.
const USE_ADX = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .adx);

// --------------------------------------------------------- //
// Public:

/// One 64-bit limb.
pub const Limb = u64;

/// Montgomery arithmetic over a fixed odd modulus of `limbs` 64-bit limbs.
///
/// Usage:
/// ```zig
/// // An RSA-2048 prime is 1024 bits, so 16 limbs
/// const Mont = montgomery.Montgomery(16);
/// const prime = Mont.fromBytes(prime_be);
/// const n0inv = Mont.n0Inv(prime[0]);
/// const r_squared = Mont.rSquaredFast(prime, n0inv);
/// const result = Mont.modExpBig(prime, n0inv, r_squared, base, exp_be);
/// ```
///
/// Param:
/// limbs - usize (comptime, the modulus width / 64)
///
/// Return:
/// - type (the namespace of the arithmetic for that width)
pub fn Montgomery(comptime limbs: usize) type {
    return struct {
        const LIMBS = limbs;

        /// Exponent window width: 5 bits for the wider primes, where the saved
        /// multiplies outweigh the larger table read.
        const WINDOW: usize = if (LIMBS >= 24) 5 else 4;
        const TABLE_LEN: usize = 1 << WINDOW;

        /// `(value << 1) mod n` via one masked conditional subtract.
        fn modDouble(value: Big, n: Big) Big {
            var carry: u1 = 0;
            var doubled: Big = undefined;

            for (0..LIMBS) |i| {
                const high: u1 = @truncate(value[i] >> 63);
                doubled[i] = (value[i] << 1) | carry;
                carry = high;
            }

            var reduced: Big = undefined;
            const borrow = subInto(&reduced, doubled, n);
            const ge_n: Limb = if (carry == 1 or borrow == 0) ~@as(Limb, 0) else 0;

            return ctSelect(ge_n, reduced, doubled);
        }

        /// `R^2 mod n`, R = 2^(64 * LIMBS), by doubling 1 up 2 * 64 * LIMBS times.
        /// The slow fallback of `rSquaredFast`.
        fn rSquared(n: Big) Big {
            var result: Big = std.mem.zeroes(Big);
            result[0] = 1;

            var i: usize = 0;
            while (i < 2 * LIMB_BITS * LIMBS) : (i += 1) result = modDouble(result, n);

            return result;
        }

        /// Portable CIOS multiply.
        fn mulPortable(lhs: Big, rhs: Big, n: Big, n0inv: Limb) Big {
            var acc = std.mem.zeroes([LIMBS + 2]Limb);

            for (0..LIMBS) |i| {
                // acc += lhs * rhs[i]
                var carry: Limb = 0;
                for (0..LIMBS) |limb| {
                    const product = @as(u128, lhs[limb]) * @as(u128, rhs[i]) +
                        @as(u128, acc[limb]) + @as(u128, carry);
                    acc[limb] = @truncate(product);
                    carry = @truncate(product >> 64);
                }

                const top_sum = @addWithOverflow(acc[LIMBS], carry);
                acc[LIMBS] = top_sum[0];
                acc[LIMBS + 1] = top_sum[1];

                // factor = acc[0] * n0inv mod 2^64, acc += factor * n, acc >>= one limb
                const factor: Limb = acc[0] *% n0inv;
                const low = @as(u128, factor) * @as(u128, n[0]) + @as(u128, acc[0]);
                var reduce_carry: Limb = @truncate(low >> 64);

                for (1..LIMBS) |limb| {
                    const product = @as(u128, factor) * @as(u128, n[limb]) +
                        @as(u128, acc[limb]) + @as(u128, reduce_carry);
                    acc[limb - 1] = @truncate(product);
                    reduce_carry = @truncate(product >> 64);
                }

                const shift_sum = @addWithOverflow(acc[LIMBS], reduce_carry);
                acc[LIMBS - 1] = shift_sum[0];
                acc[LIMBS] = acc[LIMBS + 1] + shift_sum[1];
            }

            return finalReduce(acc[0..LIMBS], acc[LIMBS], n);
        }

        /// Fused dual-carry CIOS multiply (x86_64 with ADX).
        fn mulAsm(lhs: Big, rhs: Big, n: Big, n0inv: Limb) Big {
            var acc = std.mem.zeroes([LIMBS + 2]Limb);
            const body = comptime asm_body.mulBody(LIMBS);

            asm volatile (body
                :
                : [acc] "{rdi}" (&acc),
                  [lhs] "{rsi}" (&lhs),
                  [rhs] "{r12}" (&rhs),
                  [n] "{r13}" (&n),
                  [n0inv] "{r14}" (n0inv),
                : .{
                  .rax = true,
                  .rdx = true,
                  .r8 = true,
                  .r9 = true,
                  .r10 = true,
                  .r11 = true,
                  .r15 = true,
                  .memory = true,
                  .cc = true,
                });

            return finalReduce(acc[0..LIMBS], acc[LIMBS], n);
        }

        /// Dedicated square (x86_64 with ADX).
        fn sqrAsm(value: Big, n: Big, n0inv: Limb) Big {
            var acc = std.mem.zeroes([2 * LIMBS + 1]Limb);
            const body = comptime asm_body.sqrBody(LIMBS);

            asm volatile (body
                :
                : [acc] "{rdi}" (&acc),
                  [value] "{rsi}" (&value),
                  [n] "{r13}" (&n),
                  [n0inv] "{r14}" (n0inv),
                : .{
                  .rax = true,
                  .rcx = true,
                  .rdx = true,
                  .r8 = true,
                  .r9 = true,
                  .r10 = true,
                  .r11 = true,
                  .r12 = true,
                  .r15 = true,
                  .memory = true,
                  .cc = true,
                });

            return finalReduce(acc[LIMBS .. 2 * LIMBS], acc[2 * LIMBS], n);
        }

        /// Final reduction: the value in `acc` (with a possible top word) is below
        /// 2n, so one masked subtract gives the residue.
        fn finalReduce(acc: *const [LIMBS]Limb, top: Limb, n: Big) Big {
            var result: Big = undefined;
            @memcpy(result[0..LIMBS], acc);

            var reduced: Big = undefined;
            const borrow = subInto(&reduced, result, n);
            const ge_n: Limb = if (top != 0 or borrow == 0) ~@as(Limb, 0) else 0;

            return ctSelect(ge_n, reduced, result);
        }

        /// Constant-time window read: `table[index]` by a masked scan over every
        /// entry, one vector op per entry.
        fn gather(table: *const [TABLE_LEN]Big, index: usize) Big {
            const Vec = @Vector(LIMBS, Limb);
            var result: Vec = @splat(0);

            for (0..TABLE_LEN) |entry| {
                const mask: Limb = if (entry == index) ~@as(Limb, 0) else 0;
                const row: Vec = table[entry];
                result |= row & @as(Vec, @splat(mask));
            }

            return result;
        }

        /// `width` exponent bits starting `pos` bits from the most significant end.
        /// The positions come from the exponent length (public), only the bit values
        /// are secret.
        fn windowBits(exp_be: []const u8, pos: usize, width: usize) usize {
            var value: usize = 0;

            for (0..width) |offset| {
                const bit_index = pos + offset;
                const byte = exp_be[bit_index / 8];
                const bit = (byte >> @intCast(7 - bit_index % 8)) & 1;
                value = (value << 1) | bit;
            }

            return value;
        }

        /// Little-endian limbs: `Big[0]` is the least significant.
        pub const Big = [LIMBS]Limb;

        /// `result = lhs - rhs`, returns the borrow out of the top limb.
        ///
        /// Return:
        /// - u1 (1 when rhs > lhs)
        pub fn subInto(result: *Big, lhs: Big, rhs: Big) u1 {
            var borrow: u1 = 0;

            for (0..LIMBS) |i| {
                const first = @subWithOverflow(lhs[i], rhs[i]);
                const second = @subWithOverflow(first[0], borrow);
                result[i] = second[0];
                borrow = first[1] | second[1];
            }

            return borrow;
        }

        /// `result = lhs + rhs`, returns the carry out of the top limb.
        ///
        /// Return:
        /// - u1 (1 on overflow)
        pub fn addInto(result: *Big, lhs: Big, rhs: Big) u1 {
            var carry: u1 = 0;

            for (0..LIMBS) |i| {
                const first = @addWithOverflow(lhs[i], rhs[i]);
                const second = @addWithOverflow(first[0], carry);
                result[i] = second[0];
                carry = first[1] | second[1];
            }

            return carry;
        }

        /// Constant-time select: an all-ones `mask` picks `picked`, all-zero picks
        /// `other`.
        ///
        /// Return:
        /// - Big
        pub fn ctSelect(mask: Limb, picked: Big, other: Big) Big {
            var result: Big = undefined;
            for (0..LIMBS) |i| result[i] = (picked[i] & mask) | (other[i] & ~mask);

            return result;
        }

        /// `-n0^-1 mod 2^64` via Newton iteration (n0 is odd for an odd modulus).
        ///
        /// Return:
        /// - Limb
        pub fn n0Inv(n0: Limb) Limb {
            var inverse: Limb = 1;
            inline for (0..6) |_| {
                inverse = inverse *% (2 -% n0 *% inverse);
            }

            return 0 -% inverse;
        }

        /// `R^2 mod n` in about ten operations when the top bit of `n` is set:
        /// R mod n is R - n, then doublings and Montgomery squares reach R * R
        /// (mont(R * 2^j, R * 2^j) = R * 2^(2j)).
        ///
        /// Note:
        /// - A modulus without its top bit set takes the slow doubling path.
        ///
        /// Return:
        /// - Big
        pub fn rSquaredFast(n: Big, n0inv: Limb) Big {
            if (n[LIMBS - 1] >> 63 == 0) return rSquared(n);

            const total_bits = LIMB_BITS * LIMBS;
            const squarings = @ctz(@as(usize, total_bits));
            const doublings = total_bits >> squarings;

            var value: Big = undefined;
            _ = subInto(&value, std.mem.zeroes(Big), n);

            for (0..doublings) |_| value = modDouble(value, n);
            for (0..squarings) |_| value = sqr(value, n, n0inv);

            return value;
        }

        /// `lhs * rhs * R^-1 mod n` (CIOS), the asm path on x86_64 with ADX.
        ///
        /// Return:
        /// - Big
        pub fn mul(lhs: Big, rhs: Big, n: Big, n0inv: Limb) Big {
            if (USE_ADX) return mulAsm(lhs, rhs, n, n0inv);

            return mulPortable(lhs, rhs, n, n0inv);
        }

        /// `value * value * R^-1 mod n`, the dedicated square on x86_64 with ADX.
        ///
        /// Return:
        /// - Big
        pub fn sqr(value: Big, n: Big, n0inv: Limb) Big {
            if (USE_ADX) return sqrAsm(value, n, n0inv);

            return mulPortable(value, value, n, n0inv);
        }

        /// Montgomery reduction of a 2 * LIMBS value: `wide * R^-1 mod n`.
        ///
        /// Note:
        /// - `wide` must be below n * R. `wide` is used as scratch.
        ///
        /// Return:
        /// - Big
        pub fn redc(wide: *[2 * LIMBS]Limb, n: Big, n0inv: Limb) Big {
            var top: Limb = 0;

            for (0..LIMBS) |i| {
                const factor: Limb = wide[i] *% n0inv;
                var carry: Limb = 0;

                for (0..LIMBS) |limb| {
                    const product = @as(u128, factor) * n[limb] + wide[i + limb] + carry;
                    wide[i + limb] = @truncate(product);
                    carry = @truncate(product >> 64);
                }

                const sum = @as(u128, wide[i + LIMBS]) + carry + top;
                wide[i + LIMBS] = @truncate(sum);
                top = @truncate(sum >> 64);
            }

            return finalReduce(wide[LIMBS .. 2 * LIMBS], top, n);
        }

        /// `base ^ exp mod n` with `n0inv` and `r_squared` precomputed. Fixed window:
        /// every window squares WINDOW times and multiplies by a masked table read,
        /// with no leading-zero skip.
        ///
        /// Param:
        /// n - Big (the odd modulus)
        /// n0inv - Limb (from `n0Inv`)
        /// r_squared - Big (from `rSquaredFast`)
        /// base - Big (below n, normal form)
        /// exp_be - []const u8 (the exponent, big-endian)
        ///
        /// Return:
        /// - Big (normal form, below n)
        pub fn modExpBig(
            n: Big,
            n0inv: Limb,
            r_squared: Big,
            base: Big,
            exp_be: []const u8,
        ) Big {
            var one: Big = std.mem.zeroes(Big);
            one[0] = 1;

            var table: [TABLE_LEN]Big = undefined;
            table[0] = mul(one, r_squared, n, n0inv);
            table[1] = mul(base, r_squared, n, n0inv);
            for (2..TABLE_LEN) |entry| {
                table[entry] = if (entry % 2 == 0)
                    sqr(table[entry / 2], n, n0inv)
                else
                    mul(table[entry - 1], table[1], n, n0inv);
            }

            const total_bits = exp_be.len * 8;
            if (total_bits == 0) return mul(table[0], one, n, n0inv);

            const first = if (total_bits % WINDOW == 0) WINDOW else total_bits % WINDOW;
            var acc = gather(&table, windowBits(exp_be, 0, first));

            var pos = first;
            while (pos < total_bits) : (pos += WINDOW) {
                inline for (0..WINDOW) |_| acc = sqr(acc, n, n0inv);

                acc = mul(acc, gather(&table, windowBits(exp_be, pos, WINDOW)), n, n0inv);
            }

            return mul(acc, one, n, n0inv);
        }

        /// Big-endian bytes to limbs. Bytes above the limb width are dropped.
        ///
        /// Return:
        /// - Big
        pub fn fromBytes(bytes: []const u8) Big {
            var result: Big = std.mem.zeroes(Big);

            var i: usize = 0;
            while (i < bytes.len) : (i += 1) {
                const index = (bytes.len - 1 - i) / 8;
                const offset = (bytes.len - 1 - i) % 8;
                if (index < LIMBS) result[index] |= @as(Limb, bytes[i]) << @intCast(offset * 8);
            }

            return result;
        }

        /// Limbs to big-endian bytes, right-aligned in `out`.
        ///
        /// Return:
        /// - void
        pub fn toBytes(value: Big, out: []u8) void {
            @memset(out, 0);

            for (0..LIMBS) |i| {
                for (0..8) |byte_index| {
                    const pos = i * 8 + byte_index;
                    if (pos < out.len) {
                        out[out.len - 1 - pos] = @truncate(value[i] >> @intCast(byte_index * 8));
                    }
                }
            }
        }
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// A random odd modulus with its top bit set, and a base below it.
fn randomOperands(
    comptime bytes_len: usize,
    rand: std.Random,
    n_bytes: *[bytes_len]u8,
    base_bytes: *[bytes_len]u8,
) void {
    rand.bytes(n_bytes);
    n_bytes[0] |= 0x80;
    n_bytes[bytes_len - 1] |= 0x01;

    rand.bytes(base_bytes);
    base_bytes[0] &= 0x7f;
}

/// Run modExpBig on byte operands and write the result big-endian.
fn modExpBytes(
    comptime limbs: usize,
    n_bytes: []const u8,
    base_bytes: []const u8,
    exp_bytes: []const u8,
    out: []u8,
) void {
    const Mont = Montgomery(limbs);
    const n = Mont.fromBytes(n_bytes);
    const n0inv = Mont.n0Inv(n[0]);
    const r_squared = Mont.rSquaredFast(n, n0inv);
    const result = Mont.modExpBig(n, n0inv, r_squared, Mont.fromBytes(base_bytes), exp_bytes);

    Mont.toBytes(result, out);
}

/// Check modExpBig against std.crypto.ff for random odd moduli at one width.
fn fuzzAgainstFf(comptime bits: usize, trials: usize, seed: u64) !void {
    const bytes_len = bits / 8;
    const Mod = std.crypto.ff.Modulus(bits);

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    for (0..trials) |_| {
        var n_bytes: [bytes_len]u8 = undefined;
        var base_bytes: [bytes_len]u8 = undefined;
        var exp_bytes: [bytes_len]u8 = undefined;
        randomOperands(bytes_len, rand, &n_bytes, &base_bytes);
        rand.bytes(&exp_bytes);

        const mod = try Mod.fromBytes(&n_bytes, .big);
        const base_fe = try Mod.Fe.fromBytes(mod, &base_bytes, .big);
        const ref_fe = try mod.powWithEncodedExponent(base_fe, &exp_bytes, .big);
        var ref_out: [bytes_len]u8 = undefined;
        try ref_fe.toBytes(&ref_out, .big);

        var got: [bytes_len]u8 = undefined;
        modExpBytes(bits / 64, &n_bytes, &base_bytes, &exp_bytes, &got);

        try std.testing.expectEqualSlices(u8, &ref_out, &got);
    }
}

/// Check the square and the multiply paths agree with the portable multiply.
fn fuzzSquare(comptime limbs: usize, trials: usize, seed: u64) !void {
    const Mont = Montgomery(limbs);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    for (0..trials) |_| {
        var n_bytes: [limbs * 8]u8 = undefined;
        var base_bytes: [limbs * 8]u8 = undefined;
        randomOperands(limbs * 8, rand, &n_bytes, &base_bytes);
        const n = Mont.fromBytes(&n_bytes);
        const n0inv = Mont.n0Inv(n[0]);
        const value = Mont.fromBytes(&base_bytes);

        const expected = Mont.mulPortable(value, value, n, n0inv);

        try std.testing.expectEqualSlices(Limb, &expected, &Mont.sqr(value, n, n0inv));
        try std.testing.expectEqualSlices(Limb, &expected, &Mont.mul(value, value, n, n0inv));
    }
}

test "tlz crypto: montgomery, 1024-bit modExpBig matches std.crypto.ff" {
    try fuzzAgainstFf(1024, 64, 0x515a1);
}

test "tlz crypto: montgomery, 1536-bit modExpBig matches std.crypto.ff" {
    try fuzzAgainstFf(1536, 24, 0x6c0de);
}

test "tlz crypto: montgomery, 2048-bit modExpBig matches std.crypto.ff" {
    try fuzzAgainstFf(2048, 12, 0xa11ce);
}

test "tlz crypto: montgomery, 16-limb square matches the portable multiply" {
    try fuzzSquare(16, 2000, 0x16);
}

test "tlz crypto: montgomery, 24-limb square matches the portable multiply" {
    try fuzzSquare(24, 1000, 0x24);
}

test "tlz crypto: montgomery, 32-limb square matches the portable multiply" {
    try fuzzSquare(32, 1000, 0x32);
}

test "tlz crypto: montgomery, base near the modulus matches std.crypto.ff" {
    const bits = 1024;
    const bytes_len = bits / 8;
    const Mod = std.crypto.ff.Modulus(bits);
    const n_bytes: [bytes_len]u8 = @splat(0xff);
    var base_bytes = n_bytes;
    base_bytes[bytes_len - 1] -= 2;
    const exp_bytes: [bytes_len]u8 = @splat(0xff);

    const mod = try Mod.fromBytes(&n_bytes, .big);
    const base_fe = try Mod.Fe.fromBytes(mod, &base_bytes, .big);
    const ref_fe = try mod.powWithEncodedExponent(base_fe, &exp_bytes, .big);
    var ref_out: [bytes_len]u8 = undefined;
    try ref_fe.toBytes(&ref_out, .big);
    var got: [bytes_len]u8 = undefined;

    modExpBytes(16, &n_bytes, &base_bytes, &exp_bytes, &got);

    try std.testing.expectEqualSlices(u8, &ref_out, &got);
}

test "tlz crypto: montgomery, zero exponent gives one" {
    const n_bytes: [128]u8 = @splat(0xff);
    var base_bytes: [128]u8 = @splat(0);
    base_bytes[127] = 7;
    var got: [128]u8 = undefined;

    modExpBytes(16, &n_bytes, &base_bytes, &[_]u8{0x00}, &got);

    var expected: [128]u8 = @splat(0);
    expected[127] = 1;
    try std.testing.expectEqualSlices(u8, &expected, &got);
}

test "tlz crypto: montgomery, empty exponent gives one" {
    const n_bytes: [128]u8 = @splat(0xff);
    var base_bytes: [128]u8 = @splat(0);
    base_bytes[127] = 7;
    var got: [128]u8 = undefined;

    modExpBytes(16, &n_bytes, &base_bytes, &.{}, &got);

    try std.testing.expectEqual(@as(u8, 1), got[127]);
}

test "tlz crypto: montgomery, exponent one gives the base" {
    const n_bytes: [192]u8 = @splat(0xff);
    var base_bytes: [192]u8 = @splat(0);
    base_bytes[100] = 0x5a;
    var got: [192]u8 = undefined;

    modExpBytes(24, &n_bytes, &base_bytes, &[_]u8{0x01}, &got);

    try std.testing.expectEqualSlices(u8, &base_bytes, &got);
}

test "tlz crypto: montgomery, rSquaredFast matches the doubling path" {
    const Mont = Montgomery(16);
    var prng = std.Random.DefaultPrng.init(0x22);
    var n_bytes: [128]u8 = undefined;
    var base_bytes: [128]u8 = undefined;
    randomOperands(128, prng.random(), &n_bytes, &base_bytes);
    const n = Mont.fromBytes(&n_bytes);

    const fast = Mont.rSquaredFast(n, Mont.n0Inv(n[0]));

    try std.testing.expectEqualSlices(Limb, &Mont.rSquared(n), &fast);
}

test "tlz crypto: montgomery, rSquaredFast without the top bit falls back" {
    const Mont = Montgomery(16);
    var n_bytes: [128]u8 = @splat(0x33);
    n_bytes[127] |= 1;
    const n = Mont.fromBytes(&n_bytes);

    const fast = Mont.rSquaredFast(n, Mont.n0Inv(n[0]));

    try std.testing.expectEqualSlices(Limb, &Mont.rSquared(n), &fast);
}

test "tlz crypto: montgomery, redc of a low value equals a multiply by one" {
    const Mont = Montgomery(16);
    const n_bytes: [128]u8 = @splat(0xf1);
    const n = Mont.fromBytes(&n_bytes);
    const n0inv = Mont.n0Inv(n[0]);
    var value: Mont.Big = @splat(0x0102030405060708);
    value[15] = 0x1234;
    var one: Mont.Big = std.mem.zeroes(Mont.Big);
    one[0] = 1;
    var wide = std.mem.zeroes([32]Limb);
    @memcpy(wide[0..16], &value);

    const reduced = Mont.redc(&wide, n, n0inv);

    try std.testing.expectEqualSlices(Limb, &Mont.mul(value, one, n, n0inv), &reduced);
}

test "tlz crypto: montgomery, windowBits reads from the most significant end" {
    const Mont = Montgomery(16);
    const exp_bytes = [_]u8{ 0b1011_0000, 0b0000_0001 };

    try std.testing.expectEqual(@as(usize, 0b101), Mont.windowBits(&exp_bytes, 0, 3));
    try std.testing.expectEqual(@as(usize, 0b10000), Mont.windowBits(&exp_bytes, 3, 5));
    try std.testing.expectEqual(@as(usize, 0b1), Mont.windowBits(&exp_bytes, 15, 1));
}

test "tlz crypto: montgomery, gather picks only the indexed entry" {
    const Mont = Montgomery(24);
    var table: [Mont.TABLE_LEN]Mont.Big = undefined;
    for (&table, 0..) |*entry, i| entry.* = @splat(@intCast(i + 1));

    const picked = Mont.gather(&table, 17);

    try std.testing.expectEqualSlices(Limb, &table[17], &picked);
}

test "tlz crypto: montgomery, addInto and subInto report carry and borrow" {
    const Mont = Montgomery(16);
    const max: Mont.Big = @splat(~@as(Limb, 0));
    var one: Mont.Big = std.mem.zeroes(Mont.Big);
    one[0] = 1;
    var result: Mont.Big = undefined;

    try std.testing.expectEqual(@as(u1, 1), Mont.addInto(&result, max, one));
    try std.testing.expectEqual(@as(u1, 1), Mont.subInto(&result, one, max));
    try std.testing.expectEqual(@as(u1, 0), Mont.subInto(&result, max, one));
}

test "tlz crypto: montgomery, fromBytes and toBytes round trip" {
    const Mont = Montgomery(16);
    var bytes: [128]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i * 7 + 3);
    var out: [128]u8 = undefined;

    Mont.toBytes(Mont.fromBytes(&bytes), &out);

    try std.testing.expectEqualSlices(u8, &bytes, &out);
}

test "tlz crypto: montgomery, toBytes right-aligns a short value" {
    const Mont = Montgomery(16);
    var value: Mont.Big = std.mem.zeroes(Mont.Big);
    value[0] = 0x0102;
    var out: [130]u8 = undefined;

    Mont.toBytes(value, &out);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, out[128..]);
    try std.testing.expectEqual(@as(u8, 0), out[0]);
}

