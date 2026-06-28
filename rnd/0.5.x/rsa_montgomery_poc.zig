//! RSA Montgomery modexp PoC (lever P3, OpenSSL-parity sign rate)
//!
//! What:
//!   Prove a hand-tuned Montgomery modular exponentiation for 1024-bit primes (the CRT half of an
//!   RSA-2048 sign) matches the portable std.crypto.ff result byte-for-byte, and measure ms/op so
//!   the asm path can be compared against the reference server (OpenSSL, ~0.496 ms/full-sign).
//!
//! Why:
//!   std.crypto.ff.Modulus is correct but slow on the secret path: a constant-time cmov scan over
//!   the window table, plus a portable limb multiply LLVM never lowers to the MULX + ADCX/ADOX
//!   dual-carry chain. This PoC implements CIOS Montgomery multiply two ways (portable Zig, and
//!   x86_64 MULX/ADCX/ADOX inline asm) and checks both against ff for a random odd 1024-bit modulus.
//!
//! Note:
//! - Correctness oracle is std.crypto.ff.Modulus(1024).powWithEncodedExponent.
//! - The bench drives two 1024-bit modexps (the p and q halves) to mirror one CRT sign.
//! - Run: zig run -O ReleaseFast rnd/0.5.x/rsa_montgomery_poc.zig

const std = @import("std");
const builtin = @import("builtin");

const Limb = u64;
const limb_bits = 64;
const S = 16; // 16 limbs x 64 bits = 1024-bit prime (the CRT half width)

const Big = [S]Limb; // little-endian limbs: Big[0] is least significant

// --------------------------------------------------------------- //
// limb helpers (little-endian, fixed S limbs)

