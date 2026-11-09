//! ZIX utils compression brotli Decoder
//!
//! ### file: src/zix/utils/compression/brotli/Decoder.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Decodes a whole brotli stream into an owned buffer (RFC 7932 sec 9, 10).
//! 
//! ### note:
//! 
//! limit bounds the total output before each meta-block is produced, so a
//! decompression bomb is rejected up front.
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
const BlockCategory = @import("BlockCategory.zig");
const DistanceRing = @import("DistanceRing.zig");
const HuffmanDecoder = @import("HuffmanDecoder.zig");
const context = @import("context.zig");
const dictionary = @import("dictionary.zig");
const distance = @import("distance.zig");
const prefix_read = @import("prefix_read.zig");
const tables = @import("tables.zig");
const transform = @import("transform.zig");

// --------------------------------------------------------- //
// Fields:

allocator: std.mem.Allocator,
reader: BitReader,
/// Largest total output accepted.
limit: usize,
/// Which code paths the stream used.
stats: Stats = .{},
/// Output so far, owned until run returns it.
out: std.ArrayList(u8) = .empty,
/// Largest backward distance (2^WBITS - 16).
window_size: u32 = 0,
ring: DistanceRing = .{},
/// Last output byte, for the literal context.
last_byte: u8 = 0,
/// Output byte before last_byte.
prior_byte: u8 = 0,

const Self = @This();

// --------------------------------------------------------- //
// Private:

const MAX_BLOCK_TYPES = 256;
const LITERAL_MAP_MAX = context.LITERAL_CONTEXTS * MAX_BLOCK_TYPES;
const DISTANCE_MAP_MAX = context.DISTANCE_CONTEXTS * MAX_BLOCK_TYPES;

const Inner = Error ||
    std.mem.Allocator.Error ||
    BitReader.Error ||
    HuffmanDecoder.Error ||
    BlockCategory.Error ||
    prefix_read.Error ||
    distance.Error ||
    dictionary.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixUtils_BrotliDecoder_Truncated => Error.ZixUtils_BrotliDecoder_Truncated,
        error.ZixUtils_BrotliDecoder_Malformed => Error.ZixUtils_BrotliDecoder_Malformed,
        error.ZixUtils_BrotliDecoder_OutputTooLarge => Error.ZixUtils_BrotliDecoder_OutputTooLarge,
        error.ZixUtils_BrotliDecoder_OutOfMemory => Error.ZixUtils_BrotliDecoder_OutOfMemory,
        error.OutOfMemory => Error.ZixUtils_BrotliDecoder_OutOfMemory,
        error.ZixUtils_BrotliBitReader_Truncated => Error.ZixUtils_BrotliDecoder_Truncated,
        error.ZixUtils_BrotliHuffmanDecoder_Truncated => Error.ZixUtils_BrotliDecoder_Truncated,
        error.ZixUtils_BrotliHuffmanDecoder_Malformed => Error.ZixUtils_BrotliDecoder_Malformed,
        error.ZixUtils_BrotliBlockCategory_Truncated => Error.ZixUtils_BrotliDecoder_Truncated,
        error.ZixUtils_BrotliBlockCategory_Malformed => Error.ZixUtils_BrotliDecoder_Malformed,
        error.ZixUtils_BrotliPrefixRead_Truncated => Error.ZixUtils_BrotliDecoder_Truncated,
        error.ZixUtils_BrotliPrefixRead_Malformed => Error.ZixUtils_BrotliDecoder_Malformed,
        error.ZixUtils_BrotliDistance_Truncated => Error.ZixUtils_BrotliDecoder_Truncated,
        error.ZixUtils_BrotliDistance_Malformed => Error.ZixUtils_BrotliDecoder_Malformed,
        error.ZixUtils_BrotliDictionary_Malformed => Error.ZixUtils_BrotliDecoder_Malformed,
    };
}

fn pushByte(self: *Self, byte: u8) Inner!void {
    try self.out.append(self.allocator, byte);

    self.prior_byte = self.last_byte;
    self.last_byte = byte;
}

