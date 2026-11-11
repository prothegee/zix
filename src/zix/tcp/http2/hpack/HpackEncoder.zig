//! ZIX Http2 hpack HpackEncoder
//!
//! ### file: src/zix/tcp/http2/hpack/HpackEncoder.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Encodes header fields into an HPACK block in a caller buffer.
//!
//! ### note:
//!
//! Stateless: only the static table and literals without indexing are used,
//! never the dynamic table. The same headers always give the same bytes, which
//! is what lets response_block.zig cache encoded prefixes.
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
const static_table = @import("static_table.zig");
const integer = @import("integer.zig");
const huffman = @import("huffman.zig");

// --------------------------------------------------------- //
// Fields:

/// Destination for the encoded block.
buf: []u8,
/// Bytes written so far.
pos: usize,

const Self = @This();

// --------------------------------------------------------- //
// Private:

const INDEXED_FLAG: u8 = 0x80;
const LITERAL_FLAG: u8 = 0x00;
const HUFFMAN_FLAG: u8 = 0x80;

const INDEXED_PREFIX: u3 = 7;
const LITERAL_PREFIX: u3 = 4;
const STRING_PREFIX: u3 = 7;

/// Huffman scratch for one string. A longer result is sent as a plain literal.
const HUFFMAN_SCRATCH: usize = 256;

const Inner = Error || integer.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixHttp2_HpackInteger_UnexpectedEOF => Error.ZixHttp2_HpackEncoder_UnexpectedEOF,
        error.ZixHttp2_HpackInteger_Overflow => Error.ZixHttp2_HpackEncoder_Overflow,
        error.ZixHttp2_HpackInteger_BufferFull => Error.ZixHttp2_HpackEncoder_BufferFull,
        error.ZixHttp2_HpackEncoder_UnexpectedEOF => Error.ZixHttp2_HpackEncoder_UnexpectedEOF,
        error.ZixHttp2_HpackEncoder_Overflow => Error.ZixHttp2_HpackEncoder_Overflow,
        error.ZixHttp2_HpackEncoder_BufferFull => Error.ZixHttp2_HpackEncoder_BufferFull,
    };
}

/// Copy raw bytes to the block.
fn writeBytes(self: *Self, bytes: []const u8) Inner!void {
    if (self.pos + bytes.len > self.buf.len) return Error.ZixHttp2_HpackEncoder_BufferFull;

    @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
    self.pos += bytes.len;
}

/// Write one string literal, Huffman-coded when that is shorter.
fn writeString(self: *Self, str: []const u8) Inner!void {
    var huffman_buf: [HUFFMAN_SCRATCH]u8 = undefined;

    // An explicit ?usize keeps comptime callers (cached reply blocks) working
    // when the error branch is statically unreachable.
    const huffman_len: ?usize = huffman.huffEncode(str, &huffman_buf) catch |err| switch (err) {
        // too long for the scratch: fall back to a plain literal
        error.ZixHttp2_Huffman_OutputTooSmall => null,
        error.ZixHttp2_Huffman_InvalidCode => null,
    };

    if (huffman_len) |len| {
        if (len < str.len) {
            try integer.encodeInt(self.buf, &self.pos, len, STRING_PREFIX, HUFFMAN_FLAG);

            return self.writeBytes(huffman_buf[0..len]);
        }
    }

    try integer.encodeInt(self.buf, &self.pos, str.len, STRING_PREFIX, 0x00);

    return self.writeBytes(str);
}

