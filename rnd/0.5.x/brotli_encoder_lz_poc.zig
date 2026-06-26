//! Brotli encoder PoC, phase E3 (RFC 7932), LZ77 matching into insert-and-copy commands.
//!
//! Note:
//! - Builds on E2 (rnd/0.5.x/brotli_encoder_literal_poc.zig, literal-only). E3 adds a
//!   greedy hash-chain match finder: runs of literals are inserted, repeated substrings
//!   become copy commands with a backward distance (sec 4, 5, 10). This is where real LZ
//!   compression appears.
//! - Reuses E2's shared writer, canonical-code, preamble, and literal-code helpers. New in
//!   E3: the match finder, the copy-length and distance code selection (the inverse of the
//!   decoder's readDistance for NPOSTFIX=0 / NDIRECT=0), and per-tree prefix codes for the
//!   insert-and-copy commands (HTREEI) and distances (HTREED), which are no longer single
//!   symbols.
//! - Distances always use the explicit extra-bit codes (>= 16); the last-distance ring
//!   buffer reuse (short codes 0..15) is the E4 refinement, so the ring is left untouched.
//! - Verified by self round-trip through the full decoder (brotli_conformance_poc.zig) and
//!   the `brotli -dc` interop gate (rnd/0.5.x/verify-brotli-encoder-lz.sh).
//!
//! Run: zig run rnd/0.5.x/brotli_encoder_lz_poc.zig

const std = @import("std");
const e2 = @import("brotli_encoder_literal_poc.zig");
const cmd_tables = @import("brotli_command_poc.zig");
const decoder = @import("brotli_conformance_poc.zig");

pub const EncodeError = e2.EncodeError || error{OutOfMemory};

const MIN_MATCH: usize = 4;
const MAX_MATCH: usize = 16384; // bound the copy length to keep extra bits small
const HASH_BITS = 17;
const HASH_SIZE: usize = 1 << HASH_BITS;
const MAX_CHAIN: usize = 64; // hash-chain walk limit per position
const NO_POS: u32 = std.math.maxInt(u32);

pub const DISTANCE_ALPHABET: usize = 64; // 16 + NDIRECT(0) + (48 << NPOSTFIX(0))
pub const COMMAND_ALPHABET: usize = 704;

pub const Command = struct {
    insert_len: u32,
    lit_off: usize,
    copy_len: u32, // 0 marks a trailing insert-only command (the copy is skipped at MLEN)
    distance: u32,
};

pub const DistanceCode = struct {
    code: u16,
    extra: u32,
    nextra: u6,
};

/// Encode a backward distance into its distance code and extra bits, the inverse of the
/// decoder's readDistance with NPOSTFIX=0 and NDIRECT=0 (sec 4). The codes split into two
/// interleaved series (even and odd dadj) whose value ranges tile 1, 2, 3, ... exactly.
pub fn distanceCode(value: u32) DistanceCode {
    var n: u5 = 1;
    while (n < 25) : (n += 1) {
        const span = @as(u32, 1) << n;

        const even_base = (@as(u32, 2) << n) - 3; // dadj = 2*(n-1), bit 0 = 0
        if (value >= even_base and value < even_base + span) {
            return .{ .code = 16 + 2 * (@as(u16, n) - 1), .extra = value - even_base, .nextra = n };
        }

        const odd_base = (@as(u32, 3) << n) - 3; // dadj = 2*(n-1)+1, bit 0 = 1
        if (value >= odd_base and value < odd_base + span) {
            return .{ .code = 16 + 2 * (@as(u16, n) - 1) + 1, .extra = value - odd_base, .nextra = n };
        }
    }

    unreachable; // every distance in a 2^24 window lands in a bucket with n <= 24
}

/// Largest copy-length code whose base is within reach of value (sec 5), like selectInsertCode.
pub fn selectCopyCode(value: u32) u8 {
    var code: u8 = @intCast(cmd_tables.COPY_LEN_BASE.len - 1);
    while (cmd_tables.COPY_LEN_BASE[code] > value) code -= 1;

    return code;
}

