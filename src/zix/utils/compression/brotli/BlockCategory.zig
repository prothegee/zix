//! ZIX utils compression brotli BlockCategory
//!
//! ### file: src/zix/utils/compression/brotli/BlockCategory.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Block type state of one category (literals, commands, or distances) inside a
//! meta-block (RFC 7932 sec 6).
//! 
//! ### note:
//! 
//! With NBLTYPES >= 2 the stream carries block switch commands that change the
//! active block type in the middle of the data.
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
const prefix_read = @import("prefix_read.zig");
const tables = @import("tables.zig");

// --------------------------------------------------------- //
// Fields:

/// Number of block types, 1..256.
nbltypes: u32,
/// Active block type.
btype: u32 = 0,
/// Previous block type, for the "previous" switch code.
prev_btype: u32 = 1,
/// Symbols left in the active block.
blen: u32 = 0,
/// True when nbltypes >= 2.
has_switch: bool = false,
/// Block type code, valid when has_switch.
btype_code: HuffmanDecoder = undefined,
/// Block count code, valid when has_switch.
blen_code: HuffmanDecoder = undefined,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Block length used when the category never switches (2^24).
const NO_SWITCH_BLEN: u32 = 16777216;

const Inner = Error || prefix_read.Error || HuffmanDecoder.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixUtils_BrotliBlockCategory_Truncated => {
            return Error.ZixUtils_BrotliBlockCategory_Truncated;
        },
        error.ZixUtils_BrotliBlockCategory_Malformed => {
            return Error.ZixUtils_BrotliBlockCategory_Malformed;
        },
        error.ZixUtils_BrotliPrefixRead_Truncated => {
            return Error.ZixUtils_BrotliBlockCategory_Truncated;
        },
        error.ZixUtils_BrotliPrefixRead_Malformed => {
            return Error.ZixUtils_BrotliBlockCategory_Malformed;
        },
        error.ZixUtils_BrotliHuffmanDecoder_Truncated => {
            return Error.ZixUtils_BrotliBlockCategory_Truncated;
        },
        error.ZixUtils_BrotliHuffmanDecoder_Malformed => {
            return Error.ZixUtils_BrotliBlockCategory_Malformed;
        },
    };
}

fn initInner(reader: *BitReader) Inner!Self {
    const nbltypes = try prefix_read.readBlockTypeCount(reader);
    if (nbltypes < 2) {
        return .{
            .nbltypes = nbltypes,
            .blen = NO_SWITCH_BLEN,
        };
    }

    var self = Self{
        .nbltypes = nbltypes,
        .has_switch = true,
    };
    self.btype_code = try prefix_read.readPrefixCode(reader, nbltypes + 2);
    self.blen_code = try prefix_read.readPrefixCode(reader, tables.BLOCK_COUNT_BASE.len);
    self.blen = try prefix_read.readBlockCount(reader, &self.blen_code);

    return self;
}

fn consumeInner(self: *Self, reader: *BitReader) Inner!void {
    if (self.blen == 0 and self.has_switch) {
        const symbol = try self.btype_code.readSymbol(reader);
        const next: u32 = switch (symbol) {
            0 => self.prev_btype,
            1 => (self.btype + 1) % self.nbltypes,
            else => @as(u32, symbol) - 2,
        };
        if (next >= self.nbltypes) return Error.ZixUtils_BrotliBlockCategory_Malformed;

        self.prev_btype = self.btype;
        self.btype = next;
        self.blen = try prefix_read.readBlockCount(reader, &self.blen_code);
    }

    if (self.blen > 0) self.blen -= 1;
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_BrotliBlockCategory_Truncated,
    ZixUtils_BrotliBlockCategory_Malformed,
};

/// Read NBLTYPES and, when it is 2 or more, the switch codes and first count.
///
/// Param:
/// reader - *BitReader (stream)
///
/// Return:
/// - Self
/// - Error on a truncated or malformed header
pub fn init(reader: *BitReader) Error!Self {
    return initInner(reader) catch |err| innerError(err);
}

/// Take one symbol from the active block, switching block type when it runs out.
///
/// Param:
/// reader - *BitReader (stream)
///
/// Return:
/// - void
/// - Error on a truncated or malformed switch
pub fn consume(self: *Self, reader: *BitReader) Error!void {
    return self.consumeInner(reader) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression brotli: BlockCategory, one type never switches" {
    var reader = BitReader.init(&.{0});
    var category = try init(&reader);

    try category.consume(&reader);

    try std.testing.expectEqual(@as(u32, 1), category.nbltypes);
    try std.testing.expect(!category.has_switch);
    try std.testing.expectEqual(NO_SWITCH_BLEN - 1, category.blen);
}

test "zix utils compression brotli: BlockCategory, init on empty is truncated" {
    var reader = BitReader.init(&.{});

    try std.testing.expectError(Error.ZixUtils_BrotliBlockCategory_Truncated, init(&reader));
}

test "zix utils compression brotli: BlockCategory, switch to the next type" {
    // Block count symbol 0 reads 2 extra bits.
    var reader = BitReader.init(&.{0b00});
    var category: Self = .{
        .nbltypes = 3,
        .has_switch = true,
        .btype_code = HuffmanDecoder.single(1),
        .blen_code = HuffmanDecoder.single(0),
    };

    try category.consume(&reader);

    try std.testing.expectEqual(@as(u32, 1), category.btype);
    try std.testing.expectEqual(@as(u32, 0), category.prev_btype);
    try std.testing.expectEqual(@as(u32, 0), category.blen);
}

test "zix utils compression brotli: BlockCategory, type past nbltypes is malformed" {
    var reader = BitReader.init(&.{0});
    var category: Self = .{
        .nbltypes = 2,
        .has_switch = true,
        .btype_code = HuffmanDecoder.single(5),
        .blen_code = HuffmanDecoder.single(0),
    };

    try std.testing.expectError(
        Error.ZixUtils_BrotliBlockCategory_Malformed,
        category.consume(&reader),
    );
}

