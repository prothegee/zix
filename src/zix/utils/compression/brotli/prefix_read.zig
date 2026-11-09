//! ZIX utils compression brotli prefix read
//!
//! ### file: src/zix/utils/compression/brotli/prefix_read.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Decoder side of the stream header: prefix codes (sec 3.4, 3.5), window bits
//! (sec 9.1), block type and block counts (sec 6, 9.2), and context maps (sec 7.3).
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
const BitReader = @import("BitReader.zig");
const HuffmanDecoder = @import("HuffmanDecoder.zig");
const tables = @import("tables.zig");

// --------------------------------------------------------- //
// Private:

/// Order of the 18 code length code lengths in the stream (sec 3.5).
const CODE_LENGTH_ORDER = [_]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

const Inner = Error || BitReader.Error || HuffmanDecoder.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixUtils_BrotliPrefixRead_Truncated => Error.ZixUtils_BrotliPrefixRead_Truncated,
        error.ZixUtils_BrotliPrefixRead_Malformed => Error.ZixUtils_BrotliPrefixRead_Malformed,
        error.ZixUtils_BrotliBitReader_Truncated => Error.ZixUtils_BrotliPrefixRead_Truncated,
        error.ZixUtils_BrotliHuffmanDecoder_Truncated => {
            return Error.ZixUtils_BrotliPrefixRead_Truncated;
        },
        error.ZixUtils_BrotliHuffmanDecoder_Malformed => {
            return Error.ZixUtils_BrotliPrefixRead_Malformed;
        },
    };
}

/// The static code over code length code lengths 0..5 (sec 3.5).
fn readCodeLengthCodeLength(reader: *BitReader) Inner!u8 {
    if (try reader.readBit() == 0) {
        return if (try reader.readBit() == 0) 0 else 3;
    }
    if (try reader.readBit() == 0) return 4;
    if (try reader.readBit() == 0) return 2;

    return if (try reader.readBit() == 0) 1 else 5;
}

/// Read the code lengths of the 18-symbol code length alphabet (sec 3.5).
fn readCodeLengthCode(reader: *BitReader, hskip: u32, out: *[18]u8) Inner!void {
    @memset(out, 0);

    var space: i64 = 32;
    var index: usize = hskip;
    while (index < 18) : (index += 1) {
        const len = try readCodeLengthCodeLength(reader);
        out[CODE_LENGTH_ORDER[index]] = len;

        if (len != 0) {
            space -= @as(i64, 32) >> @intCast(len);
            if (space <= 0) break;
        }
    }
}

/// Read per-symbol code lengths with repeat codes 16 (previous, 3..6) and
/// 17 (zeros, 3..10), with the repeat rule of sec 3.5.
fn readSymbolLengths(
    reader: *BitReader,
    length_code: *const HuffmanDecoder,
    alphabet_size: usize,
    out: []u8,
) Inner!void {
    @memset(out[0..alphabet_size], 0);

    var symbol: usize = 0;
    var prev_code_len: u8 = 8;
    var repeat: u32 = 0;
    var repeat_code_len: u8 = 0;
    var space: i64 = 32768;

    while (symbol < alphabet_size and space > 0) {
        const code_len = try length_code.readSymbol(reader);

        if (code_len < 16) {
            repeat = 0;
            out[symbol] = @intCast(code_len);
            symbol += 1;

            if (code_len != 0) {
                prev_code_len = @intCast(code_len);
                space -= @as(i64, 32768) >> @intCast(code_len);
            }

            continue;
        }

        const extra_bits: u6 = if (code_len == 16) 2 else 3;
        const new_len: u8 = if (code_len == 16) prev_code_len else 0;
        if (repeat_code_len != new_len) {
            repeat = 0;
            repeat_code_len = new_len;
        }

        const old_repeat = repeat;
        if (repeat > 0) {
            repeat -= 2;
            repeat <<= @intCast(extra_bits);
        }
        repeat += (try reader.readBits(extra_bits)) + 3;

        const delta = repeat - old_repeat;
        if (symbol + delta > alphabet_size) return Error.ZixUtils_BrotliPrefixRead_Malformed;

        @memset(out[symbol .. symbol + delta], repeat_code_len);
        symbol += delta;

        if (repeat_code_len != 0) {
            space -= @as(i64, delta) << @intCast(15 - repeat_code_len);
        }
    }
}

