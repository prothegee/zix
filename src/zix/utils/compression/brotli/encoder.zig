//! ZIX utils compression brotli encoder
//!
//! ### file: src/zix/utils/compression/brotli/encoder.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Brotli meta-block encoders: a store-only stream, and one compressed meta-block
//! with greedy LZ77, the static dictionary, and optimal prefix codes.
//! 
//! ### note:
//! 
//! The compressed path writes one meta-block, so its input is capped at 16 MiB.
//! The store path splits larger input.
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
const Command = @import("Command.zig");
const DictIndex = @import("DictIndex.zig");
const DistanceRing = @import("DistanceRing.zig");
const LitModel = @import("LitModel.zig");
const context = @import("context.zig");
const distance = @import("distance.zig");
const huffman = @import("huffman.zig");
const prefix_write = @import("prefix_write.zig");
const tables = @import("tables.zig");

// --------------------------------------------------------- //
// Private:

const MIN_MATCH: usize = 4;
/// Copy length cap, keeps the extra bits small.
const MAX_MATCH: usize = 16384;
const HASH_BITS = 17;
const HASH_SIZE: usize = 1 << HASH_BITS;
/// Default hash chain walk limit per position.
const MAX_CHAIN: usize = 64;
const NO_POS: u32 = std.math.maxInt(u32);

const Inner = Error ||
    std.mem.Allocator.Error ||
    BitWriter.Error ||
    prefix_write.Error ||
    huffman.Error ||
    DictIndex.Error ||
    LitModel.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixUtils_BrotliEncoder_InvalidWindowBits => {
            return Error.ZixUtils_BrotliEncoder_InvalidWindowBits;
        },
        error.ZixUtils_BrotliEncoder_InputTooLarge => {
            return Error.ZixUtils_BrotliEncoder_InputTooLarge;
        },
        error.ZixUtils_BrotliEncoder_OutOfMemory => Error.ZixUtils_BrotliEncoder_OutOfMemory,
        error.OutOfMemory => Error.ZixUtils_BrotliEncoder_OutOfMemory,
        error.ZixUtils_BrotliBitWriter_OutOfMemory => Error.ZixUtils_BrotliEncoder_OutOfMemory,
        error.ZixUtils_BrotliPrefixWrite_InvalidWindowBits => {
            return Error.ZixUtils_BrotliEncoder_InvalidWindowBits;
        },
        error.ZixUtils_BrotliPrefixWrite_OutOfMemory => Error.ZixUtils_BrotliEncoder_OutOfMemory,
        error.ZixUtils_BrotliHuffman_OutOfMemory => Error.ZixUtils_BrotliEncoder_OutOfMemory,
        error.ZixUtils_BrotliDictIndex_OutOfMemory => Error.ZixUtils_BrotliEncoder_OutOfMemory,
        error.ZixUtils_BrotliLitModel_OutOfMemory => Error.ZixUtils_BrotliEncoder_OutOfMemory,
    };
}

fn hashAt(bytes: []const u8, pos: usize) usize {
    const word = std.mem.readInt(u32, bytes[pos..][0..4], .little);

    return (word *% 0x9E3779B1) >> (32 - HASH_BITS);
}

/// Write the empty last meta-block: ISLAST = 1, ISLASTEMPTY = 1 (sec 9.2).
fn writeEmptyLast(writer: *BitWriter, allocator: std.mem.Allocator) Inner!void {
    try writer.writeBit(allocator, 1);
    try writer.writeBit(allocator, 1);
}

