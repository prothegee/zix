//! Brotli encoder PoC, phase E1 (RFC 7932), the store-only mode of the std-gap encoder.
//!
//! Note:
//! - std ships NO brotli, so the encoder is authored from RFC 7932 alongside the decoder
//!   (rnd/0.5.x/brotli_decoder_poc.zig). E1 is the smallest valid encoder: it emits a
//!   stream made only of UNCOMPRESSED meta-blocks (ISUNCOMPRESSED=1, sec 9.2) followed by
//!   an empty last meta-block. Zero compression, but it proves the encoder framing (the
//!   LSB-first bit writer, the stream header, the meta-block header) and round-trips
//!   through both the zix decoder and the system `brotli -dc`.
//! - Layout emitted, mirroring what the decoder PoC parses:
//!   stream header WBITS (sec 9.1), then for each up-to-2^24-byte chunk a non-last
//!   meta-block (ISLAST=0, MNIBBLES/MLEN, ISUNCOMPRESSED=1, byte-align, MLEN literal
//!   bytes), then a final empty meta-block (ISLAST=1, ISLASTEMPTY=1).
//! - Next phases (rnd/0.5.x/brotli-plan.md): E2 literal-only compressed blocks, then the
//!   matching / dictionary / quality work.
//!
//! Run: zig run rnd/0.5.x/brotli_encoder_poc.zig

const std = @import("std");

/// MLEN caps at 2^24 (sec 9.2: at most 6 nibbles encode MLEN - 1), so one uncompressed
/// meta-block carries at most 16 MiB. Larger input is split across several meta-blocks.
const MAX_META_BLOCK_LEN: usize = 1 << 24;

const EncodeError = error{
    InvalidWindowBits,
    OutOfMemory,
};

const DecodeError = error{
    EndOfStream,
    Truncated,
    OutTooSmall,
    NotUncompressed,
};

/// LSB-first bit writer: brotli packs bits from the least-significant bit of each byte,
/// the exact inverse of the decoder's BitReader.
const BitWriter = struct {
    bytes: std.ArrayList(u8) = .empty,
    bit_pos: u3 = 0,

    fn deinit(self: *BitWriter, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }

    fn writeBit(self: *BitWriter, allocator: std.mem.Allocator, bit: u1) EncodeError!void {
        if (self.bit_pos == 0) try self.bytes.append(allocator, 0);

        const idx = self.bytes.items.len - 1;
        self.bytes.items[idx] |= @as(u8, bit) << self.bit_pos;
        self.bit_pos = if (self.bit_pos == 7) 0 else self.bit_pos + 1;
    }

    fn writeBits(self: *BitWriter, allocator: std.mem.Allocator, value: u32, n: u6) EncodeError!void {
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            try self.writeBit(allocator, @truncate(value >> @intCast(i)));
        }
    }

    /// Advance to the next byte boundary, leaving the skipped bits as zero padding. The
    /// next writeBit then starts a fresh byte, matching the decoder's alignToByte.
    fn alignToByte(self: *BitWriter) void {
        if (self.bit_pos != 0) self.bit_pos = 0;
    }

    /// Append whole bytes. Only valid right after alignToByte (the writer is byte-aligned).
    fn writeBytes(self: *BitWriter, allocator: std.mem.Allocator, data: []const u8) EncodeError!void {
        try self.bytes.appendSlice(allocator, data);
    }

    fn toOwnedSlice(self: *BitWriter, allocator: std.mem.Allocator) EncodeError![]u8 {
        return self.bytes.toOwnedSlice(allocator);
    }
};

/// Emit the stream header window size, the inverse of the decoder's readWindowBits
/// (RFC 7932 section 9.1).
///
/// Param:
/// wbits - u6 (window log, valid range 10..24)
///
/// Return:
/// - void
/// - error.InvalidWindowBits if wbits is outside 10..24
fn writeWindowBits(bw: *BitWriter, allocator: std.mem.Allocator, wbits: u6) EncodeError!void {
    if (wbits < 10 or wbits > 24) return error.InvalidWindowBits;

    if (wbits == 16) {
        try bw.writeBit(allocator, 0);
        return;
    }

    try bw.writeBit(allocator, 1);

    if (wbits >= 18 and wbits <= 24) {
        try bw.writeBits(allocator, wbits - 17, 3);
        return;
    }

    // wbits == 17 encodes as the all-zero escape (n1 = 0, n2 = 0); 10..15 set n2 = wbits - 8.
    try bw.writeBits(allocator, 0, 3);
    if (wbits == 17) {
        try bw.writeBits(allocator, 0, 3);
        return;
    }

    try bw.writeBits(allocator, wbits - 8, 3);
}

/// Emit MNIBBLES + (MLEN - 1) for one uncompressed meta-block (RFC 7932 section 9.2).
/// The nibble count is the minimal that holds MLEN - 1, which also satisfies the rule that
/// for more than 4 nibbles the most-significant nibble must be non-zero.
fn writeMetaBlockLen(bw: *BitWriter, allocator: std.mem.Allocator, mlen: usize) EncodeError!void {
    const value: u32 = @intCast(mlen - 1);

    const nibbles: u6 = if (value < (1 << 16)) 4 else if (value < (1 << 20)) 5 else 6;

    try bw.writeBits(allocator, nibbles - 4, 2);
    try bw.writeBits(allocator, value, nibbles * 4);
}

