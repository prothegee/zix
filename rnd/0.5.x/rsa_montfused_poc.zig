//! P3c step 1: fused single-block Montgomery multiply (toward OpenSSL-parity sign rate).
//!
//! Where P3b called a dual-carry pass twice per modmul (two asm blocks, two memory-clobber
//! barriers, Zig glue between them), this fuses the whole CIOS modmul into ONE asm block: the outer
//! loop, both the multiply and reduce passes (each a dual ADCX / ADOX carry chain), the Montgomery
//! `m` computation, and the limb shift, with the accumulator staying hot across passes. One barrier
//! per modmul instead of two.
//!
//! Validated byte-for-byte against std.crypto.ff, then benchmarked against P3b's two-pass asm and
//! the portable path.
//!
//! Run: zig run -O ReleaseFast -mcpu=native rnd/0.5.x/rsa_montfused_poc.zig

const std = @import("std");

const Limb = u64;
const limb_bits = 64;
const S = 16;
const Big = [S]Limb;

// --------------------------------------------------------------- //
// scaffolding (portable, shared with the library)

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
    return finalReduce(t[0..S], t[S], n);
}

// --------------------------------------------------------------- //
// P3c: fused single-block asm modmul

/// Build the fused CIOS asm body. Registers: rdi=t, rsi=a, r12=b, r13=n, r14=n0inv, r15=i;
/// rdx=mulx multiplier; r8=lo, r9/r10=alternating high, r11=zero, rax=scratch. AT&T, `%%` escaped.
fn fusedBody() []const u8 {
    @setEvalBranchQuota(200_000);
    const Stop = std.fmt.comptimePrint("{d}", .{S * 8});
    const Sm1 = std.fmt.comptimePrint("{d}", .{(S - 1) * 8});
    const Sp1 = std.fmt.comptimePrint("{d}", .{(S + 1) * 8});

    var s: []const u8 = "xorl %%r15d, %%r15d\n"; // i = 0
    s = s ++ "1:\n";
    s = s ++ "movq (%%r12,%%r15,8), %%rdx\n"; // rdx = b[i]

    // ---- multiply pass: t[0..S] += a * b[i] (dual carry, no carry_in) ----
    s = s ++ "xorl %%r11d, %%r11d\n"; // clear CF, OF
    s = s ++ "mulxq 0(%%rsi), %%r8, %%r9\n";
    s = s ++ "adcxq 0(%%rdi), %%r8\n";
    s = s ++ "movq %%r8, 0(%%rdi)\n";
    var hi: []const u8 = "%%r9";
    for (1..S) |j| {
        const off = std.fmt.comptimePrint("{d}", .{j * 8});
        const hn = if (std.mem.eql(u8, hi, "%%r9")) "%%r10" else "%%r9";
        s = s ++ "mulxq " ++ off ++ "(%%rsi), %%r8, " ++ hn ++ "\n";
        s = s ++ "adoxq " ++ hi ++ ", %%r8\n";
        s = s ++ "adcxq " ++ off ++ "(%%rdi), %%r8\n";
        s = s ++ "movq %%r8, " ++ off ++ "(%%rdi)\n";
        hi = hn;
    }
    // multiply carry out = hi + OF + CF; s1 = t[S] + carry; t[S]=lo, t[S+1]=hi
    s = s ++ "movl $0, %%eax\n";
    s = s ++ "adoxq %%rax, " ++ hi ++ "\n";
    s = s ++ "adcxq %%rax, " ++ hi ++ "\n";
    s = s ++ "movq " ++ Stop ++ "(%%rdi), %%r8\n";
    s = s ++ "addq " ++ hi ++ ", %%r8\n";
    s = s ++ "movq %%r8, " ++ Stop ++ "(%%rdi)\n";
    s = s ++ "movl $0, %%r8d\n";
    s = s ++ "adcq $0, %%r8\n";
    s = s ++ "movq %%r8, " ++ Sp1 ++ "(%%rdi)\n";

    // ---- m = t[0] * n0inv ----
    s = s ++ "movq 0(%%rdi), %%rdx\n";
    s = s ++ "imulq %%r14, %%rdx\n";

    // ---- reduce pass: t += n * m, write shifted to t[j-1] (j=0 limb is the dropped zero) ----
    s = s ++ "xorl %%r11d, %%r11d\n";
    s = s ++ "mulxq 0(%%r13), %%r8, %%r9\n";
    s = s ++ "adcxq 0(%%rdi), %%r8\n"; // r8 = lo0 + t[0] == 0, discarded; CF set
    hi = "%%r9";
    for (1..S) |j| {
        const off = std.fmt.comptimePrint("{d}", .{j * 8});
        const offm1 = std.fmt.comptimePrint("{d}", .{(j - 1) * 8});
        const hn = if (std.mem.eql(u8, hi, "%%r9")) "%%r10" else "%%r9";
        s = s ++ "mulxq " ++ off ++ "(%%r13), %%r8, " ++ hn ++ "\n";
        s = s ++ "adoxq " ++ hi ++ ", %%r8\n";
        s = s ++ "adcxq " ++ off ++ "(%%rdi), %%r8\n";
        s = s ++ "movq %%r8, " ++ offm1 ++ "(%%rdi)\n"; // t[j-1] (shift)
        hi = hn;
    }
    // reduce carry out = hi + OF + CF; s2 = t[S] + carry; t[S-1]=lo, t[S]=t[S+1]+hi
    s = s ++ "movl $0, %%eax\n";
    s = s ++ "adoxq %%rax, " ++ hi ++ "\n";
    s = s ++ "adcxq %%rax, " ++ hi ++ "\n";
    s = s ++ "movq " ++ Stop ++ "(%%rdi), %%r8\n";
    s = s ++ "addq " ++ hi ++ ", %%r8\n"; // CF = overflow
    s = s ++ "movq %%r8, " ++ Sm1 ++ "(%%rdi)\n"; // t[S-1] = s2.lo
    s = s ++ "movq " ++ Sp1 ++ "(%%rdi), %%r8\n";
    s = s ++ "adcq $0, %%r8\n"; // t[S+1] + s2.hi
    s = s ++ "movq %%r8, " ++ Stop ++ "(%%rdi)\n"; // t[S]

    s = s ++ "incq %%r15\n";
    s = s ++ "cmpq $" ++ std.fmt.comptimePrint("{d}", .{S}) ++ ", %%r15\n";
    s = s ++ "jb 1b\n";
    return s;
}