/// Greedy parse with a local hash chain match and a dictionary word at each
/// position. A local match wins when present, the dictionary only fills gaps.
fn parse(
    scratch: std.mem.Allocator,
    input: []const u8,
    wbits: u6,
    dict_index: DictIndex,
    params: Params,
    commands: *std.ArrayList(Command),
) Inner!void {
    const window: u32 = (@as(u32, 1) << @intCast(wbits)) - 16;

    const head = try scratch.alloc(u32, HASH_SIZE);
    @memset(head, NO_POS);
    const prev = try scratch.alloc(u32, input.len);

    var lit_start: usize = 0;
    var pos: usize = 0;
    while (pos + MIN_MATCH <= input.len) {
        const bucket = hashAt(input, pos);

        var local_len: usize = 0;
        var local_dist: u32 = 0;
        var candidate = head[bucket];
        var chain: usize = 0;
        while (candidate != NO_POS and chain < params.max_chain) : (chain += 1) {
            const dist = pos - candidate;
            if (dist > window) break;

            const limit = @min(MAX_MATCH, input.len - pos);
            var len: usize = 0;
            while (len < limit and input[candidate + len] == input[pos + len]) len += 1;

            if (len > local_len) {
                local_len = len;
                local_dist = @intCast(dist);
            }

            candidate = prev[candidate];
        }

        prev[pos] = head[bucket];
        head[bucket] = @intCast(pos);

        var dict_word: u32 = 0;
        const dict_len = if (params.use_dict) dict_index.longestMatch(input, pos, &dict_word) else 0;

        const use_local = local_len >= MIN_MATCH;
        const use_dict = !use_local and dict_len >= MIN_MATCH;

        if (!use_local and !use_dict) {
            pos += 1;
            continue;
        }

        var command = Command{
            .insert_len = @intCast(pos - lit_start),
            .lit_off = lit_start,
            .copy_len = @intCast(local_len),
            .distance = local_dist,
            .is_dict = use_dict,
        };
        if (use_dict) {
            const max_allowed: u32 = @intCast(@min(@as(usize, window), pos));
            command.copy_len = @intCast(dict_len);
            command.distance = dict_word + max_allowed + 1;
        }
        try commands.append(scratch, command);

        const end = pos + command.copy_len;
        var covered = pos + 1;
        while (covered < end and covered + MIN_MATCH <= input.len) : (covered += 1) {
            const covered_bucket = hashAt(input, covered);
            prev[covered] = head[covered_bucket];
            head[covered_bucket] = @intCast(covered);
        }

        pos = end;
        lit_start = pos;
    }

    if (lit_start < input.len) {
        try commands.append(scratch, Command.insertOnly(lit_start, @intCast(input.len - lit_start)));
    }
}

fn encodeUncompressedInner(
    allocator: std.mem.Allocator,
    input: []const u8,
    wbits: u6,
) Inner![]u8 {
    var writer: BitWriter = .{};
    errdefer writer.deinit(allocator);

    try prefix_write.writeWindowBits(&writer, allocator, wbits);

    var offset: usize = 0;
    while (offset < input.len) {
        const chunk = @min(input.len - offset, tables.MAX_META_BLOCK_LEN);

        // ISLAST = 0, MLEN, ISUNCOMPRESSED = 1, then the raw bytes.
        try writer.writeBit(allocator, 0);
        try prefix_write.writeMetaBlockLen(&writer, allocator, chunk);
        try writer.writeBit(allocator, 1);
        writer.alignToByte();
        try writer.writeBytes(allocator, input[offset..][0..chunk]);

        offset += chunk;
    }

    try writeEmptyLast(&writer, allocator);

    return writer.toOwnedSlice(allocator);
}

