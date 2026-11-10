//! ZIX http1 websocket frame codec
//!
//! ### file: src/zix/tcp/http1/websocket/frame.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! RFC 6455 frame codec: parse a client frame, build a server frame, and
//! compute the handshake accept key.
//!
//! ### note:
//!
//! A frame whose payload is larger than payload_buf is reported as too large,
//! never cut. Cutting it would leave the rest of the payload in the stream and
//! break frame sync.
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
const Opcode = @import("opcode.zig").Opcode;
const WsParseResult = @import("WsParseResult.zig");

// --------------------------------------------------------- //
// Private:

/// Largest payload length that fits in the 7-bit length field.
const LEN_MAX_7BIT: usize = 125;
/// 7-bit length value that means a 16-bit length follows.
const LEN_16BIT_MARKER: u8 = 126;
/// 7-bit length value that means a 64-bit length follows.
const LEN_64BIT_MARKER: u8 = 127;
const LEN_MAX_16BIT: usize = std.math.maxInt(u16);
const LEN_16BIT_FIELD_SIZE: usize = 2;
const LEN_64BIT_FIELD_SIZE: usize = 8;
const MASK_LEN: usize = 4;

/// Bytes unmasked per vector step.
const UNMASK_VEC_WIDTH: usize = 16;

/// Room for the client key plus the RFC 6455 GUID.
const ACCEPT_HASH_INPUT_SIZE: usize = 128;

