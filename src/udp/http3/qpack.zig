//! zix HTTP/3 QPACK header compression (RFC 9204, Layer P).
//!
//! What:
//! - The prefixed-integer codec every representation rides on (4.1.1, reusing the RFC 7541 integer),
//!   the read-only static table (Appendix A), the two unidirectional stream types (4.2), and the
//!   field line representations (4.5): Indexed Field Line and Literal Field Line with Name Reference.
//! - For a static-only field section the Encoded Field Section Prefix is Required Insert Count 0 /
//!   Base 0 (two zero bytes). The dynamic table and decoder instructions live in qpack_dynamic.zig.
//! - Proven against the RFC 7541 Appendix C.1 integer vectors and RFC 9204 representations below.
//!
//! Note:
//! - The static-table encoding is live. StreamRegistry (the at-most-one encoder / decoder stream
//!   check) is implemented and tested but not enforced in the serve path yet (deferred).

const std = @import("std");

/// A decoded prefixed integer (RFC 7541 5.1): the value plus how many bytes it occupied.
pub const IntResult = struct { value: u64, len: usize };

/// Decode an N-bit prefixed integer (RFC 7541 5.1, reused by QPACK 4.1.1). The low `prefix_bits` of
/// the first byte hold the value or, if all ones, a continuation follows.
pub fn decodePrefixedInt(data: []const u8, prefix_bits: u4) error{Truncated}!IntResult {
    if (data.len == 0) return error.Truncated;

    const max: u64 = (@as(u64, 1) << prefix_bits) - 1;
    const first: u64 = data[0] & @as(u8, @intCast(max));
    if (first < max) return .{ .value = first, .len = 1 };

    var value: u64 = max;
    var len: usize = 1;
    var shift: u6 = 0;
    while (true) {
        if (len >= data.len) return error.Truncated;

        const byte = data[len];
        len += 1;
        value += @as(u64, byte & 0x7f) << shift;
        shift += 7;
        if (byte & 0x80 == 0) break;
    }

    return .{ .value = value, .len = len };
}

/// Encode an N-bit prefixed integer (RFC 7541 5.1). `high_bits` are the already-set bits above the
/// prefix in the first byte. Returns the number of bytes written.
pub fn encodePrefixedInt(out: []u8, prefix_bits: u4, high_bits: u8, value: u64) usize {
    const max: u64 = (@as(u64, 1) << prefix_bits) - 1;
    if (value < max) {
        out[0] = high_bits | @as(u8, @intCast(value));
        return 1;
    }

    out[0] = high_bits | @as(u8, @intCast(max));
    var remaining = value - max;
    var i: usize = 1;
    while (remaining >= 128) {
        out[i] = @as(u8, @intCast(remaining % 128)) + 128;
        remaining /= 128;
        i += 1;
    }
    out[i] = @intCast(remaining);

    return i + 1;
}

// --------------------------------------------------------------- //

/// A field line: a name and value (RFC 9204 Appendix A entries, and decoded representations).
pub const Field = struct { name: []const u8, value: []const u8 };

