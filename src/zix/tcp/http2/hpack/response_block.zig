//! ZIX Http2 hpack response_block
//!
//! ### file: src/zix/tcp/http2/hpack/response_block.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Encodes a response header block, with a process-wide cache for the
//! [:status, content-type, content-encoding] prefix.
//!
//! ### note:
//!
//! The cache is append-only. Readers scan 0..count without a lock (count is
//! published with release ordering after the slot is written). A spinlock
//! guards only the rare insert, one per distinct triple. A miss on a full
//! cache or a too-long triple falls back to a direct encode, so output never
//! depends on a cache hit.
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
const HpackEncoder = @import("HpackEncoder.zig");
const RespPrefix = @import("RespPrefix.zig");

// --------------------------------------------------------- //
// Private:

const PREFIX_CACHE_LEN: usize = 32;
/// Scratch for encoding a prefix before it is copied into a cache slot.
const PREFIX_SCRATCH: usize = 256;
/// Digits of the largest u16 status.
const STATUS_DIGITS: usize = 5;
/// Digits of the largest u64 content-length.
const LENGTH_DIGITS: usize = 20;

var prefix_cache: [PREFIX_CACHE_LEN]RespPrefix = undefined;
var prefix_count: usize = 0;
var prefix_lock: std.atomic.Value(bool) = .init(false);

const Inner = Error || HpackEncoder.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixHttp2_HpackEncoder_UnexpectedEOF =>
            Error.ZixHttp2_ResponseBlock_UnexpectedEOF,
        error.ZixHttp2_HpackEncoder_Overflow => Error.ZixHttp2_ResponseBlock_Overflow,
        error.ZixHttp2_HpackEncoder_BufferFull => Error.ZixHttp2_ResponseBlock_BufferFull,
        error.ZixHttp2_ResponseBlock_UnexpectedEOF =>
            Error.ZixHttp2_ResponseBlock_UnexpectedEOF,
        error.ZixHttp2_ResponseBlock_Overflow => Error.ZixHttp2_ResponseBlock_Overflow,
        error.ZixHttp2_ResponseBlock_BufferFull => Error.ZixHttp2_ResponseBlock_BufferFull,
    };
}

/// Find a cached prefix among the first count slots.
fn lookup(
    status: u16,
    content_type: []const u8,
    content_encoding: []const u8,
    count: usize,
) ?*const RespPrefix {
    for (prefix_cache[0..count]) |*entry| {
        if (entry.matches(status, content_type, content_encoding)) return entry;
    }

    return null;
}

/// Copy a cached prefix into dst and return its length.
fn copyCached(dst: []u8, entry: *const RespPrefix) Inner!usize {
    if (entry.block_len > dst.len) return Error.ZixHttp2_ResponseBlock_BufferFull;

    @memcpy(dst[0..entry.block_len], entry.block[0..entry.block_len]);

    return entry.block_len;
}

/// Encode the prefix into dst. An empty content_type or content_encoding is omitted.
fn encodePrefix(
    dst: []u8,
    status: u16,
    content_type: []const u8,
    content_encoding: []const u8,
) Inner!usize {
    var encoder = HpackEncoder.init(dst);

    var status_buf: [STATUS_DIGITS]u8 = undefined;
    const status_text = std.fmt.bufPrint(&status_buf, "{d}", .{status}) catch |err|
        switch (err) {
            error.NoSpaceLeft => return Error.ZixHttp2_ResponseBlock_BufferFull,
        };

    try encoder.writeHeader(":status", status_text);
    if (content_type.len > 0) try encoder.writeHeader("content-type", content_type);
    if (content_encoding.len > 0) {
        try encoder.writeHeader("content-encoding", content_encoding);
    }

    return encoder.pos;
}

