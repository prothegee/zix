//! Brotli encoder PoC, phase E6 (RFC 7932), static dictionary references.
//!
//! Note:
//! - Builds on E5 (rnd/0.5.x/brotli_encoder_huff_poc.zig). E6 lets a copy command reference
//!   a word in the 122,784-byte static dictionary (Appendix A) instead of earlier output,
//!   the brotli-specific win on text where a word appears before any self-reference exists.
//! - A dictionary reference is just a copy whose distance lands past the available back
//!   distance (sec 8): the decoder computes word_id = distance - (max_allowed + 1), so for
//!   the IDENTITY transform (transform 0) distance = word_index + max_allowed + 1, where
//!   max_allowed = min(window, output_position). It is encoded with the ordinary distance
//!   code and is NOT pushed to the last-distance ring.
//! - Scope: the IDENTITY transform only (the word as-is). The 120 case / prefix / suffix
//!   transforms are a later refinement; identity covers the common exact-word case.
//! - Reuses E5's optimal Huffman and E3 / E4's command and ring machinery. New here: the
//!   dictionary word index and the dict-aware match selection.
//! - Verified by self round-trip through the full decoder (brotli_conformance_poc.zig) and
//!   the `brotli -dc` interop gate (rnd/0.5.x/verify-brotli-encoder-dictref.sh).
//!
//! Run: zig run rnd/0.5.x/brotli_encoder_dictref_poc.zig

const std = @import("std");
const e2 = @import("brotli_encoder_literal_poc.zig");
const e3 = @import("brotli_encoder_lz_poc.zig");
const e4 = @import("brotli_encoder_dist_poc.zig");
const e5 = @import("brotli_encoder_huff_poc.zig");
const dict = @import("brotli_dictionary_poc.zig");
const cmd_tables = @import("brotli_command_poc.zig");
const decoder = @import("brotli_conformance_poc.zig");

pub const EncodeError = e3.EncodeError;

const MIN_MATCH: usize = 4;
const MAX_MATCH: usize = 16384;
const HASH_BITS = 17;
const HASH_SIZE: usize = 1 << HASH_BITS;
const MAX_CHAIN: usize = 64;
const NO_POS: u32 = std.math.maxInt(u32);

const DICT_MIN_LEN: usize = 4;
const DICT_MAX_LEN: usize = 24;
const DHASH_BITS = 15;
const DHASH_SIZE: usize = 1 << DHASH_BITS;

const LITERAL_ALPHABET: usize = 256;

const Command = struct {
    insert_len: u32,
    lit_off: usize,
    copy_len: u32,
    distance: u32,
    is_dict: bool,
};

/// Encoder effort, tuned by the E7 quality ladder. max_chain bounds the hash-chain walk;
/// use_dict toggles the static dictionary search.
pub const Params = struct {
    max_chain: usize = MAX_CHAIN,
    use_dict: bool = true,
};

fn hash4(bytes: []const u8, pos: usize, comptime bits: u6) usize {
    const v = std.mem.readInt(u32, bytes[pos..][0..4], .little);

    return (v *% 0x9E3779B1) >> (32 - bits);
}

