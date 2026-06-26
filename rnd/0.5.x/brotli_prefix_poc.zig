//! Brotli prefix codes PoC (RFC 7932 section 3), decoder phase D2.
//!
//! Note:
//! - The core primitive every later phase consumes: canonical Huffman decode plus the
//!   two prefix-code encodings, simple (sec 3.4) and complex (sec 3.5).
//! - Bit convention (sec 1.5.1): the stream is read LSB-first. Integer values are
//!   packed LSB-first. Prefix codes are packed MSB-first, so the FIRST bit read for a
//!   code is its most-significant bit, a plain tree walk consumes the code MSB-to-LSB
//!   with no reversal.
//! - This file is self-contained and test-only (no zix deps, no main). Validate with:
//!   zig test rnd/0.5.x/brotli_prefix_poc.zig
//! - Not yet wired into the framing decoder (brotli_decoder_poc.zig): the first prefix
//!   code in a compressed meta-block sits behind the block-switch preamble (phase D3).

const std = @import("std");

const MAX_CODE_LEN = 15;
const MAX_SYMBOLS = 1024; // brotli's largest prefix alphabet (insert-and-copy = 704)

pub const DecodeError = error{
    EndOfStream,
    InvalidSymbol,
    DuplicateSymbol,
    InvalidCode,
    Overflow,
};

/// LSB-first bit reader (sec 1.5.1).
pub const BitReader = struct {
    bytes: []const u8,
    byte_pos: usize = 0,
    bit_pos: u3 = 0,

    pub fn readBit(self: *BitReader) DecodeError!u1 {
        if (self.byte_pos >= self.bytes.len) return error.EndOfStream;

        const bit: u1 = @truncate(self.bytes[self.byte_pos] >> self.bit_pos);
        if (self.bit_pos == 7) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        } else {
            self.bit_pos += 1;
        }

        return bit;
    }

    pub fn readBits(self: *BitReader, n: u6) DecodeError!u32 {
        var value: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            value |= @as(u32, try self.readBit()) << @intCast(i);
        }

        return value;
    }

    /// Discard the remaining bits of the current byte (sec 9.2 fill bits before raw or
    /// metadata bytes). The discarded bits are not validated to be zero here.
    pub fn alignToByte(self: *BitReader) void {
        if (self.bit_pos != 0) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }
    }

    /// Return the next n bytes and advance, the reader must already be byte-aligned.
    pub fn readBytes(self: *BitReader, n: usize) DecodeError![]const u8 {
        if (self.byte_pos + n > self.bytes.len) return error.EndOfStream;

        const slice = self.bytes[self.byte_pos .. self.byte_pos + n];
        self.byte_pos += n;

        return slice;
    }
};

/// Canonical prefix-code decoder built from per-symbol code lengths (sec 3.2).
pub const HuffmanDecoder = struct {
    single_symbol: ?u16 = null,
    count: [MAX_CODE_LEN + 1]u16 = std.mem.zeroes([MAX_CODE_LEN + 1]u16),
    first_code: [MAX_CODE_LEN + 1]u16 = std.mem.zeroes([MAX_CODE_LEN + 1]u16),
    first_symbol: [MAX_CODE_LEN + 1]u16 = std.mem.zeroes([MAX_CODE_LEN + 1]u16),
    symbols: [MAX_SYMBOLS]u16 = undefined,

    pub fn build(lengths: []const u8) DecodeError!HuffmanDecoder {
        var self = HuffmanDecoder{};

        var nonzero: u16 = 0;
        var last_nonzero: u16 = 0;
        for (lengths, 0..) |len, sym| {
            if (len > MAX_CODE_LEN) return error.InvalidCode;
            if (len != 0) {
                self.count[len] += 1;
                nonzero += 1;
                last_nonzero = @intCast(sym);
            }
        }

        // sec 3.4 / 3.5: a code with a single participating symbol emits no bits.
        if (nonzero <= 1) {
            self.single_symbol = if (nonzero == 1) last_nonzero else 0;
            return self;
        }

        var code: u16 = 0;
        var sym_off: u16 = 0;
        var len: usize = 1;
        while (len <= MAX_CODE_LEN) : (len += 1) {
            code = (code + self.count[len - 1]) << 1;
            self.first_code[len] = code;
            self.first_symbol[len] = sym_off;
            sym_off += self.count[len];
        }

        var fill = self.first_symbol;
        for (lengths, 0..) |len_s, sym| {
            if (len_s != 0) {
                self.symbols[fill[len_s]] = @intCast(sym);
                fill[len_s] += 1;
            }
        }

        return self;
    }

    pub fn readSymbol(self: *const HuffmanDecoder, br: *BitReader) DecodeError!u16 {
        if (self.single_symbol) |s| return s;

        var code: u16 = 0;
        var len: usize = 1;
        while (len <= MAX_CODE_LEN) : (len += 1) {
            code = (code << 1) | (try br.readBit());
            if (self.count[len] != 0) {
                const rel = code -% self.first_code[len];
                if (rel < self.count[len]) return self.symbols[self.first_symbol[len] + rel];
            }
        }

        return error.InvalidCode;
    }
};

