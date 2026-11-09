//! ZIX utils compression brotli prefix write
//!
//! ### file: src/zix/utils/compression/brotli/prefix_write.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Encoder side of the stream header: window bits (sec 9.1), meta-block length and
//! counts (sec 9.2), prefix codes (sec 3.4, 3.5), and context maps (sec 7.3).
//! 
//! ### note:
//! 
//! Each writer is the exact inverse of the matching reader in prefix_read.zig.
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
const BitWriter = @import("BitWriter.zig");
const TreeCode = @import("TreeCode.zig");
const huffman = @import("huffman.zig");
const tables = @import("tables.zig");

// --------------------------------------------------------- //
// Private:

/// Bits the reader expects for code length code lengths 0..5 (sec 3.5),
/// in stream order.
const CODE_LENGTH_BITS = [6][]const u1{
    &[_]u1{ 0, 0 },
    &[_]u1{ 1, 1, 1, 0 },
    &[_]u1{ 1, 1, 0 },
    &[_]u1{ 0, 1 },
    &[_]u1{ 1, 0 },
    &[_]u1{ 1, 1, 1, 1 },
};

/// Order of the 18 code length code lengths in the stream (sec 3.5).
const CODE_LENGTH_ORDER = [_]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

/// Largest number of trees in one context map (64 literal contexts).
const MAX_MAP_TREES = 64;

const Inner = Error || BitWriter.Error || huffman.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixUtils_BrotliPrefixWrite_InvalidWindowBits => {
            return Error.ZixUtils_BrotliPrefixWrite_InvalidWindowBits;
        },
        error.ZixUtils_BrotliPrefixWrite_OutOfMemory => {
            return Error.ZixUtils_BrotliPrefixWrite_OutOfMemory;
        },
        error.ZixUtils_BrotliBitWriter_OutOfMemory => {
            return Error.ZixUtils_BrotliPrefixWrite_OutOfMemory;
        },
        error.ZixUtils_BrotliHuffman_OutOfMemory => {
            return Error.ZixUtils_BrotliPrefixWrite_OutOfMemory;
        },
    };
}

fn writeWindowBitsInner(
    writer: *BitWriter,
    allocator: std.mem.Allocator,
    wbits: u6,
) Inner!void {
    if (wbits < 10 or wbits > 24) return Error.ZixUtils_BrotliPrefixWrite_InvalidWindowBits;

    if (wbits == 16) return writer.writeBit(allocator, 0);

    try writer.writeBit(allocator, 1);

    if (wbits >= 18) return writer.writeInt(allocator, wbits - 17, 3);

    try writer.writeInt(allocator, 0, 3);

    if (wbits == 17) return writer.writeInt(allocator, 0, 3);

    try writer.writeInt(allocator, wbits - 8, 3);
}

fn writeMetaBlockLenInner(
    writer: *BitWriter,
    allocator: std.mem.Allocator,
    mlen: usize,
) Inner!void {
    const value: u32 = @intCast(mlen - 1);
    const nibbles: u6 = if (value < (1 << 16)) 4 else if (value < (1 << 20)) 5 else 6;

    try writer.writeInt(allocator, nibbles - 4, 2);
    try writer.writeInt(allocator, value, nibbles * 4);
}

/// Simple code with one symbol (sec 3.4, NSYM=1). The reader then reads no bits.
fn writeSingleSymbolCode(
    writer: *BitWriter,
    allocator: std.mem.Allocator,
    symbol: u16,
    alphabet_size: usize,
) Inner!void {
    try writer.writeInt(allocator, 1, 2);
    try writer.writeInt(allocator, 0, 2);
    try writer.writeInt(allocator, symbol, tables.alphabetBits(alphabet_size));
}

