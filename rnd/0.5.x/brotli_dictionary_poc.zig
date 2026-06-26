//! Brotli static dictionary PoC (RFC 7932 section 8 + Appendix A + Appendix B), phase D6.
//!
//! Note:
//! - Completes the decoder: a copy whose distance points past the produced output (the
//!   boundary D5 stopped at) is resolved into a static dictionary word plus a word
//!   transform (sec 8). With this, the text vector decodes end to end.
//! - The DICT array (Appendix A, 122,784 bytes, CRC-32 0x5136cb04) is embedded from
//!   brotli_dictionary.bin, extracted from the vendored rnd/rfc/rfc7932.txt hex. DOFFSET
//!   is derived at comptime from NDBITS via the sec 8 recursion. The 121 word transforms
//!   (Appendix B) are transcribed below and self-checked against the RFC's 648-byte
//!   serialization CRC-32 0x3d965f81.
//! - Reuses D5 (brotli_command_poc.zig) for the command machinery (insert-and-copy split,
//!   length tables, literal context, distance decode, ring buffer) and D4 for the header
//!   walk. Single block type per category, as in D5.
//! - Run the real-vector demo: zig run rnd/0.5.x/brotli_dictionary_poc.zig
//!   Run the unit tests:      zig test rnd/0.5.x/brotli_dictionary_poc.zig

const std = @import("std");
const p = @import("brotli_prefix_poc.zig");
const c = @import("brotli_context_poc.zig");
const cmd = @import("brotli_command_poc.zig");
const BitReader = p.BitReader;
const HuffmanDecoder = p.HuffmanDecoder;
const ContextMode = c.ContextMode;

// --------------------------------------------------------- //
// sec 8 dictionary geometry

/// Embedded static dictionary (Appendix A). The 0-length slice keeps it as a byte array.
pub const DICT: []const u8 = @embedFile("brotli_dictionary.bin");

/// Bit-depth of the word count per length (Appendix A): NWORDS[len] = 1 << NDBITS[len]
/// for len >= 4, otherwise 0.
pub const NDBITS = [25]u5{ 0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5 };

/// Byte offset into DICT of the first word of each length, derived from NDBITS by the
/// sec 8 recursion. DOFFSET[25] is DICTSIZE.
pub const DOFFSET = blk: {
    var off: [26]u32 = undefined;
    off[0] = 0;
    var len: usize = 0;
    while (len <= 24) : (len += 1) {
        const nwords: u32 = if (len < 4) 0 else (@as(u32, 1) << NDBITS[len]);
        off[len + 1] = off[len] + @as(u32, @intCast(len)) * nwords;
    }
    break :blk off;
};

pub fn numWords(length: usize) u32 {
    return if (length < 4) 0 else (@as(u32, 1) << NDBITS[length]);
}

// --------------------------------------------------------- //
// Appendix B word transforms

// Elementary transform identifiers, matching the RFC's serialization byte values: 0
// Identity, 1 FermentFirst, 2 FermentAll, 3..11 OmitFirst1..9, 12..20 OmitLast1..9.
const ID = 0;
const FF = 1;
const FA = 2;
const OF1 = 3;
const OF2 = 4;
const OF3 = 5;
const OF4 = 6;
const OF5 = 7;
const OF6 = 8;
const OF7 = 9;
const OF9 = 11;
const OL1 = 12;
const OL2 = 13;
const OL3 = 14;
const OL4 = 15;
const OL5 = 16;
const OL6 = 17;
const OL7 = 18;
const OL8 = 19;
const OL9 = 20;

const Transform = struct {
    prefix: []const u8,
    op: u8,
    suffix: []const u8,
};

