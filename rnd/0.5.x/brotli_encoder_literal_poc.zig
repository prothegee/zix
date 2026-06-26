//! Brotli encoder PoC, phase E2 (RFC 7932), literal-only compressed meta-blocks.
//!
//! Note:
//! - Builds on E1 (rnd/0.5.x/brotli_encoder_poc.zig, store-only). E2 emits a real
//!   COMPRESSED meta-block: the full preamble (sec 9.2), three prefix codes (literal,
//!   insert-and-copy, distance), and one command that inserts every byte as a literal with
//!   the copy skipped at MLEN (sec 10, the loop ends when produced bytes reach MLEN before
//!   the copy runs). No LZ77 matching yet, that is E3.
//! - Literal code (sec 3): a SIMPLE prefix code (sec 3.4) when the input has 1..4 distinct
//!   bytes (first real ratio on low-cardinality data), otherwise a FIXED balanced code
//!   (sec 3.5 complex) giving about log2(k) bits per byte over the k distinct values. The
//!   per-block OPTIMAL Huffman plus context modeling is the later, larger E5 win.
//! - The single meta-block is marked ISLAST=1, so the stream needs no trailing empty block.
//!   Input is capped at one meta-block (MLEN <= 2^24); larger input is an E2 limitation.
//! - Verified by self round-trip through the full decoder (brotli_conformance_poc.zig) and
//!   by the `brotli -dc` interop gate (rnd/0.5.x/verify-brotli-encoder.sh extension).
//!
//! Run: zig run rnd/0.5.x/brotli_encoder_literal_poc.zig

const std = @import("std");
const cmd_tables = @import("brotli_command_poc.zig");
const decoder = @import("brotli_conformance_poc.zig");

/// MLEN caps at 2^24 (sec 9.2), so one compressed meta-block carries at most 16 MiB.
pub const MAX_META_BLOCK_LEN: usize = 1 << 24;

pub const MAX_CODE_LEN = 15;

pub const EncodeError = error{
    InvalidWindowBits,
    InputTooLarge,
    OutOfMemory,
};

/// LSB-first bit writer. Integer fields are packed LSB-first (writeInt), prefix-code bits
/// MSB-first (writeCode), matching the decoder's reader (sec 1.5.1).
pub const BitWriter = struct {
    bytes: std.ArrayList(u8) = .empty,
    bit_pos: u3 = 0,

    pub fn deinit(self: *BitWriter, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }

    pub fn writeBit(self: *BitWriter, allocator: std.mem.Allocator, bit: u1) EncodeError!void {
        if (self.bit_pos == 0) try self.bytes.append(allocator, 0);

        const idx = self.bytes.items.len - 1;
        self.bytes.items[idx] |= @as(u8, bit) << self.bit_pos;
        self.bit_pos = if (self.bit_pos == 7) 0 else self.bit_pos + 1;
    }

    /// An integer field, least-significant bit first.
    pub fn writeInt(self: *BitWriter, allocator: std.mem.Allocator, value: u32, n: u6) EncodeError!void {
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            try self.writeBit(allocator, @truncate(value >> @intCast(i)));
        }
    }

    /// A prefix-code value, most-significant bit first (how canonical codes are packed).
    pub fn writeCode(self: *BitWriter, allocator: std.mem.Allocator, value: u32, n: u6) EncodeError!void {
        var i: u6 = n;
        while (i > 0) {
            i -= 1;
            try self.writeBit(allocator, @truncate(value >> @intCast(i)));
        }
    }

    pub fn toOwnedSlice(self: *BitWriter, allocator: std.mem.Allocator) EncodeError![]u8 {
        return self.bytes.toOwnedSlice(allocator);
    }
};

/// Canonical prefix-code values from per-symbol code lengths, the encoder twin of the
/// decoder's HuffmanDecoder.build (sec 3.2). codes_out[s] holds the MSB-first code for
/// symbol s, valid only where lengths[s] != 0.
pub fn buildCanonicalCodes(lengths: []const u8, codes_out: []u16) void {
    var count = std.mem.zeroes([MAX_CODE_LEN + 1]u16);
    for (lengths) |len| {
        if (len != 0) count[len] += 1;
    }

    var next_code = std.mem.zeroes([MAX_CODE_LEN + 1]u16);
    var code: u16 = 0;
    var len: usize = 1;
    while (len <= MAX_CODE_LEN) : (len += 1) {
        code = (code + count[len - 1]) << 1;
        next_code[len] = code;
    }

    for (lengths, 0..) |len_s, s| {
        if (len_s != 0) {
            codes_out[s] = next_code[len_s];
            next_code[len_s] += 1;
        }
    }
}