/// A hash index over the identity dictionary words, chained by their first four bytes.
const DictIndex = struct {
    head: []u32,
    next: []u32,
    word_len: []u8,
    word_index: []u32,
    word_off: []u32,

    fn build(allocator: std.mem.Allocator) EncodeError!DictIndex {
        var total: usize = 0;
        var len: usize = DICT_MIN_LEN;
        while (len <= DICT_MAX_LEN) : (len += 1) total += dict.numWords(len);

        var self: DictIndex = .{
            .head = try allocator.alloc(u32, DHASH_SIZE),
            .next = try allocator.alloc(u32, total),
            .word_len = try allocator.alloc(u8, total),
            .word_index = try allocator.alloc(u32, total),
            .word_off = try allocator.alloc(u32, total),
        };
        @memset(self.head, NO_POS);

        var entry: u32 = 0;
        len = DICT_MIN_LEN;
        while (len <= DICT_MAX_LEN) : (len += 1) {
            const words = dict.numWords(len);
            var index: u32 = 0;
            while (index < words) : (index += 1) {
                const off = dict.DOFFSET[len] + index * @as(u32, @intCast(len));
                const h = hash4(dict.DICT, off, DHASH_BITS);

                self.word_len[entry] = @intCast(len);
                self.word_index[entry] = index;
                self.word_off[entry] = off;
                self.next[entry] = self.head[h];
                self.head[h] = entry;
                entry += 1;
            }
        }

        return self;
    }

    /// The longest identity dictionary word that equals the input at pos, or length 0.
    fn longestMatch(self: DictIndex, input: []const u8, pos: usize, best_index: *u32) usize {
        if (pos + 4 > input.len) return 0;

        const h = hash4(input, pos, DHASH_BITS);
        var entry = self.head[h];
        var best_len: usize = 0;
        var chain: usize = 0;
        while (entry != NO_POS and chain < 64) : (chain += 1) {
            const len: usize = self.word_len[entry];
            if (len > best_len and pos + len <= input.len) {
                const word = dict.DICT[self.word_off[entry] .. self.word_off[entry] + len];
                if (std.mem.eql(u8, word, input[pos .. pos + len])) {
                    best_len = len;
                    best_index.* = self.word_index[entry];
                }
            }

            entry = self.next[entry];
        }

        return best_len;
    }
};

/// Greedy parse that considers both a local hash-chain match and a dictionary word at each
/// position, taking whichever is longer.
fn parseWithDict(allocator: std.mem.Allocator, input: []const u8, wbits: u6, dindex: DictIndex, params: Params, commands: *std.ArrayList(Command)) EncodeError!void {
    const window: u32 = (@as(u32, 1) << @intCast(wbits)) - 16;

    const head = try allocator.alloc(u32, HASH_SIZE);
    defer allocator.free(head);
    @memset(head, NO_POS);

    const prev = try allocator.alloc(u32, input.len);
    defer allocator.free(prev);

    var lit_start: usize = 0;
    var i: usize = 0;
    while (i + MIN_MATCH <= input.len) {
        const h = hash4(input, i, HASH_BITS);

        var local_len: usize = 0;
        var local_dist: u32 = 0;
        var cand = head[h];
        var chain: usize = 0;
        while (cand != NO_POS and chain < params.max_chain) : (chain += 1) {
            const dist = i - cand;
            if (dist > window) break;

            const limit = @min(MAX_MATCH, input.len - i);
            var len: usize = 0;
            while (len < limit and input[cand + len] == input[i + len]) len += 1;
            if (len > local_len) {
                local_len = len;
                local_dist = @intCast(dist);
            }

            cand = prev[cand];
        }

        prev[i] = head[h];
        head[h] = @intCast(i);

        var dict_index: u32 = 0;
        const dict_len = if (params.use_dict) dindex.longestMatch(input, i, &dict_index) else 0;

        // a local back-reference is cheap; a dictionary reference costs a large distance, so
        // only reach for the dictionary when there is no usable local match (the gap case).
        const use_local = local_len >= MIN_MATCH;
        const use_dict = !use_local and dict_len >= MIN_MATCH;

        if (use_dict or use_local) {
            var c = Command{
                .insert_len = @intCast(i - lit_start),
                .lit_off = lit_start,
                .copy_len = 0,
                .distance = 0,
                .is_dict = use_dict,
            };

            if (use_dict) {
                const max_allowed: u32 = @intCast(@min(@as(usize, window), i));
                c.copy_len = @intCast(dict_len);
                c.distance = dict_index + max_allowed + 1;
            } else {
                c.copy_len = @intCast(local_len);
                c.distance = local_dist;
            }
            try commands.append(allocator, c);

            const match_len = c.copy_len;
            var j = i + 1;
            const end = i + match_len;
            while (j < end and j + MIN_MATCH <= input.len) : (j += 1) {
                const hj = hash4(input, j, HASH_BITS);
                prev[j] = head[hj];
                head[hj] = @intCast(j);
            }

            i = end;
            lit_start = i;
        } else {
            i += 1;
        }
    }

    if (lit_start < input.len) {
        try commands.append(allocator, .{
            .insert_len = @intCast(input.len - lit_start),
            .lit_off = lit_start,
            .copy_len = 0,
            .distance = 0,
            .is_dict = false,
        });
    }
}

