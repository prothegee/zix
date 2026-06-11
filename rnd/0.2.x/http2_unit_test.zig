//! Unit tests: frame codec, HPACK static table, Huffman, HPACK decode/encode, dynamic table eviction, no I/O.
//! Run: zig test rnd/http2_unit_test.zig

const std = @import("std");
const core = @import("http2_poc_core.zig");

// ------------------------------------------------------------------ //
// Frame header encode/decode round-trip                               //
// ------------------------------------------------------------------ //

fn makePipe() ![2]std.posix.fd_t {
    const p = try std.Io.Threaded.pipe2(.{});
    return p;
}

test "unit: frame header encode then decode round-trips all fields" {
    // length=13, type=HEADERS(1), flags=END_STREAM|END_HEADERS(5), stream_id=1
    const raw = [9]u8{ 0x00, 0x00, 0x0d, 0x01, 0x05, 0x00, 0x00, 0x00, 0x01 };
    const fds = try makePipe();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);
    _ = std.posix.system.write(fds[1], &raw, raw.len);
    const fh = try core.readFrameHeader(fds[0]);
    try std.testing.expectEqual(13, fh.length);
    try std.testing.expectEqual(core.FT_HEADERS, fh.frame_type);
    try std.testing.expectEqual(core.FLAG_END_STREAM | core.FLAG_END_HEADERS, fh.flags);
    try std.testing.expectEqual(1, fh.stream_id);
}

test "unit: stream_id reserved bit is masked out" {
    // R bit set (bit 31 of stream_id word) must be ignored per RFC 9113.
    const raw = [9]u8{ 0x00, 0x00, 0x00, 0x04, 0x00, 0x80, 0x00, 0x00, 0x01 };
    const fds = try makePipe();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);
    _ = std.posix.system.write(fds[1], &raw, raw.len);
    const fh = try core.readFrameHeader(fds[0]);
    try std.testing.expectEqual(1, fh.stream_id);
}

// ------------------------------------------------------------------ //
// HPACK static table                                                   //
// ------------------------------------------------------------------ //

test "unit: static table index 2 is :method GET" {
    try std.testing.expectEqualStrings(":method", core.HPACK_STATIC[2].name);
    try std.testing.expectEqualStrings("GET", core.HPACK_STATIC[2].value);
}

test "unit: static table index 8 is :status 200" {
    try std.testing.expectEqualStrings(":status", core.HPACK_STATIC[8].name);
    try std.testing.expectEqualStrings("200", core.HPACK_STATIC[8].value);
}

test "unit: static table has exactly 61 valid entries (1..61)" {
    var count: usize = 0;
    for (core.HPACK_STATIC[1..]) |e| {
        if (e.name.len > 0) count += 1;
    }
    try std.testing.expectEqual(61, count);
}

// ------------------------------------------------------------------ //
// Huffman encode / decode round-trip                                  //
// ------------------------------------------------------------------ //

test "unit: huffman encode then decode round-trips ASCII string" {
    const src = "hello world";
    var enc_buf: [64]u8 = undefined;
    const enc_len = try core.huffEncode(src, &enc_buf);
    try std.testing.expect(enc_len < src.len); // Huffman must compress common ASCII

    var dec_buf: [64]u8 = undefined;
    const dec_len = try core.huffDecode(enc_buf[0..enc_len], &dec_buf);
    try std.testing.expectEqualStrings(src, dec_buf[0..dec_len]);
}

test "unit: huffman encode then decode round-trips HTTP path" {
    const src = "/api/v1/users?id=42";
    var enc: [64]u8 = undefined;
    const en = try core.huffEncode(src, &enc);
    var dec: [64]u8 = undefined;
    const dn = try core.huffDecode(enc[0..en], &dec);
    try std.testing.expectEqualStrings(src, dec[0..dn]);
}

test "unit: huffman encode then decode round-trips all printable ASCII" {
    var src: [95]u8 = undefined;
    for (0..95) |i| src[i] = @intCast(32 + i); // ' ' to '~'
    var enc: [256]u8 = undefined;
    const en = try core.huffEncode(&src, &enc);
    var dec: [256]u8 = undefined;
    const dn = try core.huffDecode(enc[0..en], &dec);
    try std.testing.expectEqualStrings(&src, dec[0..dn]);
}

// ------------------------------------------------------------------ //
// HPACK decode                                                        //
// ------------------------------------------------------------------ //

test "unit: hpack decode indexed field from static table" {
    // 0x82 = 1000 0010 = indexed, index=2 (:method GET)
    const block = [_]u8{0x82};
    var dec = core.HpackDecoder.init();
    var hdrs: [8]core.Header = undefined;
    var scratch: [512]u8 = undefined;
    const n = try dec.decode(&block, &hdrs, &scratch);
    try std.testing.expectEqual(1, n);
    try std.testing.expectEqualStrings(":method", hdrs[0].name);
    try std.testing.expectEqualStrings("GET", hdrs[0].value);
}

