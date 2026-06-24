//! QPACK PoC, phase P1 (http3-plan.md): RFC 9204 section 4.1.1 (prefixed integers), 4.2 (encoder /
//! decoder streams), Appendix A (static table) and 4.5 (static-table field line representations).
//!
//! Note:
//! - QPACK is HTTP/3's header compression. P1 is the static half: the prefixed-integer codec every
//!   representation rides on, the read-only static table, the two unidirectional stream types, and
//!   the field line representations that reference only the static table (no dynamic table yet, so
//!   the Encoded Field Section Prefix is Required Insert Count 0 / Base 0). The dynamic table and
//!   its synchronization arrive in P2 / P3.
//! - The oracle is the RFC text plus the RFC 7541 Appendix C.1 integer vectors (QPACK reuses the
//!   HPACK prefixed integer unmodified): 10 and 1337 on a 5-bit prefix, 42 on an 8-bit prefix. The
//!   static table indices and the representation bit patterns are from RFC 9204 directly.
//! - The static table here is the leading subset of the 99-entry Appendix A table (indices 0..28,
//!   covering every pseudo-header), enough to exercise lookup; the engine carries all 99. Huffman
//!   string literals (4.1.2) are detected by their flag but decoded in a later phase.
//!
//! Run:    zig run rnd/0.5.x/qpack_p1_poc.zig
//! Verify: bash rnd/0.5.x/verify-qpack-p1.sh

const std = @import("std");

// --------------------------------------------------------------- //

/// A decoded prefixed integer (RFC 7541 5.1): the value plus how many bytes it occupied.
const IntResult = struct { value: u64, len: usize };

