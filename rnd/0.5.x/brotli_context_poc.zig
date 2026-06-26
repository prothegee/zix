//! Brotli context modeling PoC (RFC 7932 section 7), decoder phase D4.
//!
//! Note:
//! - Builds on D1+D2+D3 (imports D3 brotli_meta_poc.zig for framing + the block-switch
//!   preamble, which transitively brings in D2 brotli_prefix_poc.zig for prefix codes).
//! - D4 covers the part of the meta-block header that follows NPOSTFIX / NDIRECT:
//!   the literal context modes (sec 7.1), NTREESL / NTREESD (sec 9.2, same variable
//!   length code as NBLTYPES), and the two context maps CMAPL / CMAPD (sec 7.3) with
//!   run-length-zero decoding, the context-map prefix code, and the inverse
//!   move-to-front transform. It stops at the per-block-type prefix codes (phase D5).
//! - Context ID computation (sec 7.1 Lut0/Lut1/Lut2 lookups, sec 7.2 distance context)
//!   is the consumer side used in the command loop, deferred to D5. D4 only decodes the
//!   maps that the command loop will index.
//! - Run the real-vector demo: zig run rnd/0.5.x/brotli_context_poc.zig
//!   Run the unit tests:      zig test rnd/0.5.x/brotli_context_poc.zig

const std = @import("std");
const m = @import("brotli_meta_poc.zig");
const p = @import("brotli_prefix_poc.zig");
const BitReader = p.BitReader;

// --------------------------------------------------------- //
// D4 primitives

/// Literal context mode (sec 7.1), two bits per literal block type.
pub const ContextMode = enum(u2) {
    LSB6 = 0,
    MSB6 = 1,
    UTF8 = 2,
    SIGNED = 3,
};

/// One context mode per literal block type, two bits each (sec 9.2 + sec 7.1).
pub fn readContextModes(br: *BitReader, nbltypesl: u32, out: []ContextMode) !void {
    var i: u32 = 0;
    while (i < nbltypesl) : (i += 1) out[i] = @enumFromInt(try br.readBits(2));
}

/// RLEMAX, the number of run-length codes (sec 7.3): a single 0 bit means 0, otherwise
/// the leading 1 is followed by four bits xxxx giving the value xxxx + 1 (range 1..16).
fn readRleMax(br: *BitReader) !u32 {
    if (try br.readBit() == 0) return 0;

    return (try br.readBits(4)) + 1;
}

/// The inverse move-to-front transform (sec 7.3), mapping the run-length-decoded values
/// back to prefix-code indexes in place.
fn inverseMoveToFront(v: []u8) void {
    var mtf: [256]u8 = undefined;
    for (&mtf, 0..) |*slot, i| slot.* = @intCast(i);

    for (v) |*vi| {
        const index = vi.*;
        const value = mtf[index];
        vi.* = value;

        var idx = index;
        while (idx > 0) : (idx -= 1) mtf[idx] = mtf[idx - 1];
        mtf[0] = value;
    }
}

/// Decode one context map of map_size values (sec 7.3): RLEMAX, a prefix code over
/// NTREES + RLEMAX symbols, the run-length-zero coded values, then the IMTF bit.
pub fn readContextMap(br: *BitReader, ntrees: u32, map_size: usize, out: []u8) !void {
    const rlemax = try readRleMax(br);
    const alphabet_size = ntrees + rlemax;

    const code = try p.readPrefixCode(br, alphabet_size);

    var i: usize = 0;
    while (i < map_size) {
        const sym = try code.readSymbol(br);
        if (sym == 0) {
            out[i] = 0;
            i += 1;
        } else if (sym <= rlemax) {
            const run = (@as(u32, 1) << @intCast(sym)) + (try br.readBits(@intCast(sym)));
            if (i + run > map_size) return error.ContextMapOverflow;

            var k: u32 = 0;
            while (k < run) : (k += 1) {
                out[i] = 0;
                i += 1;
            }
        } else {
            out[i] = @intCast(sym - rlemax);
            i += 1;
        }
    }

    const imtf = try br.readBit();
    if (imtf == 1) inverseMoveToFront(out[0..map_size]);
}

// --------------------------------------------------------- //
// Header walk through the context maps (phase D5 boundary)

pub const MAX_BLOCK_TYPES = 256;
pub const CMAPL_MAX = 64 * MAX_BLOCK_TYPES;
pub const CMAPD_MAX = 4 * MAX_BLOCK_TYPES;

pub const Header = struct {
    wbits: u6,
    mlen: u32,
    nbltypesl: u32,
    nbltypesi: u32,
    nbltypesd: u32,
    npostfix: u32,
    ndirect: u32,
    ntreesl: u32,
    ntreesd: u32,
};