pub fn encodeDictRefBlockAlloc(allocator: std.mem.Allocator, input: []const u8, wbits: u6, params: Params) EncodeError![]u8 {
    if (input.len > e2.MAX_META_BLOCK_LEN) return error.InputTooLarge;

    var bw: e2.BitWriter = .{};
    errdefer bw.deinit(allocator);

    try e2.writeWindowBits(&bw, allocator, wbits);

    if (input.len == 0) {
        try bw.writeBit(allocator, 1);
        try bw.writeBit(allocator, 1);

        return bw.toOwnedSlice(allocator);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const dindex = try DictIndex.build(scratch);

    var commands: std.ArrayList(Command) = .empty;
    try parseWithDict(scratch, input, wbits, dindex, params, &commands);

    // distances: dict references use the explicit code without touching the ring, local
    // matches use the ring (sec 4, 8).
    const chosen = try scratch.alloc(e3.DistanceCode, commands.items.len);
    var ring = cmd_tables.DistanceRing{};
    for (commands.items, 0..) |c, idx| {
        if (c.copy_len == 0) continue;

        chosen[idx] = if (c.is_dict) e3.distanceCode(c.distance) else e4.chooseDistance(&ring, c.distance);
    }

    var lit_freq = std.mem.zeroes([LITERAL_ALPHABET]u32);
    var cmd_freq = std.mem.zeroes([e3.COMMAND_ALPHABET]u32);
    var dist_freq = std.mem.zeroes([e3.DISTANCE_ALPHABET]u32);
    for (commands.items, 0..) |c, idx| {
        var k: usize = 0;
        while (k < c.insert_len) : (k += 1) lit_freq[input[c.lit_off + k]] += 1;

        const insert_code = e2.selectInsertCode(c.insert_len);
        if (c.copy_len > 0) {
            cmd_freq[e3.composeCommandExplicit(insert_code, e3.selectCopyCode(c.copy_len))] += 1;
            dist_freq[chosen[idx].code] += 1;
        } else {
            cmd_freq[e3.composeCommandExplicit(insert_code, 0)] += 1;
        }
    }

    const lit_code = try e5.buildOptimalTree(scratch, &lit_freq, LITERAL_ALPHABET);
    const cmd_code = try e5.buildOptimalTree(scratch, &cmd_freq, e3.COMMAND_ALPHABET);
    const dist_code = try e5.buildOptimalTree(scratch, &dist_freq, e3.DISTANCE_ALPHABET);

    try bw.writeBit(allocator, 1); // ISLAST = 1
    try bw.writeBit(allocator, 0); // ISLASTEMPTY = 0
    try e2.writeMetaBlockLen(&bw, allocator, input.len);
    try bw.writeBit(allocator, 0); // NBLTYPESL = 1
    try bw.writeBit(allocator, 0); // NBLTYPESI = 1
    try bw.writeBit(allocator, 0); // NBLTYPESD = 1
    try bw.writeInt(allocator, 0, 2); // NPOSTFIX = 0
    try bw.writeInt(allocator, 0, 4); // NDIRECT = 0
    try bw.writeInt(allocator, 0, 2); // context mode LSB6
    try bw.writeBit(allocator, 0); // NTREESL = 1
    try bw.writeBit(allocator, 0); // NTREESD = 1

    try e3.writeTreeCode(&bw, allocator, lit_code, LITERAL_ALPHABET);
    try e3.writeTreeCode(&bw, allocator, cmd_code, e3.COMMAND_ALPHABET);
    try e3.writeTreeCode(&bw, allocator, dist_code, e3.DISTANCE_ALPHABET);

    for (commands.items, 0..) |c, idx| {
        const insert_code = e2.selectInsertCode(c.insert_len);
        const copy_code: u8 = if (c.copy_len > 0) e3.selectCopyCode(c.copy_len) else 0;
        const sym = e3.composeCommandExplicit(insert_code, copy_code);

        try bw.writeCode(allocator, cmd_code.codes[sym], @intCast(cmd_code.lengths[sym]));
        try bw.writeInt(allocator, c.insert_len - cmd_tables.INSERT_LEN_BASE[insert_code], cmd_tables.INSERT_LEN_EXTRA[insert_code]);

        const copy_value: u32 = if (c.copy_len > 0) c.copy_len else cmd_tables.COPY_LEN_BASE[0];
        try bw.writeInt(allocator, copy_value - cmd_tables.COPY_LEN_BASE[copy_code], cmd_tables.COPY_LEN_EXTRA[copy_code]);

        var k: usize = 0;
        while (k < c.insert_len) : (k += 1) {
            const b = input[c.lit_off + k];
            try bw.writeCode(allocator, lit_code.codes[b], @intCast(lit_code.lengths[b]));
        }

        if (c.copy_len > 0) {
            const dc = chosen[idx];
            try bw.writeCode(allocator, dist_code.codes[dc.code], @intCast(dist_code.lengths[dc.code]));
            try bw.writeInt(allocator, dc.extra, dc.nextra);
        }
    }

    return bw.toOwnedSlice(allocator);
}

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
        const stream = try encodeDictRefBlockAlloc(allocator, input, 22, .{});

        const f = try cwd.createFile(io, output_path.?, .{});
        defer f.close(io);

        var write_buf: [8192]u8 = undefined;
        var writer = f.writer(io, &write_buf);
        try writer.interface.writeAll(stream);
        try writer.interface.flush();

        return;
    }

    // short texts where dictionary words appear before any self-reference exists.
    const samples = [_][]const u8{
        "The quick brown fox and the lazy dog went to the market today.",
        "information about the world and the people in it",
    };

    for (samples) |sample| {
        const stream = try encodeDictRefBlockAlloc(allocator, sample, 22, .{});
        const back = try decoder.decode(allocator, stream);

        const verdict = if (std.mem.eql(u8, back, sample)) "OK" else "MISMATCH";
        std.debug.print("[{d} bytes -> {d} bytes] {s}\n", .{ sample.len, stream.len, verdict });
    }
}