/// Smallest bit width that represents every symbol in the alphabet (sec 3.4).
pub fn alphabetBits(alphabet_size: usize) u6 {
    if (alphabet_size <= 1) return 0;

    return @intCast(32 - @clz(@as(u32, @intCast(alphabet_size - 1))));
}

/// The static code over code-length-code lengths 0..5 (sec 3.5 table), read LSB-first.
fn readCodeLengthCodeLength(br: *BitReader) DecodeError!u8 {
    if (try br.readBit() == 0) {
        return if (try br.readBit() == 0) 0 else 3;
    }
    if (try br.readBit() == 0) return 4;
    if (try br.readBit() == 0) return 2;
    return if (try br.readBit() == 0) 1 else 5;
}

/// Read the code lengths of the 18-symbol code-length alphabet (sec 3.5).
fn readCodeLengthCode(br: *BitReader, hskip: u32, out: *[18]u8) DecodeError!void {
    const order = [_]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    @memset(out, 0);

    var space: i64 = 32;
    var i: usize = hskip;
    while (i < 18) : (i += 1) {
        const len = try readCodeLengthCodeLength(br);
        out[order[i]] = len;
        if (len != 0) {
            space -= @as(i64, 32) >> @intCast(len);
            if (space <= 0) break;
        }
    }
}

/// Read the per-symbol code lengths using the code-length code, with repeat codes
/// 16 (copy previous, 3..6) and 17 (zeros, 3..10), modification rule per sec 3.5.
fn readSymbolLengths(br: *BitReader, cl: *const HuffmanDecoder, alphabet_size: usize, out: []u8) DecodeError!void {
    @memset(out[0..alphabet_size], 0);

    var symbol: usize = 0;
    var prev_code_len: u8 = 8;
    var repeat: u32 = 0;
    var repeat_code_len: u8 = 0;
    var space: i64 = 32768;

    while (symbol < alphabet_size and space > 0) {
        const code_len = try cl.readSymbol(br);
        if (code_len < 16) {
            repeat = 0;
            out[symbol] = @intCast(code_len);
            symbol += 1;
            if (code_len != 0) {
                prev_code_len = @intCast(code_len);
                space -= @as(i64, 32768) >> @intCast(code_len);
            }
        } else {
            const extra_bits: u6 = if (code_len == 16) 2 else 3;
            const new_len: u8 = if (code_len == 16) prev_code_len else 0;
            if (repeat_code_len != new_len) {
                repeat = 0;
                repeat_code_len = new_len;
            }
            const old_repeat = repeat;
            if (repeat > 0) {
                repeat -= 2;
                repeat <<= @intCast(extra_bits);
            }
            repeat += (try br.readBits(extra_bits)) + 3;
            const delta = repeat - old_repeat;
            if (symbol + delta > alphabet_size) return error.Overflow;

            var k: u32 = 0;
            while (k < delta) : (k += 1) {
                out[symbol] = repeat_code_len;
                symbol += 1;
            }
            if (repeat_code_len != 0) space -= @as(i64, delta) << @intCast(15 - repeat_code_len);
        }
    }
}

