//! ZIX http1 websocket frame
//!
//! ### file: src/zix/tcp/http1/websocket/WsFrame.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One parsed WebSocket frame: fin bit, opcode, and payload.
//!
//! ### note:
//!
//! payload borrows either the caller payload buffer (masked frame) or the
//! source bytes (unmasked frame). Copy it to keep it.
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

// --------------------------------------------------------- //
// Fields:

/// Last fragment of a message.
fin: bool,
/// Frame opcode.
opcode: Opcode,
/// Unmasked payload.
payload: []const u8,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1 websocket: WsFrame, keeps its fields" {
    const frame: Self = .{
        .fin = true,
        .opcode = .text,
        .payload = "hi",
    };

    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(Opcode.text, frame.opcode);
    try std.testing.expectEqualStrings("hi", frame.payload);
}

test "zix http1 websocket: WsFrame, holds an empty payload" {
    const frame: Self = .{
        .fin = false,
        .opcode = .continuation,
        .payload = &.{},
    };

    try std.testing.expectEqual(@as(usize, 0), frame.payload.len);
}