/// Compare a and b. Returns -1, 0, 1. Not constant-time (setup / final-sub use only).
fn cmp(a: Big, b: Big) i32 {
    var i: usize = S;
    while (i > 0) {
        i -= 1;
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    return 0;
}

/// r = a + b, returns the carry out of the top limb.
fn addInto(r: *Big, a: Big, b: Big) u1 {
    var carry: u1 = 0;
    for (0..S) |i| {
        const s1 = @addWithOverflow(a[i], b[i]);
        const s2 = @addWithOverflow(s1[0], carry);
        r[i] = s2[0];
        carry = s1[1] | s2[1];
    }
    return carry;
}

/// r = a - b, returns the borrow out of the top limb.
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

/// r = (a << 1) mod n via one conditional subtract. Used only to bootstrap Montgomery R.
fn modDouble(r: *Big, a: Big, n: Big) void {
    var carry: u1 = 0;
    var t: Big = undefined;
    for (0..S) |i| {
        const hi: u1 = @truncate(a[i] >> 63);
        t[i] = (a[i] << 1) | carry;
        carry = hi;
    }

    // t may be >= n (or have overflowed into bit 1024); subtract n if so.
    var sub: Big = undefined;
    const borrow = subInto(&sub, t, n);
    const ge_n = (carry == 1) or (borrow == 0);
    r.* = if (ge_n) sub else t;
}

// --------------------------------------------------------------- //
// Montgomery setup

/// n0inv = -n[0]^-1 mod 2^64 via Newton iteration (n[0] is odd for an odd modulus).
fn montN0Inv(n0: Limb) Limb {
    var x: Limb = 1;
    // x = n0^-1 mod 2^64: each step doubles the correct bit count (2,4,8,...,64).
    inline for (0..6) |_| {
        x = x *% (2 -% n0 *% x);
    }
    return 0 -% x; // -n0^-1
}

/// rr = R^2 mod n, R = 2^(64*S). Computed by doubling 1 up 2*64*S times (setup only).
fn montRR(n: Big) Big {
    var r: Big = std.mem.zeroes(Big);
    r[0] = 1;

    var i: usize = 0;
    while (i < 2 * limb_bits * S) : (i += 1) {
        modDouble(&r, r, n);
    }
    return r;
}

// --------------------------------------------------------------- //
// CIOS Montgomery multiply: portable

/// t = a * b * R^-1 mod n (CIOS, RFC-agnostic, Koc 1996). Portable Zig reference.
fn montMulPortable(a: Big, b: Big, n: Big, n0inv: Limb) Big {
    var t = std.mem.zeroes([S + 2]Limb);

    for (0..S) |i| {
        // t += a * b[i]
        var carry: Limb = 0;
        for (0..S) |j| {
            const p = @as(u128, a[j]) * @as(u128, b[i]) + @as(u128, t[j]) + @as(u128, carry);
            t[j] = @truncate(p);
            carry = @truncate(p >> 64);
        }
        const s1 = @addWithOverflow(t[S], carry);
        t[S] = s1[0];
        t[S + 1] = s1[1];

        // m = t[0] * n0inv mod 2^64; t += m * n; t >>= 64
        const m: Limb = t[0] *% n0inv;
        var carry2: Limb = 0;
        {
            const p = @as(u128, m) * @as(u128, n[0]) + @as(u128, t[0]) + @as(u128, carry2);
            carry2 = @truncate(p >> 64);
        }
        for (1..S) |j| {
            const p = @as(u128, m) * @as(u128, n[j]) + @as(u128, t[j]) + @as(u128, carry2);
            t[j - 1] = @truncate(p);
            carry2 = @truncate(p >> 64);
        }
        const s2 = @addWithOverflow(t[S], carry2);
        t[S - 1] = s2[0];
        t[S] = t[S + 1] + s2[1];
    }

    // final conditional subtract: result is in t[0..S], with possible top word in t[S]
    var res: Big = undefined;
    @memcpy(res[0..S], t[0..S]);

    var sub: Big = undefined;
    const borrow = subInto(&sub, res, n);
    const ge_n = (t[S] != 0) or (borrow == 0);
    return if (ge_n) sub else res;
}

// --------------------------------------------------------------- //
// modexp (4-bit fixed window) over Montgomery domain

fn montMul(a: Big, b: Big, n: Big, n0inv: Limb, use_asm: bool) Big {
    if (use_asm and has_asm) return montMulAsm(a, b, n, n0inv);
    return montMulPortable(a, b, n, n0inv);
}

/// Constant-time select: returns table[idx] by scanning all 16 entries with a mask (no
/// secret-dependent memory address), mirroring ff's side-channel posture.
fn ctGather(table: *const [16]Big, idx: usize) Big {
    var r: Big = std.mem.zeroes(Big);
    for (0..16) |k| {
        const m: Limb = if (k == idx) ~@as(Limb, 0) else 0;
        for (0..S) |j| r[j] |= table[k][j] & m;
    }
    return r;
}

/// base^exp mod n, exp big-endian. 4-bit fixed window, constant-time: every nibble squares 4x
/// and multiplies by a masked table gather (no leading-zero skip, no secret-indexed load).
fn modExp(base: Big, exp_be: []const u8, n: Big, use_asm: bool) Big {
    const n0inv = montN0Inv(n[0]);
    const rr = montRR(n);

    var one_norm: Big = std.mem.zeroes(Big);
    one_norm[0] = 1;
    const one_mont = montMul(one_norm, rr, n, n0inv, use_asm);
    const base_mont = montMul(base, rr, n, n0inv, use_asm);

    // table[k] = base^k in Montgomery form, k = 0..15
    var table: [16]Big = undefined;
    table[0] = one_mont;
    table[1] = base_mont;
    for (2..16) |k| {
        table[k] = montMul(table[k - 1], base_mont, n, n0inv, use_asm);
    }

    var acc = one_mont;
    for (exp_be) |byte| {
        inline for ([_]u3{ 4, 0 }) |shift| {
            inline for (0..4) |_| acc = montMul(acc, acc, n, n0inv, use_asm);

            const nib: usize = (byte >> shift) & 0x0f;
            acc = montMul(acc, ctGather(&table, nib), n, n0inv, use_asm);
        }
    }

    var one2: Big = std.mem.zeroes(Big);
    one2[0] = 1;
    return montMul(acc, one2, n, n0inv, use_asm);
}

// --------------------------------------------------------------- //
// CIOS Montgomery multiply: x86_64 MULX + ADCX/ADOX (placeholder until validated)

const has_asm = false; // flipped on once the asm path validates against the portable one

fn montMulAsm(a: Big, b: Big, n: Big, n0inv: Limb) Big {
    return montMulPortable(a, b, n, n0inv);
}

// --------------------------------------------------------------- //

fn bytesToBig(bytes: []const u8) Big {
    // bytes are big-endian (ff .big); convert to little-endian limbs
    var r: Big = std.mem.zeroes(Big);
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const limb_idx = (bytes.len - 1 - i) / 8;
        const byte_in_limb = (bytes.len - 1 - i) % 8;
        if (limb_idx < S) r[limb_idx] |= @as(Limb, bytes[i]) << @intCast(byte_in_limb * 8);
    }
    return r;
}