/// Decode framing + preamble (D3) + context modes and maps (D4), advancing br to the
/// per-block-type prefix codes (phase D5). Writes the literal context modes into cmode
/// and the run-length-decoded context maps into cmapl / cmapd.
pub fn parseHeader(br: *BitReader, cmapl: []u8, cmapd: []u8, cmode: []ContextMode) !Header {
    const wbits = try m.readWindowBits(br);

    const is_last = try br.readBit();
    if (is_last == 1 and try br.readBit() == 1) return error.EmptyStream;

    const mnibbles_code = try br.readBits(2);
    if (mnibbles_code == 3) return error.MetadataNotSupported;

    const nibbles: u6 = @intCast(mnibbles_code + 4);
    const mlen = (try br.readBits(nibbles * 4)) + 1;

    var is_uncompressed: u1 = 0;
    if (is_last == 0) is_uncompressed = try br.readBit();
    if (is_uncompressed == 1) return error.UncompressedHasNoContext;

    const lit = try m.readBlockCategory(br);
    const iac = try m.readBlockCategory(br);
    const dist = try m.readBlockCategory(br);

    const npostfix = try br.readBits(2);
    const ndirect = (try br.readBits(4)) << @intCast(npostfix);

    try readContextModes(br, lit.nbltypes, cmode[0..lit.nbltypes]);

    const ntreesl = try m.readBlockTypeCount(br);
    const cmapl_size = 64 * lit.nbltypes;
    @memset(cmapl[0..cmapl_size], 0);
    if (ntreesl >= 2) try readContextMap(br, ntreesl, cmapl_size, cmapl);

    const ntreesd = try m.readBlockTypeCount(br);
    const cmapd_size = 4 * dist.nbltypes;
    @memset(cmapd[0..cmapd_size], 0);
    if (ntreesd >= 2) try readContextMap(br, ntreesd, cmapd_size, cmapd);

    return .{
        .wbits = wbits,
        .mlen = mlen,
        .nbltypesl = lit.nbltypes,
        .nbltypesi = iac.nbltypes,
        .nbltypesd = dist.nbltypes,
        .npostfix = npostfix,
        .ndirect = ndirect,
        .ntreesl = ntreesl,
        .ntreesd = ntreesd,
    };
}

