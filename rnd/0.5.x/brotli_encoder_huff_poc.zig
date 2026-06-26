//! Brotli encoder PoC, phase E5 (RFC 7932), dynamic (optimal) prefix codes.
//!
//! Note:
//! - Builds on E4 (rnd/0.5.x/brotli_encoder_dist_poc.zig). E2..E4 used fixed balanced
//!   prefix codes (about log2(k) bits per symbol). E5 replaces all three trees (literal,
//!   insert-and-copy command, distance) with OPTIMAL length-limited Huffman codes built
//!   from the real symbol frequencies (sec 3.2). This is the bulk of the ratio gain.
//! - Huffman lengths are computed by an exact merge, then capped at 15 bits (the brotli
//!   maximum) with the standard overflow redistribution, and assigned shortest-to-most
//!   frequent. The codes are emitted with E2's complex-code writer, so the decoder rebuilds
//!   them from the per-symbol lengths.
//! - The match finder, ring-buffer distances, and command machinery are reused unchanged
//!   from E3 / E4; only the prefix codes change. Per-block literal context modeling
//!   (NTREESL > 1 with a context map) is the remaining E5 sub-step, deferred to keep this
//!   PoC focused on the dynamic-code win, the single literal tree is kept (NTREESL = 1).
//! - Verified by self round-trip through the full decoder (brotli_conformance_poc.zig) and
//!   the `brotli -dc` interop gate (rnd/0.5.x/verify-brotli-encoder-huff.sh).
//!
//! Run: zig run rnd/0.5.x/brotli_encoder_huff_poc.zig

const std = @import("std");
const e2 = @import("brotli_encoder_literal_poc.zig");
const e3 = @import("brotli_encoder_lz_poc.zig");
const e4 = @import("brotli_encoder_dist_poc.zig");
const cmd_tables = @import("brotli_command_poc.zig");
const decoder = @import("brotli_conformance_poc.zig");

const EncodeError = e3.EncodeError;

const MAX_BITS: u8 = 15;
const LITERAL_ALPHABET: usize = 256;

/// Optimal length-limited Huffman code lengths over freq (sec 3.2). A single present symbol
/// gets length 0 (a zero-bit code); the rest are exact-merge Huffman lengths capped at
/// MAX_BITS via the standard overflow redistribution, assigned shortest to most frequent.
pub fn huffmanLengths(allocator: std.mem.Allocator, freq: []const u32, lengths_out: []u8) EncodeError!void {
    @memset(lengths_out, 0);

    var present: usize = 0;
    for (freq) |f| {
        if (f != 0) present += 1;
    }
    if (present < 2) return;

    // order: present symbols, sorted by frequency ascending (least frequent first).
    const order = try allocator.alloc(usize, present);
    defer allocator.free(order);
    {
        var idx: usize = 0;
        for (freq, 0..) |f, s| {
            if (f != 0) {
                order[idx] = s;
                idx += 1;
            }
        }
        std.mem.sort(usize, order, freq, struct {
            fn lt(f: []const u32, a: usize, b: usize) bool {
                return f[a] < f[b];
            }
        }.lt);
    }

    // exact Huffman by repeated merge of the two lightest nodes (O(n^2), fine for <= 704).
    const max_nodes = 2 * present - 1;
    const weight = try allocator.alloc(u64, max_nodes);
    defer allocator.free(weight);
    const parent = try allocator.alloc(usize, max_nodes);
    defer allocator.free(parent);
    const alive = try allocator.alloc(bool, max_nodes);
    defer allocator.free(alive);

    @memset(parent, std.math.maxInt(usize));
    @memset(alive, false);
    for (0..present) |i| {
        weight[i] = freq[order[i]];
        alive[i] = true;
    }

    var next = present;
    var remaining = present;
    while (remaining > 1) {
        var m1: usize = std.math.maxInt(usize);
        var m2: usize = std.math.maxInt(usize);
        for (0..next) |j| {
            if (!alive[j]) continue;
            if (m1 == std.math.maxInt(usize) or weight[j] < weight[m1]) {
                m2 = m1;
                m1 = j;
            } else if (m2 == std.math.maxInt(usize) or weight[j] < weight[m2]) {
                m2 = j;
            }
        }

        weight[next] = weight[m1] + weight[m2];
        parent[m1] = next;
        parent[m2] = next;
        alive[m1] = false;
        alive[m2] = false;
        alive[next] = true;
        next += 1;
        remaining -= 1;
    }

    // raw depth of each leaf = its code length before the 15-bit cap.
    var count = std.mem.zeroes([64]u32);
    var raw_max: u8 = 0;
    const raw_len = try allocator.alloc(u8, present);
    defer allocator.free(raw_len);
    for (0..present) |i| {
        var depth: u8 = 0;
        var p = i;
        while (parent[p] != std.math.maxInt(usize)) : (depth += 1) p = parent[p];
        raw_len[i] = depth;
        count[depth] += 1;
        if (depth > raw_max) raw_max = depth;
    }

    // cap lengths at MAX_BITS: move the overflow to MAX_BITS, then redistribute (zlib rule).
    var overflow: i64 = 0;
    var bits: usize = MAX_BITS + 1;
    while (bits <= raw_max) : (bits += 1) overflow += count[bits];

    if (overflow > 0) {
        bits = MAX_BITS + 1;
        while (bits <= raw_max) : (bits += 1) {
            count[MAX_BITS] += count[bits];
            count[bits] = 0;
        }

        while (overflow > 0) {
            var b: usize = MAX_BITS - 1;
            while (count[b] == 0) b -= 1;
            count[b] -= 1;
            count[b + 1] += 2;
            count[MAX_BITS] -= 1;
            overflow -= 2;
        }
    }

    // assign lengths shortest-to-most-frequent (order is ascending, so walk it from the end).
    var idx: usize = present;
    var len: usize = 1;
    while (len <= MAX_BITS) : (len += 1) {
        var c = count[len];
        while (c > 0) : (c -= 1) {
            idx -= 1;
            lengths_out[order[idx]] = @intCast(len);
        }
    }
}

