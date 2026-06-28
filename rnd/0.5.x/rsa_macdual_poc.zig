//! P3b step 1: validate the dual-carry MAC primitive in isolation.
//!
//! macDual computes t[0..S] = t[0..S] + f * v[0..S] + carry_in, returning the carry out of the top
//! limb, using the x86_64 two-carry-chain trick: MULX (no flag effect) feeds one carry chain
//! through ADCX (CF) and the other through ADOX (OF), so the carry propagation of the low and high
//! product words runs on two independent flags instead of serializing. This is the one pass LLVM
//! never emits from portable Zig (it uses MULX but a single carry chain).
//!
//! Run: zig run -O ReleaseFast rnd/0.5.x/rsa_macdual_poc.zig

const std = @import("std");

const S = 16;

/// Portable reference: t += f*v + carry_in, returns carry out. The oracle for the asm version.
fn macPortable(t: *[S]u64, v: *const [S]u64, f: u64, carry_in: u64) u64 {
    var carry: u64 = carry_in;
    for (0..S) |j| {
        const p = @as(u128, f) * @as(u128, v[j]) + @as(u128, t[j]) + @as(u128, carry);
        t[j] = @truncate(p);
        carry = @truncate(p >> 64);
    }
    return carry;
}

/// Dual-carry asm: t += f*v + carry_in, returns carry out. S=16 limbs, unrolled at comptime.
fn macDual(t: *[S]u64, v: *const [S]u64, f: u64, carry_in: u64) u64 {
    const asm_body = comptime blk: {
        @setEvalBranchQuota(50_000);
        var s: []const u8 = "xorl %r11d, %r11d\n"; // clear CF and OF
        // j = 0: lo0 + t[0] on the CF chain, + carry_in on the OF chain (two independent carries
        // out, both fold into j=1). hi0 is parked, added at j=1 via the OF chain too.
        s = s ++ "mulxq 0(%rsi), %r8, %r9\n";
        s = s ++ "adcxq 0(%rdi), %r8\n";
        s = s ++ "adoxq %rcx, %r8\n";
        s = s ++ "movq %r8, 0(%rdi)\n";
        // j = 1..S-1: lo_j += hi_{j-1} (OF), then += t[j] (CF). hi alternates r9/r10.
        var hi_in: []const u8 = "%r9";
        for (1..S) |j| {
            const off = std.fmt.comptimePrint("{d}", .{j * 8});
            const hi_out = if (std.mem.eql(u8, hi_in, "%r9")) "%r10" else "%r9";
            s = s ++ "mulxq " ++ off ++ "(%rsi), %r8, " ++ hi_out ++ "\n";
            s = s ++ "adoxq " ++ hi_in ++ ", %r8\n";
            s = s ++ "adcxq " ++ off ++ "(%rdi), %r8\n";
            s = s ++ "movq %r8, " ++ off ++ "(%rdi)\n";
            hi_in = hi_out;
        }
        // carry_out = last hi + OF + CF
        s = s ++ "movq $0, %rax\n";
        s = s ++ "adoxq %rax, " ++ hi_in ++ "\n";
        s = s ++ "adcxq %rax, " ++ hi_in ++ "\n";
        s = s ++ "movq " ++ hi_in ++ ", %rax\n";
        break :blk s;
    };

    return asm volatile (asm_body
        : [ret] "={rax}" (-> u64),
        : [t] "{rdi}" (t),
          [v] "{rsi}" (v),
          [f] "{rdx}" (f),
          [ci] "{rcx}" (carry_in),
        : .{ .rax = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .memory = true, .cc = true });
}

fn nowNs() i128 {
    const linux = std.os.linux;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn main() !void {
    var prng = std.Random.DefaultPrng.init(0xd0a1c0de);
    const rand = prng.random();

    std.debug.print("== macDual vs portable (random fuzz) ==\n", .{});
    var trial: usize = 0;
    var mismatches: usize = 0;
    while (trial < 200_000) : (trial += 1) {
        var t_ref: [S]u64 = undefined;
        var v: [S]u64 = undefined;
        for (0..S) |i| {
            t_ref[i] = rand.int(u64);
            v[i] = rand.int(u64);
        }
        const f = rand.int(u64);
        const ci = rand.int(u64);

        var t_asm = t_ref;
        const c_ref = macPortable(&t_ref, &v, f, ci);
        const c_asm = macDual(&t_asm, &v, f, ci);

        if (c_ref != c_asm or !std.mem.eql(u64, &t_ref, &t_asm)) {
            mismatches += 1;
            if (mismatches <= 1) {
                std.debug.print("  MISMATCH trial {d}: carry ref={x} asm={x}\n", .{ trial, c_ref, c_asm });
                for (0..S) |i| {
                    if (t_ref[i] != t_asm[i]) std.debug.print("    limb[{d}] ref={x} asm={x}\n", .{ i, t_ref[i], t_asm[i] });
                }
            }
        }
    }
    if (mismatches == 0) {
        std.debug.print("  200,000/200,000 trials match\n", .{});
    } else {
        std.debug.print("  {d} mismatches!\n", .{mismatches});
        return error.Mismatch;
    }
}
