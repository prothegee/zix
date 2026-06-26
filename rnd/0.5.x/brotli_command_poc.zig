//! Brotli command loop PoC (RFC 7932 section 9.3 + sec 4, 5, 7.1, 7.2), decoder phase D5.
//!
//! Note:
//! - The final decoder phase before the static dictionary. It reads the per-block-type
//!   prefix codes (HTREEL / HTREEI / HTREED), then runs the command loop (sec 10): each
//!   command is an insert-and-copy length code (sec 5), Insert length literals emitted
//!   through the literal context model (sec 7.1), and a copy of Copy length bytes from a
//!   backward distance (sec 4) with the 4-entry last-distance ring buffer.
//! - Reuses D4 (brotli_context_poc.zig) for the header walk through the context maps,
//!   which transitively brings in D3 (block-switch preamble) and D2 (prefix codes).
//! - Scope: the test vectors use a single block type per category (NBLTYPES = 1), so the
//!   mid-data block-switch commands (sec 6, NBLTYPES >= 2) are not exercised and are left
//!   for a later refinement. The literal context model IS exercised: the text vector has
//!   NTREESL = 2, so each literal selects a tree via CMAPL[64 * BTYPE_L + CIDL].
//! - A copy whose distance points past the produced output is a static dictionary
//!   reference (sec 8), the boundary of phase D6, surfaced as error.DictionaryReference.
//! - Run the real-vector demo: zig run rnd/0.5.x/brotli_command_poc.zig
//!   Run the unit tests:      zig test rnd/0.5.x/brotli_command_poc.zig

const std = @import("std");
const p = @import("brotli_prefix_poc.zig");
const c = @import("brotli_context_poc.zig");
const BitReader = p.BitReader;
const HuffmanDecoder = p.HuffmanDecoder;
const ContextMode = c.ContextMode;

// --------------------------------------------------------- //
// sec 5 length code tables (insert and copy)

pub const INSERT_LEN_EXTRA = [_]u6{ 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24 };
pub const INSERT_LEN_BASE = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594 };

pub const COPY_LEN_EXTRA = [_]u6{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24 };
pub const COPY_LEN_BASE = [_]u32{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118 };

// The insert-and-copy length code is split into an insert length code and a copy length
// code by an 11-cell table (sec 5). Per cell index (cmd >> 6): the base insert code, the
// base copy code, and whether the distance is an implicit zero (cells 0 and 1, cmd<128).
const CELL_INSERT_BASE = [_]u8{ 0, 0, 0, 0, 8, 8, 0, 16, 8, 16, 16 };
const CELL_COPY_BASE = [_]u8{ 0, 8, 0, 8, 0, 8, 16, 0, 16, 8, 16 };

pub const InsertCopy = struct {
    insert_code: u8,
    copy_code: u8,
    distance_zero: bool,
};

/// Split an insert-and-copy length code into its insert and copy codes (sec 5). The copy
/// code is bits 0..2, the insert code is bits 3..5, each added to its per-cell base.
pub fn splitInsertCopy(cmd: u16) InsertCopy {
    const cell = cmd >> 6;

    return .{
        .insert_code = CELL_INSERT_BASE[cell] + @as(u8, @intCast((cmd >> 3) & 7)),
        .copy_code = CELL_COPY_BASE[cell] + @as(u8, @intCast(cmd & 7)),
        .distance_zero = cmd < 128,
    };
}

// --------------------------------------------------------- //
// sec 7.1 literal context lookup tables (UTF8 / Signed)

const Lut0 = [256]u8{
    0,  0,  0,  0,  0,  0,  0,  0,  0,  4,  4,  0,  0,  4,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    8,  12, 16, 12, 12, 20, 12, 16, 24, 28, 12, 12, 32, 12, 36, 12,
    44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 32, 32, 24, 40, 28, 12,
    12, 48, 52, 52, 52, 48, 52, 52, 52, 48, 52, 52, 52, 52, 52, 48,
    52, 52, 52, 52, 52, 48, 52, 52, 52, 52, 52, 24, 12, 28, 12, 12,
    12, 56, 60, 60, 60, 56, 60, 60, 60, 56, 60, 60, 60, 60, 60, 56,
    60, 60, 60, 60, 60, 56, 60, 60, 60, 60, 60, 24, 12, 28, 12, 0,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
};

const Lut1 = [256]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1,
    1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1,
    1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, 1, 1, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
};