const TRANSFORMS = [_]Transform{
    .{ .prefix = "", .op = ID, .suffix = "" },
    .{ .prefix = "", .op = ID, .suffix = " " },
    .{ .prefix = " ", .op = ID, .suffix = " " },
    .{ .prefix = "", .op = OF1, .suffix = "" },
    .{ .prefix = "", .op = FF, .suffix = " " },
    .{ .prefix = "", .op = ID, .suffix = " the " },
    .{ .prefix = " ", .op = ID, .suffix = "" },
    .{ .prefix = "s ", .op = ID, .suffix = " " },
    .{ .prefix = "", .op = ID, .suffix = " of " },
    .{ .prefix = "", .op = FF, .suffix = "" },
    .{ .prefix = "", .op = ID, .suffix = " and " },
    .{ .prefix = "", .op = OF2, .suffix = "" },
    .{ .prefix = "", .op = OL1, .suffix = "" },
    .{ .prefix = ", ", .op = ID, .suffix = " " },
    .{ .prefix = "", .op = ID, .suffix = ", " },
    .{ .prefix = " ", .op = FF, .suffix = " " },
    .{ .prefix = "", .op = ID, .suffix = " in " },
    .{ .prefix = "", .op = ID, .suffix = " to " },
    .{ .prefix = "e ", .op = ID, .suffix = " " },
    .{ .prefix = "", .op = ID, .suffix = "\"" },
    .{ .prefix = "", .op = ID, .suffix = "." },
    .{ .prefix = "", .op = ID, .suffix = "\">" },
    .{ .prefix = "", .op = ID, .suffix = "\n" },
    .{ .prefix = "", .op = OL3, .suffix = "" },
    .{ .prefix = "", .op = ID, .suffix = "]" },
    .{ .prefix = "", .op = ID, .suffix = " for " },
    .{ .prefix = "", .op = OF3, .suffix = "" },
    .{ .prefix = "", .op = OL2, .suffix = "" },
    .{ .prefix = "", .op = ID, .suffix = " a " },
    .{ .prefix = "", .op = ID, .suffix = " that " },
    .{ .prefix = " ", .op = FF, .suffix = "" },
    .{ .prefix = "", .op = ID, .suffix = ". " },
    .{ .prefix = ".", .op = ID, .suffix = "" },
    .{ .prefix = " ", .op = ID, .suffix = ", " },
    .{ .prefix = "", .op = OF4, .suffix = "" },
    .{ .prefix = "", .op = ID, .suffix = " with " },
    .{ .prefix = "", .op = ID, .suffix = "'" },
    .{ .prefix = "", .op = ID, .suffix = " from " },
    .{ .prefix = "", .op = ID, .suffix = " by " },
    .{ .prefix = "", .op = OF5, .suffix = "" },
    .{ .prefix = "", .op = OF6, .suffix = "" },
    .{ .prefix = " the ", .op = ID, .suffix = "" },
    .{ .prefix = "", .op = OL4, .suffix = "" },
    .{ .prefix = "", .op = ID, .suffix = ". The " },
    .{ .prefix = "", .op = FA, .suffix = "" },
    .{ .prefix = "", .op = ID, .suffix = " on " },
    .{ .prefix = "", .op = ID, .suffix = " as " },
    .{ .prefix = "", .op = ID, .suffix = " is " },
    .{ .prefix = "", .op = OL7, .suffix = "" },
    .{ .prefix = "", .op = OL1, .suffix = "ing " },
    .{ .prefix = "", .op = ID, .suffix = "\n\t" },
    .{ .prefix = "", .op = ID, .suffix = ":" },
    .{ .prefix = " ", .op = ID, .suffix = ". " },
    .{ .prefix = "", .op = ID, .suffix = "ed " },
    .{ .prefix = "", .op = OF9, .suffix = "" },
    .{ .prefix = "", .op = OF7, .suffix = "" },
    .{ .prefix = "", .op = OL6, .suffix = "" },
    .{ .prefix = "", .op = ID, .suffix = "(" },
    .{ .prefix = "", .op = FF, .suffix = ", " },
    .{ .prefix = "", .op = OL8, .suffix = "" },
    .{ .prefix = "", .op = ID, .suffix = " at " },
    .{ .prefix = "", .op = ID, .suffix = "ly " },
    .{ .prefix = " the ", .op = ID, .suffix = " of " },
    .{ .prefix = "", .op = OL5, .suffix = "" },
    .{ .prefix = "", .op = OL9, .suffix = "" },
    .{ .prefix = " ", .op = FF, .suffix = ", " },
    .{ .prefix = "", .op = FF, .suffix = "\"" },
    .{ .prefix = ".", .op = ID, .suffix = "(" },
    .{ .prefix = "", .op = FA, .suffix = " " },
    .{ .prefix = "", .op = FF, .suffix = "\">" },
    .{ .prefix = "", .op = ID, .suffix = "=\"" },
    .{ .prefix = " ", .op = ID, .suffix = "." },
    .{ .prefix = ".com/", .op = ID, .suffix = "" },
    .{ .prefix = " the ", .op = ID, .suffix = " of the " },
    .{ .prefix = "", .op = FF, .suffix = "'" },
    .{ .prefix = "", .op = ID, .suffix = ". This " },
    .{ .prefix = "", .op = ID, .suffix = "," },
    .{ .prefix = ".", .op = ID, .suffix = " " },
    .{ .prefix = "", .op = FF, .suffix = "(" },
    .{ .prefix = "", .op = FF, .suffix = "." },
    .{ .prefix = "", .op = ID, .suffix = " not " },
    .{ .prefix = " ", .op = ID, .suffix = "=\"" },
    .{ .prefix = "", .op = ID, .suffix = "er " },
    .{ .prefix = " ", .op = FA, .suffix = " " },
    .{ .prefix = "", .op = ID, .suffix = "al " },
    .{ .prefix = " ", .op = FA, .suffix = "" },
    .{ .prefix = "", .op = ID, .suffix = "='" },
    .{ .prefix = "", .op = FA, .suffix = "\"" },
    .{ .prefix = "", .op = FF, .suffix = ". " },
    .{ .prefix = " ", .op = ID, .suffix = "(" },
    .{ .prefix = "", .op = ID, .suffix = "ful " },
    .{ .prefix = " ", .op = FF, .suffix = ". " },
    .{ .prefix = "", .op = ID, .suffix = "ive " },
    .{ .prefix = "", .op = ID, .suffix = "less " },
    .{ .prefix = "", .op = FA, .suffix = "'" },
    .{ .prefix = "", .op = ID, .suffix = "est " },
    .{ .prefix = " ", .op = FF, .suffix = "." },
    .{ .prefix = "", .op = FA, .suffix = "\">" },
    .{ .prefix = " ", .op = ID, .suffix = "='" },
    .{ .prefix = "", .op = FF, .suffix = "," },
    .{ .prefix = "", .op = ID, .suffix = "ize " },
    .{ .prefix = "", .op = FA, .suffix = "." },
    .{ .prefix = "\xc2\xa0", .op = ID, .suffix = "" },
    .{ .prefix = " ", .op = ID, .suffix = "," },
    .{ .prefix = "", .op = FF, .suffix = "=\"" },
    .{ .prefix = "", .op = FA, .suffix = "=\"" },
    .{ .prefix = "", .op = ID, .suffix = "ous " },
    .{ .prefix = "", .op = FA, .suffix = ", " },
    .{ .prefix = "", .op = FF, .suffix = "='" },
    .{ .prefix = " ", .op = FF, .suffix = "," },
    .{ .prefix = " ", .op = FA, .suffix = "=\"" },
    .{ .prefix = " ", .op = FA, .suffix = ", " },
    .{ .prefix = "", .op = FA, .suffix = "," },
    .{ .prefix = "", .op = FA, .suffix = "(" },
    .{ .prefix = "", .op = FA, .suffix = ". " },
    .{ .prefix = " ", .op = FA, .suffix = "." },
    .{ .prefix = "", .op = FA, .suffix = "='" },
    .{ .prefix = " ", .op = FA, .suffix = ". " },
    .{ .prefix = " ", .op = FF, .suffix = "=\"" },
    .{ .prefix = " ", .op = FA, .suffix = "='" },
    .{ .prefix = " ", .op = FF, .suffix = "='" },
};