/// Simple prefix code: 1 to 4 listed symbols (sec 3.4).
fn readSimplePrefixCode(reader: *BitReader, alphabet_size: usize) Inner!HuffmanDecoder {
    const nsym = (try reader.readBits(2)) + 1;
    const abits = tables.alphabetBits(alphabet_size);

    var symbols: [4]u16 = undefined;
    for (0..nsym) |index| {
        const symbol: u16 = @intCast(try reader.readBits(abits));
        if (symbol >= alphabet_size) return Error.ZixUtils_BrotliPrefixRead_Malformed;

        for (symbols[0..index]) |seen| {
            if (seen == symbol) return Error.ZixUtils_BrotliPrefixRead_Malformed;
        }

        symbols[index] = symbol;
    }

    if (nsym == 1) return HuffmanDecoder.single(symbols[0]);

    var tree_select: u1 = 0;
    if (nsym == 4) tree_select = try reader.readBit();

    var lengths: [tables.MAX_SYMBOLS]u8 = undefined;
    @memset(lengths[0..alphabet_size], 0);

    switch (nsym) {
        2 => {
            lengths[symbols[0]] = 1;
            lengths[symbols[1]] = 1;
        },
        3 => {
            lengths[symbols[0]] = 1;
            lengths[symbols[1]] = 2;
            lengths[symbols[2]] = 2;
        },
        4 => {
            if (tree_select == 0) {
                for (symbols) |symbol| lengths[symbol] = 2;
            } else {
                lengths[symbols[0]] = 1;
                lengths[symbols[1]] = 2;
                lengths[symbols[2]] = 3;
                lengths[symbols[3]] = 3;
            }
        },
        // nsym is 1..4 from two bits, and 1 returned above.
        else => unreachable,
    }

    return HuffmanDecoder.build(lengths[0..alphabet_size]);
}

/// Complex prefix code: a code length code, then per-symbol lengths (sec 3.5).
fn readComplexPrefixCode(
    reader: *BitReader,
    alphabet_size: usize,
    hskip: u32,
) Inner!HuffmanDecoder {
    var code_lengths: [18]u8 = undefined;
    try readCodeLengthCode(reader, hskip, &code_lengths);

    const length_code = try HuffmanDecoder.build(&code_lengths);

    var symbol_lengths: [tables.MAX_SYMBOLS]u8 = undefined;
    try readSymbolLengths(reader, &length_code, alphabet_size, &symbol_lengths);

    return HuffmanDecoder.build(symbol_lengths[0..alphabet_size]);
}

fn readPrefixCodeInner(reader: *BitReader, alphabet_size: usize) Inner!HuffmanDecoder {
    if (alphabet_size > tables.MAX_SYMBOLS) return Error.ZixUtils_BrotliPrefixRead_Malformed;

    const selector = try reader.readBits(2);
    if (selector == 1) return readSimplePrefixCode(reader, alphabet_size);

    return readComplexPrefixCode(reader, alphabet_size, selector);
}

fn readWindowBitsInner(reader: *BitReader) Inner!u6 {
    if (try reader.readBit() == 0) return 16;

    const high = try reader.readBits(3);
    if (high != 0) return @intCast(17 + high);

    const low = try reader.readBits(3);
    if (low != 0) return @intCast(8 + low);

    return 17;
}

fn readBlockTypeCountInner(reader: *BitReader) Inner!u32 {
    if (try reader.readBit() == 0) return 1;

    const nbits = try reader.readBits(3);

    return (@as(u32, 1) << @intCast(nbits)) + 1 + (try reader.readBits(@intCast(nbits)));
}