fn readSimplePrefixCode(br: *BitReader, alphabet_size: usize) DecodeError!HuffmanDecoder {
    const nsym = (try br.readBits(2)) + 1;
    const abits = alphabetBits(alphabet_size);

    var syms: [4]u16 = undefined;
    var i: u32 = 0;
    while (i < nsym) : (i += 1) {
        const s: u16 = @intCast(try br.readBits(abits));
        if (s >= alphabet_size) return error.InvalidSymbol;
        var j: u32 = 0;
        while (j < i) : (j += 1) if (syms[j] == s) return error.DuplicateSymbol;
        syms[i] = s;
    }

    if (nsym == 1) return .{ .single_symbol = syms[0] };

    var tree_select: u1 = 0;
    if (nsym == 4) tree_select = try br.readBit();

    var lengths: [MAX_SYMBOLS]u8 = undefined;
    @memset(lengths[0..alphabet_size], 0);
    switch (nsym) {
        2 => {
            lengths[syms[0]] = 1;
            lengths[syms[1]] = 1;
        },
        3 => {
            lengths[syms[0]] = 1;
            lengths[syms[1]] = 2;
            lengths[syms[2]] = 2;
        },
        4 => {
            if (tree_select == 0) {
                for (syms) |s| lengths[s] = 2;
            } else {
                lengths[syms[0]] = 1;
                lengths[syms[1]] = 2;
                lengths[syms[2]] = 3;
                lengths[syms[3]] = 3;
            }
        },
        else => unreachable,
    }

    return HuffmanDecoder.build(lengths[0..alphabet_size]);
}

fn readComplexPrefixCode(br: *BitReader, alphabet_size: usize, hskip: u32) DecodeError!HuffmanDecoder {
    var cl_lengths: [18]u8 = undefined;
    try readCodeLengthCode(br, hskip, &cl_lengths);

    const cl = try HuffmanDecoder.build(&cl_lengths);

    var sym_lengths: [MAX_SYMBOLS]u8 = undefined;
    try readSymbolLengths(br, &cl, alphabet_size, &sym_lengths);

    return HuffmanDecoder.build(sym_lengths[0..alphabet_size]);
}