const Lut2 = [256]u8{
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7,
};

/// Literal context ID from the context mode and the last two output bytes (sec 7.1).
pub fn literalContextId(mode: ContextMode, p1: u8, p2: u8) u8 {
    return switch (mode) {
        .LSB6 => p1 & 0x3f,
        .MSB6 => p1 >> 2,
        .UTF8 => Lut0[p1] | Lut1[p2],
        .SIGNED => (Lut2[p1] << 3) | Lut2[p2],
    };
}

/// Distance context ID from the copy length (sec 7.2): 0, 1, 2 for copy length 2, 3, 4
/// and 3 for any longer copy.
pub fn distanceContextId(copy_len: u32) u8 {
    return if (copy_len > 4) 3 else @intCast(copy_len - 2);
}

// --------------------------------------------------------- //
// sec 4 distance decoding

/// The four most recent backward distances, initialized once per stream (sec 4). Index 0
/// is the last distance, index 3 the fourth-to-last.
pub const DistanceRing = struct {
    d: [4]u32 = .{ 4, 11, 15, 16 },

    pub fn push(self: *DistanceRing, dist: u32) void {
        self.d[3] = self.d[2];
        self.d[2] = self.d[1];
        self.d[1] = self.d[0];
        self.d[0] = dist;
    }
};

pub const Distance = struct {
    value: u32,
    push: bool,
};

/// Resolve one distance code into a backward distance (sec 4). The first 16 codes are
/// short references into the ring buffer, the next NDIRECT are direct distances, and the
/// rest carry extra bits decoded with the NPOSTFIX / NDIRECT formula.
pub fn readDistance(br: *BitReader, code: u16, ring: *const DistanceRing, npostfix: u32, ndirect: u32) !Distance {
    if (code < 16) {
        const value = shortDistance(code, ring);
        if (value <= 0) return error.InvalidDistance;

        return .{ .value = @intCast(value), .push = code != 0 };
    }

    if (code < 16 + ndirect) return .{ .value = code - 16 + 1, .push = true };

    const dadj: u32 = code - ndirect - 16;
    const ndistbits: u5 = @intCast(1 + (dadj >> @intCast(npostfix + 1)));
    const dextra: u64 = try br.readBits(ndistbits);
    const postfix_mask: u32 = (@as(u32, 1) << @intCast(npostfix)) - 1;
    const hcode: u32 = dadj >> @intCast(npostfix);
    const lcode: u32 = dadj & postfix_mask;
    const offset: u64 = (@as(u64, 2 + (hcode & 1)) << ndistbits) - 4;
    const value: u64 = ((offset + dextra) << @intCast(npostfix)) + lcode + ndirect + 1;

    return .{ .value = @intCast(value), .push = true };
}

/// The short distance table for codes 0..15 (sec 4): codes 0..3 are the last, second,
/// third, and fourth-to-last distances, codes 4..9 modify the last distance by -1, +1,
/// -2, +2, -3, +3, and codes 10..15 modify the second-to-last distance the same way.
fn shortDistance(code: u16, ring: *const DistanceRing) i64 {
    switch (code) {
        0 => return ring.d[0],
        1 => return ring.d[1],
        2 => return ring.d[2],
        3 => return ring.d[3],
        else => {},
    }

    const slot: usize = if (code < 10) 0 else 1;
    const offsets = [_]i64{ -1, 1, -2, 2, -3, 3 };
    const idx: usize = if (code < 10) code - 4 else code - 10;

    return @as(i64, ring.d[slot]) + offsets[idx];
}

// --------------------------------------------------------- //
// The command loop (sec 9.3 + sec 10)