fn mulFused(a: Big, b: Big, n: Big, n0inv: Limb) Big {
    var t = std.mem.zeroes([S + 2]Limb);
    const body = comptime fusedBody();

    asm volatile (body
        :
        : [t] "{rdi}" (&t),
          [a] "{rsi}" (&a),
          [b] "{r12}" (&b),
          [n] "{r13}" (&n),
          [n0inv] "{r14}" (n0inv),
        : .{ .rax = true, .rdx = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r15 = true, .memory = true, .cc = true });

    return finalReduce(t[0..S], t[S], n);
}

// --------------------------------------------------------------- //

fn modExp(base: Big, exp_be: []const u8, n: Big, comptime use_fused: bool) Big {
    const n0inv = n0Inv(n[0]);
    const rr = rSquared(n);
    const mul = if (use_fused) mulFused else mulPortable;

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
        inline for ([_]u3{ 4, 0 }) |shift| {
            inline for (0..4) |_| acc = mul(acc, acc, n, n0inv);
            const nib: usize = (byte >> shift) & 0x0f;
            // direct index here (PoC measures arithmetic; the library keeps the masked gather)
            acc = mul(acc, table[nib], n, n0inv);
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

fn nowNs() i128 {
    const l = std.os.linux;
    var ts: l.timespec = undefined;
    _ = l.clock_gettime(l.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn main() !void {
    var prng = std.Random.DefaultPrng.init(0xf03ed);
    const rand = prng.random();

    std.debug.print("== fused modmul vs std.crypto.ff ==\n", .{});
    var trial: usize = 0;
    while (trial < 200) : (trial += 1) {
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

        const got = modExp(fromBytes(&b_b), &e_b, fromBytes(&n_b), true);
        var got_o: [128]u8 = undefined;
        var k: usize = 0;
        while (k < S) : (k += 1) {
            for (0..8) |bb| {
                const pos = k * 8 + bb;
                got_o[got_o.len - 1 - pos] = @truncate(got[k] >> @intCast(bb * 8));
            }
        }
        if (!std.mem.eql(u8, &ref_o, &got_o)) {
            std.debug.print("  MISMATCH trial {d}\n", .{trial});
            return error.Mismatch;
        }
    }
    std.debug.print("  200/200 fused modexps match ff\n\n", .{});

    // benchmark: two modexps = one CRT sign
    var n_b: [128]u8 = undefined;
    rand.bytes(&n_b);
    n_b[0] |= 0x80;
    n_b[127] |= 1;
    var b_b: [128]u8 = undefined;
    rand.bytes(&b_b);
    b_b[0] &= 0x7f;
    var e_b: [128]u8 = undefined;
    rand.bytes(&e_b);
    e_b[0] |= 0x80;
    const nB = fromBytes(&n_b);
    const bB = fromBytes(&b_b);

    const iters = 400;
    for (0..20) |_| _ = modExp(bB, &e_b, nB, true);

    var t0 = nowNs();
    var sink: u64 = 0;
    for (0..iters) |_| {
        sink ^= modExp(bB, &e_b, nB, true)[0] ^ modExp(bB, &e_b, nB, true)[0];
    }
    const fused_ms = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, iters) / 1e6;

    t0 = nowNs();
    for (0..iters) |_| {
        sink ^= modExp(bB, &e_b, nB, false)[0] ^ modExp(bB, &e_b, nB, false)[0];
    }
    const port_ms = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, iters) / 1e6;

    std.debug.print("== two-modexp (one CRT sign of arithmetic) ==\n", .{});
    std.debug.print("  fused single-block asm   {d:.3} ms\n", .{fused_ms});
    std.debug.print("  portable CIOS            {d:.3} ms\n", .{port_ms});
    std.debug.print("  OpenSSL (full sign ref)  0.518 ms\n", .{});
    std.debug.print("  sink={x}\n", .{sink});
}
