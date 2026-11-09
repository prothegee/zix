//! ZIX utils compression brotli huffman
//!
//! ### file: src/zix/utils/compression/brotli/huffman.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Encoder prefix code construction: optimal length-limited code lengths and
//! canonical codes (RFC 7932 sec 3.2).
//! 
//! ### note:
//! 
//! n/a
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
const TreeCode = @import("TreeCode.zig");
const tables = @import("tables.zig");

// --------------------------------------------------------- //
// Private:

/// Longest code length the encoder emits.
const MAX_BITS: u8 = 15;

/// No parent node.
const NO_PARENT = std.math.maxInt(usize);

fn allocError(err: std.mem.Allocator.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.OutOfMemory => Error.ZixUtils_BrotliHuffman_OutOfMemory,
    };
}

fn lessFrequent(freqs: []const u32, left: usize, right: usize) bool {
    return freqs[left] < freqs[right];
}

/// Optimal code lengths capped at MAX_BITS, shortest to most frequent.
///
/// Note:
/// - Exact Huffman by repeated merge of the two lightest nodes. It is O(n^2), fine
///   for alphabets up to 704 symbols.
/// - Lengths past MAX_BITS move to MAX_BITS, then leaves are moved down until the
///   Kraft sum is exact again, so the capped code stays complete.
///
/// Param:
/// allocator - std.mem.Allocator (transient work arrays)
/// freq - []const u32 (frequency per symbol)
/// lengths_out - []u8 (code length per symbol, written)
///
/// Return:
/// - void
/// - Error.ZixUtils_BrotliHuffman_OutOfMemory
fn huffmanLengths(
    allocator: std.mem.Allocator,
    freq: []const u32,
    lengths_out: []u8,
) std.mem.Allocator.Error!void {
    @memset(lengths_out, 0);

    var present: usize = 0;
    for (freq) |count| {
        if (count != 0) present += 1;
    }
    if (present < 2) return;

    const order = try allocator.alloc(usize, present);
    defer allocator.free(order);

    var fill: usize = 0;
    for (freq, 0..) |count, symbol| {
        if (count != 0) {
            order[fill] = symbol;
            fill += 1;
        }
    }
    std.mem.sort(usize, order, freq, lessFrequent);

    const max_nodes = 2 * present - 1;
    const weight = try allocator.alloc(u64, max_nodes);
    defer allocator.free(weight);
    const parent = try allocator.alloc(usize, max_nodes);
    defer allocator.free(parent);
    const alive = try allocator.alloc(bool, max_nodes);
    defer allocator.free(alive);

    @memset(parent, NO_PARENT);
    @memset(alive, false);
    for (0..present) |i| {
        weight[i] = freq[order[i]];
        alive[i] = true;
    }

    var next = present;
    var remaining = present;
    while (remaining > 1) {
        var lightest: usize = NO_PARENT;
        var second: usize = NO_PARENT;
        for (0..next) |node| {
            if (!alive[node]) continue;

            if (lightest == NO_PARENT or weight[node] < weight[lightest]) {
                second = lightest;
                lightest = node;
            } else if (second == NO_PARENT or weight[node] < weight[second]) {
                second = node;
            }
        }

        weight[next] = weight[lightest] + weight[second];
        parent[lightest] = next;
        parent[second] = next;
        alive[lightest] = false;
        alive[second] = false;
        alive[next] = true;
        next += 1;
        remaining -= 1;
    }

    var count_per_len: [64]u32 = @splat(0);
    var raw_max: u8 = 0;
    for (0..present) |leaf| {
        var depth: u8 = 0;
        var node = leaf;
        while (parent[node] != NO_PARENT) : (depth += 1) node = parent[node];

        count_per_len[depth] += 1;
        if (depth > raw_max) raw_max = depth;
    }

    if (raw_max > MAX_BITS) {
        var bits: usize = MAX_BITS + 1;
        while (bits <= raw_max) : (bits += 1) {
            count_per_len[MAX_BITS] += count_per_len[bits];
            count_per_len[bits] = 0;
        }

        // Kraft sum in units of 2^-MAX_BITS. A complete code sums to 2^MAX_BITS.
        var kraft: u64 = 0;
        var len: usize = 1;
        while (len <= MAX_BITS) : (len += 1) {
            kraft += @as(u64, count_per_len[len]) << @intCast(MAX_BITS - len);
        }

        // Each step makes one MAX_BITS leaf the sibling of a shorter leaf moved one
        // level down, which lowers the sum by exactly one unit.
        while (kraft > (@as(u64, 1) << MAX_BITS)) : (kraft -= 1) {
            count_per_len[MAX_BITS] -= 1;

            var shorter: usize = MAX_BITS - 1;
            while (count_per_len[shorter] == 0) shorter -= 1;

            count_per_len[shorter] -= 1;
            count_per_len[shorter + 1] += 2;
        }
    }

    // order is ascending, so walk it from the end: shortest codes to most frequent.
    var index: usize = present;
    var len: usize = 1;
    while (len <= MAX_BITS) : (len += 1) {
        var left = count_per_len[len];
        while (left > 0) : (left -= 1) {
            index -= 1;
            lengths_out[order[index]] = @intCast(len);
        }
    }
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_BrotliHuffman_OutOfMemory,
};