/// Decode an N-bit prefixed integer (RFC 7541 5.1, reused by QPACK 4.1.1). The low `prefix_bits` of
/// the first byte hold the value or, if all ones, a continuation follows.
fn decodePrefixedInt(data: []const u8, prefix_bits: u4) error{Truncated}!IntResult {
    if (data.len == 0) return error.Truncated;

    const max: u64 = (@as(u64, 1) << prefix_bits) - 1;
    var value: u64 = data[0] & @as(u8, @intCast(max));
    if (value < max) return .{ .value = value, .len = 1 };

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
fn encodePrefixedInt(out: []u8, prefix_bits: u4, high_bits: u8, value: u64) usize {
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
const Field = struct { name: []const u8, value: []const u8 };

/// The leading subset of the RFC 9204 Appendix A static table (indices 0..28). The full table has
/// 99 entries; this covers every pseudo-header and is enough to exercise lookup.
const static_table = [_]Field{
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
};

// --------------------------------------------------------------- //

/// The two QPACK unidirectional stream types (RFC 9204 4.2).
const encoder_stream_type: u64 = 0x02;
const decoder_stream_type: u64 = 0x03;

/// Tracks the at-most-one-each rule for the QPACK streams (RFC 9204 4.2). A second instance of
/// either type is an H3_STREAM_CREATION_ERROR.
const StreamRegistry = struct {
    encoder_open: bool = false,
    decoder_open: bool = false,

    fn register(self: *StreamRegistry, stream_type: u64) error{StreamCreationError}!void {
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
const IndexedFieldLine = struct { static: bool, index: u64, len: usize };

/// Decode an Indexed Field Line (RFC 9204 4.5.2): leading '1', then the 'T' table bit, then a 6-bit
/// prefix index.
fn decodeIndexedFieldLine(data: []const u8) error{ Truncated, NotIndexed }!IndexedFieldLine {
    if (data.len == 0) return error.Truncated;
    if (data[0] & 0x80 == 0) return error.NotIndexed;

    const is_static = data[0] & 0x40 != 0;
    const int = try decodePrefixedInt(data, 6);

    return .{ .static = is_static, .index = int.value, .len = int.len };
}

/// Encode an Indexed Field Line referencing the static table (RFC 9204 4.5.2). Returns bytes written.
fn encodeStaticIndexedFieldLine(out: []u8, index: u64) usize {
    return encodePrefixedInt(out, 6, 0x80 | 0x40, index);
}

/// A decoded Literal Field Line with Name Reference (RFC 9204 4.5.4).
const LiteralNameRef = struct { static: bool, name_index: u64, value: []const u8, huffman: bool };

/// Decode a Literal Field Line with Name Reference (RFC 9204 4.5.4): leading '01', the 'N' and 'T'
/// bits, a 4-bit prefix name index, then an 8-bit prefix string literal value.
fn decodeLiteralNameRef(data: []const u8) error{ Truncated, NotLiteralNameRef }!LiteralNameRef {
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

    return .{ .static = is_static, .name_index = name.value, .value = data[pos .. pos + length.value], .huffman = huffman };
}

// --------------------------------------------------------------- //

/// Decode a hex literal (no separators) into a freshly allocated byte slice.
fn hex(allocator: std.mem.Allocator, comptime text: []const u8) ![]u8 {
    const bytes = try allocator.alloc(u8, text.len / 2);
    _ = try std.fmt.hexToBytes(bytes, text);

    return bytes;
}

/// Report a boolean expectation and flag a failure.
fn expect(failures: *usize, name: []const u8, ok: bool) void {
    if (ok) {
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        std.debug.print("  FAIL  {s}\n", .{name});
        failures.* += 1;
    }
}

/// Compare a byte slice against the expected hex and flag a failure.
fn expectBytes(failures: *usize, name: []const u8, actual: []const u8, comptime expected_hex: []const u8) void {
    var expected: [expected_hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, expected_hex) catch unreachable;

    if (actual.len == expected.len and std.mem.eql(u8, actual, &expected)) {
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        std.debug.print("  FAIL  {s}\n", .{name});
        std.debug.print("        want {s}\n", .{expected_hex});
        std.debug.print("        got  {x}\n", .{actual});
        failures.* += 1;
    }
}

/// Whether a field matches an expected name / value pair.
fn fieldIs(field: Field, name: []const u8, value: []const u8) bool {
    return std.mem.eql(u8, field.name, name) and std.mem.eql(u8, field.value, value);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var failures: usize = 0;

    std.debug.print("RFC 7541 Appendix C.1: prefixed integer decode + encode\n", .{});

    // C.1.1: 10 on a 5-bit prefix is a single byte 0x0a.
    expect(&failures, "decode 10 (5-bit)", (try decodePrefixedInt(try hex(arena, "0a"), 5)).value == 10);

    // C.1.2: 1337 on a 5-bit prefix is 0x1f 0x9a 0x0a.
    const v1337 = try decodePrefixedInt(try hex(arena, "1f9a0a"), 5);
    expect(&failures, "decode 1337 (5-bit)", v1337.value == 1337 and v1337.len == 3);

    // C.1.3: 42 on an 8-bit prefix is 0x2a.
    expect(&failures, "decode 42 (8-bit)", (try decodePrefixedInt(try hex(arena, "2a"), 8)).value == 42);

    var buf: [16]u8 = undefined;
    expectBytes(&failures, "encode 10 (5-bit)", buf[0..encodePrefixedInt(&buf, 5, 0, 10)], "0a");
    expectBytes(&failures, "encode 1337 (5-bit)", buf[0..encodePrefixedInt(&buf, 5, 0, 1337)], "1f9a0a");
    expectBytes(&failures, "encode 42 (8-bit)", buf[0..encodePrefixedInt(&buf, 8, 0, 42)], "2a");

    // A 62-bit value round-trips (QPACK MUST decode up to 62 bits, 4.1.1).
    const big: u64 = (1 << 62) - 1;
    const big_round = try decodePrefixedInt(buf[0..encodePrefixedInt(&buf, 5, 0, big)], 5);
    expect(&failures, "round-trip 2^62-1 (5-bit)", big_round.value == big);

    std.debug.print("RFC 9204 Appendix A: static table lookup\n", .{});

    expect(&failures, "static[0] = :authority", fieldIs(static_table[0], ":authority", ""));
    expect(&failures, "static[1] = :path /", fieldIs(static_table[1], ":path", "/"));
    expect(&failures, "static[17] = :method GET", fieldIs(static_table[17], ":method", "GET"));
    expect(&failures, "static[23] = :scheme https", fieldIs(static_table[23], ":scheme", "https"));
    expect(&failures, "static[25] = :status 200", fieldIs(static_table[25], ":status", "200"));

    std.debug.print("RFC 9204 4.2: encoder / decoder stream types\n", .{});

    expect(&failures, "encoder stream type = 0x02", encoder_stream_type == 0x02);
    expect(&failures, "decoder stream type = 0x03", decoder_stream_type == 0x03);

    var registry = StreamRegistry{};
    try registry.register(encoder_stream_type);
    try registry.register(decoder_stream_type);
    expect(&failures, "one encoder + one decoder ok", registry.encoder_open and registry.decoder_open);
    expect(&failures, "second encoder -> H3_STREAM_CREATION_ERROR", registry.register(encoder_stream_type) == error.StreamCreationError);
    expect(&failures, "second decoder -> H3_STREAM_CREATION_ERROR", registry.register(decoder_stream_type) == error.StreamCreationError);

    std.debug.print("RFC 9204 4.5: static-table field line representations\n", .{});

    // Static-only field section prefix: Required Insert Count 0, Base 0 -> two zero bytes.
    var prefix_buf: [2]u8 = undefined;
    const ric_len = encodePrefixedInt(prefix_buf[0..1], 8, 0, 0);
    const base_len = encodePrefixedInt(prefix_buf[1..2], 7, 0, 0);
    expect(&failures, "static-only prefix is RIC 0 / Base 0 (00 00)", prefix_buf[0] == 0 and prefix_buf[1] == 0 and ric_len == 1 and base_len == 1);

    // Indexed Field Line decode against the static table.
    const idx_path = try decodeIndexedFieldLine(try hex(arena, "c1"));
    expect(&failures, "indexed 0xc1 -> static :path /", idx_path.static and fieldIs(static_table[idx_path.index], ":path", "/"));

    const idx_get = try decodeIndexedFieldLine(try hex(arena, "d1"));
    expect(&failures, "indexed 0xd1 -> static :method GET", idx_get.static and fieldIs(static_table[idx_get.index], ":method", "GET"));

    const idx_status = try decodeIndexedFieldLine(try hex(arena, "d9"));
    expect(&failures, "indexed 0xd9 -> static :status 200", idx_status.static and fieldIs(static_table[idx_status.index], ":status", "200"));

    // Encode round-trips to the same byte.
    expectBytes(&failures, "encode indexed static :status 200 = 0xd9", buf[0..encodeStaticIndexedFieldLine(&buf, 25)], "d9");

    // Literal Field Line with Name Reference: name :authority (static 0), value "example.com".
    const lit = try decodeLiteralNameRef(try hex(arena, "500b6578616d706c652e636f6d"));
    expect(&failures, "literal name-ref -> :authority name", lit.static and std.mem.eql(u8, static_table[lit.name_index].name, ":authority"));
    expect(&failures, "literal name-ref value = example.com", std.mem.eql(u8, lit.value, "example.com"));
    expect(&failures, "literal name-ref not huffman here", !lit.huffman);

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9204 P1 QPACK static checks hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
