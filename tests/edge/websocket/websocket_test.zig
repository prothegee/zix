//! Edge tests: zix.Http.WebSocket frame parsing and handshake boundary conditions.
//! Verifies: incomplete frames return null, extended 16-bit length encoding,
//! and acceptKey rejects keys that exceed the 128-byte hash_input buffer.

const std = @import("std");
const zix = @import("zix");

const WS = zix.Http.WebSocket;

// --------------------------------------------------------- //

test "zix edge: parseFrame, fewer than 2 bytes returns null" {
    var payload_buf: [256]u8 = undefined;
    try std.testing.expect(WS.parseFrame(&.{}, &payload_buf) == null);
    try std.testing.expect(WS.parseFrame(&.{0x81}, &payload_buf) == null);
}

test "zix edge: parseFrame, header present but payload truncated returns null" {
    var payload_buf: [256]u8 = undefined;
    // header says payload_len=5 but only 3 payload bytes are present
    const partial = [_]u8{ 0x81, 5, 'H', 'i', '!' };
    try std.testing.expect(WS.parseFrame(&partial, &payload_buf) == null);
}

test "zix edge: parseFrame, extended 16-bit length (126-tier) is parsed correctly" {
    const PAYLOAD_LEN = 130;
    var payload: [PAYLOAD_LEN]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);

    var frame_buf: [PAYLOAD_LEN + 10]u8 = undefined;
    const len = WS.buildFrame(&frame_buf, .binary, &payload);

    // byte[1] must carry the 126 marker (unmasked frame has mask bit = 0)
    try std.testing.expectEqual(@as(u8, 126), frame_buf[1] & 0x7F);

    var payload_buf: [PAYLOAD_LEN]u8 = undefined;
    const result = WS.parseFrame(frame_buf[0..len], &payload_buf).?;
    try std.testing.expectEqual(WS.Opcode.binary, result.frame.opcode);
    try std.testing.expectEqual(PAYLOAD_LEN, result.frame.payload.len);
    try std.testing.expectEqualSlices(u8, &payload, result.frame.payload);
    try std.testing.expectEqual(len, result.consumed);
}

// --------------------------------------------------------- //

test "zix edge: acceptKey, key that exceeds hash_input buffer returns KeyTooLong" {
    // GUID is 36 bytes, key + GUID must fit in 128 bytes, so max key length is 92.
    // A 93-byte key must be rejected.
    var out: [64]u8 = undefined;
    const long_key_buf: [93]u8 = @splat('A');
    const long_key: []const u8 = &long_key_buf;
    try std.testing.expectError(error.KeyTooLong, WS.acceptKey(long_key, &out));
}
