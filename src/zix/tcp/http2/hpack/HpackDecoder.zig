//! ZIX Http2 hpack HpackDecoder
//!
//! ### file: src/zix/tcp/http2/hpack/HpackDecoder.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Decodes HPACK header blocks for one connection (RFC 7541 section 6).
//!
//! ### note:
//!
//! Every decoded name and value is copied into the caller scratch, also for
//! table lookups, so the output stays valid while the dynamic table changes.
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
const Header = @import("Header.zig");
const DynamicTable = @import("DynamicTable.zig");
const static_table = @import("static_table.zig");
const integer = @import("integer.zig");
const huffman = @import("huffman.zig");

// --------------------------------------------------------- //
// Fields:

/// The connection dynamic table.
table: DynamicTable = .{},
/// Dynamic table size limit (SETTINGS_HEADER_TABLE_SIZE, default 4096).
max_size: usize = DEFAULT_MAX_SIZE,

const Self = @This();

// --------------------------------------------------------- //
// Private:

const DEFAULT_MAX_SIZE: usize = 4096;

/// First-byte patterns of each representation (RFC 7541 section 6).
const INDEXED_FLAG: u8 = 0x80;
const INCREMENTAL_FLAG: u8 = 0x40;
const SIZE_UPDATE_FLAG: u8 = 0x20;
/// Top 3 bits that must read 001 for a dynamic table size update.
const SIZE_UPDATE_MASK: u8 = 0xE0;
const HUFFMAN_FLAG: u8 = 0x80;

const INDEXED_PREFIX: u3 = 7;
const INCREMENTAL_PREFIX: u3 = 6;
const SIZE_UPDATE_PREFIX: u3 = 5;
const LITERAL_PREFIX: u3 = 4;
const STRING_PREFIX: u3 = 7;

const Inner = Error || integer.Error || huffman.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixHttp2_HpackInteger_UnexpectedEOF => Error.ZixHttp2_HpackDecoder_UnexpectedEOF,
        error.ZixHttp2_HpackInteger_Overflow => Error.ZixHttp2_HpackDecoder_Overflow,
        error.ZixHttp2_HpackInteger_BufferFull => Error.ZixHttp2_HpackDecoder_BufferFull,
        error.ZixHttp2_Huffman_OutputTooSmall => Error.ZixHttp2_HpackDecoder_OutputTooSmall,
        error.ZixHttp2_Huffman_InvalidCode => Error.ZixHttp2_HpackDecoder_InvalidCode,
        error.ZixHttp2_HpackDecoder_UnexpectedEOF => Error.ZixHttp2_HpackDecoder_UnexpectedEOF,
        error.ZixHttp2_HpackDecoder_Overflow => Error.ZixHttp2_HpackDecoder_Overflow,
        error.ZixHttp2_HpackDecoder_BufferFull => Error.ZixHttp2_HpackDecoder_BufferFull,
        error.ZixHttp2_HpackDecoder_OutputTooSmall => Error.ZixHttp2_HpackDecoder_OutputTooSmall,
        error.ZixHttp2_HpackDecoder_InvalidCode => Error.ZixHttp2_HpackDecoder_InvalidCode,
        error.ZixHttp2_HpackDecoder_ScratchFull => Error.ZixHttp2_HpackDecoder_ScratchFull,
        error.ZixHttp2_HpackDecoder_TooManyHeaders => Error.ZixHttp2_HpackDecoder_TooManyHeaders,
        error.ZixHttp2_HpackDecoder_InvalidIndex => Error.ZixHttp2_HpackDecoder_InvalidIndex,
    };
}

/// Look up a static or dynamic entry by HPACK index.
fn getEntry(self: *const Self, index: usize) ?Header {
    if (index == 0) return null;
    if (index <= static_table.STATIC_LEN) return static_table.HPACK_STATIC[index];

    return self.table.get(index - static_table.STATIC_LEN);
}