/// Smallest bit width that addresses every symbol of the alphabet (sec 3.4 simple codes).
pub fn alphabetBits(alphabet_size: usize) u6 {
    if (alphabet_size <= 1) return 0;

    return @intCast(32 - @clz(@as(u32, @intCast(alphabet_size - 1))));
}

/// Emit the stream window size, the inverse of the decoder's readWindowBits (sec 9.1).
pub fn writeWindowBits(bw: *BitWriter, allocator: std.mem.Allocator, wbits: u6) EncodeError!void {
    if (wbits < 10 or wbits > 24) return error.InvalidWindowBits;

    if (wbits == 16) {
        try bw.writeBit(allocator, 0);
        return;
    }

    try bw.writeBit(allocator, 1);

    if (wbits >= 18 and wbits <= 24) {
        try bw.writeInt(allocator, wbits - 17, 3);
        return;
    }

    try bw.writeInt(allocator, 0, 3);
    if (wbits == 17) {
        try bw.writeInt(allocator, 0, 3);
        return;
    }

    try bw.writeInt(allocator, wbits - 8, 3);
}

/// Emit MNIBBLES + (MLEN - 1) with the minimal nibble count (sec 9.2).
pub fn writeMetaBlockLen(bw: *BitWriter, allocator: std.mem.Allocator, mlen: usize) EncodeError!void {
    const value: u32 = @intCast(mlen - 1);

    const nibbles: u6 = if (value < (1 << 16)) 4 else if (value < (1 << 20)) 5 else 6;

    try bw.writeInt(allocator, nibbles - 4, 2);
    try bw.writeInt(allocator, value, nibbles * 4);
}

/// Largest insert-length code whose base is within reach of value (sec 5). The contiguous
/// code ranges guarantee the remainder fits the code's extra bits.
pub fn selectInsertCode(value: u32) u8 {
    var code: u8 = @intCast(cmd_tables.INSERT_LEN_BASE.len - 1);
    while (cmd_tables.INSERT_LEN_BASE[code] > value) code -= 1;

    return code;
}

/// Compose an insert-and-copy command symbol with the chosen insert code and copy code 0
/// (sec 5). The copy never runs, so copy code 0 (two-byte copy, no extra bits) is free.
pub fn composeCommand(insert_code: u8) u16 {
    // cell 0 covers insert codes 0..7, cell 4 covers 8..15, cell 7 covers 16..23, each with
    // copy base 0. The command is cell * 64 + (insert offset << 3) + copy offset(0).
    if (insert_code <= 7) return @as(u16, insert_code) << 3;
    if (insert_code <= 15) return 256 + (@as(u16, insert_code - 8) << 3);

    return 448 + (@as(u16, insert_code - 16) << 3);
}

/// Emit a single-symbol prefix code in the simple format (sec 3.4, NSYM=1): selector 1,
/// NSYM-1 = 0, then the symbol value. The decoder returns it with no bits consumed.
pub fn writeSingleSymbolCode(bw: *BitWriter, allocator: std.mem.Allocator, symbol: u16, alphabet_size: usize) EncodeError!void {
    try bw.writeInt(allocator, 1, 2);
    try bw.writeInt(allocator, 0, 2);
    try bw.writeInt(allocator, symbol, alphabetBits(alphabet_size));
}

/// A balanced (complete) set of code lengths over count distinct leaves, lengths within one
/// bit of log2(count). Returns the max length used. count must be >= 1.
pub fn balancedLengths(count: usize, out: []u8) u8 {
    if (count == 1) {
        out[0] = 1;
        return 1;
    }

    var log2_ceil: u8 = 0;
    while ((@as(usize, 1) << @intCast(log2_ceil)) < count) log2_ceil += 1;

    const capacity = @as(usize, 1) << @intCast(log2_ceil);
    const n_short = capacity - count; // leaves at depth log2_ceil - 1
    var i: usize = 0;
    while (i < count) : (i += 1) out[i] = if (i < n_short) log2_ceil - 1 else log2_ceil;

    return log2_ceil;
}

pub const LiteralCode = struct {
    lengths: [256]u8 = std.mem.zeroes([256]u8),
    codes: [256]u16 = undefined,
};

