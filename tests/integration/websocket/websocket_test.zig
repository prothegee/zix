//! Integration tests: WebSocket buildFrame + parseFrame round-trips.
//! Verifies that encoded frames decode correctly for all non-text opcodes.

const std = @import("std");
const zix = @import("zix");

const WS = zix.Http.WebSocket;

test "zix integration: WebSocket binary frame round-trip" {
    var frame_buf: [32]u8 = undefined;
    var payload_buf: [256]u8 = undefined;
    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const len = WS.buildFrame(&frame_buf, .binary, &data);
    const result = WS.parseFrame(frame_buf[0..len], &payload_buf).?;
    try std.testing.expectEqual(WS.Opcode.binary, result.frame.opcode);
    try std.testing.expectEqualSlices(u8, &data, result.frame.payload);
    try std.testing.expectEqual(len, result.consumed);
}

test "zix integration: WebSocket ping + pong round-trips" {
    var frame_buf: [32]u8 = undefined;
    var payload_buf: [256]u8 = undefined;

    const ping_len = WS.buildFrame(&frame_buf, .ping, "ping!");
    const ping_result = WS.parseFrame(frame_buf[0..ping_len], &payload_buf).?;
    try std.testing.expectEqual(WS.Opcode.ping, ping_result.frame.opcode);
    try std.testing.expectEqualStrings("ping!", ping_result.frame.payload);

    const pong_len = WS.buildFrame(&frame_buf, .pong, "pong");
    const pong_result = WS.parseFrame(frame_buf[0..pong_len], &payload_buf).?;
    try std.testing.expectEqual(WS.Opcode.pong, pong_result.frame.opcode);
    try std.testing.expectEqualStrings("pong", pong_result.frame.payload);
}

test "zix integration: WebSocket close frame round-trip, empty payload" {
    var frame_buf: [16]u8 = undefined;
    var payload_buf: [256]u8 = undefined;
    const len = WS.buildFrame(&frame_buf, .close, &.{});
    const result = WS.parseFrame(frame_buf[0..len], &payload_buf).?;
    try std.testing.expectEqual(WS.Opcode.close, result.frame.opcode);
    try std.testing.expectEqual(@as(usize, 0), result.frame.payload.len);
}

test "zix integration: WebSocket RoomMap, init and deinit with no connections" {
    var rooms = WS.RoomMap.init(std.testing.allocator);
    rooms.deinit();
}