/// Copy src into scratch at scratch_pos and return the copy.
fn copyIntoScratch(src: []const u8, scratch: []u8, scratch_pos: *usize) Inner![]const u8 {
    if (scratch_pos.* + src.len > scratch.len) return Error.ZixHttp2_HpackDecoder_ScratchFull;

    const dst = scratch[scratch_pos.*..][0..src.len];
    @memcpy(dst, src);
    scratch_pos.* += src.len;

    return dst;
}

/// Decode one string literal (plain or Huffman) into scratch.
fn decodeString(
    block: []const u8,
    pos: *usize,
    scratch: []u8,
    scratch_pos: *usize,
) Inner![]const u8 {
    if (pos.* >= block.len) return Error.ZixHttp2_HpackDecoder_UnexpectedEOF;

    const is_huffman = (block[pos.*] & HUFFMAN_FLAG) != 0;
    const len = try integer.decodeInt(block, pos, STRING_PREFIX);
    if (len > block.len - pos.*) return Error.ZixHttp2_HpackDecoder_UnexpectedEOF;

    const raw = block[pos.*..][0..@intCast(len)];
    pos.* += raw.len;

    if (!is_huffman) return copyIntoScratch(raw, scratch, scratch_pos);

    const decoded_len = try huffman.huffDecode(raw, scratch[scratch_pos.*..]);
    const decoded = scratch[scratch_pos.*..][0..decoded_len];
    scratch_pos.* += decoded_len;

    return decoded;
}

/// Decode the name of a literal: index 0 means a string follows.
fn decodeName(
    self: *const Self,
    block: []const u8,
    pos: *usize,
    prefix_bits: u3,
    scratch: []u8,
    scratch_pos: *usize,
) Inner![]const u8 {
    const index = try integer.decodeInt(block, pos, prefix_bits);
    if (index == 0) return decodeString(block, pos, scratch, scratch_pos);

    const entry = self.getEntry(@intCast(index)) orelse
        return Error.ZixHttp2_HpackDecoder_InvalidIndex;

    return copyIntoScratch(entry.name, scratch, scratch_pos);
}