fn encodeCompressedInner(
    allocator: std.mem.Allocator,
    input: []const u8,
    wbits: u6,
    params: Params,
) Inner![]u8 {
    if (input.len > tables.MAX_META_BLOCK_LEN) return Error.ZixUtils_BrotliEncoder_InputTooLarge;

    var writer: BitWriter = .{};
    errdefer writer.deinit(allocator);

    try prefix_write.writeWindowBits(&writer, allocator, wbits);

    if (input.len == 0) {
        try writeEmptyLast(&writer, allocator);

        return writer.toOwnedSlice(allocator);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const dict_index = try DictIndex.build(scratch);

    var commands: std.ArrayList(Command) = .empty;
    try parse(scratch, input, wbits, dict_index, params, &commands);

    // Dictionary references use the explicit code and leave the ring alone (sec 4, 8).
    const chosen = try scratch.alloc(distance.DistanceCode, commands.items.len);
    var ring: DistanceRing = .{};
    for (commands.items, 0..) |command, index| {
        if (!command.hasCopy()) continue;

        chosen[index] = if (command.is_dict)
            distance.explicitCode(command.distance)
        else
            distance.choose(&ring, command.distance);
    }

    var command_freq: [tables.COMMAND_ALPHABET]u32 = @splat(0);
    var distance_freq: [tables.DISTANCE_ALPHABET]u32 = @splat(0);
    for (commands.items, 0..) |command, index| {
        const insert_code = tables.selectInsertCode(command.insert_len);
        const copy_code: u8 = if (command.hasCopy()) tables.selectCopyCode(command.copy_len) else 0;

        command_freq[tables.composeCommandExplicit(insert_code, copy_code)] += 1;
        if (command.hasCopy()) distance_freq[chosen[index].code] += 1;
    }

    const lit_model = try LitModel.build(scratch, input, commands.items, params.literal_contexts);
    const command_code = try huffman.buildOptimalTree(scratch, &command_freq);
    const distance_code = try huffman.buildOptimalTree(scratch, &distance_freq);

    // Header: ISLAST, ISLASTEMPTY = 0, MLEN, NBLTYPESL/I/D = 1, NPOSTFIX = 0, NDIRECT = 0.
    try writer.writeBit(allocator, 1);
    try writer.writeBit(allocator, 0);
    try prefix_write.writeMetaBlockLen(&writer, allocator, input.len);
    try writer.writeBit(allocator, 0);
    try writer.writeBit(allocator, 0);
    try writer.writeBit(allocator, 0);
    try writer.writeInt(allocator, 0, 2);
    try writer.writeInt(allocator, 0, 4);

    if (lit_model.contexts) {
        try writer.writeInt(allocator, @intFromEnum(lit_model.mode), 2);
        try prefix_write.writeBlockTypeCount(&writer, allocator, lit_model.ntrees);
        try prefix_write.writeContextMap(&writer, allocator, &lit_model.cmap, lit_model.ntrees);
    } else {
        try writer.writeInt(allocator, @intFromEnum(context.ContextMode.LSB6), 2);
        try prefix_write.writeBlockTypeCount(&writer, allocator, 1);
    }
    // NTREESD = 1.
    try prefix_write.writeBlockTypeCount(&writer, allocator, 1);

    if (lit_model.contexts) {
        for (lit_model.trees) |tree| {
            try prefix_write.writeTreeCode(&writer, allocator, tree, tables.LITERAL_ALPHABET);
        }
    } else {
        try prefix_write.writeTreeCode(&writer, allocator, lit_model.flat, tables.LITERAL_ALPHABET);
    }
    try prefix_write.writeTreeCode(&writer, allocator, command_code, tables.COMMAND_ALPHABET);
    try prefix_write.writeTreeCode(&writer, allocator, distance_code, tables.DISTANCE_ALPHABET);

    for (commands.items, 0..) |command, index| {
        const insert_code = tables.selectInsertCode(command.insert_len);
        const copy_code: u8 = if (command.hasCopy()) tables.selectCopyCode(command.copy_len) else 0;
        const symbol = tables.composeCommandExplicit(insert_code, copy_code);

        try writer.writeCode(
            allocator,
            command_code.codes[symbol],
            @intCast(command_code.lengths[symbol]),
        );
        try writer.writeInt(
            allocator,
            command.insert_len - tables.INSERT_LEN_BASE[insert_code],
            tables.INSERT_LEN_EXTRA[insert_code],
        );

        // An insert-only command still carries a copy code. The decoder stops at MLEN.
        const copy_value: u32 = if (command.hasCopy()) command.copy_len else tables.COPY_LEN_BASE[0];
        try writer.writeInt(
            allocator,
            copy_value - tables.COPY_LEN_BASE[copy_code],
            tables.COPY_LEN_EXTRA[copy_code],
        );

        for (command.lit_off..command.lit_off + command.insert_len) |lit_pos| {
            const tree = lit_model.treeFor(input, lit_pos);
            const byte = input[lit_pos];

            try writer.writeCode(allocator, tree.codes[byte], @intCast(tree.lengths[byte]));
        }

        if (command.hasCopy()) {
            const code = chosen[index];

            try writer.writeCode(
                allocator,
                distance_code.codes[code.code],
                @intCast(distance_code.lengths[code.code]),
            );
            try writer.writeInt(allocator, code.extra, code.nextra);
        }
    }

    return writer.toOwnedSlice(allocator);
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_BrotliEncoder_InvalidWindowBits,
    ZixUtils_BrotliEncoder_InputTooLarge,
    ZixUtils_BrotliEncoder_OutOfMemory,
};

/// Encoder effort.
pub const Params = struct {
    /// Hash chain walk limit per position.
    max_chain: usize = MAX_CHAIN,
    /// Search the static dictionary.
    use_dict: bool = true,
    /// Try per-context literal trees.
    literal_contexts: bool = false,
};

/// Map a quality 0..11 to encoder effort. q0 is greedy with no dictionary. Higher q
/// widens the match search and turns the dictionary on.
///
/// Param:
/// quality - u8 (0..11, clamped)
///
/// Return:
/// - Params
pub fn qualityParams(quality: u8) Params {
    const clamped = @min(quality, 11);

    if (clamped == 0) {
        return .{
            .max_chain = 1,
            .use_dict = false,
        };
    }

    return .{
        .max_chain = @as(usize, 1) << @intCast(@min(clamped, 9)),
        .use_dict = clamped >= 2,
    };
}

/// Encode input as uncompressed meta-blocks (store only). Never larger than the
/// input plus a small header.
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// input - []const u8 (bytes to store)
/// wbits - u6 (window log, 10..24)
///
/// Return:
/// - []u8 (a valid brotli stream)
/// - Error.ZixUtils_BrotliEncoder_InvalidWindowBits outside 10..24
/// - Error.ZixUtils_BrotliEncoder_OutOfMemory
pub fn encodeUncompressedAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    wbits: u6,
) Error![]u8 {
    return encodeUncompressedInner(allocator, input, wbits) catch |err| innerError(err);
}