/// The leading block of the RFC 9204 Appendix A static table (indices 0..43). Covers every
/// pseudo-header, `accept-encoding` (index 31, the request content-negotiation input), and
/// `content-encoding` (indices 42 br / 43 gzip, the response codings served). The remaining Appendix A
/// entries are reached as Literal Field Lines with Name Reference until the full table is carried.
pub const static_table = [_]Field{
    .{ .name = ":authority", .value = "" }, // 0
    .{ .name = ":path", .value = "/" }, // 1
    .{ .name = "age", .value = "0" }, // 2
    .{ .name = "content-disposition", .value = "" }, // 3
    .{ .name = "content-length", .value = "0" }, // 4
    .{ .name = "cookie", .value = "" }, // 5
    .{ .name = "date", .value = "" }, // 6
    .{ .name = "etag", .value = "" }, // 7
    .{ .name = "if-modified-since", .value = "" }, // 8
    .{ .name = "if-none-match", .value = "" }, // 9
    .{ .name = "last-modified", .value = "" }, // 10
    .{ .name = "link", .value = "" }, // 11
    .{ .name = "location", .value = "" }, // 12
    .{ .name = "referer", .value = "" }, // 13
    .{ .name = "set-cookie", .value = "" }, // 14
    .{ .name = ":method", .value = "CONNECT" }, // 15
    .{ .name = ":method", .value = "DELETE" }, // 16
    .{ .name = ":method", .value = "GET" }, // 17
    .{ .name = ":method", .value = "HEAD" }, // 18
    .{ .name = ":method", .value = "OPTIONS" }, // 19
    .{ .name = ":method", .value = "POST" }, // 20
    .{ .name = ":method", .value = "PUT" }, // 21
    .{ .name = ":scheme", .value = "http" }, // 22
    .{ .name = ":scheme", .value = "https" }, // 23
    .{ .name = ":status", .value = "103" }, // 24
    .{ .name = ":status", .value = "200" }, // 25
    .{ .name = ":status", .value = "304" }, // 26
    .{ .name = ":status", .value = "404" }, // 27
    .{ .name = ":status", .value = "503" }, // 28
    .{ .name = "accept", .value = "*/*" }, // 29
    .{ .name = "accept", .value = "application/dns-message" }, // 30
    .{ .name = "accept-encoding", .value = "gzip, deflate, br" }, // 31
    .{ .name = "accept-ranges", .value = "bytes" }, // 32
    .{ .name = "access-control-allow-headers", .value = "cache-control" }, // 33
    .{ .name = "access-control-allow-headers", .value = "content-type" }, // 34
    .{ .name = "access-control-allow-origin", .value = "*" }, // 35
    .{ .name = "cache-control", .value = "max-age=0" }, // 36
    .{ .name = "cache-control", .value = "max-age=2592000" }, // 37
    .{ .name = "cache-control", .value = "max-age=604800" }, // 38
    .{ .name = "cache-control", .value = "no-cache" }, // 39
    .{ .name = "cache-control", .value = "no-store" }, // 40
    .{ .name = "cache-control", .value = "public, max-age=31536000" }, // 41
    .{ .name = "content-encoding", .value = "br" }, // 42
    .{ .name = "content-encoding", .value = "gzip" }, // 43
};

/// The two QPACK unidirectional stream types (RFC 9204 4.2).
pub const encoder_stream_type: u64 = 0x02;
pub const decoder_stream_type: u64 = 0x03;

/// Tracks the at-most-one-each rule for the QPACK streams (RFC 9204 4.2). A second instance of either
/// type is an H3_STREAM_CREATION_ERROR.
pub const StreamRegistry = struct {
    encoder_open: bool = false,
    decoder_open: bool = false,

    pub fn register(self: *StreamRegistry, stream_type: u64) error{StreamCreationError}!void {
        switch (stream_type) {
            encoder_stream_type => {
                if (self.encoder_open) return error.StreamCreationError;
                self.encoder_open = true;
            },
            decoder_stream_type => {
                if (self.decoder_open) return error.StreamCreationError;
                self.decoder_open = true;
            },
            else => {},
        }
    }
};

// --------------------------------------------------------------- //

/// A decoded Indexed Field Line (RFC 9204 4.5.2): which table and the index.
pub const IndexedFieldLine = struct { static: bool, index: u64, len: usize };

/// Decode an Indexed Field Line (RFC 9204 4.5.2): leading '1', then the 'T' table bit, then a 6-bit
/// prefix index.
pub fn decodeIndexedFieldLine(data: []const u8) error{ Truncated, NotIndexed }!IndexedFieldLine {
    if (data.len == 0) return error.Truncated;
    if (data[0] & 0x80 == 0) return error.NotIndexed;

    const is_static = data[0] & 0x40 != 0;
    const int = try decodePrefixedInt(data, 6);

    return .{ .static = is_static, .index = int.value, .len = int.len };
}

/// Encode an Indexed Field Line referencing the static table (RFC 9204 4.5.2). Returns bytes written.
pub fn encodeStaticIndexedFieldLine(out: []u8, index: u64) usize {
    return encodePrefixedInt(out, 6, 0x80 | 0x40, index);
}

/// A decoded Literal Field Line with Name Reference (RFC 9204 4.5.4). `len` is the total bytes the
/// representation consumed, for walking a field section.
pub const LiteralNameRef = struct { static: bool, name_index: u64, value: []const u8, huffman: bool, len: usize };