/// Ferment one position (sec 8): upper-case ASCII, or flip a bit in the next byte of a
/// 2- or 3-byte UTF-8 sequence. Returns the number of bytes consumed.
fn ferment(word: []u8, pos: usize) usize {
    if (word[pos] < 192) {
        if (word[pos] >= 97 and word[pos] <= 122) word[pos] ^= 32;
        return 1;
    } else if (word[pos] < 224) {
        if (pos + 1 < word.len) word[pos + 1] ^= 32;
        return 2;
    } else {
        if (pos + 2 < word.len) word[pos + 2] ^= 5;
        return 3;
    }
}

fn fermentFirst(word: []u8) void {
    if (word.len > 0) _ = ferment(word, 0);
}

fn fermentAll(word: []u8) void {
    var i: usize = 0;
    while (i < word.len) i += ferment(word, i);
}

/// Apply a transform to a base word, writing prefix + T(word) + suffix into out (sec 8).
/// Returns the number of bytes written.
fn applyTransform(t: Transform, base: []const u8, out: []u8) usize {
    var n: usize = 0;
    @memcpy(out[n..][0..t.prefix.len], t.prefix);
    n += t.prefix.len;

    var word: [38]u8 = undefined;
    @memcpy(word[0..base.len], base);

    var mid_start: usize = 0;
    var mid_len: usize = base.len;
    if (t.op == FF) {
        fermentFirst(word[0..mid_len]);
    } else if (t.op == FA) {
        fermentAll(word[0..mid_len]);
    } else if (t.op >= OF1 and t.op <= OF9) {
        const k = t.op - 2; // OmitFirst1 is op 3
        if (k >= mid_len) mid_len = 0 else {
            mid_start = k;
            mid_len -= k;
        }
    } else if (t.op >= OL1 and t.op <= OL9) {
        const k = t.op - 11; // OmitLast1 is op 12
        if (k >= mid_len) mid_len = 0 else mid_len -= k;
    }

    @memcpy(out[n..][0..mid_len], word[mid_start .. mid_start + mid_len]);
    n += mid_len;

    @memcpy(out[n..][0..t.suffix.len], t.suffix);
    n += t.suffix.len;

    return n;
}

