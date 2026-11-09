//! ZIX utils compression brotli
//!
//! ### file: src/zix/utils/compression/brotli/brotli.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Brotli codec (RFC 7932): compress and decompress bytes, in a caller buffer or
//! a fresh allocation.
//! 
//! ### note:
//! 
//! std.compress has no brotli, so the codec is written from the RFC.
//! The encoder always also tries a store-only stream and keeps the smaller one, so
//! the output never grows past the input plus a small header.
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
const Decoder = @import("Decoder.zig");
const Level = @import("../level.zig").Level;
const encoder = @import("encoder.zig");
const tables = @import("tables.zig");

// --------------------------------------------------------- //
// Private:

/// Window log written to the stream header: 4 MiB, the brotli CLI default.
const DEFAULT_WBITS: u6 = 22;

fn encoderError(err: encoder.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixUtils_BrotliEncoder_InvalidWindowBits => Error.ZixUtils_Brotli_InvalidWindowBits,
        error.ZixUtils_BrotliEncoder_InputTooLarge => Error.ZixUtils_Brotli_InputTooLarge,
        error.ZixUtils_BrotliEncoder_OutOfMemory => Error.ZixUtils_Brotli_OutOfMemory,
    };
}

fn decoderError(err: Decoder.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixUtils_BrotliDecoder_Truncated => Error.ZixUtils_Brotli_Truncated,
        error.ZixUtils_BrotliDecoder_Malformed => Error.ZixUtils_Brotli_Malformed,
        error.ZixUtils_BrotliDecoder_OutputTooLarge => Error.ZixUtils_Brotli_OutputTooLarge,
        error.ZixUtils_BrotliDecoder_OutOfMemory => Error.ZixUtils_Brotli_OutOfMemory,
    };
}

/// Keep the smaller of best and candidate, freeing the other.
fn keepSmaller(allocator: std.mem.Allocator, best: []u8, candidate: []u8) []u8 {
    if (candidate.len < best.len) {
        allocator.free(best);

        return candidate;
    }

    allocator.free(candidate);

    return best;
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_Brotli_InvalidWindowBits,
    ZixUtils_Brotli_InputTooLarge,
    ZixUtils_Brotli_BufferTooSmall,
    ZixUtils_Brotli_Truncated,
    ZixUtils_Brotli_Malformed,
    ZixUtils_Brotli_OutputTooLarge,
    ZixUtils_Brotli_OutOfMemory,
};

/// Upper bound on the compressed size for an input length.
///
/// Note:
/// - The store fallback keeps the output within the input plus the per meta-block
///   framing. This is a stronger bound than flate.compressBound.
///
/// Param:
/// input_len - usize (uncompressed byte count)
///
/// Return:
/// - usize
pub fn compressBound(input_len: usize) usize {
    const blocks = input_len / tables.MAX_META_BLOCK_LEN + 1;

    return input_len + 6 * blocks + 16;
}

/// Compress at an explicit quality and window, never larger than a store.
///
/// Note:
/// - With the dictionary on it also tries without it and keeps the smaller.
/// - From quality 5 it also tries literal context trees and keeps the smaller.
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// data - []const u8 (bytes to compress, at most 16 MiB)
/// quality - u8 (0..11, clamped)
/// wbits - u6 (window log, 10..24)
///
/// Return:
/// - []u8 (a valid brotli stream)
/// - Error.ZixUtils_Brotli_InvalidWindowBits outside 10..24
/// - Error.ZixUtils_Brotli_InputTooLarge past 16 MiB
/// - Error.ZixUtils_Brotli_OutOfMemory
pub fn compressQualityAlloc(
    allocator: std.mem.Allocator,
    data: []const u8,
    quality: u8,
    wbits: u6,
) Error![]u8 {
    const params = encoder.qualityParams(quality);

    var best = encoder.encodeCompressedAlloc(allocator, data, wbits, params) catch |err| {
        return encoderError(err);
    };
    errdefer allocator.free(best);

    if (params.use_dict) {
        const no_dict = encoder.encodeCompressedAlloc(allocator, data, wbits, .{
            .max_chain = params.max_chain,
            .use_dict = false,
        }) catch |err| return encoderError(err);
        best = keepSmaller(allocator, best, no_dict);
    }

    if (quality >= 5) {
        const with_contexts = encoder.encodeCompressedAlloc(allocator, data, wbits, .{
            .max_chain = params.max_chain,
            .use_dict = params.use_dict,
            .literal_contexts = true,
        }) catch |err| return encoderError(err);
        best = keepSmaller(allocator, best, with_contexts);
    }

    const stored = encoder.encodeUncompressedAlloc(allocator, data, wbits) catch |err| {
        return encoderError(err);
    };

    return keepSmaller(allocator, best, stored);
}