/// Build the literal code lengths. 1..4 distinct bytes use a simple code (the syms array
/// holds the chosen order, most frequent first). 5+ distinct bytes use the balanced code,
/// the most frequent value getting the shortest leaf.
pub fn buildLiteralCode(input: []const u8, syms_out: []u16, nsym_out: *usize) LiteralCode {
    var freq = std.mem.zeroes([256]u32);
    for (input) |b| freq[b] += 1;

    var order: [256]u16 = undefined;
    var distinct: usize = 0;
    for (freq, 0..) |f, v| {
        if (f != 0) {
            order[distinct] = @intCast(v);
            distinct += 1;
        }
    }

    // sort distinct symbols by frequency descending, tie-break by value (stable insertion).
    var a: usize = 1;
    while (a < distinct) : (a += 1) {
        const cur = order[a];
        var b: usize = a;
        while (b > 0 and freq[order[b - 1]] < freq[cur]) : (b -= 1) order[b] = order[b - 1];
        order[b] = cur;
    }

    var lc = LiteralCode{};

    if (distinct == 1) {
        // a single-symbol code is decoded with zero bits, so the literal length stays 0 and
        // no per-literal bits are emitted.
        syms_out[0] = order[0];
        nsym_out.* = 1;
    } else if (distinct <= 4) {
        var bal: [4]u8 = undefined;
        _ = balancedLengths(distinct, &bal);
        var i: usize = 0;
        while (i < distinct) : (i += 1) {
            lc.lengths[order[i]] = bal[i];
            syms_out[i] = order[i];
        }
        nsym_out.* = distinct;
    } else {
        var bal: [256]u8 = undefined;
        _ = balancedLengths(distinct, &bal);
        var i: usize = 0;
        while (i < distinct) : (i += 1) lc.lengths[order[i]] = bal[i];
        nsym_out.* = 0;
    }

    buildCanonicalCodes(&lc.lengths, &lc.codes);

    return lc;
}

/// The static code-length-code table (sec 3.5), one entry per code-length value 0..5,
/// each the bit sequence the decoder reads (in stream order).
const CL_LEN_BITS = [6][]const u1{
    &[_]u1{ 0, 0 }, // 0
    &[_]u1{ 1, 1, 1, 0 }, // 1
    &[_]u1{ 1, 1, 0 }, // 2
    &[_]u1{ 0, 1 }, // 3
    &[_]u1{ 1, 0 }, // 4
    &[_]u1{ 1, 1, 1, 1 }, // 5
};

const CL_ORDER = [_]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

/// Emit a complex prefix code (sec 3.5) over any alphabet: HSKIP 0 selector, the
/// code-length-code description, then every per-symbol length up to the last used symbol.
/// The code must have at least two participating symbols (single-symbol codes use the
/// simple format instead).
pub fn writeComplexCode(bw: *BitWriter, allocator: std.mem.Allocator, lengths: []const u8) EncodeError!void {
    try bw.writeInt(allocator, 0, 2); // selector = HSKIP 0 -> complex

    var last_used: usize = 0;
    for (lengths, 0..) |len, s| {
        if (len != 0) last_used = s;
    }

    // the code-length alphabet uses the distinct length values present in 0..last_used.
    var cl_present = std.mem.zeroes([18]bool);
    var s: usize = 0;
    while (s <= last_used) : (s += 1) cl_present[lengths[s]] = true;

    var cl_distinct: usize = 0;
    var cl_values: [18]u8 = undefined;
    for (cl_present, 0..) |present, v| {
        if (present) {
            cl_values[cl_distinct] = @intCast(v);
            cl_distinct += 1;
        }
    }

    var cl_bal: [18]u8 = undefined;
    _ = balancedLengths(cl_distinct, &cl_bal);

    var cl_lengths = std.mem.zeroes([18]u8);
    var i: usize = 0;
    while (i < cl_distinct) : (i += 1) cl_lengths[cl_values[i]] = cl_bal[i];

    // emit the code-length-code lengths in the fixed order via the static table, stopping
    // the moment the code is complete (space hits 0), exactly as the decoder stops reading.
    var space: i64 = 32;
    for (CL_ORDER) |sym| {
        const cl_len = cl_lengths[sym];
        for (CL_LEN_BITS[cl_len]) |bit| try bw.writeBit(allocator, bit);
        if (cl_len != 0) {
            space -= @as(i64, 32) >> @intCast(cl_len);
            if (space <= 0) break;
        }
    }

    // a single-value code-length-code emits no per-symbol bits (decoder reads it implicitly).
    if (cl_distinct <= 1) return;

    var cl_codes: [18]u16 = undefined;
    buildCanonicalCodes(&cl_lengths, &cl_codes);

    s = 0;
    while (s <= last_used) : (s += 1) {
        const len_val = lengths[s];
        try bw.writeCode(allocator, cl_codes[len_val], @intCast(cl_lengths[len_val]));
    }
}

