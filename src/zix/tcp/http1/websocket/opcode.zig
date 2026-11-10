//! ZIX http1 websocket opcode
//!
//! ### file: src/zix/tcp/http1/websocket/opcode.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! RFC 6455 frame opcodes (section 5.2).
//!
//! ### note:
//!
//! The enum is non-exhaustive, so a reserved opcode still parses. The frame
//! loop ignores it.
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

// --------------------------------------------------------- //
// Public:

/// Opcode in the low 4 bits of the first frame byte.
pub const Opcode = enum(u8) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1 websocket: opcode, data values follow RFC 6455" {
    try std.testing.expectEqual(@as(u8, 0x0), @intFromEnum(Opcode.continuation));
    try std.testing.expectEqual(@as(u8, 0x1), @intFromEnum(Opcode.text));
    try std.testing.expectEqual(@as(u8, 0x2), @intFromEnum(Opcode.binary));
}

test "zix http1 websocket: opcode, control values follow RFC 6455" {
    try std.testing.expectEqual(@as(u8, 0x8), @intFromEnum(Opcode.close));
    try std.testing.expectEqual(@as(u8, 0x9), @intFromEnum(Opcode.ping));
    try std.testing.expectEqual(@as(u8, 0xA), @intFromEnum(Opcode.pong));
}

test "zix http1 websocket: opcode, reserved value round trips" {
    const reserved: Opcode = @enumFromInt(0x3);

    try std.testing.expectEqual(@as(u8, 0x3), @intFromEnum(reserved));
}

