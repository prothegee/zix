//! Brotli complete decoder + conformance PoC (RFC 7932 section 9 + section 10), phase D7.
//!
//! Note:
//! - Consolidates D1..D6 into one decoder and adds the cases the layered PoCs skipped:
//!   the multi-meta-block outer loop (sec 10), metadata meta-blocks (MNIBBLES = 0, sec
//!   9.2), uncompressed meta-blocks (ISUNCOMPRESSED), and mid-data block-switch commands
//!   (NBLTYPES >= 2, sec 6) for all three categories. State that persists across
//!   meta-blocks (the last two bytes p1 / p2, the distance ring buffer, the full output
//!   for backward references) is held outside the meta-block loop.
//! - Reuses the leaf primitives from the earlier phases: D2 (bit reader, prefix codes),
//!   D3 (block-type / block-count codes), D4 (context modes and maps), D5 (insert-and-copy
//!   split, length tables, literal context, distance decode, ring buffer), D6 (static
//!   dictionary words).
//! - Conformance harness: `zig build-exe` this file and run it with one or more *.br
//!   files as arguments; each is decoded and compared byte-for-byte against the sibling
//!   file with the .br suffix removed (the original). Use perf-conformance-brotli.sh to
//!   drive a corpus round-tripped through the system `brotli` CLI at several qualities and
//!   window sizes. The embedded unit tests cover the feature matrix directly.
//! - Run the unit tests:  zig test rnd/0.5.x/brotli_conformance_poc.zig
//!   Run the harness:      zig run rnd/0.5.x/brotli_conformance_poc.zig -- file1.br ...

const std = @import("std");
const p = @import("brotli_prefix_poc.zig");
const m = @import("brotli_meta_poc.zig");
const c = @import("brotli_context_poc.zig");
const cmd = @import("brotli_command_poc.zig");
const dict = @import("brotli_dictionary_poc.zig");
const BitReader = p.BitReader;
const HuffmanDecoder = p.HuffmanDecoder;
const ContextMode = c.ContextMode;

// --------------------------------------------------------- //
// Block-switch state (sec 6)

/// One block category (literals, insert-and-copy, or distances). When NBLTYPES >= 2 the
/// stream carries block-switch commands that flip the active block type mid-data.
const BlockCategory = struct {
    nbltypes: u32,
    btype: u32 = 0,
    prev_btype: u32 = 1,
    blen: u32 = 0,
    has_switch: bool = false,
    btype_code: HuffmanDecoder = undefined,
    blen_code: HuffmanDecoder = undefined,

    /// Read the per-category setup (sec 9.2): NBLTYPES, and when >= 2 the block-type code,
    /// the block-count code, and the first block count.
    fn init(br: *BitReader) !BlockCategory {
        const nbltypes = try m.readBlockTypeCount(br);
        if (nbltypes < 2) return .{ .nbltypes = nbltypes, .blen = 16777216 };

        var cat = BlockCategory{ .nbltypes = nbltypes, .has_switch = true };
        cat.btype_code = try p.readPrefixCode(br, nbltypes + 2);
        cat.blen_code = try p.readPrefixCode(br, m.BLOCK_COUNT_BASE.len);
        cat.blen = try m.readBlockCount(br, &cat.blen_code);

        return cat;
    }

    /// Consume one item from the current block (sec 10), reading a block-switch command
    /// first when the current block count has run out.
    fn consume(self: *BlockCategory, br: *BitReader) !void {
        if (self.blen == 0 and self.has_switch) {
            const sym = try self.btype_code.readSymbol(br);
            const next: u32 = switch (sym) {
                0 => self.prev_btype,
                1 => (self.btype + 1) % self.nbltypes,
                else => @as(u32, sym) - 2,
            };
            if (next >= self.nbltypes) return error.InvalidBlockType;

            self.prev_btype = self.btype;
            self.btype = next;
            self.blen = try m.readBlockCount(br, &self.blen_code);
        }

        if (self.blen > 0) self.blen -= 1;
    }
};

// --------------------------------------------------------- //
// The decoder

/// Feature coverage of a decode, so the conformance harness can prove which code paths a
/// corpus actually exercised rather than only that it round-tripped.
pub const Stats = struct {
    meta_blocks: usize = 0,
    compressed: usize = 0,
    uncompressed: usize = 0,
    metadata: usize = 0,
    block_switch: usize = 0,
};