/// Encode input as one compressed meta-block.
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice, and a transient arena)
/// input - []const u8 (bytes to compress, at most 16 MiB)
/// wbits - u6 (window log, 10..24)
/// params - Params (effort)
///
/// Return:
/// - []u8 (a valid brotli stream)
/// - Error.ZixUtils_BrotliEncoder_InputTooLarge past 16 MiB
/// - Error.ZixUtils_BrotliEncoder_InvalidWindowBits outside 10..24
/// - Error.ZixUtils_BrotliEncoder_OutOfMemory
pub fn encodeCompressedAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    wbits: u6,
    params: Params,
) Error![]u8 {
    return encodeCompressedInner(allocator, input, wbits, params) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Decoder = @import("Decoder.zig");

fn decodeAll(stream: []const u8) Decoder.Error![]u8 {
    var decoder = Decoder.init(std.testing.allocator, stream, 1 << 20);
    defer decoder.deinit();

    return decoder.run();
}

test "zix utils compression brotli: encoder, qualityParams q0 has no dictionary" {
    const params = qualityParams(0);

    try std.testing.expectEqual(@as(usize, 1), params.max_chain);
    try std.testing.expect(!params.use_dict);
}

test "zix utils compression brotli: encoder, qualityParams clamps past 11" {
    const params = qualityParams(200);

    try std.testing.expectEqual(@as(usize, 512), params.max_chain);
    try std.testing.expect(params.use_dict);
}

test "zix utils compression brotli: encoder, store round-trips" {
    const input = "stored bytes, no compression";

    const stream = try encodeUncompressedAlloc(std.testing.allocator, input, 22);
    defer std.testing.allocator.free(stream);

    const back = try decodeAll(stream);
    defer std.testing.allocator.free(back);

    try std.testing.expectEqualStrings(input, back);
}

test "zix utils compression brotli: encoder, store of empty input round-trips" {
    const stream = try encodeUncompressedAlloc(std.testing.allocator, "", 22);
    defer std.testing.allocator.free(stream);

    const back = try decodeAll(stream);
    defer std.testing.allocator.free(back);

    try std.testing.expectEqual(@as(usize, 0), back.len);
}

test "zix utils compression brotli: encoder, compressed round-trips" {
    const input = "the quick brown fox jumps over the lazy dog. the quick brown fox.";

    const stream = try encodeCompressedAlloc(std.testing.allocator, input, 22, .{});
    defer std.testing.allocator.free(stream);

    const back = try decodeAll(stream);
    defer std.testing.allocator.free(back);

    try std.testing.expectEqualStrings(input, back);
}

test "zix utils compression brotli: encoder, dictionary words round-trip" {
    const input = "information about the world and the people in the government";

    const stream = try encodeCompressedAlloc(std.testing.allocator, input, 22, .{});
    defer std.testing.allocator.free(stream);

    const back = try decodeAll(stream);
    defer std.testing.allocator.free(back);

    try std.testing.expectEqualStrings(input, back);
}

test "zix utils compression brotli: encoder, context model round-trips" {
    var input: [4096]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = if (i % 8 == 0) 'a' else 'b';

    const stream = try encodeCompressedAlloc(std.testing.allocator, &input, 22, .{
        .literal_contexts = true,
    });
    defer std.testing.allocator.free(stream);

    const back = try decodeAll(stream);
    defer std.testing.allocator.free(back);

    try std.testing.expectEqualSlices(u8, &input, back);
}

test "zix utils compression brotli: encoder, window bits 9 is invalid" {
    try std.testing.expectError(
        Error.ZixUtils_BrotliEncoder_InvalidWindowBits,
        encodeCompressedAlloc(std.testing.allocator, "abc", 9, .{}),
    );
}

test "zix utils compression brotli: encoder, failing allocator is out of memory" {
    try std.testing.expectError(
        Error.ZixUtils_BrotliEncoder_OutOfMemory,
        encodeUncompressedAlloc(std.testing.failing_allocator, "abc", 22),
    );
}

