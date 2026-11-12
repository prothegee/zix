//! TLZ crypto montgomery asm_body
//!
//! ### file: src/tlz/src/crypto/montgomery/asm_body.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Builds, at comptime, the x86_64 ADX asm text of the Montgomery multiply and the
//! dedicated Montgomery square for a fixed limb count.
//!
//! ### note:
//!
//! Both bodies run a dual carry chain: MULX splits each product without touching
//! the flags, ADCX carries on CF and ADOX on OF. The schedule is fixed, with no
//! branch on a secret value. AT&T syntax, literal registers escaped as `%%`.
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
// Private:

/// Up to this limb count the square reduction is fully unrolled. Above it the
/// unrolled text outgrows the instruction cache, so it runs as a loop.
const UNROLL_REDUCE_MAX_LIMBS: usize = 16;

/// Byte offset of a limb, as asm text.
fn byteOffset(comptime index: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{index * 8});
}

/// The high register the next MULX writes, alternating r9 and r10.
fn nextHigh(comptime high: []const u8) []const u8 {
    return if (std.mem.eql(u8, high, "%%r9")) "%%r10" else "%%r9";
}

/// One dual-chain row: `base[first..limbs]` times rdx, added into `acc[at..]`,
/// written back to `acc[at - shift..]`. The final high word is left in the
/// returned register, with both carries still pending.
fn rowText(
    comptime base: []const u8,
    comptime acc: []const u8,
    comptime first: usize,
    comptime limbs: usize,
    comptime at: usize,
    comptime shift: usize,
    comptime high_out: *[]const u8,
) []const u8 {
    var text: []const u8 = "";
    var high: []const u8 = "%%r9";

    text = text ++ "mulxq " ++ byteOffset(first) ++ "(" ++ base ++ "), %%r8, %%r9\n";
    text = text ++ "adcxq " ++ byteOffset(at) ++ "(" ++ acc ++ "), %%r8\n";
    if (shift == 0) text = text ++ "movq %%r8, " ++ byteOffset(at) ++ "(" ++ acc ++ ")\n";

    for (first + 1..limbs) |col| {
        const next = nextHigh(high);
        const pos = at + col - first;
        text = text ++ "mulxq " ++ byteOffset(col) ++ "(" ++ base ++ "), %%r8, " ++ next ++ "\n";
        text = text ++ "adoxq " ++ high ++ ", %%r8\n";
        text = text ++ "adcxq " ++ byteOffset(pos) ++ "(" ++ acc ++ "), %%r8\n";
        text = text ++ "movq %%r8, " ++ byteOffset(pos - shift) ++ "(" ++ acc ++ ")\n";
        high = next;
    }

    text = text ++ "movl $0, %%eax\n";
    text = text ++ "adoxq %%rax, " ++ high ++ "\n";
    text = text ++ "adcxq %%rax, " ++ high ++ "\n";
    high_out.* = high;

    return text;
}

/// One square reduction row at `row` (rcx in loop form): factor = acc[0] * n0inv,
/// acc += n * factor, then the top word with the carry kept in r15.
fn reduceRowText(
    comptime acc: []const u8,
    comptime row: usize,
    comptime limbs: usize,
) []const u8 {
    var high: []const u8 = undefined;
    var text: []const u8 = "";

    text = text ++ "movq " ++ byteOffset(row) ++ "(" ++ acc ++ "), %%rdx\n";
    text = text ++ "imulq %%r14, %%rdx\n";
    text = text ++ "xorl %%eax, %%eax\n";
    text = text ++ rowText("%%r13", acc, 0, limbs, row, 0, &high);

    text = text ++ "movq %%r15, %%r12\n";
    text = text ++ "xorl %%r15d, %%r15d\n";
    text = text ++ "movq " ++ byteOffset(row + limbs) ++ "(" ++ acc ++ "), %%rax\n";
    text = text ++ "addq " ++ high ++ ", %%rax\n";
    text = text ++ "adcq $0, %%r15\n";
    text = text ++ "addq %%r12, %%rax\n";
    text = text ++ "adcq $0, %%r15\n";
    text = text ++ "movq %%rax, " ++ byteOffset(row + limbs) ++ "(" ++ acc ++ ")\n";

    return text;
}