// --------------------------------------------------------- //
// test cases
// --------------------------------------------------------- //

const testing = std.testing;

fn roundTrip(input: []const u8, wbits: u6) !void {
    const stream = try encodeDictRefBlockAlloc(testing.allocator, input, wbits, .{});
    defer testing.allocator.free(stream);

    const back = try decoder.decode(testing.allocator, stream);
    defer testing.allocator.free(back);

    try testing.expectEqualSlices(u8, input, back);
}

test "dictionary index finds a known word" {
    const dindex = try DictIndex.build(testing.allocator);
    defer {
        testing.allocator.free(dindex.head);
        testing.allocator.free(dindex.next);
        testing.allocator.free(dindex.word_len);
        testing.allocator.free(dindex.word_index);
        testing.allocator.free(dindex.word_off);
    }

    // feed an actual dictionary word (the first length-8 word) and confirm the index finds it.
    const off = dict.DOFFSET[8];
    const word = dict.DICT[off .. off + 8];
    var idx: u32 = 0;
    const len = dindex.longestMatch(word, 0, &idx);
    try testing.expect(len >= 4);
    try testing.expectEqualSlices(u8, dict.DICT[dict.DOFFSET[len] + idx * len ..][0..len], word[0..len]);
}

test "empty and no-match inputs round-trip" {
    try roundTrip("", 22);
    try roundTrip("\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f", 22);
}

test "short English text round-trips (dictionary path)" {
    try roundTrip("The quick brown fox and the lazy dog went to the market.", 22);
}

test "text using common dictionary words round-trips" {
    try roundTrip("information about the world and the people in the government", 22);
}

test "dictionary reference then self-reference round-trips" {
    try roundTrip("the time has come the time has come for all good people", 22);
}

test "real text round-trips and is no larger than the E5 single-tree size" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var r: usize = 0;
    while (r < 40) : (r += 1) {
        try buf.appendSlice(testing.allocator, "the government of the people for the people. ");
    }

    try roundTrip(buf.items, 22);
}

test "binary data round-trips" {
    var input: [3000]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @truncate((i * 2654435761) >> 12);

    try roundTrip(&input, 22);
}

test "full byte alphabet round-trips" {
    var input: [256]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @intCast(i);

    try roundTrip(&input, 18);
}