/// Emit HTREEL: a simple prefix code for 1..4 distinct bytes (syms holds the chosen order),
/// otherwise the balanced complex code. Shared by E2 and later phases.
pub fn writeLiteralCode(bw: *BitWriter, allocator: std.mem.Allocator, lc: *const LiteralCode, syms: []const u16, nsym: usize) EncodeError!void {
    if (nsym >= 1 and nsym <= 4) {
        if (nsym == 1) {
            try writeSingleSymbolCode(bw, allocator, syms[0], 256);
        } else {
            try bw.writeInt(allocator, 1, 2); // selector = simple
            try bw.writeInt(allocator, @intCast(nsym - 1), 2);
            for (syms[0..nsym]) |sym| try bw.writeInt(allocator, sym, 8);
            if (nsym == 4) try bw.writeBit(allocator, 0); // tree-select 0 -> all length 2
        }
        return;
    }

    try writeComplexCode(bw, allocator, &lc.lengths);
}

/// Encode input as a single literal-only compressed brotli meta-block (phase E2).
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// input - []const u8 (bytes to compress, at most 2^24)
/// wbits - u6 (window log, 10..24)
///
/// Return:
/// - []u8 (a valid brotli stream, caller frees)
/// - error.InvalidWindowBits / error.InputTooLarge / error.OutOfMemory
fn encodeLiteralBlockAlloc(allocator: std.mem.Allocator, input: []const u8, wbits: u6) EncodeError![]u8 {
    if (input.len > MAX_META_BLOCK_LEN) return error.InputTooLarge;

    var bw: BitWriter = .{};
    errdefer bw.deinit(allocator);

    try writeWindowBits(&bw, allocator, wbits);

    if (input.len == 0) {
        try bw.writeBit(allocator, 1); // ISLAST = 1
        try bw.writeBit(allocator, 1); // ISLASTEMPTY = 1

        return bw.toOwnedSlice(allocator);
    }

    // meta-block header: last, non-empty, MLEN, compressed (no ISUNCOMPRESSED when ISLAST).
    try bw.writeBit(allocator, 1); // ISLAST = 1
    try bw.writeBit(allocator, 0); // ISLASTEMPTY = 0
    try writeMetaBlockLen(&bw, allocator, input.len);

    // preamble: one block type per category, NPOSTFIX/NDIRECT zero, one literal context
    // mode (unused with one tree), one literal tree, one distance tree (sec 9.2).
    try bw.writeBit(allocator, 0); // NBLTYPESL = 1
    try bw.writeBit(allocator, 0); // NBLTYPESI = 1
    try bw.writeBit(allocator, 0); // NBLTYPESD = 1
    try bw.writeInt(allocator, 0, 2); // NPOSTFIX = 0
    try bw.writeInt(allocator, 0, 4); // NDIRECT = 0
    try bw.writeInt(allocator, 0, 2); // context mode LSB6 for the one literal block type
    try bw.writeBit(allocator, 0); // NTREESL = 1
    try bw.writeBit(allocator, 0); // NTREESD = 1

    // HTREEL: the literal code, simple for 1..4 distinct bytes else the balanced complex code.
    var syms: [4]u16 = undefined;
    var nsym: usize = 0;
    const lc = buildLiteralCode(input, &syms, &nsym);
    try writeLiteralCode(&bw, allocator, &lc, &syms, nsym);

    // HTREEI: one command. HTREED: one distance symbol (never read). Both single-symbol.
    const insert_code = selectInsertCode(@intCast(input.len));
    const command = composeCommand(insert_code);
    try writeSingleSymbolCode(&bw, allocator, command, 704);

    const dist_alphabet = 16 + (@as(usize, 48) << 0); // NDIRECT 0, NPOSTFIX 0 -> 64
    try writeSingleSymbolCode(&bw, allocator, 0, dist_alphabet);

    // the command body: insert all bytes (extra bits), copy code 0 has no extra bits, then
    // the literals. The decoder ends the meta-block when produced bytes reach MLEN (sec 10).
    const insert_extra: u6 = cmd_tables.INSERT_LEN_EXTRA[insert_code];
    try bw.writeInt(allocator, @as(u32, @intCast(input.len)) - cmd_tables.INSERT_LEN_BASE[insert_code], insert_extra);

    for (input) |b| try bw.writeCode(allocator, lc.codes[b], @intCast(lc.lengths[b]));

    return bw.toOwnedSlice(allocator);
}