/// Resolve a dictionary reference (sec 8) into out, returning the bytes written.
pub fn dictionaryWord(length: u32, distance: u32, max_allowed: u32, out: []u8) !usize {
    if (length < 4 or length > 24) return error.InvalidDictionaryLength;

    const word_id = distance - (max_allowed + 1);
    const index = word_id % numWords(length);
    const transform_id = word_id >> NDBITS[length];
    if (transform_id > 120) return error.InvalidTransform;

    const offset = DOFFSET[length] + index * length;
    const base = DICT[offset .. offset + length];

    return applyTransform(TRANSFORMS[transform_id], base, out);
}

// --------------------------------------------------------- //
// The full decoder (D5 command loop + the dictionary branch)

/// Decode a single-meta-block compressed stream into freshly allocated output, resolving
/// both backward references and static dictionary references (sec 10).
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

    const window_size = (@as(u32, 1) << @intCast(h.wbits)) - 16;

    const out = try allocator.alloc(u8, h.mlen);
    errdefer allocator.free(out);

    var pos: usize = 0;
    var ring = cmd.DistanceRing{};
    var p1: u8 = 0;
    var p2: u8 = 0;

    while (pos < h.mlen) {
        const command = try htreei.readSymbol(&br);
        const ic = cmd.splitInsertCopy(command);

        const insert_len = cmd.INSERT_LEN_BASE[ic.insert_code] + try br.readBits(cmd.INSERT_LEN_EXTRA[ic.insert_code]);
        const copy_len = cmd.COPY_LEN_BASE[ic.copy_code] + try br.readBits(cmd.COPY_LEN_EXTRA[ic.copy_code]);

        var i: u32 = 0;
        while (i < insert_len) : (i += 1) {
            const cid = cmd.literalContextId(cmode[0], p1, p2);
            const lit: u8 = @intCast(try htreel[cmapl[cid]].readSymbol(&br));

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
            const cid = cmd.distanceContextId(copy_len);
            const dcode = try htreed[cmapd[cid]].readSymbol(&br);
            const d = try cmd.readDistance(&br, dcode, &ring, h.npostfix, h.ndirect);
            distance = d.value;
            push_candidate = d.push;
        }

        const max_allowed: u32 = @min(window_size, @as(u32, @intCast(pos)));
        if (distance <= max_allowed) {
            // A real backward reference: push to the ring here, after ruling out a
            // dictionary reference (sec 4, dictionary refs are never pushed to the ring).
            if (push_candidate) ring.push(distance);

            var j: u32 = 0;
            while (j < copy_len and pos < h.mlen) : (j += 1) {
                const b = out[pos - distance];

                out[pos] = b;
                pos += 1;
                p2 = p1;
                p1 = b;
            }
        } else {
            const written = try dictionaryWord(copy_len, distance, max_allowed, out[pos..]);
            if (written >= 2) {
                p2 = out[pos + written - 2];
                p1 = out[pos + written - 1];
            } else if (written == 1) {
                p2 = p1;
                p1 = out[pos];
            }
            pos += written;
        }
    }

    return out;
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 'the quick brown fox ' x12: this vector needs the static dictionary (D5 stopped on
    // it, the words live in the brotli dictionary).
    const text = "\x1f\xef\x00\xf8\x8d\x94\x6e\xe6\xa2\x06\x31\xa3\xc3\x53\x68\x6f\x39\xc8\x24\xa3\xe5\x08\xdb\x74\x54\x16\x48\xd7\x16\x0f";

    const out = decompress(allocator, text) catch |err| {
        std.debug.print("stopped at: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("decoded {d} bytes:\n{s}\n", .{ out.len, out });
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const testing = std.testing;

/// CRC-32 with the RFC 7932 Appendix C polynomial (0xedb88320), for the self-checks.
fn crc32(data: []const u8) u32 {
    const poly: u32 = 0xedb88320;
    var crc: u32 = 0xffffffff;
    for (data) |byte| {
        var ch: u32 = (crc ^ byte) & 0xff;
        var k: usize = 0;
        while (k < 8) : (k += 1) ch = if (ch & 1 != 0) poly ^ (ch >> 1) else ch >> 1;
        crc = ch ^ (crc >> 8);
    }

    return crc ^ 0xffffffff;
}

test "embedded dictionary matches the RFC size and CRC-32 (Appendix A)" {
    try testing.expectEqual(@as(usize, 122784), DICT.len);
    try testing.expectEqual(@as(u32, 122784), DOFFSET[25]); // DICTSIZE
    try testing.expectEqual(@as(u32, 0x5136cb04), crc32(DICT));
}

test "transform table matches the RFC serialization length and CRC-32 (Appendix B)" {
    // Each transform serializes as prefix + 0 + op + suffix + 0, concatenated (sec note).
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    for (TRANSFORMS) |t| {
        @memcpy(buf[n..][0..t.prefix.len], t.prefix);
        n += t.prefix.len;
        buf[n] = 0;
        n += 1;
        buf[n] = t.op;
        n += 1;
        @memcpy(buf[n..][0..t.suffix.len], t.suffix);
        n += t.suffix.len;
        buf[n] = 0;
        n += 1;
    }

    try testing.expectEqual(@as(usize, 121), TRANSFORMS.len);
    try testing.expectEqual(@as(usize, 648), n);
    try testing.expectEqual(@as(u32, 0x3d965f81), crc32(buf[0..n]));
}

test "elementary transforms apply correctly" {
    var out: [64]u8 = undefined;

    // op 0 identity, no affixes.
    try testing.expectEqual(@as(usize, 3), applyTransform(TRANSFORMS[0], "abc", &out));
    try testing.expectEqualStrings("abc", out[0..3]);

    // op 5: identity + " the " suffix.
    const n5 = applyTransform(TRANSFORMS[5], "abc", &out);
    try testing.expectEqualStrings("abc the ", out[0..n5]);

    // op 3: OmitFirst1.
    const n3 = applyTransform(TRANSFORMS[3], "abc", &out);
    try testing.expectEqualStrings("bc", out[0..n3]);

    // op 12: OmitLast1.
    const n12 = applyTransform(TRANSFORMS[12], "abc", &out);
    try testing.expectEqualStrings("ab", out[0..n12]);

    // op 9: FermentFirst upper-cases the first ASCII letter.
    const n9 = applyTransform(TRANSFORMS[9], "abc", &out);
    try testing.expectEqualStrings("Abc", out[0..n9]);

    // op 44: FermentAll upper-cases all ASCII letters.
    const n44 = applyTransform(TRANSFORMS[44], "abc", &out);
    try testing.expectEqualStrings("ABC", out[0..n44]);
}

test "decompress text vector resolves dictionary words and matches brotli -dc" {
    const text = "\x1f\xef\x00\xf8\x8d\x94\x6e\xe6\xa2\x06\x31\xa3\xc3\x53\x68\x6f\x39\xc8\x24\xa3\xe5\x08\xdb\x74\x54\x16\x48\xd7\x16\x0f";

    const out = try decompress(testing.allocator, text);
    defer testing.allocator.free(out);

    const unit = "the quick brown fox ";
    try testing.expectEqual(@as(usize, unit.len * 12), out.len);

    var i: usize = 0;
    while (i < out.len) : (i += unit.len) try testing.expectEqualStrings(unit, out[i .. i + unit.len]);
}
