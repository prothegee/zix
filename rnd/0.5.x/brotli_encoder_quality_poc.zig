//! Brotli encoder PoC, phase E7 (RFC 7932), quality levels and a never-expand fallback.
//!
//! Note:
//! - Builds on E6 (rnd/0.5.x/brotli_encoder_dictref_poc.zig), the full compressed pipeline.
//!   E7 is the public front-end: a quality level 0..11 maps to encoder effort, and the
//!   encoder always also produces an E1 store-only stream and returns whichever is smaller,
//!   so the output never grows beyond the input plus the store header (the guarantee a
//!   response compressor needs on already-compressed or random bodies).
//! - Quality ladder: q0 is greedy nearest-match with no dictionary, higher q widens the
//!   hash-chain walk and turns the dictionary on. A response compressor wants a modest level
//!   (about q5), not q11, which is why the ladder tops out at a bounded chain depth.
//! - Block splitting (several meta-blocks with their own trees inside one stream) is the
//!   remaining E7 ratio refinement, deferred; this PoC keeps the single optimal-code block
//!   from E5 / E6 and adds the quality knob and the store fallback.
//! - Verified by self round-trip through the full decoder (brotli_conformance_poc.zig) and
//!   the `brotli -dc` interop gate (rnd/0.5.x/verify-brotli-encoder-quality.sh).
//!
//! Run: zig run rnd/0.5.x/brotli_encoder_quality_poc.zig
//!      zig run rnd/0.5.x/brotli_encoder_quality_poc.zig -- <input> <output.br> [quality]

const std = @import("std");
const e1 = @import("brotli_encoder_poc.zig");
const e2 = @import("brotli_encoder_literal_poc.zig");
const e6 = @import("brotli_encoder_dictref_poc.zig");
const decoder = @import("brotli_conformance_poc.zig");

const EncodeError = e6.EncodeError;

/// Map a quality 0..11 to encoder effort (sec note: a response compressor needs a modest
/// level). q0 is greedy with no dictionary; higher q widens the match search and uses the
/// dictionary. The chain depth is bounded so the top of the ladder stays cheap.
pub fn qualityParams(quality: u8) e6.Params {
    const q = @min(quality, 11);

    if (q == 0) return .{ .max_chain = 1, .use_dict = false };

    return .{
        .max_chain = @as(usize, 1) << @intCast(@min(q, 9)),
        .use_dict = q >= 2,
    };
}

/// Compress input to a brotli stream at the given quality, never larger than an E1 store of
/// the same input. Caller owns the returned slice.
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// input - []const u8 (bytes to compress, at most 2^24)
/// quality - u8 (0..11, clamped)
/// wbits - u6 (window log, 10..24)
///
/// Return:
/// - []u8 (a valid brotli stream, caller frees)
/// - error.InputTooLarge / error.InvalidWindowBits / error.OutOfMemory
pub fn compressBrotliAlloc(allocator: std.mem.Allocator, input: []const u8, quality: u8, wbits: u6) EncodeError![]u8 {
    const params = qualityParams(quality);

    var best = try e6.encodeDictRefBlockAlloc(allocator, input, wbits, params);
    errdefer allocator.free(best);

    // a dictionary reference can cost more than literals when the word repeats locally, so
    // when the dictionary is on, also try it off and keep the smaller (real brotli cost-models
    // this; the PoC just encodes both).
    if (params.use_dict) {
        const no_dict = try e6.encodeDictRefBlockAlloc(allocator, input, wbits, .{ .max_chain = params.max_chain, .use_dict = false });
        if (no_dict.len < best.len) {
            allocator.free(best);
            best = no_dict;
        } else {
            allocator.free(no_dict);
        }
    }

    const stored = try e1.encodeUncompressedAlloc(allocator, input, wbits, e2.MAX_META_BLOCK_LEN);
    if (stored.len < best.len) {
        allocator.free(best);
        return stored;
    }

    allocator.free(stored);
    return best;
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
        const quality: u8 = if (arg_iter.next()) |q| (std.fmt.parseInt(u8, q, 10) catch 5) else 5;

        const io = process.io;
        const cwd = std.Io.Dir.cwd();

        const input = try cwd.readFileAlloc(io, input_path.?, allocator, .unlimited);
        const stream = try compressBrotliAlloc(allocator, input, quality, 22);

        const f = try cwd.createFile(io, output_path.?, .{});
        defer f.close(io);

        var write_buf: [8192]u8 = undefined;
        var writer = f.writer(io, &write_buf);
        try writer.interface.writeAll(stream);
        try writer.interface.flush();

        return;
    }

    const sample = "the quick brown fox jumps over the lazy dog. the quick brown fox jumps again.";
    var q: u8 = 0;
    while (q <= 11) : (q += 2) {
        const stream = try compressBrotliAlloc(allocator, sample, q, 22);
        const back = try decoder.decode(allocator, stream);

        const verdict = if (std.mem.eql(u8, back, sample)) "OK" else "MISMATCH";
        std.debug.print("[q{d:>2}] {d} bytes -> {d} bytes {s}\n", .{ q, sample.len, stream.len, verdict });
    }
}

