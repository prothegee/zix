//! TLZ dtls handshake Fragmenter
//!
//! ### file: src/tlz/src/dtls/handshake/Fragmenter.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Cuts one DTLS handshake message into fragments that each fit a size limit
//! (RFC 6347 4.2.3).
//!
//! ### note:
//!
//! The limit is on the fragment BODY, so a caller sizing against a PMTU subtracts
//! its record and header overhead first. A message shorter than the limit comes out
//! as one fragment covering all of it.
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
const handshake = @import("../handshake.zig");
const MessageType = @import("message_type.zig").MessageType;

// --------------------------------------------------------- //
// Fields:

msg_type: MessageType,
message_seq: u16,
/// The whole message body to cut up.
body: []const u8,
max_fragment_len: usize,
pos: usize = 0,
/// Set after the first fragment, so an empty message still emits one.
emitted: bool = false,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Write the next fragment, header included, into `out`.
///
/// Param:
/// out - []u8 (room for a header and at least one body byte)
///
/// Usage:
/// ```zig
/// var fragmenter: Fragmenter = .{
///     .msg_type = .CERTIFICATE,
///     .message_seq = 2,
///     .body = certificate_bytes,
///     .max_fragment_len = 1000,
/// };
///
/// var buf: [1024]u8 = undefined;
/// while (fragmenter.next(&buf)) |piece| try sendRecord(piece);
/// ```
///
/// Return:
/// - []const u8 (the fragment, borrowing `out`)
/// - null when the message is fully emitted, or `out` cannot hold a header and one
///   byte
pub fn next(self: *Self, out: []u8) ?[]const u8 {
    if (self.emitted and self.pos == self.body.len) return null;
    if (out.len <= handshake.HEADER_LEN) return null;
    if (self.max_fragment_len == 0) return null;

    const room = @min(out.len - handshake.HEADER_LEN, self.max_fragment_len);
    const take = @min(room, self.body.len - self.pos);

    handshake.writeHeader(out, .{
        .msg_type = self.msg_type,
        .length = @intCast(self.body.len),
        .message_seq = self.message_seq,
        .fragment_offset = @intCast(self.pos),
        .fragment_length = @intCast(take),
    });
    @memcpy(out[handshake.HEADER_LEN..][0..take], self.body[self.pos..][0..take]);

    self.pos += take;
    self.emitted = true;

    return out[0 .. handshake.HEADER_LEN + take];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls handshake: Fragmenter, a short message comes out whole" {
    var out: [128]u8 = undefined;
    var fragmenter: Self = .{
        .msg_type = .FINISHED,
        .message_seq = 5,
        .body = "verify_data",
        .max_fragment_len = 1000,
    };

    const piece = fragmenter.next(&out).?;
    const header = try handshake.parseHeader(piece);

    try std.testing.expect(header.isWholeMessage());
    try std.testing.expectEqual(@as(u24, 11), header.length);
    try std.testing.expectEqualStrings("verify_data", piece[handshake.HEADER_LEN..]);
    try std.testing.expectEqual(@as(?[]const u8, null), fragmenter.next(&out));
}

test "tlz dtls handshake: Fragmenter, an empty message still emits one fragment" {
    var out: [64]u8 = undefined;
    var fragmenter: Self = .{
        .msg_type = .SERVER_HELLO_DONE,
        .message_seq = 3,
        .body = "",
        .max_fragment_len = 100,
    };

    const piece = fragmenter.next(&out).?;

    try std.testing.expectEqual(handshake.HEADER_LEN, piece.len);
    try std.testing.expectEqual(@as(?[]const u8, null), fragmenter.next(&out));
}

test "tlz dtls handshake: Fragmenter, a long message splits at the limit" {
    var body: [250]u8 = undefined;
    for (&body, 0..) |*byte, i| byte.* = @intCast(i);

    var out: [512]u8 = undefined;
    var fragmenter: Self = .{
        .msg_type = .CERTIFICATE,
        .message_seq = 2,
        .body = &body,
        .max_fragment_len = 100,
    };
    var pieces: usize = 0;

    while (fragmenter.next(&out)) |piece| : (pieces += 1) {
        const header = try handshake.parseHeader(piece);

        try std.testing.expectEqual(@as(u24, 250), header.length);
        try std.testing.expectEqual(@as(u24, @intCast(pieces * 100)), header.fragment_offset);
    }

    try std.testing.expectEqual(@as(usize, 3), pieces);
}

test "tlz dtls handshake: Fragmenter, a small out buffer caps the fragment" {
    var out: [handshake.HEADER_LEN + 4]u8 = undefined;
    var fragmenter: Self = .{
        .msg_type = .CERTIFICATE,
        .message_seq = 2,
        .body = "abcdefgh",
        .max_fragment_len = 100,
    };

    const piece = fragmenter.next(&out).?;

    try std.testing.expectEqualStrings("abcd", piece[handshake.HEADER_LEN..]);
}

test "tlz dtls handshake: Fragmenter, an out buffer of only a header gives null" {
    var out: [handshake.HEADER_LEN]u8 = undefined;
    var fragmenter: Self = .{
        .msg_type = .CERTIFICATE,
        .message_seq = 2,
        .body = "abc",
        .max_fragment_len = 100,
    };

    try std.testing.expectEqual(@as(?[]const u8, null), fragmenter.next(&out));
}

test "tlz dtls handshake: Fragmenter, a zero fragment limit gives null" {
    var out: [64]u8 = undefined;
    var fragmenter: Self = .{
        .msg_type = .CERTIFICATE,
        .message_seq = 2,
        .body = "abc",
        .max_fragment_len = 0,
    };

    try std.testing.expectEqual(@as(?[]const u8, null), fragmenter.next(&out));
}

