//! Brotli meta-block preamble PoC (RFC 7932 section 9.2 + section 6), decoder phase D3.
//!
//! Note:
//! - Integrates D1 (framing, re-included below) + D2 (prefix codes, imported from
//!   brotli_prefix_poc.zig) + D3 (the block-switch preamble) and parses a REAL
//!   compressed meta-block header up to the context modes, the boundary of phase D4.
//! - D3 covers: NBLTYPES / NTREES variable-length code (sec 9.2), the 26-symbol block
//!   count code base + extra (sec 6), the per-category setup (NBLTYPES, and when >= 2
//!   the block-type code, the block-count code, and the first block count), and
//!   NPOSTFIX / NDIRECT.
//! - Run the real-vector demo: zig run rnd/0.5.x/brotli_meta_poc.zig
//!   Run the unit tests:      zig test rnd/0.5.x/brotli_meta_poc.zig

const std = @import("std");
const p = @import("brotli_prefix_poc.zig");
const BitReader = p.BitReader;

// --------------------------------------------------------- //
// D1 framing (re-included, small)

pub fn readWindowBits(br: *BitReader) !u6 {
    if (try br.readBit() == 0) return 16;

    const n1 = try br.readBits(3);
    if (n1 != 0) return @intCast(17 + n1);

    const n2 = try br.readBits(3);
    if (n2 != 0) return @intCast(8 + n2);

    return 17;
}

// --------------------------------------------------------- //
// D3 primitives

/// NBLTYPES / NTREES variable-length uint, 1..256 (sec 9.2).
pub fn readBlockTypeCount(br: *BitReader) !u32 {
    if (try br.readBit() == 0) return 1;

    const n = try br.readBits(3);

    return (@as(u32, 1) << @intCast(n)) + 1 + (try br.readBits(@intCast(n)));
}

// The 26-symbol block count code: base value and extra-bit count per symbol (sec 6).
pub const BLOCK_COUNT_BASE = [_]u32{ 1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497, 753, 1265, 2289, 4337, 8433, 16625 };
pub const BLOCK_COUNT_EXTRA = [_]u6{ 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24 };

/// One block count: a block-count code symbol then its extra bits (sec 6).
pub fn readBlockCount(br: *BitReader, code: *const p.HuffmanDecoder) !u32 {
    const sym = try code.readSymbol(br);
    if (sym >= BLOCK_COUNT_BASE.len) return error.InvalidBlockCountCode;

    return BLOCK_COUNT_BASE[sym] + (try br.readBits(BLOCK_COUNT_EXTRA[sym]));
}

pub const Category = struct {
    nbltypes: u32,
    first_block_count: ?u32 = null,
};

/// Per-category block-switch setup (sec 9.2): NBLTYPES, and when >= 2 the block-type
/// code, the block-count code, and the first block count.
pub fn readBlockCategory(br: *BitReader) !Category {
    const nbltypes = try readBlockTypeCount(br);
    if (nbltypes < 2) return .{ .nbltypes = nbltypes };

    _ = try p.readPrefixCode(br, nbltypes + 2); // block-type code (HTREE_BTYPE)
    const blen_code = try p.readPrefixCode(br, BLOCK_COUNT_BASE.len); // block-count code (HTREE_BLEN)
    const first = try readBlockCount(br, &blen_code);

    return .{ .nbltypes = nbltypes, .first_block_count = first };
}