// --------------------------------------------------------- //
// test cases
// --------------------------------------------------------- //

const testing = std.testing;

fn roundTripAt(input: []const u8, quality: u8, wbits: u6) !void {
    const stream = try compressBrotliAlloc(testing.allocator, input, quality, wbits);
    defer testing.allocator.free(stream);

    const back = try decoder.decode(testing.allocator, stream);
    defer testing.allocator.free(back);

    try testing.expectEqualSlices(u8, input, back);
}

test "quality params ladder is monotonic in effort" {
    try testing.expectEqual(@as(usize, 1), qualityParams(0).max_chain);
    try testing.expect(!qualityParams(0).use_dict);
    try testing.expect(qualityParams(5).max_chain > qualityParams(1).max_chain);
    try testing.expect(qualityParams(5).use_dict);
    // clamps above 11.
    try testing.expectEqual(qualityParams(11).max_chain, qualityParams(50).max_chain);
}

test "round-trips at every quality" {
    const text = "the government of the people, by the people, for the people, shall not perish";
    var q: u8 = 0;
    while (q <= 11) : (q += 1) try roundTripAt(text, q, 22);
}

test "empty and tiny inputs round-trip" {
    try roundTripAt("", 5, 22);
    try roundTripAt("x", 5, 22);
    try roundTripAt("ab", 0, 22);
}

test "random data never expands beyond the store overhead" {
    var input: [8192]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @truncate((i *% 2654435761) >> 11);

    const stream = try compressBrotliAlloc(testing.allocator, &input, 9, 22);
    defer testing.allocator.free(stream);

    // the store fallback bounds the output at the input size plus a tiny header.
    try testing.expect(stream.len <= input.len + 8);

    const back = try decoder.decode(testing.allocator, stream);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, &input, back);
}

test "higher quality is no worse than quality 0 on repetitive data" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var r: usize = 0;
    while (r < 100) : (r += 1) try buf.appendSlice(testing.allocator, "lorem ipsum dolor sit amet ");

    const q0 = try compressBrotliAlloc(testing.allocator, buf.items, 0, 22);
    defer testing.allocator.free(q0);
    const q9 = try compressBrotliAlloc(testing.allocator, buf.items, 9, 22);
    defer testing.allocator.free(q9);

    try testing.expect(q9.len <= q0.len);
}

test "binary and full-alphabet inputs round-trip at a modest quality" {
    var bin: [3000]u8 = undefined;
    for (&bin, 0..) |*b, i| b.* = @truncate((i * 131 + 7) ^ (i >> 3));
    try roundTripAt(&bin, 5, 22);

    var alpha: [256]u8 = undefined;
    for (&alpha, 0..) |*b, i| b.* = @intCast(i);
    try roundTripAt(&alpha, 5, 18);
}

test "long repetitive input round-trips at high quality" {
    var input: [50000]u8 = undefined;
    const unit = "abcdefghij";
    for (&input, 0..) |*b, i| b.* = unit[i % unit.len];

    try roundTripAt(&input, 11, 24);
}