/// Complex code (sec 3.5) with HSKIP 0. Needs at least two used symbols.
fn writeComplexCode(writer: *BitWriter, allocator: std.mem.Allocator, lengths: []const u8) Inner!void {
    try writer.writeInt(allocator, 0, 2);

    var last_used: usize = 0;
    for (lengths, 0..) |len, symbol| {
        if (len != 0) last_used = symbol;
    }

    var length_present: [18]bool = @splat(false);
    for (lengths[0 .. last_used + 1]) |len| length_present[len] = true;

    var distinct: usize = 0;
    var distinct_values: [18]u8 = undefined;
    for (length_present, 0..) |present, value| {
        if (present) {
            distinct_values[distinct] = @intCast(value);
            distinct += 1;
        }
    }

    var balanced: [18]u8 = undefined;
    _ = huffman.balancedLengths(distinct, &balanced);

    var code_lengths: [18]u8 = @splat(0);
    for (0..distinct) |i| code_lengths[distinct_values[i]] = balanced[i];

    // Stop as soon as the code is complete, exactly where the reader stops.
    var space: i64 = 32;
    for (CODE_LENGTH_ORDER) |symbol| {
        const code_len = code_lengths[symbol];
        for (CODE_LENGTH_BITS[code_len]) |bit| try writer.writeBit(allocator, bit);

        if (code_len != 0) {
            space -= @as(i64, 32) >> @intCast(code_len);
            if (space <= 0) break;
        }
    }

    // A code length code with one value carries no per-symbol bits.
    if (distinct <= 1) return;

    var length_codes: [18]u16 = undefined;
    huffman.buildCanonicalCodes(&code_lengths, &length_codes);

    for (lengths[0 .. last_used + 1]) |len| {
        try writer.writeCode(allocator, length_codes[len], @intCast(code_lengths[len]));
    }
}

fn writeTreeCodeInner(
    writer: *BitWriter,
    allocator: std.mem.Allocator,
    tree: TreeCode,
    alphabet_size: usize,
) Inner!void {
    if (tree.isSingle()) return writeSingleSymbolCode(writer, allocator, tree.single, alphabet_size);

    try writeComplexCode(writer, allocator, tree.lengths);
}

fn writeBlockTypeCountInner(
    writer: *BitWriter,
    allocator: std.mem.Allocator,
    value: u32,
) Inner!void {
    if (value == 1) return writer.writeBit(allocator, 0);

    try writer.writeBit(allocator, 1);

    const offset = value - 1;
    const nbits: u6 = @intCast(31 - @clz(offset));

    try writer.writeInt(allocator, nbits, 3);
    try writer.writeInt(allocator, offset - (@as(u32, 1) << @intCast(nbits)), nbits);
}

fn writeContextMapInner(
    writer: *BitWriter,
    allocator: std.mem.Allocator,
    map: []const u8,
    ntrees: usize,
) Inner!void {
    // RLEMAX = 0.
    try writer.writeBit(allocator, 0);

    var freq: [MAX_MAP_TREES]u32 = @splat(0);
    for (map) |value| freq[value] += 1;

    const code = try huffman.buildOptimalTree(allocator, freq[0..ntrees]);
    defer allocator.free(code.lengths);
    defer allocator.free(code.codes);

    try writeTreeCodeInner(writer, allocator, code, ntrees);

    if (!code.isSingle()) {
        for (map) |value| {
            try writer.writeCode(allocator, code.codes[value], @intCast(code.lengths[value]));
        }
    }

    // IMTF off.
    try writer.writeBit(allocator, 0);
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_BrotliPrefixWrite_InvalidWindowBits,
    ZixUtils_BrotliPrefixWrite_OutOfMemory,
};

/// Write the stream window bits (sec 9.1).
///
/// Param:
/// writer - *BitWriter (output)
/// allocator - std.mem.Allocator (grows the output)
/// wbits - u6 (window log, 10..24)
///
/// Return:
/// - void
/// - Error.ZixUtils_BrotliPrefixWrite_InvalidWindowBits outside 10..24
pub fn writeWindowBits(writer: *BitWriter, allocator: std.mem.Allocator, wbits: u6) Error!void {
    return writeWindowBitsInner(writer, allocator, wbits) catch |err| innerError(err);
}