/// Canonical code per symbol from code lengths, the twin of HuffmanDecoder.build.
///
/// Param:
/// lengths - []const u8 (code length per symbol)
/// codes_out - []u16 (code per symbol, written where lengths is not 0)
pub fn buildCanonicalCodes(lengths: []const u8, codes_out: []u16) void {
    var count: [tables.MAX_CODE_LEN + 1]u16 = @splat(0);
    for (lengths) |len| {
        if (len != 0) count[len] += 1;
    }

    var next_code: [tables.MAX_CODE_LEN + 1]u16 = @splat(0);
    var code: u16 = 0;
    var len: usize = 1;
    while (len <= tables.MAX_CODE_LEN) : (len += 1) {
        code = (code + count[len - 1]) << 1;
        next_code[len] = code;
    }

    for (lengths, 0..) |symbol_len, symbol| {
        if (symbol_len != 0) {
            codes_out[symbol] = next_code[symbol_len];
            next_code[symbol_len] += 1;
        }
    }
}

/// A complete set of code lengths over count leaves, each within one bit of log2.
///
/// Param:
/// count - usize (leaf count, at least 1)
/// out - []u8 (length per leaf, written)
///
/// Return:
/// - u8 (the longest length used)
pub fn balancedLengths(count: usize, out: []u8) u8 {
    if (count == 1) {
        out[0] = 1;

        return 1;
    }

    var log2_ceil: u8 = 0;
    while ((@as(usize, 1) << @intCast(log2_ceil)) < count) log2_ceil += 1;

    const capacity = @as(usize, 1) << @intCast(log2_ceil);
    const short_leaves = capacity - count;
    for (0..count) |i| out[i] = if (i < short_leaves) log2_ceil - 1 else log2_ceil;

    return log2_ceil;
}

/// Build an optimal prefix code over an alphabet from symbol frequencies.
///
/// Param:
/// allocator - std.mem.Allocator (owns lengths and codes of the result)
/// freq - []const u32 (frequency per symbol, length is the alphabet size)
///
/// Return:
/// - TreeCode
/// - Error.ZixUtils_BrotliHuffman_OutOfMemory
pub fn buildOptimalTree(allocator: std.mem.Allocator, freq: []const u32) Error!TreeCode {
    const lengths = allocator.alloc(u8, freq.len) catch |err| return allocError(err);
    errdefer allocator.free(lengths);
    @memset(lengths, 0);

    const codes = allocator.alloc(u16, freq.len) catch |err| return allocError(err);
    errdefer allocator.free(codes);

    var present: usize = 0;
    var single: u16 = 0;
    for (freq, 0..) |count, symbol| {
        if (count != 0) {
            present += 1;
            single = @intCast(symbol);
        }
    }

    if (present >= 2) {
        huffmanLengths(allocator, freq, lengths) catch |err| return allocError(err);
        buildCanonicalCodes(lengths, codes);
    }

    return .{
        .lengths = lengths,
        .codes = codes,
        .present = present,
        .single = single,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn freeTree(tree: TreeCode) void {
    std.testing.allocator.free(tree.lengths);
    std.testing.allocator.free(tree.codes);
}

test "zix utils compression brotli: huffman, canonical codes follow lengths" {
    var codes: [3]u16 = undefined;
    buildCanonicalCodes(&.{ 1, 2, 2 }, &codes);

    try std.testing.expectEqualSlices(u16, &.{ 0b0, 0b10, 0b11 }, &codes);
}

test "zix utils compression brotli: huffman, balanced lengths of one leaf" {
    var out: [1]u8 = undefined;

    try std.testing.expectEqual(@as(u8, 1), balancedLengths(1, &out));
    try std.testing.expectEqual(@as(u8, 1), out[0]);
}

test "zix utils compression brotli: huffman, balanced lengths of three leaves" {
    var out: [3]u8 = undefined;

    try std.testing.expectEqual(@as(u8, 2), balancedLengths(3, &out));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 2 }, &out);
}

test "zix utils compression brotli: huffman, frequent symbol gets the short code" {
    const tree = try buildOptimalTree(std.testing.allocator, &.{ 100, 1, 1 });
    defer freeTree(tree);

    try std.testing.expectEqual(@as(u8, 1), tree.lengths[0]);
    try std.testing.expectEqual(@as(u8, 2), tree.lengths[1]);
}

test "zix utils compression brotli: huffman, one present symbol is single" {
    const tree = try buildOptimalTree(std.testing.allocator, &.{ 0, 7, 0 });
    defer freeTree(tree);

    try std.testing.expect(tree.isSingle());
    try std.testing.expectEqual(@as(u16, 1), tree.single);
}

test "zix utils compression brotli: huffman, lengths cap at 15 bits" {
    // Fibonacci frequencies give a raw depth past 15.
    var freq: [24]u32 = undefined;
    freq[0] = 1;
    freq[1] = 1;
    for (2..freq.len) |i| freq[i] = freq[i - 1] + freq[i - 2];

    const tree = try buildOptimalTree(std.testing.allocator, &freq);
    defer freeTree(tree);

    var kraft: u64 = 0;
    for (tree.lengths) |len| {
        try std.testing.expect(len >= 1 and len <= MAX_BITS);
        kraft += @as(u64, 1) << @intCast(MAX_BITS - len);
    }

    try std.testing.expectEqual(@as(u64, 1) << MAX_BITS, kraft);
}

test "zix utils compression brotli: huffman, failing allocator is out of memory" {
    try std.testing.expectError(
        Error.ZixUtils_BrotliHuffman_OutOfMemory,
        buildOptimalTree(std.testing.failing_allocator, &.{ 1, 1 }),
    );
}