fn writeHeaderInner(self: *Self, name: []const u8, value: []const u8) Inner!void {
    for (static_table.HPACK_STATIC[1..], 1..) |entry, index| {
        if (!std.ascii.eqlIgnoreCase(entry.name, name)) continue;
        if (!std.mem.eql(u8, entry.value, value)) continue;

        return integer.encodeInt(self.buf, &self.pos, index, INDEXED_PREFIX, INDEXED_FLAG);
    }

    for (static_table.HPACK_STATIC[1..], 1..) |entry, index| {
        if (!std.ascii.eqlIgnoreCase(entry.name, name)) continue;

        try integer.encodeInt(self.buf, &self.pos, index, LITERAL_PREFIX, LITERAL_FLAG);

        return self.writeString(value);
    }

    try integer.encodeInt(self.buf, &self.pos, 0, LITERAL_PREFIX, LITERAL_FLAG);
    try self.writeString(name);

    return self.writeString(value);
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 hpack encoder error
pub const Error = error {
    ZixHttp2_HpackEncoder_UnexpectedEOF,
    ZixHttp2_HpackEncoder_Overflow,
    ZixHttp2_HpackEncoder_BufferFull,
};

/// An encoder that writes into buf from the start.
///
/// Param:
/// buf - []u8 (destination, must outlive the encoder)
///
/// Return:
/// - HpackEncoder
pub fn init(buf: []u8) Self {
    return .{
        .buf = buf,
        .pos = 0,
    };
}

/// The bytes encoded so far.
///
/// Return:
/// - []const u8
pub fn encoded(self: *const Self) []const u8 {
    return self.buf[0..self.pos];
}

/// Encode one header field.
///
/// Note:
/// - An exact static table match is sent as an index, a static name match as
///   a name index plus a literal value, anything else as two literals. None of
///   them touch the dynamic table.
///
/// Param:
/// name - []const u8 (header name)
/// value - []const u8 (header value)
///
/// Return:
/// - void when the field was written
/// - error.ZixHttp2_HpackEncoder_BufferFull when buf has no room left
pub fn writeHeader(self: *Self, name: []const u8, value: []const u8) Error!void {
    return self.writeHeaderInner(name, value) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const HpackDecoder = @import("HpackDecoder.zig");
const Header = @import("Header.zig");

test "zix http2 hpack: HpackEncoder, exact static match is one indexed byte" {
    var buf: [64]u8 = undefined;
    var encoder = init(&buf);

    try encoder.writeHeader(":method", "GET");

    try std.testing.expectEqualSlices(u8, &[_]u8{0x82}, encoder.encoded());
}

test "zix http2 hpack: HpackEncoder, static name match keeps the name index" {
    var buf: [64]u8 = undefined;
    var encoder = init(&buf);

    try encoder.writeHeader(":path", "/x");

    try std.testing.expectEqual(@as(u8, 0x04), encoder.encoded()[0]);
}

test "zix http2 hpack: HpackEncoder, unknown name is a literal name" {
    var buf: [64]u8 = undefined;
    var encoder = init(&buf);

    try encoder.writeHeader("x-custom", "v");

    try std.testing.expectEqual(@as(u8, 0x00), encoder.encoded()[0]);
}

test "zix http2 hpack: HpackEncoder, name match ignores case" {
    var buf: [64]u8 = undefined;
    var encoder = init(&buf);

    try encoder.writeHeader(":METHOD", "GET");

    try std.testing.expectEqualSlices(u8, &[_]u8{0x82}, encoder.encoded());
}

test "zix http2 hpack: HpackEncoder, round trips through the decoder" {
    var buf: [256]u8 = undefined;
    var encoder = init(&buf);
    try encoder.writeHeader(":status", "200");
    try encoder.writeHeader("content-type", "application/json");
    try encoder.writeHeader("x-trace", "abc123");

    var decoder = HpackDecoder.init();
    var out: [8]Header = undefined;
    var scratch: [256]u8 = undefined;
    const count = try decoder.decode(encoder.encoded(), &out, &scratch);

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("application/json", out[1].value);
    try std.testing.expectEqualStrings("x-trace", out[2].name);
    try std.testing.expectEqualStrings("abc123", out[2].value);
}

test "zix http2 hpack: HpackEncoder, value past the Huffman scratch is a plain literal" {
    var buf: [1024]u8 = undefined;
    var encoder = init(&buf);
    const long_value: [400]u8 = @splat('a');

    try encoder.writeHeader("x-long", &long_value);

    var decoder = HpackDecoder.init();
    var out: [2]Header = undefined;
    var scratch: [1024]u8 = undefined;
    _ = try decoder.decode(encoder.encoded(), &out, &scratch);

    try std.testing.expectEqualSlices(u8, &long_value, out[0].value);
}

test "zix http2 hpack: HpackEncoder, full buffer is BufferFull" {
    var buf: [4]u8 = undefined;
    var encoder = init(&buf);

    const result = encoder.writeHeader("x-custom", "value");

    try std.testing.expectError(Error.ZixHttp2_HpackEncoder_BufferFull, result);
}

test "zix http2 hpack: HpackEncoder, empty buffer is BufferFull" {
    var encoder = init(&[_]u8{});

    const result = encoder.writeHeader(":method", "GET");

    try std.testing.expectError(Error.ZixHttp2_HpackEncoder_BufferFull, result);
}