/// Write MNIBBLES and MLEN - 1 with the fewest nibbles (sec 9.2).
///
/// Param:
/// writer - *BitWriter (output)
/// allocator - std.mem.Allocator (grows the output)
/// mlen - usize (meta-block length, 1..2^24)
///
/// Return:
/// - void
/// - Error.ZixUtils_BrotliPrefixWrite_OutOfMemory
pub fn writeMetaBlockLen(writer: *BitWriter, allocator: std.mem.Allocator, mlen: usize) Error!void {
    return writeMetaBlockLenInner(writer, allocator, mlen) catch |err| innerError(err);
}

/// Write one prefix code: simple for a single symbol, complex otherwise.
///
/// Param:
/// writer - *BitWriter (output)
/// allocator - std.mem.Allocator (grows the output)
/// tree - TreeCode (code to write)
/// alphabet_size - usize (symbol count)
///
/// Return:
/// - void
/// - Error.ZixUtils_BrotliPrefixWrite_OutOfMemory
pub fn writeTreeCode(
    writer: *BitWriter,
    allocator: std.mem.Allocator,
    tree: TreeCode,
    alphabet_size: usize,
) Error!void {
    return writeTreeCodeInner(writer, allocator, tree, alphabet_size) catch |err| innerError(err);
}

/// Write NBLTYPES or NTREES (sec 9.2), the inverse of readBlockTypeCount.
///
/// Param:
/// writer - *BitWriter (output)
/// allocator - std.mem.Allocator (grows the output)
/// value - u32 (1..256)
///
/// Return:
/// - void
/// - Error.ZixUtils_BrotliPrefixWrite_OutOfMemory
pub fn writeBlockTypeCount(
    writer: *BitWriter,
    allocator: std.mem.Allocator,
    value: u32,
) Error!void {
    return writeBlockTypeCountInner(writer, allocator, value) catch |err| innerError(err);
}