fn readBlockCountInner(reader: *BitReader, code: *const HuffmanDecoder) Inner!u32 {
    const symbol = try code.readSymbol(reader);
    if (symbol >= tables.BLOCK_COUNT_BASE.len) return Error.ZixUtils_BrotliPrefixRead_Malformed;

    const extra = try reader.readBits(tables.BLOCK_COUNT_EXTRA[symbol]);

    return tables.BLOCK_COUNT_BASE[symbol] + extra;
}

/// RLEMAX (sec 7.3): a 0 bit is 0, else four bits plus one.
fn readRleMax(reader: *BitReader) Inner!u32 {
    if (try reader.readBit() == 0) return 0;

    return (try reader.readBits(4)) + 1;
}

/// Inverse move-to-front transform, in place (sec 7.3).
fn inverseMoveToFront(values: []u8) void {
    var mtf: [256]u8 = undefined;
    for (&mtf, 0..) |*slot, index| slot.* = @intCast(index);

    for (values) |*value| {
        const index = value.*;
        const front = mtf[index];
        value.* = front;

        var pos: usize = index;
        while (pos > 0) : (pos -= 1) mtf[pos] = mtf[pos - 1];
        mtf[0] = front;
    }
}

fn readContextMapInner(reader: *BitReader, ntrees: u32, out: []u8) Inner!void {
    const rlemax = try readRleMax(reader);
    const code = try readPrefixCodeInner(reader, ntrees + rlemax);

    var index: usize = 0;
    while (index < out.len) {
        const symbol = try code.readSymbol(reader);

        if (symbol == 0) {
            out[index] = 0;
            index += 1;
        } else if (symbol <= rlemax) {
            const extra = try reader.readBits(@intCast(symbol));
            const run = (@as(u32, 1) << @intCast(symbol)) + extra;
            if (index + run > out.len) return Error.ZixUtils_BrotliPrefixRead_Malformed;

            @memset(out[index .. index + run], 0);
            index += run;
        } else {
            out[index] = @intCast(symbol - rlemax);
            index += 1;
        }
    }

    if (try reader.readBit() == 1) inverseMoveToFront(out);
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_BrotliPrefixRead_Truncated,
    ZixUtils_BrotliPrefixRead_Malformed,
};

/// Read one prefix code. The 2-bit selector is 1 for simple, otherwise HSKIP.
///
/// Param:
/// reader - *BitReader (stream)
/// alphabet_size - usize (symbol count, at most MAX_SYMBOLS)
///
/// Return:
/// - HuffmanDecoder
/// - Error on a truncated or malformed code
pub fn readPrefixCode(reader: *BitReader, alphabet_size: usize) Error!HuffmanDecoder {
    return readPrefixCodeInner(reader, alphabet_size) catch |err| innerError(err);
}

/// Read the stream window bits (sec 9.1).
///
/// Param:
/// reader - *BitReader (stream)
///
/// Return:
/// - u6 (WBITS)
/// - Error.ZixUtils_BrotliPrefixRead_Truncated past the end
pub fn readWindowBits(reader: *BitReader) Error!u6 {
    return readWindowBitsInner(reader) catch |err| innerError(err);
}

/// Read NBLTYPES or NTREES, 1..256 (sec 9.2).
///
/// Param:
/// reader - *BitReader (stream)
///
/// Return:
/// - u32
/// - Error.ZixUtils_BrotliPrefixRead_Truncated past the end
pub fn readBlockTypeCount(reader: *BitReader) Error!u32 {
    return readBlockTypeCountInner(reader) catch |err| innerError(err);
}

/// Read one block count: a block count symbol and its extra bits (sec 6).
///
/// Param:
/// reader - *BitReader (stream)
/// code - *const HuffmanDecoder (block count code)
///
/// Return:
/// - u32
/// - Error on a truncated or malformed count
pub fn readBlockCount(reader: *BitReader, code: *const HuffmanDecoder) Error!u32 {
    return readBlockCountInner(reader, code) catch |err| innerError(err);
}

