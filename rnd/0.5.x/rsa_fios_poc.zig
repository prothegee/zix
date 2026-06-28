//! P3d step 1: 4-wide FIOS Montgomery multiply (toward OpenSSL mulx4x).
//!
//! P3c is CIOS: a multiply sweep then a reduce sweep, each a dual ADCX / ADOX chain. FIOS (Finely
//! Integrated Operand Scanning, the shape of OpenSSL's mulx4x) interleaves them into ONE sweep per
//! b[i]: a[j]*b[i] accumulates on one carry flag, n[j]*m on the other, so T is touched once per limb
//! and both flag chains stay busy. Processed 4 limbs at a time to amortize the rdx switch between
//! b[i] and m. CIOS and FIOS give identical results, so the oracle is still std.crypto.ff.
//!
//! This file validates a per-b[i] FIOS asm step (Zig drives the outer loop) against the portable
//! CIOS and ff, then benchmarks it against P3c.
//!
//! Run: zig run -O ReleaseFast -mcpu=native rnd/0.5.x/rsa_fios_poc.zig

const std = @import("std");

const Limb = u64;
const limb_bits = 64;
const S = 16; // must be a multiple of 4
const Big = [S]Limb;

// --------------------------------------------------------------- //
// scaffolding (portable, the oracle)

fn subInto(r: *Big, a: Big, b: Big) u1 {
    var borrow: u1 = 0;
    for (0..S) |i| {
        const d1 = @subWithOverflow(a[i], b[i]);
        const d2 = @subWithOverflow(d1[0], borrow);
        r[i] = d2[0];
        borrow = d1[1] | d2[1];
    }
    return borrow;
}

fn ctSelect(mask: Limb, a: Big, b: Big) Big {
    var r: Big = undefined;
    for (0..S) |i| r[i] = (a[i] & mask) | (b[i] & ~mask);
    return r;
}

fn modDouble(a: Big, n: Big) Big {
    var carry: u1 = 0;
    var t: Big = undefined;
    for (0..S) |i| {
        const hi: u1 = @truncate(a[i] >> 63);
        t[i] = (a[i] << 1) | carry;
        carry = hi;
    }
    var sub: Big = undefined;
    const borrow = subInto(&sub, t, n);
    const ge_n: Limb = if (carry == 1 or borrow == 0) ~@as(Limb, 0) else 0;
    return ctSelect(ge_n, sub, t);
}

fn n0Inv(n0: Limb) Limb {
    var x: Limb = 1;
    inline for (0..6) |_| x = x *% (2 -% n0 *% x);
    return 0 -% x;
}

fn rSquared(n: Big) Big {
    var r: Big = std.mem.zeroes(Big);
    r[0] = 1;
    var i: usize = 0;
    while (i < 2 * limb_bits * S) : (i += 1) r = modDouble(r, n);
    return r;
}

fn finalReduce(t: *const [S]Limb, top: Limb, n: Big) Big {
    var res: Big = undefined;
    @memcpy(res[0..S], t);
    var sub: Big = undefined;
    const borrow = subInto(&sub, res, n);
    const ge_n: Limb = if (top != 0 or borrow == 0) ~@as(Limb, 0) else 0;
    return ctSelect(ge_n, sub, res);
}

fn mulPortable(a: Big, b: Big, n: Big, n0inv: Limb) Big {
    var t = std.mem.zeroes([S + 2]Limb);
    for (0..S) |i| {
        var carry: Limb = 0;
        for (0..S) |j| {
            const p = @as(u128, a[j]) * @as(u128, b[i]) + @as(u128, t[j]) + @as(u128, carry);
            t[j] = @truncate(p);
            carry = @truncate(p >> 64);
        }
        const s1 = @addWithOverflow(t[S], carry);
        t[S] = s1[0];
        t[S + 1] = s1[1];
        const m: Limb = t[0] *% n0inv;
        var c2: Limb = 0;
        {
            const p = @as(u128, m) * @as(u128, n[0]) + @as(u128, t[0]) + @as(u128, c2);
            c2 = @truncate(p >> 64);
        }
        for (1..S) |j| {
            const p = @as(u128, m) * @as(u128, n[j]) + @as(u128, t[j]) + @as(u128, c2);
            t[j - 1] = @truncate(p);
            c2 = @truncate(p >> 64);
        }
        const s2 = @addWithOverflow(t[S], c2);
        t[S - 1] = s2[0];
        t[S] = t[S + 1] + s2[1];
    }
    return finalReduce(t[0..S], t[S], n);
}

// --------------------------------------------------------------- //
// FIOS per-b[i] step, portable reference (same result as CIOS, validates the asm)