/// Write a context map with RLEMAX 0 and IMTF off (sec 7.3), so the reader reads
/// each value straight back.
///
/// Param:
/// writer - *BitWriter (output)
/// allocator - std.mem.Allocator (grows the output and the transient code)
/// map - []const u8 (tree index per context, each below ntrees)
/// ntrees - usize (number of trees, 2..64)
///
/// Return:
/// - void
/// - Error.ZixUtils_BrotliPrefixWrite_OutOfMemory
pub fn writeContextMap(
    writer: *BitWriter,
    allocator: std.mem.Allocator,
    map: []const u8,
    ntrees: usize,
) Error!void {
    return writeContextMapInner(writer, allocator, map, ntrees) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const BitReader = @import("BitReader.zig");
const prefix_read = @import("prefix_read.zig");

test "zix utils compression brotli: prefix_write, window bits round-trip 10 to 24" {
    var wbits: u6 = 10;
    while (wbits <= 24) : (wbits += 1) {
        var writer: BitWriter = .{};
        defer writer.deinit(std.testing.allocator);

        try writeWindowBits(&writer, std.testing.allocator, wbits);

        var reader = BitReader.init(writer.bytes.items);

        try std.testing.expectEqual(wbits, try prefix_read.readWindowBits(&reader));
    }
}

test "zix utils compression brotli: prefix_write, window bits 9 is invalid" {
    var writer: BitWriter = .{};
    defer writer.deinit(std.testing.allocator);

    try std.testing.expectError(
        Error.ZixUtils_BrotliPrefixWrite_InvalidWindowBits,
        writeWindowBits(&writer, std.testing.allocator, 9),
    );
}

test "zix utils compression brotli: prefix_write, window bits 25 is invalid" {
    var writer: BitWriter = .{};
    defer writer.deinit(std.testing.allocator);

    try std.testing.expectError(
        Error.ZixUtils_BrotliPrefixWrite_InvalidWindowBits,
        writeWindowBits(&writer, std.testing.allocator, 25),
    );
}

test "zix utils compression brotli: prefix_write, block type count round-trips" {
    const samples = [_]u32{ 1, 2, 3, 4, 17, 128, 256 };

    for (samples) |value| {
        var writer: BitWriter = .{};
        defer writer.deinit(std.testing.allocator);

        try writeBlockTypeCount(&writer, std.testing.allocator, value);

        var reader = BitReader.init(writer.bytes.items);

        try std.testing.expectEqual(value, try prefix_read.readBlockTypeCount(&reader));
    }
}

test "zix utils compression brotli: prefix_write, meta-block length uses 4 nibbles" {
    var writer: BitWriter = .{};
    defer writer.deinit(std.testing.allocator);

    try writeMetaBlockLen(&writer, std.testing.allocator, 1);

    var reader = BitReader.init(writer.bytes.items);

    try std.testing.expectEqual(@as(u32, 0), try reader.readBits(2));
    try std.testing.expectEqual(@as(u32, 0), try reader.readBits(16));
}

test "zix utils compression brotli: prefix_write, meta-block length uses 6 nibbles" {
    var writer: BitWriter = .{};
    defer writer.deinit(std.testing.allocator);

    try writeMetaBlockLen(&writer, std.testing.allocator, 1 << 24);

    var reader = BitReader.init(writer.bytes.items);

    try std.testing.expectEqual(@as(u32, 2), try reader.readBits(2));
    try std.testing.expectEqual(@as(u32, (1 << 24) - 1), try reader.readBits(24));
}

test "zix utils compression brotli: prefix_write, complex tree round-trips" {
    const freq = [_]u32{ 50, 20, 0, 10, 5, 5, 0, 1 };
    const tree = try huffman.buildOptimalTree(std.testing.allocator, &freq);
    defer std.testing.allocator.free(tree.lengths);
    defer std.testing.allocator.free(tree.codes);

    var writer: BitWriter = .{};
    defer writer.deinit(std.testing.allocator);

    try writeTreeCode(&writer, std.testing.allocator, tree, freq.len);
    for (freq, 0..) |count, symbol| {
        if (count != 0) {
            try writer.writeCode(
                std.testing.allocator,
                tree.codes[symbol],
                @intCast(tree.lengths[symbol]),
            );
        }
    }

    var reader = BitReader.init(writer.bytes.items);
    const decoder = try prefix_read.readPrefixCode(&reader, freq.len);

    for (freq, 0..) |count, symbol| {
        if (count != 0) {
            try std.testing.expectEqual(@as(u16, @intCast(symbol)), try decoder.readSymbol(&reader));
        }
    }
}

test "zix utils compression brotli: prefix_write, single tree reads no bits" {
    const tree = try huffman.buildOptimalTree(std.testing.allocator, &.{ 0, 0, 9 });
    defer std.testing.allocator.free(tree.lengths);
    defer std.testing.allocator.free(tree.codes);

    var writer: BitWriter = .{};
    defer writer.deinit(std.testing.allocator);

    try writeTreeCode(&writer, std.testing.allocator, tree, 3);

    var reader = BitReader.init(writer.bytes.items);
    const decoder = try prefix_read.readPrefixCode(&reader, 3);

    try std.testing.expectEqual(@as(?u16, 2), decoder.single_symbol);
}

test "zix utils compression brotli: prefix_write, context map round-trips" {
    const map = [_]u8{ 0, 1, 1, 2, 0, 2, 2, 2 };

    var writer: BitWriter = .{};
    defer writer.deinit(std.testing.allocator);

    try writeContextMap(&writer, std.testing.allocator, &map, 3);

    var reader = BitReader.init(writer.bytes.items);
    var decoded: [map.len]u8 = undefined;
    try prefix_read.readContextMap(&reader, 3, &decoded);

    try std.testing.expectEqualSlices(u8, &map, &decoded);
}

test "zix utils compression brotli: prefix_write, failing allocator is out of memory" {
    var writer: BitWriter = .{};

    try std.testing.expectError(
        Error.ZixUtils_BrotliPrefixWrite_OutOfMemory,
        writeBlockTypeCount(&writer, std.testing.failing_allocator, 1),
    );
}