fn runInner(self: *Self) Inner![]u8 {
    const wbits = try prefix_read.readWindowBits(&self.reader);
    self.window_size = (@as(u32, 1) << @intCast(wbits)) - 16;

    while (true) {
        const is_last = try self.reader.readBit();
        if (is_last == 1 and try self.reader.readBit() == 1) break;

        const mnibbles_code = try self.reader.readBits(2);
        if (mnibbles_code == 3) {
            try self.skipMetadata();
        } else {
            const nibbles: u6 = @intCast(mnibbles_code + 4);
            const mlen = (try self.reader.readBits(nibbles * 4)) + 1;

            if (self.out.items.len + mlen > self.limit) {
                return Error.ZixUtils_BrotliDecoder_OutputTooLarge;
            }

            var is_uncompressed = false;
            if (is_last == 0) is_uncompressed = (try self.reader.readBit() == 1);

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

/// Metadata meta-block (sec 9.2): skip MSKIPLEN bytes, produce nothing.
fn skipMetadata(self: *Self) Inner!void {
    self.stats.meta_blocks += 1;
    self.stats.metadata += 1;

    if (try self.reader.readBit() != 0) return Error.ZixUtils_BrotliDecoder_Malformed;

    const mskipbytes = try self.reader.readBits(2);
    var mskiplen: u32 = 0;
    if (mskipbytes > 0) mskiplen = (try self.reader.readBits(@intCast(mskipbytes * 8))) + 1;

    self.reader.alignToByte();
    _ = try self.reader.readBytes(mskiplen);
}

/// Uncompressed meta-block: copy MLEN bytes as they are.
fn copyUncompressed(self: *Self, mlen: u32) Inner!void {
    self.stats.meta_blocks += 1;
    self.stats.uncompressed += 1;

    self.reader.alignToByte();
    const raw = try self.reader.readBytes(mlen);

    try self.out.appendSlice(self.allocator, raw);

    if (mlen >= 2) {
        self.prior_byte = raw[mlen - 2];
        self.last_byte = raw[mlen - 1];
    } else if (mlen == 1) {
        self.prior_byte = self.last_byte;
        self.last_byte = raw[0];
    }
}

/// One context mode per literal block type (sec 9.2, 7.1).
fn readContextModes(self: *Self, out: []context.ContextMode) Inner!void {
    for (out) |*mode| mode.* = @enumFromInt(try self.reader.readBits(2));
}

/// Compressed meta-block: header (sec 9.2), then the command loop (sec 10).
fn decodeMetaBlock(self: *Self, mlen: u32) Inner!void {
    self.stats.meta_blocks += 1;
    self.stats.compressed += 1;

    var literal_cat = try BlockCategory.init(&self.reader);
    var command_cat = try BlockCategory.init(&self.reader);
    var distance_cat = try BlockCategory.init(&self.reader);
    if (literal_cat.has_switch or command_cat.has_switch or distance_cat.has_switch) {
        self.stats.block_switch += 1;
    }

    const npostfix = try self.reader.readBits(2);
    const ndirect = (try self.reader.readBits(4)) << @intCast(npostfix);

    var modes: [MAX_BLOCK_TYPES]context.ContextMode = undefined;
    try self.readContextModes(modes[0..literal_cat.nbltypes]);

    var literal_map: [LITERAL_MAP_MAX]u8 = undefined;
    const ntrees_literal = try prefix_read.readBlockTypeCount(&self.reader);
    const literal_map_size = context.LITERAL_CONTEXTS * literal_cat.nbltypes;
    @memset(literal_map[0..literal_map_size], 0);
    if (ntrees_literal >= 2) {
        try prefix_read.readContextMap(
            &self.reader,
            ntrees_literal,
            literal_map[0..literal_map_size],
        );
    }

    var distance_map: [DISTANCE_MAP_MAX]u8 = undefined;
    const ntrees_distance = try prefix_read.readBlockTypeCount(&self.reader);
    const distance_map_size = context.DISTANCE_CONTEXTS * distance_cat.nbltypes;
    @memset(distance_map[0..distance_map_size], 0);
    if (ntrees_distance >= 2) {
        try prefix_read.readContextMap(
            &self.reader,
            ntrees_distance,
            distance_map[0..distance_map_size],
        );
    }

    const literal_trees = try self.allocator.alloc(HuffmanDecoder, ntrees_literal);
    defer self.allocator.free(literal_trees);
    for (literal_trees) |*tree| {
        tree.* = try prefix_read.readPrefixCode(&self.reader, tables.LITERAL_ALPHABET);
    }

    const command_trees = try self.allocator.alloc(HuffmanDecoder, command_cat.nbltypes);
    defer self.allocator.free(command_trees);
    for (command_trees) |*tree| {
        tree.* = try prefix_read.readPrefixCode(&self.reader, tables.COMMAND_ALPHABET);
    }

    const distance_alphabet = 16 + ndirect + (@as(u32, 48) << @intCast(npostfix));
    const distance_trees = try self.allocator.alloc(HuffmanDecoder, ntrees_distance);
    defer self.allocator.free(distance_trees);
    for (distance_trees) |*tree| {
        tree.* = try prefix_read.readPrefixCode(&self.reader, distance_alphabet);
    }

    try self.out.ensureUnusedCapacity(self.allocator, mlen);

    var produced: u32 = 0;
    while (produced < mlen) {
        try command_cat.consume(&self.reader);
        const command = try command_trees[command_cat.btype].readSymbol(&self.reader);
        const parts = tables.splitInsertCopy(command);

        const insert_extra = try self.reader.readBits(tables.INSERT_LEN_EXTRA[parts.insert_code]);
        const insert_len = tables.INSERT_LEN_BASE[parts.insert_code] + insert_extra;
        const copy_extra = try self.reader.readBits(tables.COPY_LEN_EXTRA[parts.copy_code]);
        const copy_len = tables.COPY_LEN_BASE[parts.copy_code] + copy_extra;

        for (0..insert_len) |_| {
            try literal_cat.consume(&self.reader);

            const context_id = context.literalContextId(
                modes[literal_cat.btype],
                self.last_byte,
                self.prior_byte,
            );
            const tree_index = literal_map[context.LITERAL_CONTEXTS * literal_cat.btype + context_id];
            const literal: u8 = @intCast(try literal_trees[tree_index].readSymbol(&self.reader));

            try self.pushByte(literal);
            produced += 1;
            if (produced == mlen) return;
        }

        var backward: u32 = undefined;
        var push_candidate = false;
        if (parts.distance_zero) {
            backward = self.ring.dist[0];
        } else {
            try distance_cat.consume(&self.reader);

            const context_id = context.distanceContextId(copy_len);
            const tree_index =
                distance_map[context.DISTANCE_CONTEXTS * distance_cat.btype + context_id];
            const code = try distance_trees[tree_index].readSymbol(&self.reader);
            const resolved = try distance.read(&self.reader, code, &self.ring, npostfix, ndirect);

            backward = resolved.value;
            push_candidate = resolved.push;
        }

        const max_allowed: u32 = @min(self.window_size, @as(u32, @intCast(self.out.items.len)));
        if (backward <= max_allowed) {
            // A real backward reference goes into the ring. Dictionary ones do not.
            if (push_candidate) self.ring.push(backward);

            var copied: u32 = 0;
            while (copied < copy_len and produced < mlen) : (copied += 1) {
                const byte = self.out.items[self.out.items.len - backward];

                try self.pushByte(byte);
                produced += 1;
            }
        } else {
            var word: [transform.MAX_OUTPUT_LEN]u8 = undefined;
            const written = try dictionary.word(copy_len, backward, max_allowed, &word);
            if (produced + written > mlen) return Error.ZixUtils_BrotliDecoder_Malformed;

            for (word[0..written]) |byte| try self.pushByte(byte);
            produced += @intCast(written);
        }
    }
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_BrotliDecoder_Truncated,
    ZixUtils_BrotliDecoder_Malformed,
    ZixUtils_BrotliDecoder_OutputTooLarge,
    ZixUtils_BrotliDecoder_OutOfMemory,
};

/// Which meta-block kinds a decode went through.
pub const Stats = struct {
    meta_blocks: usize = 0,
    compressed: usize = 0,
    uncompressed: usize = 0,
    metadata: usize = 0,
    block_switch: usize = 0,
};

/// Start a decoder over a compressed stream.
///
/// Param:
/// allocator - std.mem.Allocator (owns the output and transient tables)
/// compressed - []const u8 (brotli stream)
/// limit - usize (largest total output accepted)
///
/// Return:
/// - Self
pub fn init(allocator: std.mem.Allocator, compressed: []const u8, limit: usize) Self {
    return .{
        .allocator = allocator,
        .reader = BitReader.init(compressed),
        .limit = limit,
    };
}

/// Free the output when run did not hand it over.
pub fn deinit(self: *Self) void {
    self.out.deinit(self.allocator);
}

/// Decode the whole stream (sec 10).
///
/// Return:
/// - []u8 (owned by the caller, free with the same allocator)
/// - Error.ZixUtils_BrotliDecoder_OutputTooLarge past the limit
/// - Error.ZixUtils_BrotliDecoder_Truncated or Malformed on a bad stream
pub fn run(self: *Self) Error![]u8 {
    return self.runInner() catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn decodeAll(stream: []const u8, limit: usize) Error![]u8 {
    var decoder = init(std.testing.allocator, stream, limit);
    defer decoder.deinit();

    return decoder.run();
}

test "zix utils compression brotli: Decoder, empty stream decodes to nothing" {
    const out = try decodeAll("\x3f", 16);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "zix utils compression brotli: Decoder, decodes a brotli CLI vector" {
    const vector = "\x1f\xef\x00\xf8\x8d\x94\x6e\xe6\xa2\x06\x31\xa3\xc3\x53\x68\x6f" ++
        "\x39\xc8\x24\xa3\xe5\x08\xdb\x74\x54\x16\x48\xd7\x16\x0f";

    var expected: [240]u8 = undefined;
    var pos: usize = 0;
    while (pos < expected.len) : (pos += 20) {
        @memcpy(expected[pos .. pos + 20], "the quick brown fox ");
    }

    const out = try decodeAll(vector, 1024);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualSlices(u8, &expected, out);
}

test "zix utils compression brotli: Decoder, CLI vector counts one compressed block" {
    const vector = "\x1f\xef\x00\xf8\x8d\x94\x6e\xe6\xa2\x06\x31\xa3\xc3\x53\x68\x6f" ++
        "\x39\xc8\x24\xa3\xe5\x08\xdb\x74\x54\x16\x48\xd7\x16\x0f";

    var decoder = init(std.testing.allocator, vector, 1024);
    defer decoder.deinit();

    const out = try decoder.run();
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(@as(usize, 1), decoder.stats.compressed);
}

test "zix utils compression brotli: Decoder, output past the limit is too large" {
    const vector = "\x1f\xef\x00\xf8\x8d\x94\x6e\xe6\xa2\x06\x31\xa3\xc3\x53\x68\x6f" ++
        "\x39\xc8\x24\xa3\xe5\x08\xdb\x74\x54\x16\x48\xd7\x16\x0f";

    try std.testing.expectError(Error.ZixUtils_BrotliDecoder_OutputTooLarge, decodeAll(vector, 16));
}

test "zix utils compression brotli: Decoder, empty input is truncated" {
    try std.testing.expectError(Error.ZixUtils_BrotliDecoder_Truncated, decodeAll("", 16));
}

test "zix utils compression brotli: Decoder, cut stream is truncated" {
    const vector = "\x1f\xef\x00\xf8\x8d\x94\x6e\xe6";

    try std.testing.expectError(Error.ZixUtils_BrotliDecoder_Truncated, decodeAll(vector, 1024));
}

