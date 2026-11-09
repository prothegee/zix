//! ZIX utils compression flate fast
//!
//! ### file: src/zix/utils/compression/flate/flate_fast.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Fast gzip encoder for small bodies: greedy LZ over a single-probe hash table,
//! fixed-Huffman coding, one final block.
//! 
//! ### note:
//! 
//! Input is capped below 64 KiB so hash positions fit u16 with 0 as the empty
//! sentinel. The caller gates on fitsFast and uses flate.zig above the cap.
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
const FastBitWriter = @import("FastBitWriter.zig");

// --------------------------------------------------------- //
// Private:

const HASH_BITS = 13;
const HASH_SIZE = 1 << HASH_BITS;
const MIN_MATCH = 4;
const MAX_MATCH = 258;
const INPUT_CAP = 65535;
/// DEFLATE back-reference window.
const WINDOW_SIZE = 32768;

/// gzip header (10) + footer (8) + block header + accumulator slack.
const WRAP_SLACK = 64;

/// gzip member header: magic, CM=8, no flags, no mtime, XFL=0, OS=3 (unix).
const GZIP_HEADER = [_]u8{ 0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0x03 };

/// Distance base per distance symbol (RFC 1951 3.2.5).
const DIST_BASES = [_]u16{
    1,    2,    3,    4,    5,    7,     9,     13,    17,    25,
    33,   49,   65,   97,   129,  193,   257,   385,   513,   769,
    1025, 1537, 2049, 3073, 4097, 6145,  8193,  12289, 16385, 24577,
};

/// Extra bit count per distance symbol (RFC 1951 3.2.5).
const DIST_EXTRAS = [_]u4{
    0, 0, 0,  0,  1,  1,  2,  2,  3,  3,
    4, 4, 5,  5,  6,  6,  7,  7,  8,  8,
    9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
};

/// Length base per length symbol 257..285 (RFC 1951 3.2.5).
const LEN_BASES = [_]u16{
    3,  4,  5,  6,  7,  8,  9,   10,  11,  13,
    15, 17, 19, 23, 27, 31, 35,  43,  51,  59,
    67, 83, 99, 115, 131, 163, 195, 227, 258,
};

/// Extra bit count per length symbol 257..285 (RFC 1951 3.2.5).
const LEN_EXTRAS = [_]u4{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1,
    1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
    4, 4, 4, 4, 5, 5, 5, 5, 0,
};

/// One fixed-Huffman literal code, bit-reversed for LSB-first output.
const LitCode = struct {
    code: u16,
    bits: u4,
};

/// A length or distance: its code with the extra bits appended.
const PatternCode = struct {
    pattern: u32,
    bits: u6,
};

/// One 128-wide distance slot above 256: code, base, and extra width.
const DistSlot = struct {
    code: u16,
    base: u16,
    extra_bits: u6,
};

/// Reverse the low bits of value.
///
/// Param:
/// value - u16 (bits to reverse)
/// bits - u4 (number of low bits to reverse)
///
/// Return:
/// - u16
fn bitReverse(value: u16, bits: u4) u16 {
    var out: u16 = 0;
    var i: u4 = 0;
    while (i < bits) : (i += 1) {
        out = (out << 1) | ((value >> @intCast(i)) & 1);
    }

    return out;
}

/// Index of the last base that is <= value.
///
/// Param:
/// bases - []const u16 (ascending bases)
/// value - u16 (value to place)
///
/// Return:
/// - usize
fn symbolFor(bases: []const u16, value: u16) usize {
    var symbol: usize = 0;
    for (bases, 0..) |base, idx| {
        if (value >= base) symbol = idx;
    }

    return symbol;
}

/// Fixed-Huffman literal codes (RFC 1951 3.2.6): 0-143 are 8-bit codes from 0x30,
/// 144-255 are 9-bit codes from 0x190.
const lit_codes = blk: {
    @setEvalBranchQuota(20000);

    var table: [256]LitCode = undefined;
    for (0..144) |lit| {
        table[lit] = .{
            .code = bitReverse(0x30 + @as(u16, @intCast(lit)), 8),
            .bits = 8,
        };
    }
    for (144..256) |lit| {
        table[lit] = .{
            .code = bitReverse(0x190 + @as(u16, @intCast(lit - 144)), 9),
            .bits = 9,
        };
    }

    break :blk table;
};