/// Compress into a fresh brotli stream at the shared Level.
///
/// Note:
/// - FASTEST is quality 5, DEFAULT is quality 9. Both stay under q11.
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// data - []const u8 (bytes to compress)
/// level - Level (effort)
///
/// Return:
/// - []u8 (a valid brotli stream)
/// - Error from compressQualityAlloc
pub fn compressBrotliAlloc(allocator: std.mem.Allocator, data: []const u8, level: Level) Error![]u8 {
    const quality: u8 = switch (level) {
        .FASTEST => 5,
        .DEFAULT => 9,
    };

    return compressQualityAlloc(allocator, data, quality, DEFAULT_WBITS);
}

/// Compress into a caller buffer at the shared Level.
///
/// Note:
/// - The encoder keeps the smallest of several variants, so it compresses through
///   compressBrotliAlloc and copies the result in.
///
/// Param:
/// allocator - std.mem.Allocator (transient codec scratch, freed before return)
/// data - []const u8 (bytes to compress)
/// out_buf - []u8 (destination, sized with compressBound)
/// level - Level (effort)
///
/// Return:
/// - usize (compressed byte count written into out_buf)
/// - Error.ZixUtils_Brotli_BufferTooSmall when out_buf cannot hold the result
pub fn compressBrotli(
    allocator: std.mem.Allocator,
    data: []const u8,
    out_buf: []u8,
    level: Level,
) Error!usize {
    const stream = try compressBrotliAlloc(allocator, data, level);
    defer allocator.free(stream);

    if (out_buf.len < stream.len) return Error.ZixUtils_Brotli_BufferTooSmall;

    @memcpy(out_buf[0..stream.len], stream);

    return stream.len;
}

/// Decompress into a fresh buffer, capped at max_out (bomb guard).
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// compressed - []const u8 (brotli stream)
/// max_out - usize (largest output accepted)
///
/// Return:
/// - []u8 (the decoded bytes)
/// - Error.ZixUtils_Brotli_OutputTooLarge past max_out
/// - Error.ZixUtils_Brotli_Truncated or Malformed on a bad stream
pub fn decompressBrotliAlloc(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    max_out: usize,
) Error![]u8 {
    var decoder = Decoder.init(allocator, compressed, max_out);
    defer decoder.deinit();

    return decoder.run() catch |err| decoderError(err);
}