/// Encode input as a brotli stream of uncompressed meta-blocks (phase E1, store-only).
///
/// Note:
/// - max_block_len lets tests force a multi-meta-block split below the 16 MiB cap. Pass
///   MAX_META_BLOCK_LEN for the real maximum.
/// - empty input yields just the stream header plus the empty last meta-block.
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// input - []const u8 (the literal bytes to store)
/// wbits - u6 (window log written to the stream header, 10..24)
/// max_block_len - usize (largest meta-block body, clamped to MAX_META_BLOCK_LEN)
///
/// Return:
/// - []u8 (a valid brotli stream, caller frees)
/// - error.InvalidWindowBits / error.OutOfMemory
pub fn encodeUncompressedAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    wbits: u6,
    max_block_len: usize,
) EncodeError![]u8 {
    const block_cap = @min(@max(max_block_len, 1), MAX_META_BLOCK_LEN);

    var bw: BitWriter = .{};
    errdefer bw.deinit(allocator);

    try writeWindowBits(&bw, allocator, wbits);

    var offset: usize = 0;
    while (offset < input.len) {
        const chunk = @min(input.len - offset, block_cap);

        try bw.writeBit(allocator, 0); // ISLAST = 0
        try writeMetaBlockLen(&bw, allocator, chunk);
        try bw.writeBit(allocator, 1); // ISUNCOMPRESSED = 1

        bw.alignToByte();
        try bw.writeBytes(allocator, input[offset..][0..chunk]);

        offset += chunk;
    }

    // empty last meta-block: ISLAST = 1, ISLASTEMPTY = 1 (sec 9.2). Any trailing bits in
    // the final byte stay zero, which the decoder requires.
    try bw.writeBit(allocator, 1);
    try bw.writeBit(allocator, 1);

    return bw.toOwnedSlice(allocator);
}

/// LSB-first bit reader, the subset of the decoder needed to self-check the encoder's
/// uncompressed output (full decoding lives in brotli_decoder_poc.zig).
const BitReader = struct {
    bytes: []const u8,
    byte_pos: usize = 0,
    bit_pos: u3 = 0,

    fn readBit(self: *BitReader) DecodeError!u1 {
        if (self.byte_pos >= self.bytes.len) return error.EndOfStream;

        const bit: u1 = @truncate(self.bytes[self.byte_pos] >> self.bit_pos);
        if (self.bit_pos == 7) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        } else {
            self.bit_pos += 1;
        }

        return bit;
    }

    fn readBits(self: *BitReader, n: u6) DecodeError!u32 {
        var value: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            value |= @as(u32, try self.readBit()) << @intCast(i);
        }

        return value;
    }

    fn alignToByte(self: *BitReader) void {
        if (self.bit_pos != 0) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }
    }
};

fn readWindowBits(br: *BitReader) DecodeError!u6 {
    if (try br.readBit() == 0) return 16;

    const n1 = try br.readBits(3);
    if (n1 != 0) return @intCast(17 + n1);

    const n2 = try br.readBits(3);
    if (n2 != 0) return @intCast(8 + n2);

    return 17;
}

/// Decode a stream that contains only uncompressed (and empty) meta-blocks back to bytes.
/// Rejects a compressed meta-block with error.NotUncompressed, so it doubles as a check
/// that E1 truly emitted store-only output.
fn decodeUncompressedAlloc(allocator: std.mem.Allocator, stream: []const u8) (DecodeError || error{OutOfMemory})![]u8 {
    var br = BitReader{ .bytes = stream };

    _ = try readWindowBits(&br);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    while (true) {
        const is_last = try br.readBit();
        if (is_last == 1) {
            const is_last_empty = try br.readBit();
            if (is_last_empty == 1) return out.toOwnedSlice(allocator);
        }

        const nibbles: u6 = @intCast((try br.readBits(2)) + 4);
        const mlen = (try br.readBits(nibbles * 4)) + 1;

        var is_uncompressed: u1 = 0;
        if (is_last == 0) is_uncompressed = try br.readBit();
        if (is_uncompressed == 0) return error.NotUncompressed;

        br.alignToByte();
        if (br.byte_pos + mlen > br.bytes.len) return error.Truncated;

        try out.appendSlice(allocator, br.bytes[br.byte_pos..][0..mlen]);
        br.byte_pos += mlen;
    }
}