/// Decode a single-meta-block compressed stream into freshly allocated output (sec 10).
/// Allocator owns the returned slice. Single block type per category (see file note).
fn decompress(allocator: std.mem.Allocator, vector: []const u8) ![]u8 {
    var br = BitReader{ .bytes = vector };

    var cmapl: [c.CMAPL_MAX]u8 = undefined;
    var cmapd: [c.CMAPD_MAX]u8 = undefined;
    var cmode: [c.MAX_BLOCK_TYPES]ContextMode = undefined;

    const h = try c.parseHeader(&br, &cmapl, &cmapd, &cmode);
    if (h.nbltypesl > 1 or h.nbltypesi > 1 or h.nbltypesd > 1) return error.BlockSwitchNotSupported;

    const htreel = try allocator.alloc(HuffmanDecoder, h.ntreesl);
    defer allocator.free(htreel);
    for (htreel) |*tree| tree.* = try p.readPrefixCode(&br, 256);

    const htreei = try p.readPrefixCode(&br, 704);

    const dist_alphabet = 16 + h.ndirect + (@as(u32, 48) << @intCast(h.npostfix));
    const htreed = try allocator.alloc(HuffmanDecoder, h.ntreesd);
    defer allocator.free(htreed);
    for (htreed) |*tree| tree.* = try p.readPrefixCode(&br, dist_alphabet);

    const out = try allocator.alloc(u8, h.mlen);
    errdefer allocator.free(out);

    var pos: usize = 0;
    var ring = DistanceRing{};
    var p1: u8 = 0;
    var p2: u8 = 0;

    while (pos < h.mlen) {
        const cmd = try htreei.readSymbol(&br);
        const ic = splitInsertCopy(cmd);

        const insert_len = INSERT_LEN_BASE[ic.insert_code] + try br.readBits(INSERT_LEN_EXTRA[ic.insert_code]);
        const copy_len = COPY_LEN_BASE[ic.copy_code] + try br.readBits(COPY_LEN_EXTRA[ic.copy_code]);

        var i: u32 = 0;
        while (i < insert_len) : (i += 1) {
            const cid = literalContextId(cmode[0], p1, p2);
            const tree = cmapl[cid];
            const lit: u8 = @intCast(try htreel[tree].readSymbol(&br));

            out[pos] = lit;
            pos += 1;
            p2 = p1;
            p1 = lit;
            if (pos == h.mlen) return out;
        }

        var distance: u32 = undefined;
        var push_candidate = false;
        if (ic.distance_zero) {
            distance = ring.d[0];
        } else {
            const cid = distanceContextId(copy_len);
            const dcode = try htreed[cmapd[cid]].readSymbol(&br);
            const d = try readDistance(&br, dcode, &ring, h.npostfix, h.ndirect);
            distance = d.value;
            push_candidate = d.push;
        }

        if (distance > pos) return error.DictionaryReference;

        // A real backward reference: push to the ring here, after ruling out a dictionary
        // reference (sec 4, dictionary refs are never pushed to the last-distance ring).
        if (push_candidate) ring.push(distance);

        var j: u32 = 0;
        while (j < copy_len and pos < h.mlen) : (j += 1) {
            const b = out[pos - distance];

            out[pos] = b;
            pos += 1;
            p2 = p1;
            p1 = b;
        }
    }

    return out;
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // WBITS=24 text vector: 'the quick brown fox ' x12 (the D3/D4 vector).
    const text = "\x1f\xef\x00\xf8\x8d\x94\x6e\xe6\xa2\x06\x31\xa3\xc3\x53\x68\x6f\x39\xc8\x24\xa3\xe5\x08\xdb\x74\x54\x16\x48\xd7\x16\x0f";

    // WBITS=10 non-dictionary vector: 'Zq7Kx9' x40 (pure LZ back-references).
    const tokens = "\xa1\x78\x07\xc0\x6f\xa4\x44\x9d\x5f\xbd\xa4\x15\x87\xa7\x6e\x72\x62\xb6\x38\x00\xc9\x70";

    runOne(allocator, "text", text);
    runOne(allocator, "tokens", tokens);
}