/// Length 3..258 to its full bit pattern: the fixed length symbol code
/// (257-279 are 7-bit, 280-285 are 8-bit) with the extra bits appended.
const len_codes = blk: {
    @setEvalBranchQuota(100000);

    var table: [MAX_MATCH + 1]PatternCode = undefined;
    for (3..MAX_MATCH + 1) |len| {
        const symbol_index = symbolFor(&LEN_BASES, len);
        const symbol = 257 + symbol_index;

        var code: u16 = undefined;
        var code_bits: u4 = undefined;
        if (symbol <= 279) {
            code = bitReverse(@intCast(symbol - 256), 7);
            code_bits = 7;
        } else {
            code = bitReverse(@intCast(0xC0 + (symbol - 280)), 8);
            code_bits = 8;
        }

        const extra_val: u32 = @intCast(len - LEN_BASES[symbol_index]);
        table[len] = .{
            .pattern = @as(u32, code) | (extra_val << code_bits),
            .bits = @as(u6, code_bits) + LEN_EXTRAS[symbol_index],
        };
    }

    break :blk table;
};

/// Full bit pattern for one distance.
///
/// Param:
/// dist - u16 (distance 1..32768)
///
/// Return:
/// - PatternCode
fn distEntry(dist: u16) PatternCode {
    const symbol = symbolFor(&DIST_BASES, dist);
    const code = bitReverse(@intCast(symbol), 5);
    const extra_val: u32 = dist - DIST_BASES[symbol];

    return .{
        .pattern = @as(u32, code) | (extra_val << 5),
        .bits = 5 + @as(u6, DIST_EXTRAS[symbol]),
    };
}

/// Distances 1..256, fully precomputed.
const dist_lo = blk: {
    @setEvalBranchQuota(200000);

    var table: [257]PatternCode = undefined;
    for (1..257) |dist| table[dist] = distEntry(@intCast(dist));
    table[0] = .{
        .pattern = 0,
        .bits = 0,
    };

    break :blk table;
};

/// Above distance 256 every fixed-code range is at least 128 wide, so each
/// 128-wide slot maps to exactly one symbol.
const dist_hi = blk: {
    @setEvalBranchQuota(200000);

    var table: [256]DistSlot = undefined;
    for (0..256) |slot| {
        const dist: u16 = (@as(u16, @intCast(slot)) << 7) + 1;
        const symbol = symbolFor(&DIST_BASES, dist);

        table[slot] = .{
            .code = bitReverse(@intCast(symbol), 5),
            .base = DIST_BASES[symbol],
            .extra_bits = DIST_EXTRAS[symbol],
        };
    }

    break :blk table;
};

/// Bit pattern for a distance, from the two lookup tables.
///
/// Param:
/// dist - u16 (distance 1..32768)
///
/// Return:
/// - PatternCode
fn distCode(dist: u16) PatternCode {
    if (dist < 257) return dist_lo[dist];

    const slot = dist_hi[(dist - 1) >> 7];

    return .{
        .pattern = @as(u32, slot.code) | (@as(u32, dist - slot.base) << 5),
        .bits = 5 + slot.extra_bits,
    };
}

/// Per-worker hash head table. Positions are stored +1 so 0 marks an empty slot.
threadlocal var tl_head: [HASH_SIZE]u16 = undefined;

/// Hash four bytes into a head table slot.
///
/// Param:
/// word - u32 (four input bytes, little endian)
///
/// Return:
/// - u16
inline fn hash4(word: u32) u16 {
    return @intCast((word *% 0x9E3779B1) >> (32 - HASH_BITS));
}