// The cell of the insert-and-copy table per (insert band, copy band), each band 0..2 for
// codes 0..7 / 8..15 / 16..23. All these cells encode an explicit distance (cmd >= 128).
const CELL_BY_BAND = [3][3]u16{
    .{ 2, 3, 6 },
    .{ 4, 5, 8 },
    .{ 7, 9, 10 },
};

/// Compose an insert-and-copy command symbol that carries an explicit distance (sec 5).
pub fn composeCommandExplicit(insert_code: u8, copy_code: u8) u16 {
    const insert_band = insert_code / 8;
    const copy_band = copy_code / 8;
    const cell = CELL_BY_BAND[insert_band][copy_band];

    return cell * 64 + (@as(u16, insert_code % 8) << 3) + (copy_code % 8);
}

fn hash4(window: []const u8, pos: usize) usize {
    const v = std.mem.readInt(u32, window[pos..][0..4], .little);

    return (v *% 0x9E3779B1) >> (32 - HASH_BITS);
}

fn matchLength(input: []const u8, a: usize, b: usize, limit: usize) usize {
    var len: usize = 0;
    while (len < limit and input[a + len] == input[b + len]) len += 1;

    return len;
}

/// Greedy LZ77 parse: walk the input, find the longest hash-chain match at each position,
/// and append insert-and-copy commands (trailing literals become a final insert-only one).
pub fn parseCommands(allocator: std.mem.Allocator, input: []const u8, wbits: u6, commands: *std.ArrayList(Command)) EncodeError!void {
    const window: u32 = (@as(u32, 1) << @intCast(wbits)) - 16;

    const head = try allocator.alloc(u32, HASH_SIZE);
    defer allocator.free(head);
    @memset(head, NO_POS);

    const prev = try allocator.alloc(u32, input.len);
    defer allocator.free(prev);

    var lit_start: usize = 0;
    var i: usize = 0;
    while (i + MIN_MATCH <= input.len) {
        const h = hash4(input, i);

        var best_len: usize = 0;
        var best_dist: u32 = 0;
        var cand = head[h];
        var chain: usize = 0;
        while (cand != NO_POS and chain < MAX_CHAIN) : (chain += 1) {
            const dist = i - cand;
            if (dist > window) break;

            const limit = @min(MAX_MATCH, input.len - i);
            const len = matchLength(input, cand, i, limit);
            if (len > best_len) {
                best_len = len;
                best_dist = @intCast(dist);
            }

            cand = prev[cand];
        }

        prev[i] = head[h];
        head[h] = @intCast(i);

        if (best_len >= MIN_MATCH) {
            try commands.append(allocator, .{
                .insert_len = @intCast(i - lit_start),
                .lit_off = lit_start,
                .copy_len = @intCast(best_len),
                .distance = best_dist,
            });

            var j = i + 1;
            const end = i + best_len;
            while (j < end and j + MIN_MATCH <= input.len) : (j += 1) {
                const hj = hash4(input, j);
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
        });
    }
}

pub const TreeCode = struct {
    lengths: []u8,
    codes: []u16,
    present: usize,
    single: u16,
};

/// Build a prefix code over an alphabet from symbol frequencies: a single present symbol
/// gets length 0 (zero-bit code), otherwise a balanced code with the most frequent symbols
/// at the shorter length. Caller owns lengths and codes.
pub fn buildTreeCode(allocator: std.mem.Allocator, freq: []const u32, alphabet_size: usize) EncodeError!TreeCode {
    const lengths = try allocator.alloc(u8, alphabet_size);
    @memset(lengths, 0);
    const codes = try allocator.alloc(u16, alphabet_size);

    var order: [COMMAND_ALPHABET]u16 = undefined;
    var present: usize = 0;
    for (freq, 0..) |f, v| {
        if (f != 0) {
            order[present] = @intCast(v);
            present += 1;
        }
    }

    var single: u16 = 0;
    if (present == 1) {
        single = order[0]; // length stays 0, so the symbol is emitted with zero bits
    } else if (present >= 2) {
        var a: usize = 1;
        while (a < present) : (a += 1) {
            const cur = order[a];
            var b: usize = a;
            while (b > 0 and freq[order[b - 1]] < freq[cur]) : (b -= 1) order[b] = order[b - 1];
            order[b] = cur;
        }

        var bal: [COMMAND_ALPHABET]u8 = undefined;
        _ = e2.balancedLengths(present, &bal);
        var k: usize = 0;
        while (k < present) : (k += 1) lengths[order[k]] = bal[k];

        e2.buildCanonicalCodes(lengths, codes);
    }

    return .{ .lengths = lengths, .codes = codes, .present = present, .single = single };
}