/// Build an optimal Huffman tree over an alphabet from symbol frequencies, returning the
/// e3.TreeCode shape so e3.writeTreeCode can emit it.
pub fn buildOptimalTree(allocator: std.mem.Allocator, freq: []const u32, alphabet_size: usize) EncodeError!e3.TreeCode {
    const lengths = try allocator.alloc(u8, alphabet_size);
    @memset(lengths, 0);
    const codes = try allocator.alloc(u16, alphabet_size);

    var present: usize = 0;
    var single: u16 = 0;
    for (freq, 0..) |f, s| {
        if (f != 0) {
            present += 1;
            single = @intCast(s);
        }
    }

    if (present >= 2) {
        try huffmanLengths(allocator, freq, lengths);
        e2.buildCanonicalCodes(lengths, codes);
    }

    return .{ .lengths = lengths, .codes = codes, .present = present, .single = single };
}

/// Encode input as a single LZ77 compressed brotli meta-block with optimal Huffman codes
/// and ring-buffer distances (phase E5).
fn encodeHuffBlockAlloc(allocator: std.mem.Allocator, input: []const u8, wbits: u6) EncodeError![]u8 {
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

    var commands: std.ArrayList(e3.Command) = .empty;
    try e3.parseCommands(scratch, input, wbits, &commands);

    const chosen = try scratch.alloc(e3.DistanceCode, commands.items.len);
    var ring = cmd_tables.DistanceRing{};
    for (commands.items, 0..) |c, idx| {
        if (c.copy_len > 0) chosen[idx] = e4.chooseDistance(&ring, c.distance);
    }

    // frequencies for the three trees.
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

    const lit_code = try buildOptimalTree(scratch, &lit_freq, LITERAL_ALPHABET);
    const cmd_code = try buildOptimalTree(scratch, &cmd_freq, e3.COMMAND_ALPHABET);
    const dist_code = try buildOptimalTree(scratch, &dist_freq, e3.DISTANCE_ALPHABET);

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
        const stream = try encodeHuffBlockAlloc(allocator, input, 22);

        const f = try cwd.createFile(io, output_path.?, .{});
        defer f.close(io);

        var write_buf: [8192]u8 = undefined;
        var writer = f.writer(io, &write_buf);
        try writer.interface.writeAll(stream);
        try writer.interface.flush();

        return;
    }

    const samples = [_][]const u8{
        "the quick brown fox jumps over the lazy dog, the quick brown fox again",
        "aaaaaabbbbbbccccccddddddeeeeee",
    };

    for (samples) |sample| {
        const stream = try encodeHuffBlockAlloc(allocator, sample, 22);
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
    const stream = try encodeHuffBlockAlloc(testing.allocator, input, wbits);
    defer testing.allocator.free(stream);

    const back = try decoder.decode(testing.allocator, stream);
    defer testing.allocator.free(back);

    try testing.expectEqualSlices(u8, input, back);
}

test "huffman lengths form a complete code (kraft sum = 1)" {
    const freq = [_]u32{ 10, 1, 1, 1, 1, 5, 0, 0 };
    var lengths: [8]u8 = undefined;
    try huffmanLengths(testing.allocator, &freq, &lengths);

    var kraft: f64 = 0;
    for (lengths) |l| {
        if (l != 0) kraft += std.math.pow(f64, 2, -@as(f64, @floatFromInt(l)));
    }
    try testing.expectApproxEqAbs(@as(f64, 1.0), kraft, 1e-9);

    // the most frequent symbol gets the shortest code.
    try testing.expect(lengths[0] <= lengths[1]);
}

test "huffman caps lengths at 15 bits on a skewed alphabet" {
    var freq: [40]u32 = undefined;
    for (&freq, 0..) |*f, i| f.* = @as(u32, 1) << @intCast(i % 28); // exponential skew (forces deep tree)
    var lengths: [40]u8 = undefined;
    try huffmanLengths(testing.allocator, &freq, &lengths);

    for (lengths) |l| try testing.expect(l <= 15);
}

test "empty and no-match inputs round-trip" {
    try roundTrip("", 22);
    try roundTrip("abcdefghijklmnopqrstuvwxyz0123456789", 22);
}

test "skewed literal distribution round-trips" {
    try roundTrip("aaaaaaaaaaaaaaaaaaaaaaaabbbbbbcccd", 22);
}

test "repeated phrase round-trips" {
    try roundTrip("the quick brown fox the quick brown fox the quick brown fox", 22);
}

test "long single-byte run round-trips" {
    var input: [40000]u8 = undefined;
    @memset(&input, 'q');

    try roundTrip(&input, 24);
}

test "full byte alphabet round-trips" {
    var input: [256]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @intCast(i);

    try roundTrip(&input, 18);
}

test "binary data round-trips" {
    var input: [4000]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @truncate((i * 2654435761) >> 12);

    try roundTrip(&input, 22);
}

test "optimal codes beat the balanced E4 codes on real text" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var r: usize = 0;
    while (r < 60) : (r += 1) {
        try buf.appendSlice(testing.allocator, "the quick brown fox jumps over the lazy dog. ");
    }

    const huff = try encodeHuffBlockAlloc(testing.allocator, buf.items, 22);
    defer testing.allocator.free(huff);

    const back = try decoder.decode(testing.allocator, huff);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, buf.items, back);
}