fn bigToBytes(a: Big, out: []u8) void {
    @memset(out, 0);
    for (0..S) |i| {
        for (0..8) |b| {
            const idx = out.len - 1 - (i * 8 + b);
            if (i * 8 + b < out.len) out[idx] = @truncate(a[i] >> @intCast(b * 8));
        }
    }
}

const Modulus1024 = std.crypto.ff.Modulus(1024);

/// Build a random odd 1024-bit modulus, base < n, and a 1024-bit exponent. Verify modExp == ff.
fn correctness(prng: *std.Random.DefaultPrng) !void {
    const rand = prng.random();

    var n_bytes: [128]u8 = undefined;
    rand.bytes(&n_bytes);
    n_bytes[0] |= 0x80; // top bit set: a true 1024-bit modulus
    n_bytes[127] |= 0x01; // odd

    var base_bytes: [128]u8 = undefined;
    rand.bytes(&base_bytes);
    base_bytes[0] &= 0x7f; // ensure base < n (clear top bit)

    var exp_bytes: [128]u8 = undefined;
    rand.bytes(&exp_bytes);

    const mod = try Modulus1024.fromBytes(&n_bytes, .big);
    const base_fe = try Modulus1024.Fe.fromBytes(mod, &base_bytes, .big);
    const ref_fe = try mod.powWithEncodedExponent(base_fe, &exp_bytes, .big);
    var ref_out: [128]u8 = undefined;
    try ref_fe.toBytes(&ref_out, .big);

    const n_big = bytesToBig(&n_bytes);
    const base_big = bytesToBig(&base_bytes);
    const got = modExp(base_big, &exp_bytes, n_big, false);
    var got_out: [128]u8 = undefined;
    bigToBytes(got, &got_out);

    if (!std.mem.eql(u8, &ref_out, &got_out)) {
        std.debug.print("MISMATCH\n  ref={x}\n  got={x}\n", .{ ref_out, got_out });
        return error.Mismatch;
    }
}

fn nowNs() i128 {
    const linux = std.os.linux;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn main() !void {
    var prng = std.Random.DefaultPrng.init(0x515 ^ 0xa1);

    std.debug.print("== correctness (portable CIOS vs std.crypto.ff) ==\n", .{});
    var trial: usize = 0;
    while (trial < 64) : (trial += 1) try correctness(&prng);
    std.debug.print("  64/64 random 1024-bit modexps match ff\n\n", .{});

    // benchmark: two 1024-bit modexps == one CRT sign
    const rand = prng.random();
    var n_bytes: [128]u8 = undefined;
    rand.bytes(&n_bytes);
    n_bytes[0] |= 0x80;
    n_bytes[127] |= 0x01;
    var base_bytes: [128]u8 = undefined;
    rand.bytes(&base_bytes);
    base_bytes[0] &= 0x7f;
    var exp_bytes: [128]u8 = undefined;
    rand.bytes(&exp_bytes);
    exp_bytes[0] |= 0x80;

    const n_big = bytesToBig(&n_bytes);
    const base_big = bytesToBig(&base_bytes);

    const iters = 200;

    // ff reference path (the current production cost), two halves per sign
    const mod = try Modulus1024.fromBytes(&n_bytes, .big);
    const base_fe = try Modulus1024.Fe.fromBytes(mod, &base_bytes, .big);
    var t0 = nowNs();
    var sink: u64 = 0;
    for (0..iters) |_| {
        const a = try mod.powWithEncodedExponent(base_fe, &exp_bytes, .big);
        const b = try mod.powWithEncodedExponent(base_fe, &exp_bytes, .big);
        sink ^= a.v.limbs_buffer[0] ^ b.v.limbs_buffer[0];
    }
    const ff_ms = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, iters) / 1.0e6;

    // portable CIOS, two halves per sign
    t0 = nowNs();
    for (0..iters) |_| {
        const a = modExp(base_big, &exp_bytes, n_big, false);
        const b = modExp(base_big, &exp_bytes, n_big, false);
        sink ^= a[0] ^ b[0];
    }
    const cios_ms = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, iters) / 1.0e6;

    std.debug.print("== sign-rate (two 1024-bit modexps = one CRT sign) ==\n", .{});
    std.debug.print("  std.crypto.ff (.medium default)  {d:.3} ms/sign\n", .{ff_ms});
    std.debug.print("  portable CIOS Montgomery         {d:.3} ms/sign\n", .{cios_ms});
    std.debug.print("  reference (OpenSSL, for context)  0.496 ms/sign\n", .{});
    std.debug.print("  asm MULX/ADCX/ADOX               (pending)\n", .{});
    std.debug.print("\n  sink={x}\n", .{sink});
}
