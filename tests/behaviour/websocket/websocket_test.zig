//! Behaviour tests: zix.Http.WebSocket frame format contracts.
//! Verifies the RFC 6455 properties callers rely on: FIN bit always set
//! for single-frame messages and server frames are never masked.

const std = @import("std");
const zix = @import("zix");

const WS = zix.Http.WebSocket;

// --------------------------------------------------------- //

test "zix behaviour: buildFrame, FIN bit is always set" {
    var buf: [32]u8 = undefined;
    for ([_]WS.Opcode{ .text, .binary, .ping, .pong, .close }) |op| {
        _ = WS.buildFrame(&buf, op, "x");
        // RFC 6455 5.2: FIN is bit 7 of byte 0
        try std.testing.expectEqual(@as(u8, 0x80), buf[0] & 0x80);
    }
}

test "zix behaviour: buildFrame, server frames are unmasked (mask bit = 0)" {
    var buf: [32]u8 = undefined;
    _ = WS.buildFrame(&buf, .text, "hello");
    // RFC 6455 5.1: server->client frames MUST NOT be masked, mask bit is byte[1] bit 7
    try std.testing.expectEqual(@as(u8, 0), buf[1] & 0x80);
}