/// Length of the match at pos against candidate_pos, up to max_len.
///
/// Param:
/// src - []const u8 (input)
/// pos - usize (current position)
/// candidate_pos - usize (earlier position, already equal for MIN_MATCH bytes)
/// max_len - usize (longest allowed match)
///
/// Return:
/// - usize
fn matchLength(src: []const u8, pos: usize, candidate_pos: usize, max_len: usize) usize {
    var len: usize = MIN_MATCH;
    while (len + 8 <= max_len) {
        const ahead = std.mem.readInt(u64, src[pos + len ..][0..8], .little);
        const behind = std.mem.readInt(u64, src[candidate_pos + len ..][0..8], .little);
        const diff = ahead ^ behind;
        if (diff != 0) return @min(len + @ctz(diff) / 8, max_len);

        len += 8;
    }

    while (len < max_len and src[pos + len] == src[candidate_pos + len]) len += 1;

    return len;
}

// --------------------------------------------------------- //
// Public:

/// Worst-case output for input_len bytes: fixed-Huffman literals are at most
/// 9 bits per byte, plus container wrap and flush slack.
///
/// Param:
/// input_len - usize (uncompressed byte count)
///
/// Return:
/// - usize
pub fn gzipFastBound(input_len: usize) usize {
    return input_len + input_len / 8 + WRAP_SLACK;
}

/// Whether input_len is inside the input cap and its worst-case output fits out_cap.
///
/// Param:
/// input_len - usize (uncompressed byte count)
/// out_cap - usize (destination capacity)
///
/// Return:
/// - bool
pub fn fitsFast(input_len: usize, out_cap: usize) bool {
    return input_len < INPUT_CAP and gzipFastBound(input_len) <= out_cap;
}