/// RFC 6455 section 1.3 GUID. The spec fixes this value.
const RFC6455_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// XOR src with the repeating 4-byte mask into dst.
fn unmask(src: []const u8, mask: [MASK_LEN]u8, dst: []u8) []const u8 {
    var pattern: [UNMASK_VEC_WIDTH]u8 = undefined;
    for (&pattern, 0..) |*byte, i| byte.* = mask[i % MASK_LEN];

    const vec_mask: @Vector(UNMASK_VEC_WIDTH, u8) = pattern;
    var i: usize = 0;

    while (i + UNMASK_VEC_WIDTH <= src.len) : (i += UNMASK_VEC_WIDTH) {
        const chunk: @Vector(UNMASK_VEC_WIDTH, u8) = src[i..][0..UNMASK_VEC_WIDTH].*;
        dst[i..][0..UNMASK_VEC_WIDTH].* = chunk ^ vec_mask;
    }
    while (i < src.len) : (i += 1) {
        dst[i] = src[i] ^ mask[i % MASK_LEN];
    }

    return dst[0..src.len];
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 WebSocket frame error
pub const Error = error {
    ZixHttp1_WebSocketFrame_PayloadTooLarge,
    ZixHttp1_WebSocketFrame_KeyTooLong,
};

/// Largest server frame header: 2 bytes plus a 64-bit length.
pub const MAX_HEADER: usize = 10;

/// Encoded length of a Sec-WebSocket-Accept value.
pub const ACCEPT_LEN: usize = std.base64.standard.Encoder.calcSize(20);

/// Parse one WebSocket frame from the front of buf.
///
/// Note:
/// - A masked payload is unmasked into payload_buf. An unmasked payload is
///   returned as a slice of buf.
/// - payload_buf sets the largest accepted payload, masked or not.
///
/// Param:
/// buf - []const u8 (raw bytes from the connection)
/// payload_buf - []u8 (buffer for the unmasked payload)
///
/// Return:
/// - WsParseResult when buf holds one complete frame
/// - null when buf does not hold a complete frame yet
/// - error.ZixHttp1_WebSocketFrame_PayloadTooLarge when the payload is larger
///   than payload_buf
pub fn parseFrame(
    buf: []const u8,
    payload_buf: []u8,
) error{ZixHttp1_WebSocketFrame_PayloadTooLarge}!?WsParseResult {
    if (buf.len < 2) return null;

    const fin = (buf[0] & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(buf[0] & 0x0F);
    const masked = (buf[1] & 0x80) != 0;
    var payload_len: u64 = buf[1] & 0x7F;
    var offset: usize = 2;

    if (payload_len == LEN_16BIT_MARKER) {
        if (buf.len < offset + LEN_16BIT_FIELD_SIZE) return null;

        payload_len = std.mem.readInt(u16, buf[offset..][0..LEN_16BIT_FIELD_SIZE], .big);
        offset += LEN_16BIT_FIELD_SIZE;
    } else if (payload_len == LEN_64BIT_MARKER) {
        if (buf.len < offset + LEN_64BIT_FIELD_SIZE) return null;

        payload_len = std.mem.readInt(u64, buf[offset..][0..LEN_64BIT_FIELD_SIZE], .big);
        offset += LEN_64BIT_FIELD_SIZE;
    }

    if (payload_len > payload_buf.len) return error.ZixHttp1_WebSocketFrame_PayloadTooLarge;

    const len: usize = @intCast(payload_len);
    var mask: [MASK_LEN]u8 = @splat(0);

    if (masked) {
        if (buf.len < offset + MASK_LEN) return null;

        @memcpy(&mask, buf[offset..][0..MASK_LEN]);
        offset += MASK_LEN;
    }

    if (buf.len < offset + len) return null;

    const src = buf[offset..][0..len];
    const payload = if (masked) unmask(src, mask, payload_buf[0..len]) else src;

    return .{
        .frame = .{
            .fin = fin,
            .opcode = opcode,
            .payload = payload,
        },
        .consumed = offset + len,
    };
}

/// Build the header of a server frame (unmasked, RFC 6455 section 5.1),
/// without the payload.
///
/// Param:
/// buf - []u8 (destination, at least MAX_HEADER bytes)
/// opcode - Opcode
/// payload_len - usize (length the payload will be)
///
/// Return:
/// - usize (header bytes written into buf)
pub fn buildHeader(buf: []u8, opcode: Opcode, payload_len: usize) usize {
    buf[0] = 0x80 | @intFromEnum(opcode);

    if (payload_len <= LEN_MAX_7BIT) {
        buf[1] = @intCast(payload_len);

        return 2;
    }

    if (payload_len <= LEN_MAX_16BIT) {
        buf[1] = LEN_16BIT_MARKER;
        std.mem.writeInt(u16, buf[2..][0..LEN_16BIT_FIELD_SIZE], @intCast(payload_len), .big);

        return 2 + LEN_16BIT_FIELD_SIZE;
    }

    buf[1] = LEN_64BIT_MARKER;
    std.mem.writeInt(u64, buf[2..][0..LEN_64BIT_FIELD_SIZE], payload_len, .big);

    return 2 + LEN_64BIT_FIELD_SIZE;
}

/// Build a whole server frame (unmasked, RFC 6455 section 5.1).
///
/// Param:
/// buf - []u8 (destination, at least payload.len + MAX_HEADER bytes)
/// opcode - Opcode
/// payload - []const u8
///
/// Return:
/// - usize (bytes written into buf)
pub fn buildFrame(buf: []u8, opcode: Opcode, payload: []const u8) usize {
    const header_len = buildHeader(buf, opcode, payload.len);

    @memcpy(buf[header_len..][0..payload.len], payload);

    return header_len + payload.len;
}

/// Compute Sec-WebSocket-Accept from Sec-WebSocket-Key (RFC 6455 section 4.2.2).
///
/// Param:
/// key - []const u8 (value of the Sec-WebSocket-Key request header)
/// out - *[64]u8 (output buffer, the result is a slice of it)
///
/// Return:
/// - []const u8 (the accept value, ACCEPT_LEN bytes)
/// - error.ZixHttp1_WebSocketFrame_KeyTooLong when the key does not fit
pub fn acceptKey(
    key: []const u8,
    out: *[64]u8,
) error{ZixHttp1_WebSocketFrame_KeyTooLong}![]const u8 {
    var hash_input: [ACCEPT_HASH_INPUT_SIZE]u8 = undefined;
    if (key.len + RFC6455_GUID.len > hash_input.len) {
        return error.ZixHttp1_WebSocketFrame_KeyTooLong;
    }

    @memcpy(hash_input[0..key.len], key);
    @memcpy(hash_input[key.len..][0..RFC6455_GUID.len], RFC6455_GUID);

    var hash: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(hash_input[0 .. key.len + RFC6455_GUID.len], &hash, .{});

    return std.base64.standard.Encoder.encode(out[0..ACCEPT_LEN], &hash);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Build a masked client frame with a 7-bit length.
fn testMaskedFrame(out: []u8, opcode: Opcode, payload: []const u8, mask: [4]u8) usize {
    out[0] = 0x80 | @intFromEnum(opcode);
    out[1] = 0x80 | @as(u8, @intCast(payload.len));
    @memcpy(out[2..6], &mask);
    for (payload, 0..) |byte, i| out[6 + i] = byte ^ mask[i % 4];

    return 6 + payload.len;
}

test "zix http1 websocket: frame, acceptKey matches the RFC 6455 vector" {
    var out: [64]u8 = undefined;
    const accept = try acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);

    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "zix http1 websocket: frame, acceptKey rejects a key too long" {
    var out: [64]u8 = undefined;
    const key: [ACCEPT_HASH_INPUT_SIZE]u8 = @splat('k');

    try std.testing.expectError(
        Error.ZixHttp1_WebSocketFrame_KeyTooLong,
        acceptKey(&key, &out),
    );
}

test "zix http1 websocket: frame, buildFrame then parseFrame round trips" {
    var buf: [128]u8 = undefined;
    const len = buildFrame(&buf, .text, "hello");

    try std.testing.expectEqual(@as(u8, 0x81), buf[0]);
    try std.testing.expectEqual(@as(u8, 5), buf[1]);

    var payload_buf: [128]u8 = undefined;
    const result = (try parseFrame(buf[0..len], &payload_buf)).?;

    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqual(Opcode.text, result.frame.opcode);
    try std.testing.expectEqualStrings("hello", result.frame.payload);
    try std.testing.expectEqual(len, result.consumed);
}

test "zix http1 websocket: frame, parseFrame unmasks the RFC 6455 vector" {
    const raw = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    var payload_buf: [128]u8 = undefined;
    const result = (try parseFrame(&raw, &payload_buf)).?;

    try std.testing.expectEqualStrings("Hello", result.frame.payload);
    try std.testing.expectEqual(raw.len, result.consumed);
}

test "zix http1 websocket: frame, parseFrame unmasks two full vectors" {
    const plain = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef";
    var raw: [6 + plain.len]u8 = undefined;
    const len = testMaskedFrame(&raw, .binary, plain, .{ 0xAA, 0xBB, 0xCC, 0xDD });

    var payload_buf: [64]u8 = undefined;
    const result = (try parseFrame(raw[0..len], &payload_buf)).?;

    try std.testing.expectEqualStrings(plain, result.frame.payload);
}

test "zix http1 websocket: frame, parseFrame unmasks a vector plus tail" {
    const plain = "12345678901234567";
    var raw: [6 + plain.len]u8 = undefined;
    const len = testMaskedFrame(&raw, .binary, plain, .{ 0x11, 0x22, 0x33, 0x44 });

    var payload_buf: [64]u8 = undefined;
    const result = (try parseFrame(raw[0..len], &payload_buf)).?;

    try std.testing.expectEqualStrings(plain, result.frame.payload);
}

test "zix http1 websocket: frame, parseFrame waits on a partial header" {
    const raw = [_]u8{0x81};
    var payload_buf: [16]u8 = undefined;

    try std.testing.expect((try parseFrame(&raw, &payload_buf)) == null);
}

test "zix http1 websocket: frame, parseFrame waits on a partial payload" {
    var raw: [16]u8 = undefined;
    const len = testMaskedFrame(&raw, .text, "hello", .{ 1, 2, 3, 4 });
    var payload_buf: [16]u8 = undefined;

    try std.testing.expect((try parseFrame(raw[0 .. len - 1], &payload_buf)) == null);
}

test "zix http1 websocket: frame, parseFrame waits on a partial mask" {
    const raw = [_]u8{ 0x81, 0x85, 0x01, 0x02 };
    var payload_buf: [16]u8 = undefined;

    try std.testing.expect((try parseFrame(&raw, &payload_buf)) == null);
}

test "zix http1 websocket: frame, parseFrame reads a 16-bit length" {
    var buf: [300 + MAX_HEADER]u8 = undefined;
    const payload: [300]u8 = @splat('a');
    const len = buildFrame(&buf, .binary, &payload);

    try std.testing.expectEqual(LEN_16BIT_MARKER, buf[1]);

    var payload_buf: [512]u8 = undefined;
    const result = (try parseFrame(buf[0..len], &payload_buf)).?;

    try std.testing.expectEqual(@as(usize, 300), result.frame.payload.len);
    try std.testing.expectEqual(len, result.consumed);
}

test "zix http1 websocket: frame, parseFrame reads a 64-bit length" {
    const size = LEN_MAX_16BIT + 1;
    const buf = try std.testing.allocator.alloc(u8, size + MAX_HEADER);
    defer std.testing.allocator.free(buf);
    const payload = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(payload);
    const payload_buf = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(payload_buf);

    @memset(payload, 'z');
    const len = buildFrame(buf, .binary, payload);

    try std.testing.expectEqual(LEN_64BIT_MARKER, buf[1]);
    try std.testing.expectEqual(@as(usize, 2 + LEN_64BIT_FIELD_SIZE), len - size);

    const result = (try parseFrame(buf[0..len], payload_buf)).?;

    try std.testing.expectEqual(size, result.frame.payload.len);
}

test "zix http1 websocket: frame, parseFrame rejects a payload too large" {
    var raw: [16]u8 = undefined;
    const len = testMaskedFrame(&raw, .text, "hello", .{ 1, 2, 3, 4 });
    var payload_buf: [4]u8 = undefined;

    try std.testing.expectError(
        error.ZixHttp1_WebSocketFrame_PayloadTooLarge,
        parseFrame(raw[0..len], &payload_buf),
    );
}

test "zix http1 websocket: frame, parseFrame rejects a huge length before the payload" {
    const raw = [_]u8{ 0x82, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var payload_buf: [16]u8 = undefined;

    try std.testing.expectError(
        error.ZixHttp1_WebSocketFrame_PayloadTooLarge,
        parseFrame(&raw, &payload_buf),
    );
}

test "zix http1 websocket: frame, parseFrame keeps an unmasked payload in place" {
    var buf: [16]u8 = undefined;
    const len = buildFrame(&buf, .text, "abc");
    var payload_buf: [16]u8 = undefined;
    const result = (try parseFrame(buf[0..len], &payload_buf)).?;

    try std.testing.expect(result.frame.payload.ptr == buf[2..].ptr);
}

test "zix http1 websocket: frame, parseFrame reads the fin bit clear" {
    const raw = [_]u8{ 0x01, 0x00 };
    var payload_buf: [4]u8 = undefined;
    const result = (try parseFrame(&raw, &payload_buf)).?;

    try std.testing.expect(!result.frame.fin);
    try std.testing.expectEqual(@as(usize, 2), result.consumed);
}

test "zix http1 websocket: frame, buildHeader matches the buildFrame prefix" {
    var frame_buf: [128]u8 = undefined;
    var header_buf: [MAX_HEADER]u8 = undefined;
    const frame_len = buildFrame(&frame_buf, .text, "hello");
    const header_len = buildHeader(&header_buf, .text, 5);

    try std.testing.expectEqual(frame_len - 5, header_len);
    try std.testing.expectEqualSlices(u8, frame_buf[0..header_len], header_buf[0..header_len]);
}

test "zix http1 websocket: frame, buildHeader uses 7 bits at 125" {
    var header_buf: [MAX_HEADER]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 2), buildHeader(&header_buf, .text, LEN_MAX_7BIT));
    try std.testing.expectEqual(
        @as(usize, 4),
        buildHeader(&header_buf, .text, LEN_MAX_7BIT + 1),
    );
}