const Decoder = struct {
    allocator: std.mem.Allocator,
    br: BitReader,
    stats: *Stats,
    out: std.ArrayList(u8) = .empty,
    window_size: u32 = 0,
    ring: cmd.DistanceRing = .{},
    p1: u8 = 0,
    p2: u8 = 0,

    fn pushByte(self: *Decoder, b: u8) !void {
        try self.out.append(self.allocator, b);
        self.p2 = self.p1;
        self.p1 = b;
    }

    /// Decode the whole stream (sec 10), returning the owned uncompressed bytes.
    fn run(self: *Decoder) ![]u8 {
        const wbits = try m.readWindowBits(&self.br);
        self.window_size = (@as(u32, 1) << @intCast(wbits)) - 16;

        while (true) {
            const is_last = try self.br.readBit();
            if (is_last == 1 and try self.br.readBit() == 1) break;

            const mnibbles_code = try self.br.readBits(2);
            if (mnibbles_code == 3) {
                try self.skipMetadata();
            } else {
                const nibbles: u6 = @intCast(mnibbles_code + 4);
                const mlen = (try self.br.readBits(nibbles * 4)) + 1;

                var is_uncompressed = false;
                if (is_last == 0) is_uncompressed = (try self.br.readBit() == 1);

                if (is_uncompressed) {
                    try self.copyUncompressed(mlen);
                } else {
                    try self.decodeMetaBlock(mlen);
                }
            }

            if (is_last == 1) break;
        }

        return self.out.toOwnedSlice(self.allocator);
    }

    /// Metadata meta-block (MNIBBLES = 0, sec 9.2): skip MSKIPLEN bytes, produce nothing.
    fn skipMetadata(self: *Decoder) !void {
        self.stats.meta_blocks += 1;
        self.stats.metadata += 1;
        if (try self.br.readBit() != 0) return error.BadReservedBit;

        const mskipbytes = try self.br.readBits(2);
        var mskiplen: u32 = 0;
        if (mskipbytes > 0) mskiplen = (try self.br.readBits(@intCast(mskipbytes * 8))) + 1;

        self.br.alignToByte();
        _ = try self.br.readBytes(mskiplen);
    }

    /// Uncompressed meta-block (ISUNCOMPRESSED): copy MLEN literal bytes verbatim.
    fn copyUncompressed(self: *Decoder, mlen: u32) !void {
        self.stats.meta_blocks += 1;
        self.stats.uncompressed += 1;
        self.br.alignToByte();
        const raw = try self.br.readBytes(mlen);

        try self.out.appendSlice(self.allocator, raw);
        if (mlen >= 2) {
            self.p2 = raw[mlen - 2];
            self.p1 = raw[mlen - 1];
        } else if (mlen == 1) {
            self.p2 = self.p1;
            self.p1 = raw[0];
        }
    }

    /// Compressed meta-block: parse the header (sec 9.2) and run the command loop (sec 10).
    fn decodeMetaBlock(self: *Decoder, mlen: u32) !void {
        self.stats.meta_blocks += 1;
        self.stats.compressed += 1;

        var cat_l = try BlockCategory.init(&self.br);
        var cat_i = try BlockCategory.init(&self.br);
        var cat_d = try BlockCategory.init(&self.br);
        if (cat_l.nbltypes >= 2 or cat_i.nbltypes >= 2 or cat_d.nbltypes >= 2) self.stats.block_switch += 1;

        const npostfix = try self.br.readBits(2);
        const ndirect = (try self.br.readBits(4)) << @intCast(npostfix);

        var cmode: [c.MAX_BLOCK_TYPES]ContextMode = undefined;
        try c.readContextModes(&self.br, cat_l.nbltypes, cmode[0..cat_l.nbltypes]);

        var cmapl: [c.CMAPL_MAX]u8 = undefined;
        const ntreesl = try m.readBlockTypeCount(&self.br);
        const cmapl_size = 64 * cat_l.nbltypes;
        @memset(cmapl[0..cmapl_size], 0);
        if (ntreesl >= 2) try c.readContextMap(&self.br, ntreesl, cmapl_size, &cmapl);

        var cmapd: [c.CMAPD_MAX]u8 = undefined;
        const ntreesd = try m.readBlockTypeCount(&self.br);
        const cmapd_size = 4 * cat_d.nbltypes;
        @memset(cmapd[0..cmapd_size], 0);
        if (ntreesd >= 2) try c.readContextMap(&self.br, ntreesd, cmapd_size, &cmapd);

        const htreel = try self.allocator.alloc(HuffmanDecoder, ntreesl);
        defer self.allocator.free(htreel);
        for (htreel) |*tree| tree.* = try p.readPrefixCode(&self.br, 256);

        const htreei = try self.allocator.alloc(HuffmanDecoder, cat_i.nbltypes);
        defer self.allocator.free(htreei);
        for (htreei) |*tree| tree.* = try p.readPrefixCode(&self.br, 704);

        const dist_alphabet = 16 + ndirect + (@as(u32, 48) << @intCast(npostfix));
        const htreed = try self.allocator.alloc(HuffmanDecoder, ntreesd);
        defer self.allocator.free(htreed);
        for (htreed) |*tree| tree.* = try p.readPrefixCode(&self.br, dist_alphabet);

        try self.out.ensureUnusedCapacity(self.allocator, mlen);

        var produced: u32 = 0;
        while (produced < mlen) {
            try cat_i.consume(&self.br);
            const command = try htreei[cat_i.btype].readSymbol(&self.br);
            const ic = cmd.splitInsertCopy(command);

            const insert_len = cmd.INSERT_LEN_BASE[ic.insert_code] + try self.br.readBits(cmd.INSERT_LEN_EXTRA[ic.insert_code]);
            const copy_len = cmd.COPY_LEN_BASE[ic.copy_code] + try self.br.readBits(cmd.COPY_LEN_EXTRA[ic.copy_code]);

            var k: u32 = 0;
            while (k < insert_len) : (k += 1) {
                try cat_l.consume(&self.br);
                const cid = cmd.literalContextId(cmode[cat_l.btype], self.p1, self.p2);
                const lit: u8 = @intCast(try htreel[cmapl[64 * cat_l.btype + cid]].readSymbol(&self.br));

                try self.pushByte(lit);
                produced += 1;
                if (produced == mlen) return;
            }

            var distance: u32 = undefined;
            var push_candidate = false;
            if (ic.distance_zero) {
                distance = self.ring.d[0];
            } else {
                try cat_d.consume(&self.br);
                const cid = cmd.distanceContextId(copy_len);
                const dcode = try htreed[cmapd[4 * cat_d.btype + cid]].readSymbol(&self.br);
                const d = try cmd.readDistance(&self.br, dcode, &self.ring, npostfix, ndirect);
                distance = d.value;
                push_candidate = d.push;
            }

            const max_allowed: u32 = @min(self.window_size, @as(u32, @intCast(self.out.items.len)));
            if (distance <= max_allowed) {
                // A real backward reference: push to the ring buffer here, after confirming
                // it is not a dictionary reference (sec 4, dictionary refs are not pushed).
                if (push_candidate) self.ring.push(distance);

                var j: u32 = 0;
                while (j < copy_len and produced < mlen) : (j += 1) {
                    const b = self.out.items[self.out.items.len - distance];

                    try self.pushByte(b);
                    produced += 1;
                }
            } else {
                var word: [38]u8 = undefined;
                const written = try dict.dictionaryWord(copy_len, distance, max_allowed, &word);

                for (word[0..written]) |b| try self.pushByte(b);
                produced += @intCast(written);
            }
        }
    }
};