/// Two modes:
/// - no args: encode a few in-memory samples and self-check the round-trip (diagnostics).
/// - `<input> <output.br>`: read input, literal-encode it, write the brotli stream to output
///   (feeds the `brotli -dc` interop gate, rnd/0.5.x/verify-brotli-encoder-literal.sh).
pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();

    const input_path = arg_iter.next();
    const output_path = arg_iter.next();

    if (input_path != null and output_path != null) {
        const io = process.io;
        const cwd = std.Io.Dir.cwd();

        const input = try cwd.readFileAlloc(io, input_path.?, allocator, .unlimited);
        const stream = try encodeLiteralBlockAlloc(allocator, input, 22);

        const f = try cwd.createFile(io, output_path.?, .{});
        defer f.close(io);

        var write_buf: [8192]u8 = undefined;
        var writer = f.writer(io, &write_buf);
        try writer.interface.writeAll(stream);
        try writer.interface.flush();

        return;
    }

    const samples = [_][]const u8{
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", // 1 distinct byte
        "abababababababababababab", // 2 distinct
        "the quick brown fox jumps over the lazy dog", // many distinct
    };

    for (samples) |sample| {
        const stream = try encodeLiteralBlockAlloc(allocator, sample, 22);
        const back = try decoder.decode(allocator, stream);

        const verdict = if (std.mem.eql(u8, back, sample)) "OK" else "MISMATCH";
        const pct = if (sample.len == 0) 0 else stream.len * 100 / sample.len;
        std.debug.print("[{d} bytes -> {d} bytes, {d}%] {s}\n", .{ sample.len, stream.len, pct, verdict });
    }
}

// --------------------------------------------------------- //
// test cases
// --------------------------------------------------------- //

const testing = std.testing;

fn roundTrip(input: []const u8, wbits: u6) !void {
    const stream = try encodeLiteralBlockAlloc(testing.allocator, input, wbits);
    defer testing.allocator.free(stream);

    const back = try decoder.decode(testing.allocator, stream);
    defer testing.allocator.free(back);

    try testing.expectEqualSlices(u8, input, back);
}

test "empty input round-trips" {
    try roundTrip("", 22);
}

test "single distinct byte round-trips and compresses hard" {
    var input: [500]u8 = undefined;
    @memset(&input, 'a');

    const stream = try encodeLiteralBlockAlloc(testing.allocator, &input, 22);
    defer testing.allocator.free(stream);

    const back = try decoder.decode(testing.allocator, stream);
    defer testing.allocator.free(back);

    try testing.expectEqualSlices(u8, &input, back);
    // a single-symbol literal code emits zero bits per byte, so 500 bytes pack tiny.
    try testing.expect(stream.len < 20);
}

test "two distinct bytes round-trip (simple nsym=2)" {
    var input: [200]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = if (i % 2 == 0) 'a' else 'b';

    try roundTrip(&input, 22);
}

test "three distinct bytes round-trip (simple nsym=3)" {
    try roundTrip("abcabcabcabcabcabcabc", 22);
}

test "four distinct bytes round-trip (simple nsym=4)" {
    try roundTrip("abcdabcdabcdabcdabcdabcd", 18);
}

test "many distinct bytes round-trip (balanced complex code)" {
    try roundTrip("the quick brown fox jumps over the lazy dog 0123456789", 22);
}

test "full byte alphabet round-trips (balanced over 256 symbols)" {
    var input: [256]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @intCast(i);

    try roundTrip(&input, 24);
}

test "low-cardinality text actually shrinks" {
    // five distinct bytes over 600 bytes: the balanced code is ~3 bits each, so well under
    // the input size even with the header overhead.
    const unit = "abcde";
    var input: [600]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = unit[i % unit.len];

    const stream = try encodeLiteralBlockAlloc(testing.allocator, &input, 22);
    defer testing.allocator.free(stream);

    try testing.expect(stream.len < input.len);

    const back = try decoder.decode(testing.allocator, stream);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, &input, back);
}

test "binary data with many byte values round-trips" {
    var input: [777]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @truncate(i * 131 + 17);

    try roundTrip(&input, 24);
}

test "out-of-range window bits is rejected" {
    try testing.expectError(error.InvalidWindowBits, encodeLiteralBlockAlloc(testing.allocator, "abc", 9));
}