pub fn main() void {
    // printf 'the quick brown fox ' (x12) | brotli -c  (240 raw -> 30 bytes, compressed)
    const compressed = "\x1f\xef\x00\xf8\x8d\x94\x6e\xe6\xa2\x06\x31\xa3\xc3\x53\x68\x6f\x39\xc8\x24\xa3\xe5\x08\xdb\x74\x54\x16\x48\xd7\x16\x0f";

    var br = BitReader{ .bytes = compressed };
    var cmapl: [CMAPL_MAX]u8 = undefined;
    var cmapd: [CMAPD_MAX]u8 = undefined;
    var cmode: [MAX_BLOCK_TYPES]ContextMode = undefined;

    const h = parseHeader(&br, &cmapl, &cmapd, &cmode) catch |err| {
        std.debug.print("stopped at: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("WBITS={d} MLEN={d}\n", .{ h.wbits, h.mlen });
    std.debug.print("NBLTYPESL={d} NBLTYPESI={d} NBLTYPESD={d}\n", .{ h.nbltypesl, h.nbltypesi, h.nbltypesd });
    std.debug.print("NPOSTFIX={d} NDIRECT={d}\n", .{ h.npostfix, h.ndirect });
    std.debug.print("NTREESL={d} NTREESD={d}\n", .{ h.ntreesl, h.ntreesd });
    std.debug.print("-> context modes + maps parsed; next is the per-block prefix codes (phase D5)\n", .{});
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const testing = std.testing;

/// LSB-first bit writer, test helper (integers LSB-first, prefix codes MSB-first).
const BitWriter = struct {
    buf: [256]u8 = std.mem.zeroes([256]u8),
    nbits: usize = 0,

    fn writeBit(self: *BitWriter, b: u1) void {
        if (b == 1) self.buf[self.nbits / 8] |= (@as(u8, 1) << @intCast(self.nbits % 8));
        self.nbits += 1;
    }

    fn writeInt(self: *BitWriter, value: u32, n: u6) void {
        var i: u6 = 0;
        while (i < n) : (i += 1) self.writeBit(@truncate(value >> @intCast(i)));
    }

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

test "RLEMAX: 0, 1, 5, 16" {
    const cases = [_]struct { bits: ?u32, expect: u32 }{
        .{ .bits = null, .expect = 0 }, // single 0 bit
        .{ .bits = 0, .expect = 1 }, // flag 1, xxxx = 0
        .{ .bits = 4, .expect = 5 }, // flag 1, xxxx = 4 (RFC example "01001")
        .{ .bits = 15, .expect = 16 }, // flag 1, xxxx = 15
    };

    for (cases) |c| {
        var bw = BitWriter{};
        if (c.bits) |x| {
            bw.writeBit(1);
            bw.writeInt(x, 4);
        } else {
            bw.writeBit(0);
        }
        var br = bw.reader();
        try testing.expectEqual(c.expect, try readRleMax(&br));
    }
}

test "inverse move-to-front: [1,0,0] -> [1,1,1]" {
    var v = [_]u8{ 1, 0, 0 };
    inverseMoveToFront(&v);

    try testing.expectEqualSlices(u8, &[_]u8{ 1, 1, 1 }, &v);
}

test "inverse move-to-front: identity input stays identity" {
    var v = [_]u8{ 0, 1, 2, 3 };
    inverseMoveToFront(&v);

    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3 }, &v);
}

test "context modes: two literal block types decode LSB6 and UTF8" {
    var bw = BitWriter{};
    bw.writeInt(0, 2); // LSB6
    bw.writeInt(2, 2); // UTF8

    var br = bw.reader();
    var modes: [2]ContextMode = undefined;
    try readContextModes(&br, 2, &modes);

    try testing.expectEqual(ContextMode.LSB6, modes[0]);
    try testing.expectEqual(ContextMode.UTF8, modes[1]);
}

test "context map: RLEMAX 0, direct values, no IMTF" {
    // NTREES = 2, RLEMAX = 0 -> alphabet size 2, values are symbols directly.
    var bw = BitWriter{};
    bw.writeBit(0); // RLEMAX = 0

    // simple prefix code over alphabet 2, nsym = 2, symbols 0 and 1 (abits = 1).
    bw.writeInt(1, 2); // selector = simple
    bw.writeInt(1, 2); // NSYM - 1 = 1
    bw.writeInt(0, 1); // symbol 0
    bw.writeInt(1, 1); // symbol 1
    // canonical lengths [1,1]: sym0 -> "0", sym1 -> "1".

    // map values [0, 1, 1, 0]
    bw.writeCode(0, 1);
    bw.writeCode(1, 1);
    bw.writeCode(1, 1);
    bw.writeCode(0, 1);

    bw.writeBit(0); // IMTF off

    var br = bw.reader();
    var map: [4]u8 = undefined;
    try readContextMap(&br, 2, 4, &map);

    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 1, 0 }, &map);
}

test "context map: RLEMAX 1, zero run then value" {
    // NTREES = 2, RLEMAX = 1 -> alphabet size 3: 0 = zero, 1 = run, 2 = value 1.
    var bw = BitWriter{};
    bw.writeBit(1);
    bw.writeInt(0, 4); // RLEMAX = 1

    // simple prefix code over alphabet 3, nsym = 3, symbols 0,1,2 (abits = 2).
    bw.writeInt(1, 2); // selector = simple
    bw.writeInt(2, 2); // NSYM - 1 = 2
    bw.writeInt(0, 2); // symbol 0
    bw.writeInt(1, 2); // symbol 1
    bw.writeInt(2, 2); // symbol 2
    // canonical lengths [1,2,2]: sym0 -> "0", sym1 -> "10", sym2 -> "11".

    // run code (sym1) with 1 extra bit = 1 -> (1<<1)+1 = 3 zeros, then sym2 -> value 1.
    bw.writeCode(0b10, 2);
    bw.writeInt(1, 1); // extra bit for the run length
    bw.writeCode(0b11, 2);

    bw.writeBit(0); // IMTF off

    var br = bw.reader();
    var map: [4]u8 = undefined;
    try readContextMap(&br, 2, 4, &map);

    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1 }, &map);
}

test "context map: IMTF transform applied" {
    // RLEMAX 0, NTREES 2, raw symbols [1,0,0], IMTF on -> [1,1,1].
    var bw = BitWriter{};
    bw.writeBit(0); // RLEMAX = 0

    bw.writeInt(1, 2); // selector = simple
    bw.writeInt(1, 2); // NSYM - 1 = 1
    bw.writeInt(0, 1); // symbol 0
    bw.writeInt(1, 1); // symbol 1

    bw.writeCode(1, 1); // value 1
    bw.writeCode(0, 1); // value 0
    bw.writeCode(0, 1); // value 0

    bw.writeBit(1); // IMTF on

    var br = bw.reader();
    var map: [3]u8 = undefined;
    try readContextMap(&br, 2, 3, &map);

    try testing.expectEqualSlices(u8, &[_]u8{ 1, 1, 1 }, &map);
}