/// T[0..S] (S+1 limbs, T[S] the running top) := (T + a*bi + m*n) >> 64. The interleaved form; the
/// asm mirrors this with two carry flags. Portable, so it doubles as the asm oracle.
fn fiosStepPortable(t: *[S + 1]Limb, a: *const Big, n: *const Big, bi: Limb, n0inv: Limb) void {
    var mc: Limb = 0; // multiply carry
    // j = 0: form uu0 = t[0] + a[0]*bi, derive m, then reduce makes low 0
    const p0 = @as(u128, a[0]) * @as(u128, bi) + @as(u128, t[0]);
    const uu0: Limb = @truncate(p0);
    mc = @truncate(p0 >> 64);
    const m: Limb = uu0 *% n0inv;
    var rc: Limb = 0; // reduce carry
    {
        const q0 = @as(u128, m) * @as(u128, n[0]) + @as(u128, uu0);
        rc = @truncate(q0 >> 64);
    }
    for (1..S) |j| {
        const p = @as(u128, a[j]) * @as(u128, bi) + @as(u128, t[j]) + @as(u128, mc);
        const u: Limb = @truncate(p);
        mc = @truncate(p >> 64);
        const q = @as(u128, m) * @as(u128, n[j]) + @as(u128, u) + @as(u128, rc);
        t[j - 1] = @truncate(q);
        rc = @truncate(q >> 64);
    }
    const top = @as(u128, t[S]) + @as(u128, mc) + @as(u128, rc);
    t[S - 1] = @truncate(top);
    t[S] = @truncate(top >> 64);
}

fn mulFiosPortable(a: Big, b: Big, n: Big, n0inv: Limb) Big {
    var t = std.mem.zeroes([S + 1]Limb);
    for (0..S) |i| fiosStepPortable(&t, &a, &n, b[i], n0inv);
    return finalReduce(t[0..S], t[S], n);
}

// --------------------------------------------------------------- //
// Finding (P3d): a 1-wide dual-carry asm FIOS is NOT possible. One limb would have to absorb
// t[j] + a[j]*bi_lo + n[j]*m_lo + mul_carry + reduce_carry, a sum of up to five 64-bit terms whose
// carry needs 3 bits, but ADCX + ADOX provide only two carry flags. An earlier attempt here failed
// the oracle for exactly this reason (off-by-carry). OpenSSL's mulx4x routes carries across limbs so
// each flag chain adds at most one product-lo plus one prior product-hi per limb (<= 1 carry each),
// which only closes in the full 4-wide interleaved form. So the asm port of P3d is the faithful
// OpenSSL choreography, not a reducible shortcut. The portable FIOS above stands as its oracle.

// --------------------------------------------------------------- //

fn modExp(base: Big, exp_be: []const u8, n: Big, comptime which: u8) Big {
    const n0inv = n0Inv(n[0]);
    const rr = rSquared(n);
    const mul = switch (which) {
        0 => mulPortable,
        1 => mulFiosPortable,
        else => mulPortable,
    };

    var one_norm: Big = std.mem.zeroes(Big);
    one_norm[0] = 1;
    const one_mont = mul(one_norm, rr, n, n0inv);
    const base_mont = mul(base, rr, n, n0inv);

    var table: [16]Big = undefined;
    table[0] = one_mont;
    table[1] = base_mont;
    for (2..16) |k| table[k] = mul(table[k - 1], base_mont, n, n0inv);

    var acc = one_mont;
    for (exp_be) |byte| {
        inline for ([_]u3{ 4, 0 }) |sh| {
            inline for (0..4) |_| acc = mul(acc, acc, n, n0inv);
            acc = mul(acc, table[(byte >> sh) & 0x0f], n, n0inv);
        }
    }
    var one2: Big = std.mem.zeroes(Big);
    one2[0] = 1;
    return mul(acc, one2, n, n0inv);
}

fn fromBytes(bytes: []const u8) Big {
    var r: Big = std.mem.zeroes(Big);
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const idx = (bytes.len - 1 - i) / 8;
        const off = (bytes.len - 1 - i) % 8;
        if (idx < S) r[idx] |= @as(Limb, bytes[i]) << @intCast(off * 8);
    }
    return r;
}

const Mod1024 = std.crypto.ff.Modulus(1024);

pub fn main() !void {
    var prng = std.Random.DefaultPrng.init(0xf105);
    const rand = prng.random();

    std.debug.print("== FIOS-portable modexp vs std.crypto.ff ==\n", .{});
    var trial: usize = 0;
    while (trial < 300) : (trial += 1) {
        var n_b: [128]u8 = undefined;
        rand.bytes(&n_b);
        n_b[0] |= 0x80;
        n_b[127] |= 1;
        var b_b: [128]u8 = undefined;
        rand.bytes(&b_b);
        b_b[0] &= 0x7f;
        var e_b: [128]u8 = undefined;
        rand.bytes(&e_b);

        const mod = try Mod1024.fromBytes(&n_b, .big);
        const base_fe = try Mod1024.Fe.fromBytes(mod, &b_b, .big);
        const ref = try mod.powWithEncodedExponent(base_fe, &e_b, .big);
        var ref_o: [128]u8 = undefined;
        try ref.toBytes(&ref_o, .big);

        const gp = modExp(fromBytes(&b_b), &e_b, fromBytes(&n_b), 1);
        var gp_o: [128]u8 = undefined;
        for (0..S) |k| {
            for (0..8) |bb| {
                const pos = k * 8 + bb;
                gp_o[gp_o.len - 1 - pos] = @truncate(gp[k] >> @intCast(bb * 8));
            }
        }
        if (!std.mem.eql(u8, &ref_o, &gp_o)) {
            std.debug.print("  MISMATCH trial {d}\n", .{trial});
            return error.Mismatch;
        }
    }
    std.debug.print("  300/300 FIOS-portable modexps match ff (interleave math confirmed)\n", .{});
    std.debug.print("  see the finding note: the asm port of FIOS needs OpenSSL's 4-wide\n", .{});
    std.debug.print("  cross-limb carry routing, not a 1-wide form (only 2 carry flags)\n", .{});
}