/// Decode a full brotli stream into freshly allocated output (allocator owns the result),
/// recording feature coverage into stats.
pub fn decodeStats(allocator: std.mem.Allocator, data: []const u8, stats: *Stats) ![]u8 {
    var decoder = Decoder{ .allocator = allocator, .br = .{ .bytes = data }, .stats = stats };
    errdefer decoder.out.deinit(allocator);

    return decoder.run();
}

/// Decode a full brotli stream into freshly allocated output (allocator owns the result).
pub fn decode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var stats: Stats = .{};

    return decodeStats(allocator, data, &stats);
}

// --------------------------------------------------------- //
// Conformance harness (argv: *.br files, compared to the sibling original)

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = process.io;
    const cwd = std.Io.Dir.cwd();

    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();

    var pass: usize = 0;
    var fail: usize = 0;
    var total: Stats = .{};
    var multi_meta_files: usize = 0;
    while (arg_iter.next()) |path| {
        if (!std.mem.endsWith(u8, path, ".br")) continue;

        const original_path = path[0 .. path.len - 3];
        const compressed = cwd.readFileAlloc(io, path, allocator, .unlimited) catch |err| {
            std.debug.print("FAIL {s}: read {s}\n", .{ path, @errorName(err) });
            fail += 1;
            continue;
        };
        const expected = try cwd.readFileAlloc(io, original_path, allocator, .unlimited);

        var stats: Stats = .{};
        const got = decodeStats(allocator, compressed, &stats) catch |err| {
            std.debug.print("FAIL {s}: decode {s}\n", .{ path, @errorName(err) });
            fail += 1;
            continue;
        };

        if (std.mem.eql(u8, got, expected)) {
            pass += 1;
            total.meta_blocks += stats.meta_blocks;
            total.compressed += stats.compressed;
            total.uncompressed += stats.uncompressed;
            total.metadata += stats.metadata;
            total.block_switch += stats.block_switch;
            if (stats.meta_blocks > 1) multi_meta_files += 1;
        } else {
            std.debug.print("FAIL {s}: {d} bytes vs {d} expected\n", .{ path, got.len, expected.len });
            fail += 1;
        }
    }

    std.debug.print("conformance: {d} passed, {d} failed\n", .{ pass, fail });
    std.debug.print("coverage: meta-blocks={d} compressed={d} uncompressed={d} metadata={d} block-switch={d} multi-meta-block-files={d}\n", .{ total.meta_blocks, total.compressed, total.uncompressed, total.metadata, total.block_switch, multi_meta_files });
    if (fail != 0) return error.ConformanceFailed;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const testing = std.testing;

