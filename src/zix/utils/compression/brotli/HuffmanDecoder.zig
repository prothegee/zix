//! ZIX utils compression brotli HuffmanDecoder
//!
//! ### file: src/zix/utils/compression/brotli/HuffmanDecoder.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Canonical prefix code decoder built from per-symbol code lengths
//! (RFC 7932 sec 3.2).
//! 
//! ### note:
//! 
//! A code with one participating symbol reads no bits (sec 3.4, 3.5).
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
const tables = @import("tables.zig");

// --------------------------------------------------------- //
// Fields:

/// Set when only one symbol takes part. readSymbol then reads no bits.
single_symbol: ?u16 = null,
/// Number of codes per length.
count: [tables.MAX_CODE_LEN + 1]u16 = @splat(0),
/// First canonical code per length.
first_code: [tables.MAX_CODE_LEN + 1]u16 = @splat(0),
/// Index into symbols of the first symbol per length.
first_symbol: [tables.MAX_CODE_LEN + 1]u16 = @splat(0),
/// Symbols sorted by code length, then by value.
symbols: [tables.MAX_SYMBOLS]u16 = undefined,

const Self = @This();

// --------------------------------------------------------- //
// Private:

const Inner = Error || BitReader.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixUtils_BrotliHuffmanDecoder_Truncated => {
            return Error.ZixUtils_BrotliHuffmanDecoder_Truncated;
        },
        error.ZixUtils_BrotliHuffmanDecoder_Malformed => {
            return Error.ZixUtils_BrotliHuffmanDecoder_Malformed;
        },
        error.ZixUtils_BrotliBitReader_Truncated => {
            return Error.ZixUtils_BrotliHuffmanDecoder_Truncated;
        },
    };
}

fn readSymbolInner(self: *const Self, reader: *BitReader) Inner!u16 {
    if (self.single_symbol) |symbol| return symbol;

    var code: u16 = 0;
    var len: usize = 1;
    while (len <= tables.MAX_CODE_LEN) : (len += 1) {
        code = (code << 1) | (try reader.readBit());

        if (self.count[len] != 0) {
            const rel = code -% self.first_code[len];
            if (rel < self.count[len]) return self.symbols[self.first_symbol[len] + rel];
        }
    }

    return Error.ZixUtils_BrotliHuffmanDecoder_Malformed;
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_BrotliHuffmanDecoder_Truncated,
    ZixUtils_BrotliHuffmanDecoder_Malformed,
};

/// A decoder that always yields one symbol and reads no bits.
///
/// Param:
/// symbol - u16 (the only symbol)
///
/// Return:
/// - Self
pub fn single(symbol: u16) Self {
    return .{
        .single_symbol = symbol,
    };
}

/// Build the decoder from per-symbol code lengths.
///
/// Param:
/// lengths - []const u8 (code length per symbol, 0 means absent)
///
/// Return:
/// - Self
/// - Error.ZixUtils_BrotliHuffmanDecoder_Malformed when a length passes MAX_CODE_LEN
pub fn build(lengths: []const u8) Error!Self {
    var self = Self{};

    var nonzero: u16 = 0;
    var last_nonzero: u16 = 0;
    for (lengths, 0..) |len, symbol| {
        if (len > tables.MAX_CODE_LEN) return Error.ZixUtils_BrotliHuffmanDecoder_Malformed;

        if (len != 0) {
            self.count[len] += 1;
            nonzero += 1;
            last_nonzero = @intCast(symbol);
        }
    }

    if (nonzero <= 1) {
        self.single_symbol = if (nonzero == 1) last_nonzero else 0;

        return self;
    }

    var code: u16 = 0;
    var symbol_offset: u16 = 0;
    var len: usize = 1;
    while (len <= tables.MAX_CODE_LEN) : (len += 1) {
        code = (code + self.count[len - 1]) << 1;
        self.first_code[len] = code;
        self.first_symbol[len] = symbol_offset;
        symbol_offset += self.count[len];
    }

    var fill = self.first_symbol;
    for (lengths, 0..) |symbol_len, symbol| {
        if (symbol_len != 0) {
            self.symbols[fill[symbol_len]] = @intCast(symbol);
            fill[symbol_len] += 1;
        }
    }

    return self;
}

/// Read one symbol, prefix code bits most significant first.
///
/// Param:
/// reader - *BitReader (stream)
///
/// Return:
/// - u16
/// - Error.ZixUtils_BrotliHuffmanDecoder_Truncated past the end
/// - Error.ZixUtils_BrotliHuffmanDecoder_Malformed on an unused code
pub fn readSymbol(self: *const Self, reader: *BitReader) Error!u16 {
    return self.readSymbolInner(reader) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression brotli: HuffmanDecoder, single symbol reads no bits" {
    var reader = BitReader.init(&.{});
    const decoder = single(42);

    try std.testing.expectEqual(@as(u16, 42), try decoder.readSymbol(&reader));
}

test "zix utils compression brotli: HuffmanDecoder, one present length is single" {
    const decoder = try build(&.{ 0, 0, 3, 0 });

    try std.testing.expectEqual(@as(?u16, 2), decoder.single_symbol);
}

test "zix utils compression brotli: HuffmanDecoder, reads a two-symbol code" {
    const decoder = try build(&.{ 1, 1 });
    var reader = BitReader.init(&.{0b10});

    try std.testing.expectEqual(@as(u16, 0), try decoder.readSymbol(&reader));
    try std.testing.expectEqual(@as(u16, 1), try decoder.readSymbol(&reader));
}

test "zix utils compression brotli: HuffmanDecoder, reads a canonical code" {
    // Lengths 1, 2, 2: codes 0, 10, 11 (MSB first).
    const decoder = try build(&.{ 1, 2, 2 });
    var reader = BitReader.init(&.{0b0001_1010});

    try std.testing.expectEqual(@as(u16, 0), try decoder.readSymbol(&reader));
    try std.testing.expectEqual(@as(u16, 1), try decoder.readSymbol(&reader));
    try std.testing.expectEqual(@as(u16, 2), try decoder.readSymbol(&reader));
}

test "zix utils compression brotli: HuffmanDecoder, length past the cap is malformed" {
    try std.testing.expectError(Error.ZixUtils_BrotliHuffmanDecoder_Malformed, build(&.{ 16, 1 }));
}

test "zix utils compression brotli: HuffmanDecoder, empty stream is truncated" {
    const decoder = try build(&.{ 1, 1 });
    var reader = BitReader.init(&.{});

    try std.testing.expectError(
        Error.ZixUtils_BrotliHuffmanDecoder_Truncated,
        decoder.readSymbol(&reader),
    );
}

test "zix utils compression brotli: HuffmanDecoder, incomplete code is malformed" {
    // One code of length 2 and one of length 3 leave most codes unused.
    const decoder = try build(&.{ 2, 3 });
    var reader = BitReader.init(&.{ 0xff, 0xff, 0xff });

    try std.testing.expectError(
        Error.ZixUtils_BrotliHuffmanDecoder_Malformed,
        decoder.readSymbol(&reader),
    );
}