/// Read one context map into out (sec 7.3).
///
/// Param:
/// reader - *BitReader (stream)
/// ntrees - u32 (number of trees, at least 2)
/// out - []u8 (context map, its length is the map size)
///
/// Return:
/// - void
/// - Error on a truncated or malformed map
pub fn readContextMap(reader: *BitReader, ntrees: u32, out: []u8) Error!void {
    return readContextMapInner(reader, ntrees, out) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Pack (value, bit count) fields LSB first into out, the way the stream is read.
fn packBits(out: []u8, fields: []const [2]u32) void {
    @memset(out, 0);

    var bit_index: usize = 0;
    for (fields) |field| {
        for (0..field[1]) |bit| {
            const value: u8 = @intCast((field[0] >> @intCast(bit)) & 1);
            out[bit_index / 8] |= value << @intCast(bit_index % 8);
            bit_index += 1;
        }
    }
}

test "zix utils compression brotli: prefix_read, window bits 0 is 16" {
    var bytes: [1]u8 = undefined;
    packBits(&bytes, &.{.{ 0, 1 }});
    var reader = BitReader.init(&bytes);

    try std.testing.expectEqual(@as(u6, 16), try readWindowBits(&reader));
}

test "zix utils compression brotli: prefix_read, window bits 22" {
    var bytes: [1]u8 = undefined;
    packBits(&bytes, &.{ .{ 1, 1 }, .{ 5, 3 } });
    var reader = BitReader.init(&bytes);

    try std.testing.expectEqual(@as(u6, 22), try readWindowBits(&reader));
}

test "zix utils compression brotli: prefix_read, window bits 17" {
    var bytes: [1]u8 = undefined;
    packBits(&bytes, &.{ .{ 1, 1 }, .{ 0, 3 }, .{ 0, 3 } });
    var reader = BitReader.init(&bytes);

    try std.testing.expectEqual(@as(u6, 17), try readWindowBits(&reader));
}

test "zix utils compression brotli: prefix_read, window bits on empty is truncated" {
    var reader = BitReader.init(&.{});

    try std.testing.expectError(Error.ZixUtils_BrotliPrefixRead_Truncated, readWindowBits(&reader));
}

test "zix utils compression brotli: prefix_read, block type count 0 bit is 1" {
    var bytes: [1]u8 = undefined;
    packBits(&bytes, &.{.{ 0, 1 }});
    var reader = BitReader.init(&bytes);

    try std.testing.expectEqual(@as(u32, 1), try readBlockTypeCount(&reader));
}

test "zix utils compression brotli: prefix_read, block type count reads extra" {
    var bytes: [1]u8 = undefined;
    packBits(&bytes, &.{ .{ 1, 1 }, .{ 1, 3 }, .{ 1, 1 } });
    var reader = BitReader.init(&bytes);

    try std.testing.expectEqual(@as(u32, 4), try readBlockTypeCount(&reader));
}

test "zix utils compression brotli: prefix_read, simple single symbol code" {
    var bytes: [1]u8 = undefined;
    packBits(&bytes, &.{ .{ 1, 2 }, .{ 0, 2 }, .{ 5, 3 } });
    var reader = BitReader.init(&bytes);

    const code = try readPrefixCode(&reader, 8);

    try std.testing.expectEqual(@as(?u16, 5), code.single_symbol);
}

test "zix utils compression brotli: prefix_read, simple code symbol past the alphabet" {
    var bytes: [1]u8 = undefined;
    packBits(&bytes, &.{ .{ 1, 2 }, .{ 0, 2 }, .{ 7, 3 } });
    var reader = BitReader.init(&bytes);

    try std.testing.expectError(
        Error.ZixUtils_BrotliPrefixRead_Malformed,
        readPrefixCode(&reader, 6),
    );
}

test "zix utils compression brotli: prefix_read, simple code duplicate symbol" {
    var bytes: [1]u8 = undefined;
    packBits(&bytes, &.{ .{ 1, 2 }, .{ 1, 2 }, .{ 1, 1 }, .{ 1, 1 } });
    var reader = BitReader.init(&bytes);

    try std.testing.expectError(
        Error.ZixUtils_BrotliPrefixRead_Malformed,
        readPrefixCode(&reader, 2),
    );
}

test "zix utils compression brotli: prefix_read, simple two symbol code reads both" {
    var bytes: [2]u8 = undefined;
    packBits(&bytes, &.{ .{ 1, 2 }, .{ 1, 2 }, .{ 3, 2 }, .{ 1, 2 }, .{ 1, 1 } });
    var reader = BitReader.init(&bytes);

    const code = try readPrefixCode(&reader, 4);

    try std.testing.expectEqual(@as(u16, 3), try code.readSymbol(&reader));
}

test "zix utils compression brotli: prefix_read, alphabet past MAX_SYMBOLS is malformed" {
    var reader = BitReader.init(&.{0});

    try std.testing.expectError(
        Error.ZixUtils_BrotliPrefixRead_Malformed,
        readPrefixCode(&reader, tables.MAX_SYMBOLS + 1),
    );
}

test "zix utils compression brotli: prefix_read, block count uses base and extra" {
    var bytes: [1]u8 = undefined;
    packBits(&bytes, &.{.{ 3, 2 }});
    var reader = BitReader.init(&bytes);
    const code = HuffmanDecoder.single(0);

    try std.testing.expectEqual(@as(u32, 1 + 3), try readBlockCount(&reader, &code));
}

test "zix utils compression brotli: prefix_read, block count symbol past table" {
    var reader = BitReader.init(&.{});
    const code = HuffmanDecoder.single(26);

    try std.testing.expectError(
        Error.ZixUtils_BrotliPrefixRead_Malformed,
        readBlockCount(&reader, &code),
    );
}

test "zix utils compression brotli: prefix_read, inverseMoveToFront restores values" {
    var values = [_]u8{ 1, 0, 2 };
    inverseMoveToFront(&values);

    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 2 }, &values);
}