/// Write the prefix into dst from the cache, encoding and caching it on a miss.
fn writePrefix(
    dst: []u8,
    status: u16,
    content_type: []const u8,
    content_encoding: []const u8,
) Inner!usize {
    const count = @atomicLoad(usize, &prefix_count, .acquire);
    if (lookup(status, content_type, content_encoding, count)) |entry| {
        return copyCached(dst, entry);
    }

    const too_long =
        content_type.len > RespPrefix.CONTENT_TYPE_MAX or
        content_encoding.len > RespPrefix.CONTENT_ENCODING_MAX;
    if (too_long) return encodePrefix(dst, status, content_type, content_encoding);

    while (prefix_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer prefix_lock.store(false, .release);

    // another worker may have inserted this triple since the load above
    const now = @atomicLoad(usize, &prefix_count, .acquire);
    if (lookup(status, content_type, content_encoding, now)) |entry| {
        return copyCached(dst, entry);
    }

    if (now == PREFIX_CACHE_LEN) {
        return encodePrefix(dst, status, content_type, content_encoding);
    }

    var scratch: [PREFIX_SCRATCH]u8 = undefined;
    const encoded_len = try encodePrefix(&scratch, status, content_type, content_encoding);
    if (encoded_len > RespPrefix.BLOCK_MAX) {
        return encodePrefix(dst, status, content_type, content_encoding);
    }

    const entry = &prefix_cache[now];
    entry.status = status;
    entry.content_type_len = @intCast(content_type.len);
    entry.content_encoding_len = @intCast(content_encoding.len);
    entry.block_len = @intCast(encoded_len);
    @memcpy(entry.content_type[0..content_type.len], content_type);
    @memcpy(entry.content_encoding[0..content_encoding.len], content_encoding);
    @memcpy(entry.block[0..encoded_len], scratch[0..encoded_len]);

    @atomicStore(usize, &prefix_count, now + 1, .release);

    return copyCached(dst, entry);
}

fn respHeaderBlockInner(
    dst: []u8,
    status: u16,
    content_type: []const u8,
    content_encoding: []const u8,
    content_length: ?u64,
) Inner!usize {
    const prefix_len = try writePrefix(dst, status, content_type, content_encoding);
    const length = content_length orelse return prefix_len;

    var encoder: HpackEncoder = .{
        .buf = dst,
        .pos = prefix_len,
    };
    var length_buf: [LENGTH_DIGITS]u8 = undefined;
    const length_text = std.fmt.bufPrint(&length_buf, "{d}", .{length}) catch |err|
        switch (err) {
            error.NoSpaceLeft => return Error.ZixHttp2_ResponseBlock_BufferFull,
        };

    try encoder.writeHeader("content-length", length_text);

    return encoder.pos;
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 hpack response block error
pub const Error = error {
    ZixHttp2_ResponseBlock_UnexpectedEOF,
    ZixHttp2_ResponseBlock_Overflow,
    ZixHttp2_ResponseBlock_BufferFull,
};

/// Encode a response header block
/// [:status, content-type, content-encoding, content-length] into dst.
///
/// Note:
/// - The first three fields come from the prefix cache. Only content-length is
///   encoded on every call.
///
/// Param:
/// dst - []u8 (destination for the block)
/// status - u16 (response status, e.g. 200)
/// content_type - []const u8 (empty omits the header)
/// content_encoding - []const u8 (empty omits the header)
/// content_length - ?u64 (null omits the header)
///
/// Return:
/// - usize (block length in dst)
/// - error.ZixHttp2_ResponseBlock_BufferFull when dst is too small
pub fn respHeaderBlock(
    dst: []u8,
    status: u16,
    content_type: []const u8,
    content_encoding: []const u8,
    content_length: ?u64,
) Error!usize {
    return respHeaderBlockInner(
        dst,
        status,
        content_type,
        content_encoding,
        content_length,
    ) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const HpackDecoder = @import("HpackDecoder.zig");
const Header = @import("Header.zig");

fn testReference(buf: []u8, fields: []const [2][]const u8) ![]const u8 {
    var encoder = HpackEncoder.init(buf);
    for (fields) |field| try encoder.writeHeader(field[0], field[1]);

    return encoder.encoded();
}

test "zix http2 hpack: response_block, matches writeHeader byte for byte" {
    var ref_buf: [256]u8 = undefined;
    const want = try testReference(&ref_buf, &.{
        .{ ":status", "200" },
        .{ "content-type", "application/json" },
        .{ "content-length", "1234" },
    });

    var got: [256]u8 = undefined;
    const got_len = try respHeaderBlock(&got, 200, "application/json", "", 1234);

    try std.testing.expectEqualSlices(u8, want, got[0..got_len]);
}

test "zix http2 hpack: response_block, cached prefix gives the same bytes" {
    var first: [256]u8 = undefined;
    const first_len = try respHeaderBlock(&first, 201, "text/csv", "", 5);

    var second: [256]u8 = undefined;
    const second_len = try respHeaderBlock(&second, 201, "text/csv", "", 5);

    try std.testing.expectEqualSlices(u8, first[0..first_len], second[0..second_len]);
}

test "zix http2 hpack: response_block, cached prefix re-encodes the length" {
    var warm: [256]u8 = undefined;
    _ = try respHeaderBlock(&warm, 200, "text/html", "", 1);

    var ref_buf: [256]u8 = undefined;
    const want = try testReference(&ref_buf, &.{
        .{ ":status", "200" },
        .{ "content-type", "text/html" },
        .{ "content-length", "7" },
    });

    var got: [256]u8 = undefined;
    const got_len = try respHeaderBlock(&got, 200, "text/html", "", 7);

    try std.testing.expectEqualSlices(u8, want, got[0..got_len]);
}

test "zix http2 hpack: response_block, includes content-encoding" {
    var ref_buf: [256]u8 = undefined;
    const want = try testReference(&ref_buf, &.{
        .{ ":status", "200" },
        .{ "content-type", "text/plain" },
        .{ "content-encoding", "br" },
        .{ "content-length", "9" },
    });

    var got: [256]u8 = undefined;
    const got_len = try respHeaderBlock(&got, 200, "text/plain", "br", 9);

    try std.testing.expectEqualSlices(u8, want, got[0..got_len]);
}

test "zix http2 hpack: response_block, null length omits content-length" {
    var ref_buf: [256]u8 = undefined;
    const want = try testReference(&ref_buf, &.{
        .{ ":status", "404" },
        .{ "content-type", "text/plain" },
    });

    var got: [256]u8 = undefined;
    const got_len = try respHeaderBlock(&got, 404, "text/plain", "", null);

    try std.testing.expectEqualSlices(u8, want, got[0..got_len]);
}

test "zix http2 hpack: response_block, round trips through the decoder" {
    var block: [256]u8 = undefined;
    const block_len = try respHeaderBlock(&block, 200, "application/json", "", 42);

    var decoder = HpackDecoder.init();
    var out: [8]Header = undefined;
    var scratch: [256]u8 = undefined;
    const count = try decoder.decode(block[0..block_len], &out, &scratch);

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("200", out[0].value);
    try std.testing.expectEqualStrings("application/json", out[1].value);
    try std.testing.expectEqualStrings("42", out[2].value);
}

test "zix http2 hpack: response_block, five-digit status encodes" {
    var block: [256]u8 = undefined;
    const block_len = try respHeaderBlock(&block, 59999, "", "", null);

    var decoder = HpackDecoder.init();
    var out: [2]Header = undefined;
    var scratch: [64]u8 = undefined;
    _ = try decoder.decode(block[0..block_len], &out, &scratch);

    try std.testing.expectEqualStrings("59999", out[0].value);
}

test "zix http2 hpack: response_block, too-long content-type bypasses the cache" {
    const long_type: [RespPrefix.CONTENT_TYPE_MAX + 1]u8 = @splat('t');
    var block: [512]u8 = undefined;

    const block_len = try respHeaderBlock(&block, 200, &long_type, "", null);

    var decoder = HpackDecoder.init();
    var out: [2]Header = undefined;
    var scratch: [256]u8 = undefined;
    _ = try decoder.decode(block[0..block_len], &out, &scratch);

    try std.testing.expectEqualSlices(u8, &long_type, out[1].value);
}

test "zix http2 hpack: response_block, small dst is BufferFull" {
    var block: [2]u8 = undefined;

    const result = respHeaderBlock(&block, 200, "application/json", "", 42);

    try std.testing.expectError(Error.ZixHttp2_ResponseBlock_BufferFull, result);
}