pub fn writeTreeCode(bw: *e2.BitWriter, allocator: std.mem.Allocator, tree: TreeCode, alphabet_size: usize) EncodeError!void {
    if (tree.present <= 1) {
        try e2.writeSingleSymbolCode(bw, allocator, tree.single, alphabet_size);
        return;
    }

    try e2.writeComplexCode(bw, allocator, tree.lengths);
}

/// Encode input as a single LZ77 compressed brotli meta-block (phase E3).
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// input - []const u8 (bytes to compress, at most 2^24)
/// wbits - u6 (window log, 10..24)
///
/// Return:
/// - []u8 (a valid brotli stream, caller frees)
/// - error.InvalidWindowBits / error.InputTooLarge / error.OutOfMemory
fn encodeLzBlockAlloc(allocator: std.mem.Allocator, input: []const u8, wbits: u6) EncodeError![]u8 {
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

    var commands: std.ArrayList(Command) = .empty;
    try parseCommands(scratch, input, wbits, &commands);

    // literal code over the inserted literals only (the matched bytes are not literals).
    var lits: std.ArrayList(u8) = .empty;
    for (commands.items) |c| try lits.appendSlice(scratch, input[c.lit_off..][0..c.insert_len]);

    var lsyms: [4]u16 = undefined;
    var lnsym: usize = 0;
    const lc = e2.buildLiteralCode(lits.items, &lsyms, &lnsym);

    // command and distance frequencies drive their prefix codes.
    var cmd_freq = std.mem.zeroes([COMMAND_ALPHABET]u32);
    var dist_freq = std.mem.zeroes([DISTANCE_ALPHABET]u32);
    for (commands.items) |c| {
        const insert_code = e2.selectInsertCode(c.insert_len);
        if (c.copy_len > 0) {
            const copy_code = selectCopyCode(c.copy_len);
            cmd_freq[composeCommandExplicit(insert_code, copy_code)] += 1;
            dist_freq[distanceCode(c.distance).code] += 1;
        } else {
            cmd_freq[composeCommandExplicit(insert_code, 0)] += 1;
        }
    }

    const cmd_code = try buildTreeCode(scratch, &cmd_freq, COMMAND_ALPHABET);
    const dist_code = try buildTreeCode(scratch, &dist_freq, DISTANCE_ALPHABET);

    // meta-block header + preamble (one block type per category, no postfix/direct, one tree).
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

    try e2.writeLiteralCode(&bw, allocator, &lc, &lsyms, lnsym);
    try writeTreeCode(&bw, allocator, cmd_code, COMMAND_ALPHABET);
    try writeTreeCode(&bw, allocator, dist_code, DISTANCE_ALPHABET);

    // the command loop: command symbol, insert extra, copy extra, literals, then the distance
    // (skipped for the trailing insert-only command, where the decoder ends at MLEN first).
    for (commands.items) |c| {
        const insert_code = e2.selectInsertCode(c.insert_len);
        const copy_code: u8 = if (c.copy_len > 0) selectCopyCode(c.copy_len) else 0;
        const sym = composeCommandExplicit(insert_code, copy_code);

        try bw.writeCode(allocator, cmd_code.codes[sym], @intCast(cmd_code.lengths[sym]));
        try bw.writeInt(allocator, c.insert_len - cmd_tables.INSERT_LEN_BASE[insert_code], cmd_tables.INSERT_LEN_EXTRA[insert_code]);

        const copy_value: u32 = if (c.copy_len > 0) c.copy_len else cmd_tables.COPY_LEN_BASE[0];
        try bw.writeInt(allocator, copy_value - cmd_tables.COPY_LEN_BASE[copy_code], cmd_tables.COPY_LEN_EXTRA[copy_code]);

        var k: usize = 0;
        while (k < c.insert_len) : (k += 1) {
            const b = input[c.lit_off + k];
            try bw.writeCode(allocator, lc.codes[b], @intCast(lc.lengths[b]));
        }

        if (c.copy_len > 0) {
            const dc = distanceCode(c.distance);
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
        const stream = try encodeLzBlockAlloc(allocator, input, 22);

        const f = try cwd.createFile(io, output_path.?, .{});
        defer f.close(io);

        var write_buf: [8192]u8 = undefined;
        var writer = f.writer(io, &write_buf);
        try writer.interface.writeAll(stream);
        try writer.interface.flush();

        return;
    }

    const samples = [_][]const u8{
        "the quick brown fox the quick brown fox the quick brown fox",
        "abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc",
        "no repeats here just some random-ish text 0123456789",
    };

    for (samples) |sample| {
        const stream = try encodeLzBlockAlloc(allocator, sample, 22);
        const back = try decoder.decode(allocator, stream);

        const verdict = if (std.mem.eql(u8, back, sample)) "OK" else "MISMATCH";
        const pct = stream.len * 100 / sample.len;
        std.debug.print("[{d} bytes -> {d} bytes, {d}%] {s}\n", .{ sample.len, stream.len, pct, verdict });
    }
}

// --------------------------------------------------------- //
// test cases
// --------------------------------------------------------- //

const testing = std.testing;

fn roundTrip(input: []const u8, wbits: u6) !void {
    const stream = try encodeLzBlockAlloc(testing.allocator, input, wbits);
    defer testing.allocator.free(stream);

    const back = try decoder.decode(testing.allocator, stream);
    defer testing.allocator.free(back);

    try testing.expectEqualSlices(u8, input, back);
}

test "distance code inverts the decoder for the first distances" {
    // the two interleaved series tile the value ranges 1,2 | 3,4 | 5.. exactly.
    try testing.expectEqual(@as(u16, 16), distanceCode(1).code);
    try testing.expectEqual(@as(u16, 16), distanceCode(2).code);
    try testing.expectEqual(@as(u16, 17), distanceCode(3).code);
    try testing.expectEqual(@as(u16, 17), distanceCode(4).code);
    try testing.expectEqual(@as(u16, 18), distanceCode(5).code);
}

test "empty input round-trips" {
    try roundTrip("", 22);
}

test "no-match input round-trips (degrades to literals)" {
    try roundTrip("abcdefghijklmnopqrstuvwxyz0123456789", 22);
}

test "single repeated unit compresses via back-references" {
    var input: [600]u8 = undefined;
    const unit = "abcdefgh";
    for (&input, 0..) |*b, i| b.* = unit[i % unit.len];

    const stream = try encodeLzBlockAlloc(testing.allocator, &input, 22);
    defer testing.allocator.free(stream);

    try testing.expect(stream.len < input.len / 4);

    const back = try decoder.decode(testing.allocator, stream);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, &input, back);
}