fn runOne(allocator: std.mem.Allocator, label: []const u8, vector: []const u8) void {
    const out = decompress(allocator, vector) catch |err| {
        std.debug.print("[{s}] stopped at: {s}\n", .{ label, @errorName(err) });
        return;
    };

    std.debug.print("[{s}] decoded {d} bytes:\n{s}\n", .{ label, out.len, out });
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const testing = std.testing;

test "split insert-and-copy: cell 0 reuses distance, decomposes codes" {
    // cmd 0: cell 0, copy bits = 0, insert bits = 0, distance implicit zero.
    const a = splitInsertCopy(0);
    try testing.expectEqual(@as(u8, 0), a.insert_code);
    try testing.expectEqual(@as(u8, 0), a.copy_code);
    try testing.expect(a.distance_zero);

    // cmd 147 = 0b10010011: cell 2, copy bits 0..2 = 3, insert bits 3..5 = 2 (asymmetric,
    // guards against swapping the two fields).
    const b = splitInsertCopy(147);
    try testing.expectEqual(@as(u8, 2), b.insert_code);
    try testing.expectEqual(@as(u8, 3), b.copy_code);
    try testing.expect(!b.distance_zero);

    // cmd 128: cell 2, insert base 0, copy base 0, distance NOT implicit zero.
    const d = splitInsertCopy(128);
    try testing.expectEqual(@as(u8, 0), d.insert_code);
    try testing.expectEqual(@as(u8, 0), d.copy_code);
    try testing.expect(!d.distance_zero);

    // cmd 703: cell 10, insert base 16 + 7, copy base 16 + 7.
    const e = splitInsertCopy(703);
    try testing.expectEqual(@as(u8, 23), e.insert_code);
    try testing.expectEqual(@as(u8, 23), e.copy_code);
    try testing.expect(!e.distance_zero);
}

test "distance context id from copy length (sec 7.2)" {
    try testing.expectEqual(@as(u8, 0), distanceContextId(2));
    try testing.expectEqual(@as(u8, 1), distanceContextId(3));
    try testing.expectEqual(@as(u8, 2), distanceContextId(4));
    try testing.expectEqual(@as(u8, 3), distanceContextId(5));
    try testing.expectEqual(@as(u8, 3), distanceContextId(1000));
}

test "distance ring short codes (sec 4)" {
    var ring = DistanceRing{}; // [4, 11, 15, 16]
    var br = BitReader{ .bytes = &.{} };

    // code 0 -> last distance (4), not pushed.
    try testing.expectEqual(@as(u32, 4), (try readDistance(&br, 0, &ring, 0, 0)).value);
    // code 1 -> second-to-last (11).
    try testing.expectEqual(@as(u32, 11), (try readDistance(&br, 1, &ring, 0, 0)).value);
    // code 4 -> last distance - 1 = 3.
    try testing.expectEqual(@as(u32, 3), (try readDistance(&br, 4, &ring, 0, 0)).value);
    // code 5 -> last distance + 1 = 5.
    try testing.expectEqual(@as(u32, 5), (try readDistance(&br, 5, &ring, 0, 0)).value);
    // code 11 -> second-to-last + 1 = 12.
    try testing.expectEqual(@as(u32, 12), (try readDistance(&br, 11, &ring, 0, 0)).value);
}

test "direct distance codes map 16.. to 1.. (sec 4)" {
    var ring = DistanceRing{};
    var br = BitReader{ .bytes = &.{} };

    // NDIRECT = 120: code 16 -> distance 1, code 135 -> distance 120.
    try testing.expectEqual(@as(u32, 1), (try readDistance(&br, 16, &ring, 3, 120)).value);
    try testing.expectEqual(@as(u32, 120), (try readDistance(&br, 135, &ring, 3, 120)).value);
}

test "distance ring push order" {
    var ring = DistanceRing{};
    ring.push(20);

    try testing.expectEqual(@as(u32, 20), ring.d[0]);
    try testing.expectEqual(@as(u32, 4), ring.d[1]);
    try testing.expectEqual(@as(u32, 11), ring.d[2]);
    try testing.expectEqual(@as(u32, 15), ring.d[3]);
}

test "text vector stops at the static dictionary boundary (phase D6)" {
    // 'the quick brown fox' is built from brotli static dictionary words, so after the
    // first literals the encoder emits a dictionary reference (distance past the output).
    // D5 decodes up to that point and reports the boundary, the same way D1 stopped at the
    // compressed boundary. The full decode of this vector lands in phase D6.
    const text = "\x1f\xef\x00\xf8\x8d\x94\x6e\xe6\xa2\x06\x31\xa3\xc3\x53\x68\x6f\x39\xc8\x24\xa3\xe5\x08\xdb\x74\x54\x16\x48\xd7\x16\x0f";

    try testing.expectError(error.DictionaryReference, decompress(testing.allocator, text));
}

test "decompress non-dictionary token vector matches brotli -dc" {
    const tokens = "\xa1\x78\x07\xc0\x6f\xa4\x44\x9d\x5f\xbd\xa4\x15\x87\xa7\x6e\x72\x62\xb6\x38\x00\xc9\x70";

    const out = try decompress(testing.allocator, tokens);
    defer testing.allocator.free(out);

    const unit = "Zq7Kx9";
    try testing.expectEqual(@as(usize, unit.len * 40), out.len);

    var i: usize = 0;
    while (i < out.len) : (i += unit.len) try testing.expectEqualStrings(unit, out[i .. i + unit.len]);
}
