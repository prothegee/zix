//! Integration tests: zix.Http.WebSocket protocol layer.
//! Covers gaps not in the unit tests in src/tcp/http/websocket.zig:
//!   - parseFrame for all non-text opcodes (close, ping, pong, binary)
//!   - parseFrame incomplete frame → null
//!   - parseFrame extended 16-bit payload length (126-tier)
//!   - buildFrame for all opcodes
//!   - buildFrame extended length encoding
//!   - buildFrame + parseFrame round-trip for all opcodes
//!   - acceptKey: key too long → error.KeyTooLong
//!   - RoomMap: init and deinit with no connections

const std = @import("std");
const zix = @import("zix");

const WS = zix.Http.WebSocket;

// --------------------------------------------------------- //

test "zix integration: parseFrame — incomplete returns null" {
    var payload_buf: [256]u8 = undefined;

    // fewer than 2 bytes → null (can't read header)
    try std.testing.expect(WS.parseFrame(&.{0x81}, &payload_buf) == null);
    try std.testing.expect(WS.parseFrame(&.{}, &payload_buf) == null);

    // header says payload_len=5 but only 3 payload bytes present → null
    const partial = [_]u8{ 0x81, 5, 'H', 'i', '!' }; // 3 of 5
    try std.testing.expect(WS.parseFrame(&partial, &payload_buf) == null);
}

test "zix integration: parseFrame — binary opcode" {
    var payload_buf: [256]u8 = undefined;
    const data = [_]u8{0xDE, 0xAD, 0xBE, 0xEF};
    // build raw unmasked binary frame manually
    var frame_buf: [16]u8 = undefined;
    const len = WS.buildFrame(&frame_buf, .binary, &data);

    const result = WS.parseFrame(frame_buf[0..len], &payload_buf).?;
    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqual(WS.Opcode.binary, result.frame.opcode);
    try std.testing.expectEqualSlices(u8, &data, result.frame.payload);
    try std.testing.expectEqual(len, result.consumed);
}

test "zix integration: parseFrame — ping opcode with payload" {
    var payload_buf: [256]u8 = undefined;
    const ping_data = "ping!";
    var frame_buf: [32]u8 = undefined;
    const len = WS.buildFrame(&frame_buf, .ping, ping_data);

    const result = WS.parseFrame(frame_buf[0..len], &payload_buf).?;
    try std.testing.expectEqual(WS.Opcode.ping, result.frame.opcode);
    try std.testing.expectEqualStrings(ping_data, result.frame.payload);
}

test "zix integration: parseFrame — pong opcode" {
    var payload_buf: [256]u8 = undefined;
    var frame_buf: [32]u8 = undefined;
    const len = WS.buildFrame(&frame_buf, .pong, "pong");

    const result = WS.parseFrame(frame_buf[0..len], &payload_buf).?;
    try std.testing.expectEqual(WS.Opcode.pong, result.frame.opcode);
    try std.testing.expectEqualStrings("pong", result.frame.payload);
}

test "zix integration: parseFrame — close opcode, empty payload" {
    var payload_buf: [256]u8 = undefined;
    var frame_buf: [16]u8 = undefined;
    const len = WS.buildFrame(&frame_buf, .close, &.{});

    const result = WS.parseFrame(frame_buf[0..len], &payload_buf).?;
    try std.testing.expectEqual(WS.Opcode.close, result.frame.opcode);
    try std.testing.expectEqual(@as(usize, 0), result.frame.payload.len);
    try std.testing.expectEqual(len, result.consumed);
}

test "zix integration: parseFrame — extended 16-bit length (126-tier)" {
    // payload > 125 bytes triggers the 126-tier: 2 extra length bytes in header.
    const PAYLOAD_LEN = 130;
    var payload: [PAYLOAD_LEN]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);

    var frame_buf: [PAYLOAD_LEN + 10]u8 = undefined;
    const len = WS.buildFrame(&frame_buf, .binary, &payload);

    // header: byte[1] must be 126 (extended marker)
    try std.testing.expectEqual(@as(u8, 126), frame_buf[1] & 0x7F);

    var payload_buf: [PAYLOAD_LEN]u8 = undefined;
    const result = WS.parseFrame(frame_buf[0..len], &payload_buf).?;
    try std.testing.expectEqual(WS.Opcode.binary, result.frame.opcode);
    try std.testing.expectEqual(PAYLOAD_LEN, result.frame.payload.len);
    try std.testing.expectEqualSlices(u8, &payload, result.frame.payload);
    try std.testing.expectEqual(len, result.consumed);
}

test "zix integration: buildFrame — server frames are unmasked (mask bit = 0)" {
    var buf: [32]u8 = undefined;
    _ = WS.buildFrame(&buf, .text, "hello");
    // RFC 6455 5.1: server→client frames MUST NOT be masked; mask bit is byte[1] & 0x80
    try std.testing.expectEqual(@as(u8, 0), buf[1] & 0x80);
}

test "zix integration: buildFrame — fin bit is always set (single-frame messages)" {
    var buf: [32]u8 = undefined;
    for ([_]WS.Opcode{ .text, .binary, .ping, .pong, .close }) |op| {
        _ = WS.buildFrame(&buf, op, "x");
        try std.testing.expectEqual(@as(u8, 0x80), buf[0] & 0x80); // FIN bit
    }
}

test "zix integration: buildFrame + parseFrame round-trip — all opcodes" {
    var frame_buf: [256]u8 = undefined;
    var payload_buf: [256]u8 = undefined;
    const test_payload = "roundtrip";

    for ([_]WS.Opcode{ .text, .binary, .ping, .pong }) |op| {
        const len = WS.buildFrame(&frame_buf, op, test_payload);
        const result = WS.parseFrame(frame_buf[0..len], &payload_buf).?;
        try std.testing.expectEqual(op, result.frame.opcode);
        try std.testing.expectEqualStrings(test_payload, result.frame.payload);
        try std.testing.expectEqual(len, result.consumed);
    }

    // close with empty payload
    const clen = WS.buildFrame(&frame_buf, .close, &.{});
    const cresult = WS.parseFrame(frame_buf[0..clen], &payload_buf).?;
    try std.testing.expectEqual(WS.Opcode.close, cresult.frame.opcode);
}

test "zix integration: acceptKey — key too long returns error" {
    // RFC 6455: key + GUID must fit in 128 bytes. GUID is 36 bytes → key must be ≤ 92.
    var out: [64]u8 = undefined;
    const long_key = "A" ** 93; // 93 bytes > 92 limit
    try std.testing.expectError(error.KeyTooLong, WS.acceptKey(long_key, &out));
}

test "zix integration: RoomMap — init and deinit with no connections" {
    var rooms = WS.RoomMap.init(std.testing.allocator);
    rooms.deinit(); // must not crash or leak
}