/// Two modes:
/// - no args: encode a few in-memory samples and self-check the round-trip (diagnostics).
/// - `<input> <output.br>`: read input, store-encode it, write the brotli stream to output.
///   This file mode feeds the `brotli -dc` interop gate (rnd/0.5.x/verify-brotli-encoder.md).
pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const io = process.io;

    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();

    const input_path = arg_iter.next();
    const output_path = arg_iter.next();

    if (input_path != null and output_path != null) {
        const cwd = std.Io.Dir.cwd();

        const input = try cwd.readFileAlloc(io, input_path.?, allocator, .unlimited);
        const stream = try encodeUncompressedAlloc(allocator, input, 22, MAX_META_BLOCK_LEN);

        const f = try cwd.createFile(io, output_path.?, .{});
        defer f.close(io);

        var write_buf: [8192]u8 = undefined;
        var writer = f.writer(io, &write_buf);
        try writer.interface.writeAll(stream);
        try writer.interface.flush();

        return;
    }

    const samples = [_][]const u8{
        "",
        "a",
        "hello over brotli E1 (store-only)",
    };

    for (samples) |sample| {
        const stream = try encodeUncompressedAlloc(allocator, sample, 22, MAX_META_BLOCK_LEN);
        const back = try decodeUncompressedAlloc(allocator, stream);

        const verdict = if (std.mem.eql(u8, back, sample)) "round-trip OK" else "ROUND-TRIP MISMATCH";
        std.debug.print("[{s}] {d} bytes -> {d} byte stream -> {s}\n", .{ sample, sample.len, stream.len, verdict });
    }
}

// --------------------------------------------------------- //
// test cases
// --------------------------------------------------------- //

test "empty input encodes to the canonical brotli empty stream at wbits 24" {
    const stream = try encodeUncompressedAlloc(std.testing.allocator, "", 24, MAX_META_BLOCK_LEN);
    defer std.testing.allocator.free(stream);

    // wbits=24 (1 + 111) then ISLAST=1, ISLASTEMPTY=1 packs to 0b00111111 = 0x3f, the exact
    // byte the system `brotli` CLI emits for empty input.
    try std.testing.expectEqualSlices(u8, &[_]u8{0x3f}, stream);
}

test "single byte round-trips" {
    const stream = try encodeUncompressedAlloc(std.testing.allocator, "x", 22, MAX_META_BLOCK_LEN);
    defer std.testing.allocator.free(stream);

    const back = try decodeUncompressedAlloc(std.testing.allocator, stream);
    defer std.testing.allocator.free(back);

    try std.testing.expectEqualSlices(u8, "x", back);
}

test "multi-byte text round-trips and stays store-only" {
    const text = "the quick brown fox jumps over the lazy dog";

    const stream = try encodeUncompressedAlloc(std.testing.allocator, text, 22, MAX_META_BLOCK_LEN);
    defer std.testing.allocator.free(stream);

    const back = try decodeUncompressedAlloc(std.testing.allocator, stream);
    defer std.testing.allocator.free(back);

    try std.testing.expectEqualSlices(u8, text, back);
}

test "input larger than the block cap splits into several meta-blocks and round-trips" {
    var input: [1000]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @truncate(i * 7 + 3);

    // a 4-byte cap forces 250 meta-blocks, exercising the multi-block loop and the
    // per-block byte alignment.
    const stream = try encodeUncompressedAlloc(std.testing.allocator, &input, 18, 4);
    defer std.testing.allocator.free(stream);

    const back = try decodeUncompressedAlloc(std.testing.allocator, stream);
    defer std.testing.allocator.free(back);

    try std.testing.expectEqualSlices(u8, &input, back);
}

test "all window sizes in range produce a decodable header" {
    const wbits_cases = [_]u6{ 10, 15, 16, 17, 18, 22, 24 };

    for (wbits_cases) |wbits| {
        const stream = try encodeUncompressedAlloc(std.testing.allocator, "abc", wbits, MAX_META_BLOCK_LEN);
        defer std.testing.allocator.free(stream);

        var br = BitReader{ .bytes = stream };
        try std.testing.expectEqual(wbits, try readWindowBits(&br));

        const back = try decodeUncompressedAlloc(std.testing.allocator, stream);
        defer std.testing.allocator.free(back);

        try std.testing.expectEqualSlices(u8, "abc", back);
    }
}

test "out-of-range window bits is rejected" {
    try std.testing.expectError(error.InvalidWindowBits, encodeUncompressedAlloc(std.testing.allocator, "abc", 9, MAX_META_BLOCK_LEN));
    try std.testing.expectError(error.InvalidWindowBits, encodeUncompressedAlloc(std.testing.allocator, "abc", 25, MAX_META_BLOCK_LEN));
}

test "the 5-nibble MLEN path round-trips a block over 64 KiB" {
    const big = try std.testing.allocator.alloc(u8, 70000);
    defer std.testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i);

    // one meta-block of 70000 bytes needs MLEN - 1 = 69999, which is > 2^16, so the encoder
    // must select 5 nibbles (the >4-nibble non-zero-top-nibble rule).
    const stream = try encodeUncompressedAlloc(std.testing.allocator, big, 24, MAX_META_BLOCK_LEN);
    defer std.testing.allocator.free(stream);

    const back = try decodeUncompressedAlloc(std.testing.allocator, stream);
    defer std.testing.allocator.free(back);

    try std.testing.expectEqualSlices(u8, big, back);
}