test "unit: hpack decode literal without indexing, non-huffman value" {
    // 0x00 = literal without indexing, index=0 (new name)
    // name: H=0, len=4, "test"
    // value: H=0, len=5, "value"
    const block = [_]u8{ 0x00, 0x04, 't', 'e', 's', 't', 0x05, 'v', 'a', 'l', 'u', 'e' };
    var dec = core.HpackDecoder.init();
    var hdrs: [8]core.Header = undefined;
    var scratch: [512]u8 = undefined;
    const n = try dec.decode(&block, &hdrs, &scratch);
    try std.testing.expectEqual(1, n);
    try std.testing.expectEqualStrings("test", hdrs[0].name);
    try std.testing.expectEqualStrings("value", hdrs[0].value);
}

test "unit: hpack decode multiple indexed headers" {
    // 0x82 = :method GET, 0x84 = :path /, 0x86 = :scheme http
    const block = [_]u8{ 0x82, 0x84, 0x86 };
    var dec = core.HpackDecoder.init();
    var hdrs: [8]core.Header = undefined;
    var scratch: [512]u8 = undefined;
    const n = try dec.decode(&block, &hdrs, &scratch);
    try std.testing.expectEqual(3, n);
    try std.testing.expectEqualStrings(":method", hdrs[0].name);
    try std.testing.expectEqualStrings(":path", hdrs[1].name);
    try std.testing.expectEqualStrings(":scheme", hdrs[2].name);
}

// ------------------------------------------------------------------ //
// HPACK encode                                                        //
// ------------------------------------------------------------------ //

test "unit: hpack encoder emits indexed byte for :status 200" {
    var buf: [32]u8 = undefined;
    var enc = core.HpackEncoder.init(&buf);
    try enc.writeHeader(":status", "200");
    const out = enc.encoded();
    // Index 8 in static table = :status 200, indexed encoding = 0x88 (1000 1000)
    try std.testing.expectEqual(1, out.len);
    try std.testing.expectEqual(0x88, out[0]);
}

test "unit: hpack encode then decode round-trips a custom header" {
    var enc_buf: [256]u8 = undefined;
    var enc = core.HpackEncoder.init(&enc_buf);
    try enc.writeHeader("x-request-id", "abc-123");
    const block = enc.encoded();

    var dec = core.HpackDecoder.init();
    var hdrs: [8]core.Header = undefined;
    var scratch: [512]u8 = undefined;
    const n = try dec.decode(block, &hdrs, &scratch);
    try std.testing.expectEqual(1, n);
    try std.testing.expectEqualStrings("x-request-id", hdrs[0].name);
    try std.testing.expectEqualStrings("abc-123", hdrs[0].value);
}

// ------------------------------------------------------------------ //
// HPACK dynamic table eviction                                        //
// ------------------------------------------------------------------ //

test "unit: hpack dynamic table evicts oldest entry when table is full" {
    var dec = core.HpackDecoder.init();
    dec.max_size = 34; // exactly one entry: name(1) + value(1) + 32 = 34

    var hdrs: [8]core.Header = undefined;
    var scratch: [512]u8 = undefined;

    // Entry 1: name="x", value="y": literal with incremental indexing (0x40), new name.
    const block1 = [_]u8{ 0x40, 0x01, 'x', 0x01, 'y' };
    _ = try dec.decode(&block1, &hdrs, &scratch);
    try std.testing.expectEqual(1, dec.dyn_count);
    try std.testing.expectEqual(34, dec.dyn_size);

    // Entry 2: name="a", value="b": must evict entry 1 before adding.
    const block2 = [_]u8{ 0x40, 0x01, 'a', 0x01, 'b' };
    _ = try dec.decode(&block2, &hdrs, &scratch);
    try std.testing.expectEqual(1, dec.dyn_count); // entry 1 evicted
    try std.testing.expectEqual(34, dec.dyn_size);
}

test "unit: hpack dynamic table size update to zero evicts all entries" {
    var dec = core.HpackDecoder.init();
    var hdrs: [8]core.Header = undefined;
    var scratch: [512]u8 = undefined;

    // Add two entries (each 34 bytes: name(1) + value(1) + 32).
    const block1 = [_]u8{
        0x40, 0x01, 'x', 0x01, 'y',
        0x40, 0x01, 'a', 0x01, 'b',
    };
    _ = try dec.decode(&block1, &hdrs, &scratch);
    try std.testing.expectEqual(2, dec.dyn_count);

    // Dynamic table size update to 0: 0x20 = 001 00000 (RFC 7541 6.3, 5-bit prefix, value=0).
    const block2 = [_]u8{0x20};
    _ = try dec.decode(&block2, &hdrs, &scratch);
    try std.testing.expectEqual(0, dec.dyn_count);
    try std.testing.expectEqual(0, dec.dyn_size);
}