/// Compress src as one gzip member into dst.
///
/// Note:
/// - The caller must gate with fitsFast(src.len, dst.len). It is asserted here.
///
/// Param:
/// src - []const u8 (bytes to compress)
/// dst - []u8 (destination)
///
/// Return:
/// - usize (bytes written to dst)
pub fn gzipFastInto(src: []const u8, dst: []u8) usize {
    std.debug.assert(fitsFast(src.len, dst.len));

    @memcpy(dst[0..GZIP_HEADER.len], &GZIP_HEADER);
    @memset(&tl_head, 0);

    var bit_writer = FastBitWriter.init(dst[GZIP_HEADER.len..]);

    // Block header, LSB first: BFINAL=1, then BTYPE=01 (fixed).
    bit_writer.put(0b011, 3);

    var pos: usize = 0;
    const limit = if (src.len >= MIN_MATCH) src.len - MIN_MATCH + 1 else 0;
    while (pos < limit) {
        const word = std.mem.readInt(u32, src[pos..][0..4], .little);
        const slot = hash4(word);
        const candidate = tl_head[slot];
        tl_head[slot] = @intCast(pos + 1);

        if (candidate != 0) {
            const candidate_pos = candidate - 1;
            const in_window = pos - candidate_pos <= WINDOW_SIZE;

            if (in_window and
                std.mem.readInt(u32, src[candidate_pos..][0..4], .little) == word)
            {
                const max_len = @min(MAX_MATCH, src.len - pos);
                const len = matchLength(src, pos, candidate_pos, max_len);

                const len_entry = len_codes[len];
                bit_writer.put(len_entry.pattern, len_entry.bits);
                const dist_entry = distCode(@intCast(pos - candidate_pos));
                bit_writer.put(dist_entry.pattern, dist_entry.bits);

                // Hash every other covered byte, warm enough at half the cost.
                var insert_pos = pos + 1;
                const insert_end = @min(pos + len, limit);
                while (insert_pos < insert_end) : (insert_pos += 2) {
                    const insert_word = std.mem.readInt(u32, src[insert_pos..][0..4], .little);
                    tl_head[hash4(insert_word)] = @intCast(insert_pos + 1);
                }

                pos += len;
                continue;
            }
        }

        const lit = lit_codes[src[pos]];
        bit_writer.put(lit.code, lit.bits);
        pos += 1;
    }

    while (pos < src.len) : (pos += 1) {
        const lit = lit_codes[src[pos]];
        bit_writer.put(lit.code, lit.bits);
    }

    // End of block: symbol 256, seven zero bits.
    bit_writer.put(0, 7);
    bit_writer.finishByteAlign();

    const deflate_len = bit_writer.written();
    const tail = dst[GZIP_HEADER.len + deflate_len ..];
    const crc = std.hash.Crc32.hash(src);
    std.mem.writeInt(u32, tail[0..4], crc, .little);
    std.mem.writeInt(u32, tail[4..8], @intCast(src.len), .little);

    return GZIP_HEADER.len + deflate_len + 8;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const flate = @import("flate.zig");

fn roundTrip(data: []const u8) !void {
    const out_buf = try std.testing.allocator.alloc(u8, gzipFastBound(data.len));
    defer std.testing.allocator.free(out_buf);

    const out_len = gzipFastInto(data, out_buf);

    const plain = try flate.decompressGzipAlloc(
        std.testing.allocator,
        out_buf[0..out_len],
        INPUT_CAP + 1,
    );
    defer std.testing.allocator.free(plain);

    try std.testing.expectEqualSlices(u8, data, plain);
}

test "zix utils compression flate: flate_fast, round-trips empty input" {
    try roundTrip("");
}

test "zix utils compression flate: flate_fast, round-trips tiny inputs" {
    try roundTrip("a");
    try roundTrip("abc");
}

test "zix utils compression flate: flate_fast, round-trips repetitive inputs" {
    try roundTrip("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try roundTrip("{\"items\":[{\"id\":1,\"name\":\"Alpha\"},{\"id\":2,\"name\":\"Alpha\"}]}");
}

test "zix utils compression flate: flate_fast, round-trips incompressible input" {
    var prng = std.Random.DefaultPrng.init(42);
    const random_body = try std.testing.allocator.alloc(u8, 16 * 1024);
    defer std.testing.allocator.free(random_body);

    prng.random().bytes(random_body);

    try roundTrip(random_body);
}

test "zix utils compression flate: flate_fast, round-trips a uniform large input" {
    const zero_body = try std.testing.allocator.alloc(u8, 32 * 1024);
    defer std.testing.allocator.free(zero_body);

    @memset(zero_body, 0);

    try roundTrip(zero_body);
}

test "zix utils compression flate: flate_fast, round-trips a near-cap input" {
    const body = try std.testing.allocator.alloc(u8, INPUT_CAP - 1);
    defer std.testing.allocator.free(body);

    for (body, 0..) |*byte, i| byte.* = @truncate(i *% 31);

    try roundTrip(body);
}

test "zix utils compression flate: flate_fast, fitsFast rejects the cap" {
    try std.testing.expect(!fitsFast(INPUT_CAP, 1 << 20));
}

test "zix utils compression flate: flate_fast, fitsFast rejects a short buffer" {
    try std.testing.expect(!fitsFast(100, 64));
}

test "zix utils compression flate: flate_fast, fitsFast accepts the exact bound" {
    try std.testing.expect(fitsFast(100, gzipFastBound(100)));
}

test "zix utils compression flate: flate_fast, compresses structured json well" {
    const chunk = "{\"id\":123,\"name\":\"Alpha Widget\",\"category\":\"electronics\"," ++
        "\"price\":328,\"quantity\":15,\"active\":true},";

    var body_buf: [8 * 1024]u8 = undefined;
    var pos: usize = 0;
    for (0..40) |_| {
        @memcpy(body_buf[pos..][0..chunk.len], chunk);
        pos += chunk.len;
    }

    var out_buf: [16 * 1024]u8 = undefined;
    const out_len = gzipFastInto(body_buf[0..pos], &out_buf);

    try std.testing.expect(out_len < pos / 2);
}

test "zix utils compression flate: flate_fast, writes the gzip magic" {
    var out_buf: [128]u8 = undefined;
    _ = gzipFastInto("magic", &out_buf);

    try std.testing.expectEqualSlices(u8, &GZIP_HEADER, out_buf[0..GZIP_HEADER.len]);
}