// --------------------------------------------------------- //
// Public:

/// The fused CIOS multiply: a runtime outer loop over `rhs[i]`, the multiply pass
/// and the reduce pass each a dual carry chain, the factor step, and the one-limb
/// shift (the reduce pass writes `acc[col - 1]`).
///
/// Note:
/// - Registers: rdi=acc (limbs + 2), rsi=lhs, r12=rhs, r13=n, r14=n0inv, r15=i,
///   rdx=multiplier, r8=low, r9/r10=alternating high, r11=zero, rax=scratch.
///
/// Param:
/// limbs - usize (comptime, the modulus width in 64-bit limbs)
///
/// Return:
/// - []const u8 (the asm text)
pub fn mulBody(comptime limbs: usize) []const u8 {
    @setEvalBranchQuota(400_000);

    const off_top = byteOffset(limbs);
    const off_top_m1 = byteOffset(limbs - 1);
    const off_top_p1 = byteOffset(limbs + 1);
    var high: []const u8 = undefined;

    var text: []const u8 = "xorl %%r15d, %%r15d\n";
    text = text ++ "1:\n";
    text = text ++ "movq (%%r12,%%r15,8), %%rdx\n";

    // Multiply pass: acc[0..limbs] += lhs * rhs[i]
    text = text ++ "xorl %%r11d, %%r11d\n";
    text = text ++ rowText("%%rsi", "%%rdi", 0, limbs, 0, 0, &high);

    // acc[limbs] += carry, overflow into acc[limbs + 1]
    text = text ++ "movq " ++ off_top ++ "(%%rdi), %%r8\n";
    text = text ++ "addq " ++ high ++ ", %%r8\n";
    text = text ++ "movq %%r8, " ++ off_top ++ "(%%rdi)\n";
    text = text ++ "movl $0, %%r8d\n";
    text = text ++ "adcq $0, %%r8\n";
    text = text ++ "movq %%r8, " ++ off_top_p1 ++ "(%%rdi)\n";

    // factor = acc[0] * n0inv
    text = text ++ "movq 0(%%rdi), %%rdx\n";
    text = text ++ "imulq %%r14, %%rdx\n";

    // Reduce pass: acc += n * factor, written shifted to acc[col - 1]
    text = text ++ "xorl %%r11d, %%r11d\n";
    text = text ++ rowText("%%r13", "%%rdi", 0, limbs, 0, 1, &high);

    // acc[limbs - 1] = acc[limbs] + carry, acc[limbs] = acc[limbs + 1] + overflow
    text = text ++ "movq " ++ off_top ++ "(%%rdi), %%r8\n";
    text = text ++ "addq " ++ high ++ ", %%r8\n";
    text = text ++ "movq %%r8, " ++ off_top_m1 ++ "(%%rdi)\n";
    text = text ++ "movq " ++ off_top_p1 ++ "(%%rdi), %%r8\n";
    text = text ++ "adcq $0, %%r8\n";
    text = text ++ "movq %%r8, " ++ off_top ++ "(%%rdi)\n";

    text = text ++ "incq %%r15\n";
    text = text ++ "cmpq $" ++ std.fmt.comptimePrint("{d}", .{limbs}) ++ ", %%r15\n";
    text = text ++ "jb 1b\n";

    return text;
}