/// Read one prefix code (sec 3.4/3.5). The 2-bit prefix is 1 for simple, otherwise it
/// is HSKIP (0, 2, or 3) for a complex code.
pub fn readPrefixCode(br: *BitReader, alphabet_size: usize) DecodeError!HuffmanDecoder {
    const selector = try br.readBits(2);
    if (selector == 1) return readSimplePrefixCode(br, alphabet_size);

    return readComplexPrefixCode(br, alphabet_size, selector);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const testing = std.testing;

/// LSB-first bit writer, test helper to build streams without hand-packing bytes.
const BitWriter = struct {
    buf: [256]u8 = std.mem.zeroes([256]u8),
    nbits: usize = 0,

    fn writeBit(self: *BitWriter, b: u1) void {
        if (b == 1) self.buf[self.nbits / 8] |= (@as(u8, 1) << @intCast(self.nbits % 8));
        self.nbits += 1;
    }

    /// Integer value, LSB-first (for fixed-width integer elements).
    fn writeInt(self: *BitWriter, value: u32, n: u6) void {
        var i: u6 = 0;
        while (i < n) : (i += 1) self.writeBit(@truncate(value >> @intCast(i)));
    }

    /// Prefix-code bits, MSB-first (matches how codes are packed, sec 1.5.1).
    fn writeCode(self: *BitWriter, value: u32, n: u6) void {
        var i: u6 = n;
        while (i > 0) {
            i -= 1;
            self.writeBit(@truncate(value >> @intCast(i)));
        }
    }

    fn reader(self: *const BitWriter) BitReader {
        return .{ .bytes = self.buf[0 .. (self.nbits + 7) / 8] };
    }
};

test "huffman: canonical lengths (2,1,3,3) decode in symbol order" {
    // sec 3.2 worked example: sym1="0", sym0="10", sym2="110", sym3="111".
    const d = try HuffmanDecoder.build(&[_]u8{ 2, 1, 3, 3 });

    var bw = BitWriter{};
    bw.writeCode(0b0, 1); // sym 1
    bw.writeCode(0b10, 2); // sym 0
    bw.writeCode(0b110, 3); // sym 2
    bw.writeCode(0b111, 3); // sym 3

    var br = bw.reader();
    try testing.expectEqual(@as(u16, 1), try d.readSymbol(&br));
    try testing.expectEqual(@as(u16, 0), try d.readSymbol(&br));
    try testing.expectEqual(@as(u16, 2), try d.readSymbol(&br));
    try testing.expectEqual(@as(u16, 3), try d.readSymbol(&br));
}

test "huffman: single-symbol code emits no bits" {
    var lengths = std.mem.zeroes([8]u8);
    lengths[5] = 1; // only one participating symbol
    const d = try HuffmanDecoder.build(&lengths);

    var br = BitReader{ .bytes = &.{} };
    try testing.expectEqual(@as(u16, 5), try d.readSymbol(&br)); // no bits consumed
}

test "code-length-code: static table 0,3,4,2,1,5" {
    var bw = BitWriter{};
    bw.writeBit(0);
    bw.writeBit(0); // 0
    bw.writeBit(0);
    bw.writeBit(1); // 3
    bw.writeBit(1);
    bw.writeBit(0); // 4
    bw.writeBit(1);
    bw.writeBit(1);
    bw.writeBit(0); // 2
    bw.writeBit(1);
    bw.writeBit(1);
    bw.writeBit(1);
    bw.writeBit(0); // 1
    bw.writeBit(1);
    bw.writeBit(1);
    bw.writeBit(1);
    bw.writeBit(1); // 5

    var br = bw.reader();
    for ([_]u8{ 0, 3, 4, 2, 1, 5 }) |expected| {
        try testing.expectEqual(expected, try readCodeLengthCodeLength(&br));
    }
}

test "simple prefix code: nsym=2 over alphabet 4" {
    var bw = BitWriter{};
    bw.writeInt(1, 2); // selector = simple
    bw.writeInt(1, 2); // NSYM - 1 = 1 (NSYM = 2)
    bw.writeInt(3, 2); // symbol 3 (abits = 2)
    bw.writeInt(1, 2); // symbol 1
    // both length 1, canonical sorts: sym1 -> "0", sym3 -> "1"
    bw.writeCode(0, 1); // decode -> sym 1
    bw.writeCode(1, 1); // decode -> sym 3

    var br = bw.reader();
    const d = try readPrefixCode(&br, 4);
    try testing.expectEqual(@as(u16, 1), try d.readSymbol(&br));
    try testing.expectEqual(@as(u16, 3), try d.readSymbol(&br));
}

test "complex prefix code: builds [2,2,2,2] over alphabet 4" {
    var bw = BitWriter{};
    bw.writeInt(0, 2); // selector = HSKIP 0 -> complex
    // code-length-code lengths, order starts at symbol 1 then 2 (both length 1).
    // static code for length 1 is "0111" -> read bits 1,1,1,0.
    for ([_]u1{ 1, 1, 1, 0 }) |b| bw.writeBit(b); // symbol 1 -> len 1
    for ([_]u1{ 1, 1, 1, 0 }) |b| bw.writeBit(b); // symbol 2 -> len 1, space fills, stop
    // cl-code: sym1 -> "0", sym2 -> "1". Emit code-length symbol 2 four times ("1").
    bw.writeCode(1, 1);
    bw.writeCode(1, 1);
    bw.writeCode(1, 1);
    bw.writeCode(1, 1);
    // main code [2,2,2,2]: "00","01","10","11". Decode sym2 then sym0.
    bw.writeCode(0b10, 2);
    bw.writeCode(0b00, 2);

    var br = bw.reader();
    const d = try readPrefixCode(&br, 4);
    try testing.expectEqual(@as(u16, 2), try d.readSymbol(&br));
    try testing.expectEqual(@as(u16, 0), try d.readSymbol(&br));
}