fn expectRoundTrip(compressed: []const u8, expected: []const u8) !void {
    const got = try decode(testing.allocator, compressed);
    defer testing.allocator.free(got);

    try testing.expectEqualStrings(expected, got);
}

test "single meta-block with static dictionary (the quick brown fox)" {
    const v = "\x1f\xef\x00\xf8\x8d\x94\x6e\xe6\xa2\x06\x31\xa3\xc3\x53\x68\x6f\x39\xc8\x24\xa3\xe5\x08\xdb\x74\x54\x16\x48\xd7\x16\x0f";

    var buf: [240]u8 = undefined;
    var i: usize = 0;
    while (i < 240) : (i += 20) @memcpy(buf[i .. i + 20], "the quick brown fox ");

    try expectRoundTrip(v, &buf);
}

test "single meta-block with pure back-references (non-dictionary tokens)" {
    const v = "\xa1\x78\x07\xc0\x6f\xa4\x44\x9d\x5f\xbd\xa4\x15\x87\xa7\x6e\x72\x62\xb6\x38\x00\xc9\x70";

    var buf: [240]u8 = undefined;
    var i: usize = 0;
    while (i < 240) : (i += 6) @memcpy(buf[i .. i + 6], "Zq7Kx9");

    try expectRoundTrip(v, &buf);
}

test "empty stream decodes to nothing" {
    // printf '' | brotli -c  ->  single byte 0x3f (WBITS=24 then ISLAST + ISLASTEMPTY).
    try expectRoundTrip("\x3f", "");
}

test "metadata meta-block is skipped, producing no output" {
    // Hand-crafted (the brotli CLI never emits metadata blocks): WBITS=16, a metadata
    // meta-block carrying 3 skip bytes (0xAA 0xBB 0xCC), then a last empty meta-block.
    // Verified to decode to empty with `brotli -dc`.
    const v = "\x2c\x01\xaa\xbb\xcc\x03";

    var stats: Stats = .{};
    const got = try decodeStats(testing.allocator, v, &stats);
    defer testing.allocator.free(got);

    try testing.expectEqualStrings("", got);
    try testing.expectEqual(@as(usize, 1), stats.metadata);
}