/// Decompress into a caller buffer.
///
/// Param:
/// allocator - std.mem.Allocator (transient decoder state, freed before return)
/// compressed - []const u8 (brotli stream)
/// out_buf - []u8 (destination)
///
/// Return:
/// - usize (decoded byte count written into out_buf)
/// - Error.ZixUtils_Brotli_BufferTooSmall when the output does not fit
/// - Error.ZixUtils_Brotli_Truncated or Malformed on a bad stream
pub fn decompressBrotli(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    out_buf: []u8,
) Error!usize {
    const decoded = decompressBrotliAlloc(allocator, compressed, out_buf.len) catch |err| {
        return switch (err) {
            Error.ZixUtils_Brotli_OutputTooLarge => Error.ZixUtils_Brotli_BufferTooSmall,
            else => err,
        };
    };
    defer allocator.free(decoded);

    @memcpy(out_buf[0..decoded.len], decoded);

    return decoded.len;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn roundTripQuality(input: []const u8, quality: u8, wbits: u6) !void {
    const stream = try compressQualityAlloc(std.testing.allocator, input, quality, wbits);
    defer std.testing.allocator.free(stream);

    const back = try decompressBrotliAlloc(std.testing.allocator, stream, 1 << 20);
    defer std.testing.allocator.free(back);

    try std.testing.expectEqualSlices(u8, input, back);
}

fn repeated(comptime unit: []const u8, comptime times: usize) [unit.len * times]u8 {
    var out: [unit.len * times]u8 = undefined;
    for (0..times) |i| @memcpy(out[i * unit.len ..][0..unit.len], unit);

    return out;
}

test "zix utils compression brotli: brotli, empty input round-trips at every quality" {
    for (0..12) |quality| try roundTripQuality("", @intCast(quality), 22);
}

test "zix utils compression brotli: brotli, short ascii round-trips at every quality" {
    const text = "the quick brown fox jumps over the lazy dog";

    for (0..12) |quality| try roundTripQuality(text, @intCast(quality), 22);
}

test "zix utils compression brotli: brotli, every byte value round-trips" {
    var input: [256]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = @intCast(i);

    try roundTripQuality(&input, 5, 18);
}

test "zix utils compression brotli: brotli, repetitive text shrinks below a quarter" {
    const input = repeated("the quick brown fox jumps over the lazy dog. ", 80);

    const stream = try compressQualityAlloc(std.testing.allocator, &input, 9, 22);
    defer std.testing.allocator.free(stream);

    try std.testing.expect(stream.len < input.len / 4);
}

test "zix utils compression brotli: brotli, dictionary path round-trips English text" {
    try roundTripQuality("information about the world and the people in the government", 9, 22);
    try roundTripQuality("The quick brown fox and the lazy dog went to the market.", 9, 22);
}

test "zix utils compression brotli: brotli, random data stays within the store overhead" {
    var input: [8192]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = @truncate((i *% 2654435761) >> 11);

    const stream = try compressQualityAlloc(std.testing.allocator, &input, 9, 22);
    defer std.testing.allocator.free(stream);

    try std.testing.expect(stream.len <= input.len + 8);
}

test "zix utils compression brotli: brotli, quality 9 is no worse than quality 0" {
    const input = repeated("lorem ipsum dolor sit amet ", 100);

    const low = try compressQualityAlloc(std.testing.allocator, &input, 0, 22);
    defer std.testing.allocator.free(low);
    const high = try compressQualityAlloc(std.testing.allocator, &input, 9, 22);
    defer std.testing.allocator.free(high);

    try std.testing.expect(high.len <= low.len);
}

test "zix utils compression brotli: brotli, long input round-trips at quality 11" {
    var input: [50000]u8 = undefined;
    const unit = "abcdefghij";
    for (&input, 0..) |*byte, i| byte.* = unit[i % unit.len];

    try roundTripQuality(&input, 11, 24);
}

test "zix utils compression brotli: brotli, both levels round-trip" {
    const text = repeated("facade roundtrip over the brotli codec, repeated. ", 2);

    inline for (.{ Level.FASTEST, Level.DEFAULT }) |level| {
        const stream = try compressBrotliAlloc(std.testing.allocator, &text, level);
        defer std.testing.allocator.free(stream);

        const back = try decompressBrotliAlloc(std.testing.allocator, stream, 1 << 16);
        defer std.testing.allocator.free(back);

        try std.testing.expectEqualSlices(u8, &text, back);
    }
}

test "zix utils compression brotli: brotli, window bits 9 is invalid" {
    try std.testing.expectError(
        Error.ZixUtils_Brotli_InvalidWindowBits,
        compressQualityAlloc(std.testing.allocator, "abc", 5, 9),
    );
}

test "zix utils compression brotli: brotli, window bits 25 is invalid" {
    try std.testing.expectError(
        Error.ZixUtils_Brotli_InvalidWindowBits,
        compressQualityAlloc(std.testing.allocator, "abc", 5, 25),
    );
}

test "zix utils compression brotli: brotli, decode past the cap is too large" {
    const input = repeated("compressible repeated body ", 50);

    const stream = try compressQualityAlloc(std.testing.allocator, &input, 9, 22);
    defer std.testing.allocator.free(stream);

    try std.testing.expectError(
        Error.ZixUtils_Brotli_OutputTooLarge,
        decompressBrotliAlloc(std.testing.allocator, stream, 16),
    );
}

test "zix utils compression brotli: brotli, cut stream is truncated" {
    const input = repeated("a compressible body that needs a real prefix code ", 40);

    const stream = try compressQualityAlloc(std.testing.allocator, &input, 9, 22);
    defer std.testing.allocator.free(stream);

    try std.testing.expectError(
        Error.ZixUtils_Brotli_Truncated,
        decompressBrotliAlloc(std.testing.allocator, stream[0 .. stream.len / 2], 1 << 20),
    );
}

test "zix utils compression brotli: brotli, compressBound holds for random input" {
    var input: [4096]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = @truncate((i *% 40503) >> 7);

    const stream = try compressQualityAlloc(std.testing.allocator, &input, 9, 22);
    defer std.testing.allocator.free(stream);

    try std.testing.expect(stream.len <= compressBound(input.len));
}

test "zix utils compression brotli: brotli, caller buffers round-trip" {
    const input = repeated("information about the world and the people, repeated. ", 2);

    var comp_buf: [256]u8 = undefined;
    const written = try compressBrotli(std.testing.allocator, &input, &comp_buf, .DEFAULT);

    var out_buf: [256]u8 = undefined;
    const inflated = try decompressBrotli(std.testing.allocator, comp_buf[0..written], &out_buf);

    try std.testing.expectEqualSlices(u8, &input, out_buf[0..inflated]);
}

test "zix utils compression brotli: brotli, caller buffers round-trip empty input" {
    var comp_buf: [64]u8 = undefined;
    const written = try compressBrotli(std.testing.allocator, "", &comp_buf, .DEFAULT);

    var out_buf: [8]u8 = undefined;
    const inflated = try decompressBrotli(std.testing.allocator, comp_buf[0..written], &out_buf);

    try std.testing.expectEqual(@as(usize, 0), inflated);
}

test "zix utils compression brotli: brotli, compress one byte short is too small" {
    const input = "boundary text that compresses to a stable length under the default effort.";

    const reference = try compressBrotliAlloc(std.testing.allocator, input, .DEFAULT);
    defer std.testing.allocator.free(reference);

    const exact = try std.testing.allocator.alloc(u8, reference.len);
    defer std.testing.allocator.free(exact);
    const short = try std.testing.allocator.alloc(u8, reference.len - 1);
    defer std.testing.allocator.free(short);

    try std.testing.expectEqual(
        reference.len,
        try compressBrotli(std.testing.allocator, input, exact, .DEFAULT),
    );
    try std.testing.expectError(
        Error.ZixUtils_Brotli_BufferTooSmall,
        compressBrotli(std.testing.allocator, input, short, .DEFAULT),
    );
}

test "zix utils compression brotli: brotli, decompress one byte short is too small" {
    const input = "boundary text that round-trips to a known length after inflation.";

    const stream = try compressBrotliAlloc(std.testing.allocator, input, .DEFAULT);
    defer std.testing.allocator.free(stream);

    var exact: [input.len]u8 = undefined;
    var short: [input.len - 1]u8 = undefined;

    try std.testing.expectEqual(
        input.len,
        try decompressBrotli(std.testing.allocator, stream, &exact),
    );
    try std.testing.expectError(
        Error.ZixUtils_Brotli_BufferTooSmall,
        decompressBrotli(std.testing.allocator, stream, &short),
    );
}

test "zix utils compression brotli: brotli, buffer and alloc variants write the same bytes" {
    const input = "the buffer-into and alloc variants must produce identical brotli streams.";

    const reference = try compressBrotliAlloc(std.testing.allocator, input, .DEFAULT);
    defer std.testing.allocator.free(reference);

    var buf: [256]u8 = undefined;
    const written = try compressBrotli(std.testing.allocator, input, &buf, .DEFAULT);

    try std.testing.expectEqualSlices(u8, reference, buf[0..written]);
}

test "zix utils compression brotli: brotli, decodes a brotli CLI vector" {
    const vector = "\x1f\xef\x00\xf8\x8d\x94\x6e\xe6\xa2\x06\x31\xa3\xc3\x53\x68\x6f" ++
        "\x39\xc8\x24\xa3\xe5\x08\xdb\x74\x54\x16\x48\xd7\x16\x0f";
    const expected = repeated("the quick brown fox ", 12);

    const back = try decompressBrotliAlloc(std.testing.allocator, vector, 1024);
    defer std.testing.allocator.free(back);

    try std.testing.expectEqualSlices(u8, &expected, back);
}

test "zix utils compression brotli: brotli, failing allocator is out of memory" {
    try std.testing.expectError(
        Error.ZixUtils_Brotli_OutOfMemory,
        compressBrotliAlloc(std.testing.failing_allocator, "abc", .DEFAULT),
    );
}