test "zix utils compression brotli: prefix_read, context map reads plain values" {
    var bytes: [2]u8 = undefined;
    packBits(&bytes, &.{
        .{ 0, 1 },
        .{ 1, 2 },
        .{ 1, 2 },
        .{ 0, 1 },
        .{ 1, 1 },
        .{ 1, 1 },
        .{ 0, 1 },
        .{ 1, 1 },
        .{ 0, 1 },
        .{ 0, 1 },
    });
    var reader = BitReader.init(&bytes);
    var map: [4]u8 = undefined;

    try readContextMap(&reader, 2, &map);

    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 1, 0 }, &map);
}

test "zix utils compression brotli: prefix_read, context map applies IMTF" {
    var bytes: [2]u8 = undefined;
    packBits(&bytes, &.{
        .{ 0, 1 },
        .{ 1, 2 },
        .{ 1, 2 },
        .{ 0, 1 },
        .{ 1, 1 },
        .{ 1, 1 },
        .{ 0, 1 },
        .{ 1, 1 },
    });
    var reader = BitReader.init(&bytes);
    var map: [2]u8 = undefined;

    try readContextMap(&reader, 2, &map);

    try std.testing.expectEqualSlices(u8, &.{ 1, 1 }, &map);
}

test "zix utils compression brotli: prefix_read, context map run past the end" {
    var bytes: [2]u8 = undefined;
    packBits(&bytes, &.{
        .{ 1, 1 },
        .{ 0, 4 },
        .{ 1, 2 },
        .{ 0, 2 },
        .{ 1, 2 },
        .{ 1, 1 },
    });
    var reader = BitReader.init(&bytes);
    var map: [2]u8 = undefined;

    try std.testing.expectError(
        Error.ZixUtils_BrotliPrefixRead_Malformed,
        readContextMap(&reader, 2, &map),
    );
}