/// Decode a Literal Field Line with Name Reference (RFC 9204 4.5.4): leading '01', the 'N' and 'T'
/// bits, a 4-bit prefix name index, then an 8-bit prefix string literal value.
pub fn decodeLiteralNameRef(data: []const u8) error{ Truncated, NotLiteralNameRef }!LiteralNameRef {
    if (data.len == 0) return error.Truncated;
    if (data[0] & 0xc0 != 0x40) return error.NotLiteralNameRef;

    const is_static = data[0] & 0x10 != 0;
    const name = try decodePrefixedInt(data, 4);
    var pos = name.len;

    if (pos >= data.len) return error.Truncated;

    const huffman = data[pos] & 0x80 != 0;
    const length = try decodePrefixedInt(data[pos..], 7);
    pos += length.len;
    if (data.len < pos + length.value) return error.Truncated;

    return .{ .static = is_static, .name_index = name.value, .value = data[pos .. pos + length.value], .huffman = huffman, .len = pos + @as(usize, @intCast(length.value)) };
}

/// Look up a static-table entry by index, or null if out of range.
pub fn staticEntry(index: u64) ?Field {
    if (index >= static_table.len) return null;

    return static_table[@intCast(index)];
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

fn h(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;

    return out;
}

fn fieldIs(field: Field, name: []const u8, value: []const u8) bool {
    return std.mem.eql(u8, field.name, name) and std.mem.eql(u8, field.value, value);
}

test "zix http3: RFC 7541 C.1 prefixed integer decode and encode" {
    try std.testing.expectEqual(@as(u64, 10), (try decodePrefixedInt(&h("0a"), 5)).value);

    const v1337 = try decodePrefixedInt(&h("1f9a0a"), 5);
    try std.testing.expect(v1337.value == 1337 and v1337.len == 3);

    try std.testing.expectEqual(@as(u64, 42), (try decodePrefixedInt(&h("2a"), 8)).value);

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &h("0a"), buf[0..encodePrefixedInt(&buf, 5, 0, 10)]);
    try std.testing.expectEqualSlices(u8, &h("1f9a0a"), buf[0..encodePrefixedInt(&buf, 5, 0, 1337)]);
    try std.testing.expectEqualSlices(u8, &h("2a"), buf[0..encodePrefixedInt(&buf, 8, 0, 42)]);

    const big: u64 = (1 << 62) - 1;
    const big_round = try decodePrefixedInt(buf[0..encodePrefixedInt(&buf, 5, 0, big)], 5);
    try std.testing.expectEqual(big, big_round.value);
}

test "zix http3: RFC 9204 Appendix A static table and 4.2 streams" {
    try std.testing.expect(fieldIs(static_table[0], ":authority", ""));
    try std.testing.expect(fieldIs(static_table[17], ":method", "GET"));
    try std.testing.expect(fieldIs(static_table[23], ":scheme", "https"));
    try std.testing.expect(fieldIs(static_table[25], ":status", "200"));

    // The content-negotiation entries: accept-encoding (request input) and content-encoding (served
    // codings). staticEntry resolves them so request decode maps index 31 to accept-encoding.
    try std.testing.expect(fieldIs(staticEntry(31).?, "accept-encoding", "gzip, deflate, br"));
    try std.testing.expect(fieldIs(staticEntry(42).?, "content-encoding", "br"));
    try std.testing.expect(fieldIs(staticEntry(43).?, "content-encoding", "gzip"));

    var registry = StreamRegistry{};
    try registry.register(encoder_stream_type);
    try registry.register(decoder_stream_type);
    try std.testing.expect(registry.encoder_open and registry.decoder_open);
    try std.testing.expectError(error.StreamCreationError, registry.register(encoder_stream_type));
    try std.testing.expectError(error.StreamCreationError, registry.register(decoder_stream_type));
}

test "zix http3: RFC 9204 4.5 static-table field line representations" {
    const idx_path = try decodeIndexedFieldLine(&h("c1"));
    try std.testing.expect(idx_path.static and fieldIs(static_table[idx_path.index], ":path", "/"));

    const idx_get = try decodeIndexedFieldLine(&h("d1"));
    try std.testing.expect(idx_get.static and fieldIs(static_table[idx_get.index], ":method", "GET"));

    const idx_status = try decodeIndexedFieldLine(&h("d9"));
    try std.testing.expect(idx_status.static and fieldIs(static_table[idx_status.index], ":status", "200"));

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &h("d9"), buf[0..encodeStaticIndexedFieldLine(&buf, 25)]);

    const lit = try decodeLiteralNameRef(&h("500b6578616d706c652e636f6d"));
    try std.testing.expect(lit.static and std.mem.eql(u8, static_table[lit.name_index].name, ":authority"));
    try std.testing.expect(std.mem.eql(u8, lit.value, "example.com") and !lit.huffman);
}