/// Decode framing + the D3 preamble, stopping at the context modes (phase D4).
fn decodePreamble(vector: []const u8) !void {
    var br = BitReader{ .bytes = vector };

    const wbits = try readWindowBits(&br);
    std.debug.print("WBITS = {d}\n", .{wbits});

    const is_last = try br.readBit();
    if (is_last == 1 and try br.readBit() == 1) {
        std.debug.print("empty stream\n", .{});
        return;
    }

    const mnibbles_code = try br.readBits(2);
    if (mnibbles_code == 3) return error.MetadataNotSupported;

    const nibbles: u6 = @intCast(mnibbles_code + 4);
    const mlen = (try br.readBits(nibbles * 4)) + 1;

    var is_uncompressed: u1 = 0;
    if (is_last == 0) is_uncompressed = try br.readBit();

    std.debug.print("meta-block: ISLAST={d} MLEN={d} ISUNCOMPRESSED={d}\n", .{ is_last, mlen, is_uncompressed });
    if (is_uncompressed == 1) {
        std.debug.print("uncompressed meta-block, no D3 preamble\n", .{});
        return;
    }

    const lit = try readBlockCategory(&br);
    const iac = try readBlockCategory(&br);
    const dist = try readBlockCategory(&br);

    const npostfix = try br.readBits(2);
    const ndirect = (try br.readBits(4)) << @intCast(npostfix);

    std.debug.print("NBLTYPESL={d} NBLTYPESI={d} NBLTYPESD={d}\n", .{ lit.nbltypes, iac.nbltypes, dist.nbltypes });
    std.debug.print("NPOSTFIX={d} NDIRECT={d}\n", .{ npostfix, ndirect });
    std.debug.print("-> D3 preamble parsed; next is context modes / maps (phase D4)\n", .{});
}

pub fn main() void {
    // printf 'the quick brown fox ' (x12) | brotli -c  (240 raw -> 30 bytes, compressed)
    const compressed = "\x1f\xef\x00\xf8\x8d\x94\x6e\xe6\xa2\x06\x31\xa3\xc3\x53\x68\x6f\x39\xc8\x24\xa3\xe5\x08\xdb\x74\x54\x16\x48\xd7\x16\x0f";

    decodePreamble(compressed) catch |err| {
        std.debug.print("stopped at: {s}\n", .{@errorName(err)});
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const testing = std.testing;

const BitWriter = struct {
    buf: [64]u8 = std.mem.zeroes([64]u8),
    nbits: usize = 0,

    fn writeBit(self: *BitWriter, b: u1) void {
        if (b == 1) self.buf[self.nbits / 8] |= (@as(u8, 1) << @intCast(self.nbits % 8));
        self.nbits += 1;
    }

    fn writeInt(self: *BitWriter, value: u32, n: u6) void {
        var i: u6 = 0;
        while (i < n) : (i += 1) self.writeBit(@truncate(value >> @intCast(i)));
    }

    fn reader(self: *const BitWriter) BitReader {
        return .{ .bytes = self.buf[0 .. (self.nbits + 7) / 8] };
    }
};

test "NBLTYPES variable-length code: 1, 2, 12" {
    // value 1 -> "0"
    {
        var bw = BitWriter{};
        bw.writeBit(0);
        var br = bw.reader();
        try testing.expectEqual(@as(u32, 1), try readBlockTypeCount(&br));
    }
    // value 2 -> leading 1, n=0
    {
        var bw = BitWriter{};
        bw.writeBit(1);
        bw.writeInt(0, 3);
        var br = bw.reader();
        try testing.expectEqual(@as(u32, 2), try readBlockTypeCount(&br));
    }
    // value 12 -> leading 1, n=3, extra=3 (RFC example "0110111" = 12)
    {
        var bw = BitWriter{};
        bw.writeBit(1);
        bw.writeInt(3, 3);
        bw.writeInt(3, 3);
        var br = bw.reader();
        try testing.expectEqual(@as(u32, 12), try readBlockTypeCount(&br));
    }
}

test "block count: code symbol 4 (base 17, 3 extra) + 5 = 22" {
    // single-symbol block-count code over symbol 4, so readSymbol consumes no bits.
    var lengths = std.mem.zeroes([26]u8);
    lengths[4] = 1;
    const code = try p.HuffmanDecoder.build(&lengths);

    var bw = BitWriter{};
    bw.writeInt(5, 3); // 3 extra bits = 5
    var br = bw.reader();

    try testing.expectEqual(@as(u32, 22), try readBlockCount(&br, &code));
}