/// The dedicated square (SOS form): the upper triangle `a[i] * a[j]`, j > i, once,
/// then doubled with the diagonal `a[i]^2` added in the same pass (CF doubles, OF
/// adds), then the Montgomery reduction of the 2 * limbs product.
///
/// Note:
/// - Registers: rdi=acc (2 * limbs + 1, zeroed), rsi=a, r13=n, r14=n0inv,
///   rdx=multiplier, r8=low, r9/r10=alternating high, r11=zero or row count,
///   r12/r15=top carry, rcx=row pointer, rax=scratch.
/// - The top carry lands in acc[2 * limbs].
///
/// Param:
/// limbs - usize (comptime, the modulus width in 64-bit limbs)
///
/// Return:
/// - []const u8 (the asm text)
pub fn sqrBody(comptime limbs: usize) []const u8 {
    @setEvalBranchQuota(4_000_000);

    var high: []const u8 = undefined;
    var text: []const u8 = "";

    // 1. Upper triangle, one dual-chain row per a[i]
    for (0..limbs - 1) |row| {
        text = text ++ "movq " ++ byteOffset(row) ++ "(%%rsi), %%rdx\n";
        text = text ++ "xorl %%r11d, %%r11d\n";
        text = text ++ rowText("%%rsi", "%%rdi", row + 1, limbs, 2 * row + 1, 0, &high);
        text = text ++ "movq " ++ high ++ ", " ++ byteOffset(row + limbs) ++ "(%%rdi)\n";
    }

    // 2. Double and add the diagonal
    text = text ++ "xorl %%r11d, %%r11d\n";
    for (0..limbs) |row| {
        text = text ++ "movq " ++ byteOffset(row) ++ "(%%rsi), %%rdx\n";
        text = text ++ "mulxq %%rdx, %%r8, %%r9\n";
        text = text ++ "movq " ++ byteOffset(2 * row) ++ "(%%rdi), %%rax\n";
        text = text ++ "adcxq %%rax, %%rax\n";
        text = text ++ "adoxq %%r8, %%rax\n";
        text = text ++ "movq %%rax, " ++ byteOffset(2 * row) ++ "(%%rdi)\n";
        text = text ++ "movq " ++ byteOffset(2 * row + 1) ++ "(%%rdi), %%rax\n";
        text = text ++ "adcxq %%rax, %%rax\n";
        text = text ++ "adoxq %%r9, %%rax\n";
        text = text ++ "movq %%rax, " ++ byteOffset(2 * row + 1) ++ "(%%rdi)\n";
    }

    // 3. Montgomery reduction, top carry in r15
    text = text ++ "xorl %%r15d, %%r15d\n";

    if (limbs <= UNROLL_REDUCE_MAX_LIMBS) {
        for (0..limbs) |row| text = text ++ reduceRowText("%%rdi", row, limbs);
    } else {
        text = text ++ "movq %%rdi, %%rcx\n";
        text = text ++ "movl $" ++ std.fmt.comptimePrint("{d}", .{limbs}) ++ ", %%r11d\n";
        text = text ++ "2:\n";
        text = text ++ reduceRowText("%%rcx", 0, limbs);
        text = text ++ "addq $8, %%rcx\n";
        text = text ++ "decq %%r11\n";
        text = text ++ "jnz 2b\n";
    }

    text = text ++ "movq %%r15, " ++ byteOffset(2 * limbs) ++ "(%%rdi)\n";

    return text;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn countOf(comptime text: []const u8, comptime needle: []const u8) usize {
    return comptime std.mem.count(u8, text, needle);
}

test "tlz crypto montgomery: asm_body, mulBody runs two MULX passes per outer step" {
    try std.testing.expectEqual(@as(usize, 2 * 16), countOf(comptime mulBody(16), "mulxq"));
}

test "tlz crypto montgomery: asm_body, mulBody loops over every limb of rhs" {
    try std.testing.expect(std.mem.find(u8, comptime mulBody(16), "cmpq $16, %%r15") != null);
}

test "tlz crypto montgomery: asm_body, sqrBody unrolled has triangle, diagonal, and reduce" {
    const limbs = 16;
    const triangle = limbs * (limbs - 1) / 2;
    const reduce = limbs * limbs;
    const body = comptime sqrBody(limbs);

    try std.testing.expectEqual(triangle + limbs + reduce, countOf(body, "mulxq"));
}

test "tlz crypto montgomery: asm_body, sqrBody above the unroll cap loops the reduce" {
    const limbs = 24;
    const triangle = limbs * (limbs - 1) / 2;
    const body = comptime sqrBody(limbs);

    try std.testing.expectEqual(triangle + limbs + limbs, countOf(body, "mulxq"));
    try std.testing.expect(std.mem.find(u8, body, "jnz 2b") != null);
}

test "tlz crypto montgomery: asm_body, sqrBody stores the top carry last" {
    const body = comptime sqrBody(16);

    try std.testing.expect(std.mem.endsWith(u8, body, "movq %%r15, 256(%%rdi)\n"));
}