test "repeated phrase round-trips" {
    try roundTrip("the quick brown fox the quick brown fox the quick brown fox", 22);
}

test "match ending exactly at MLEN round-trips" {
    // the input ends inside a repeat, so the final command is a copy that lands on MLEN.
    var input: [256]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @truncate(i % 13);

    try roundTrip(&input, 18);
}

test "long run of one byte round-trips (max match split)" {
    var input: [40000]u8 = undefined;
    @memset(&input, 'z');

    try roundTrip(&input, 24);
}

test "real-ish text with overlap round-trips and shrinks" {
    // a phrase repeated enough that the matches dominate the fixed tree-header overhead
    // (tiny inputs do not shrink in E3, that needs E5's optimal codes and context).
    const phrase = "lorem ipsum dolor sit amet consectetur adipiscing elit ";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var r: usize = 0;
    while (r < 20) : (r += 1) try buf.appendSlice(testing.allocator, phrase);

    const stream = try encodeLzBlockAlloc(testing.allocator, buf.items, 22);
    defer testing.allocator.free(stream);

    try testing.expect(stream.len < buf.items.len / 4);

    const back = try decoder.decode(testing.allocator, stream);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, buf.items, back);
}

test "binary data round-trips" {
    var input: [2000]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @truncate((i * 2654435761) >> 13);

    try roundTrip(&input, 22);
}