fn decodeInner(self: *Self, block: []const u8, out: []Header, scratch: []u8) Inner!usize {
    var pos: usize = 0;
    var out_count: usize = 0;
    var scratch_pos: usize = 0;

    while (pos < block.len) {
        const first = block[pos];

        if ((first & SIZE_UPDATE_MASK) == SIZE_UPDATE_FLAG) {
            const new_max = try integer.decodeInt(block, &pos, SIZE_UPDATE_PREFIX);
            self.max_size = @intCast(new_max);
            self.table.evictTo(self.max_size);

            continue;
        }

        if (out_count >= out.len) return Error.ZixHttp2_HpackDecoder_TooManyHeaders;

        if ((first & INDEXED_FLAG) != 0) {
            const index = try integer.decodeInt(block, &pos, INDEXED_PREFIX);
            const entry = self.getEntry(@intCast(index)) orelse
                return Error.ZixHttp2_HpackDecoder_InvalidIndex;

            out[out_count] = .{
                .name = try copyIntoScratch(entry.name, scratch, &scratch_pos),
                .value = try copyIntoScratch(entry.value, scratch, &scratch_pos),
            };
            out_count += 1;

            continue;
        }

        const incremental = (first & INCREMENTAL_FLAG) != 0;
        const prefix_bits = if (incremental) INCREMENTAL_PREFIX else LITERAL_PREFIX;

        const name = try self.decodeName(block, &pos, prefix_bits, scratch, &scratch_pos);
        const value = try decodeString(block, &pos, scratch, &scratch_pos);

        if (incremental) self.table.add(name, value, self.max_size);

        out[out_count] = .{
            .name = name,
            .value = value,
        };
        out_count += 1;
    }

    return out_count;
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 hpack decoder error
pub const Error = error {
    ZixHttp2_HpackDecoder_UnexpectedEOF,
    ZixHttp2_HpackDecoder_Overflow,
    ZixHttp2_HpackDecoder_BufferFull,
    ZixHttp2_HpackDecoder_OutputTooSmall,
    ZixHttp2_HpackDecoder_InvalidCode,
    ZixHttp2_HpackDecoder_ScratchFull,
    ZixHttp2_HpackDecoder_TooManyHeaders,
    ZixHttp2_HpackDecoder_InvalidIndex,
};

/// A decoder with an empty dynamic table and the default size limit.
pub fn init() Self {
    return .{};
}

/// Drop the oldest dynamic entries until the table fits target.
///
/// Param:
/// target - usize (size limit in HPACK octets)
///
/// Return:
/// - void
pub fn evictTo(self: *Self, target: usize) void {
    self.table.evictTo(target);
}

/// Decode one HPACK header block into out.
///
/// Note:
/// - Every slice in out points into scratch. scratch is caller-owned and must
///   outlive the use of out.
///
/// Param:
/// block - []const u8 (the complete header block)
/// out - []Header (destination for the decoded headers)
/// scratch - []u8 (backing bytes for the decoded names and values)
///
/// Return:
/// - usize (number of headers decoded)
/// - error.ZixHttp2_HpackDecoder_TooManyHeaders when out is too short
/// - error.ZixHttp2_HpackDecoder_ScratchFull or OutputTooSmall when scratch is too short
/// - error.ZixHttp2_HpackDecoder_InvalidIndex on an unknown table index
/// - error.ZixHttp2_HpackDecoder_UnexpectedEOF, Overflow, or InvalidCode on a
///   malformed block
pub fn decode(self: *Self, block: []const u8, out: []Header, scratch: []u8) Error!usize {
    return self.decodeInner(block, out, scratch) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 hpack: HpackDecoder, decodes indexed :method GET" {
    var decoder = init();
    var out: [8]Header = undefined;
    var scratch: [256]u8 = undefined;

    const count = try decoder.decode(&[_]u8{0x82}, &out, &scratch);

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings(":method", out[0].name);
    try std.testing.expectEqualStrings("GET", out[0].value);
}

test "zix http2 hpack: HpackDecoder, decodes RFC 7541 C.3.1 request" {
    const block = [_]u8{
        0x82, 0x86, 0x84, 0x41, 0x0f, 'w', 'w', 'w', '.', 'e', 'x', 'a', 'm', 'p', 'l', 'e', '.',
        'c', 'o', 'm',
    };
    var decoder = init();
    var out: [8]Header = undefined;
    var scratch: [256]u8 = undefined;

    const count = try decoder.decode(&block, &out, &scratch);

    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqualStrings(":scheme", out[1].name);
    try std.testing.expectEqualStrings("http", out[1].value);
    try std.testing.expectEqualStrings(":authority", out[3].name);
    try std.testing.expectEqualStrings("www.example.com", out[3].value);
    try std.testing.expectEqual(@as(usize, 57), decoder.table.size);
}

test "zix http2 hpack: HpackDecoder, decodes a Huffman value (RFC 7541 C.4.2)" {
    const block = [_]u8{ 0x58, 0x86, 0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf };
    var decoder = init();
    var out: [8]Header = undefined;
    var scratch: [256]u8 = undefined;

    _ = try decoder.decode(&block, &out, &scratch);

    try std.testing.expectEqualStrings("cache-control", out[0].name);
    try std.testing.expectEqualStrings("no-cache", out[0].value);
}

test "zix http2 hpack: HpackDecoder, literal without indexing leaves the table empty" {
    const block = [_]u8{ 0x04, 0x01, '/' };
    var decoder = init();
    var out: [8]Header = undefined;
    var scratch: [256]u8 = undefined;

    _ = try decoder.decode(&block, &out, &scratch);

    try std.testing.expectEqualStrings(":path", out[0].name);
    try std.testing.expectEqual(@as(usize, 0), decoder.table.count);
}

test "zix http2 hpack: HpackDecoder, indexed lookup survives a zeroed scratch" {
    const path_value = "/svc.Svc/Greet";
    var decoder = init();

    var block1: [32]u8 = undefined;
    block1[0] = 0x44;
    block1[1] = path_value.len;
    @memcpy(block1[2..][0..path_value.len], path_value);

    var scratch1: [256]u8 = undefined;
    var out1: [8]Header = undefined;
    _ = try decoder.decode(block1[0 .. 2 + path_value.len], &out1, &scratch1);
    @memset(&scratch1, 0);

    // 0xBE is indexed 62: the first dynamic entry
    var scratch2: [256]u8 = undefined;
    var out2: [8]Header = undefined;
    const count = try decoder.decode(&[_]u8{0xBE}, &out2, &scratch2);

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings(":path", out2[0].name);
    try std.testing.expectEqualStrings(path_value, out2[0].value);
}

test "zix http2 hpack: HpackDecoder, indexed output points into scratch" {
    var decoder = init();
    decoder.table.add("x-test", "value", decoder.max_size);

    var scratch: [256]u8 = undefined;
    var out: [8]Header = undefined;
    _ = try decoder.decode(&[_]u8{0xBE}, &out, &scratch);

    const scratch_base = @intFromPtr(&scratch[0]);
    const scratch_end = scratch_base + scratch.len;

    try std.testing.expect(@intFromPtr(out[0].value.ptr) >= scratch_base);
    try std.testing.expect(@intFromPtr(out[0].value.ptr) < scratch_end);
}

test "zix http2 hpack: HpackDecoder, size update changes max_size and evicts" {
    var decoder = init();
    decoder.table.add("x-test", "value", decoder.max_size);

    var out: [8]Header = undefined;
    var scratch: [64]u8 = undefined;
    const count = try decoder.decode(&[_]u8{0x20}, &out, &scratch);

    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(@as(usize, 0), decoder.max_size);
    try std.testing.expectEqual(@as(usize, 0), decoder.table.count);
}

test "zix http2 hpack: HpackDecoder, evictTo forwards to the table" {
    var decoder = init();
    decoder.table.add("x-test", "value", decoder.max_size);

    decoder.evictTo(0);

    try std.testing.expectEqual(@as(usize, 0), decoder.table.count);
}

test "zix http2 hpack: HpackDecoder, unknown index is InvalidIndex" {
    var decoder = init();
    var out: [8]Header = undefined;
    var scratch: [64]u8 = undefined;

    const result = decoder.decode(&[_]u8{0xBE}, &out, &scratch);

    try std.testing.expectError(Error.ZixHttp2_HpackDecoder_InvalidIndex, result);
}

test "zix http2 hpack: HpackDecoder, index 0 is InvalidIndex" {
    var decoder = init();
    var out: [8]Header = undefined;
    var scratch: [64]u8 = undefined;

    const result = decoder.decode(&[_]u8{0x80}, &out, &scratch);

    try std.testing.expectError(Error.ZixHttp2_HpackDecoder_InvalidIndex, result);
}

test "zix http2 hpack: HpackDecoder, too many headers is TooManyHeaders" {
    var decoder = init();
    var out: [1]Header = undefined;
    var scratch: [64]u8 = undefined;

    const result = decoder.decode(&[_]u8{ 0x82, 0x84 }, &out, &scratch);

    try std.testing.expectError(Error.ZixHttp2_HpackDecoder_TooManyHeaders, result);
}

test "zix http2 hpack: HpackDecoder, small scratch is ScratchFull" {
    var decoder = init();
    var out: [8]Header = undefined;
    var scratch: [4]u8 = undefined;

    const result = decoder.decode(&[_]u8{0x82}, &out, &scratch);

    try std.testing.expectError(Error.ZixHttp2_HpackDecoder_ScratchFull, result);
}

test "zix http2 hpack: HpackDecoder, string past the block is UnexpectedEOF" {
    var decoder = init();
    var out: [8]Header = undefined;
    var scratch: [64]u8 = undefined;

    const result = decoder.decode(&[_]u8{ 0x04, 0x05, '/' }, &out, &scratch);

    try std.testing.expectError(Error.ZixHttp2_HpackDecoder_UnexpectedEOF, result);
}

test "zix http2 hpack: HpackDecoder, bad Huffman value is InvalidCode" {
    var decoder = init();
    var out: [8]Header = undefined;
    var scratch: [64]u8 = undefined;

    const result = decoder.decode(&[_]u8{ 0x04, 0x82, 0xff, 0xff }, &out, &scratch);

    try std.testing.expectError(Error.ZixHttp2_HpackDecoder_InvalidCode, result);
}

