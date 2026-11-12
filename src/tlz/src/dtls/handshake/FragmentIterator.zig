//! TLZ dtls handshake FragmentIterator
//!
//! ### file: src/tlz/src/dtls/handshake/FragmentIterator.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Walks the handshake fragments packed into one DTLS record body.
//!
//! ### note:
//!
//! Several messages may share a record as long as they belong to the same flight
//! (RFC 6347 4.2.3).
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
const Fragment = @import("Fragment.zig");

// --------------------------------------------------------- //
// Fields:

body: []const u8,
pos: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_DtlsFragmentIterator_Truncated,
};

/// The next fragment in the record body.
///
/// Return:
/// - Fragment (borrowing the body)
/// - null when the body is fully walked
/// - Error.Tlz_DtlsFragmentIterator_Truncated when a header or fragment runs past
///   the end
pub fn next(self: *Self) Error!?Fragment {
    if (self.pos == self.body.len) return null;

    const header = handshake.parseHeader(self.body[self.pos..]) catch |err| switch (err) {
        error.Tlz_DtlsHandshake_Truncated => return Error.Tlz_DtlsFragmentIterator_Truncated,
    };
    const data_start = self.pos + handshake.HEADER_LEN;
    const data_end = data_start + header.fragment_length;
    if (data_end > self.body.len) return Error.Tlz_DtlsFragmentIterator_Truncated;

    self.pos = data_end;

    return .{
        .header = header,
        .data = self.body[data_start..data_end],
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn writeMessage(out: []u8, msg_type: handshake.MessageType, seq: u16, body: []const u8) usize {
    handshake.writeHeader(out, .{
        .msg_type = msg_type,
        .length = @intCast(body.len),
        .message_seq = seq,
        .fragment_offset = 0,
        .fragment_length = @intCast(body.len),
    });
    @memcpy(out[handshake.HEADER_LEN..][0..body.len], body);

    return handshake.HEADER_LEN + body.len;
}

test "tlz dtls handshake: FragmentIterator, several messages share one record" {
    var body: [128]u8 = undefined;
    var used: usize = 0;

    used += writeMessage(body[used..], .SERVER_HELLO, 0, "server hello");
    used += writeMessage(body[used..], .CERTIFICATE, 1, "cert");
    used += writeMessage(body[used..], .SERVER_HELLO_DONE, 2, "");

    var iterator: Self = .{ .body = body[0..used] };
    const first = (try iterator.next()).?;
    const second = (try iterator.next()).?;
    const third = (try iterator.next()).?;

    try std.testing.expectEqualStrings("server hello", first.data);
    try std.testing.expectEqualStrings("cert", second.data);
    try std.testing.expectEqual(handshake.MessageType.SERVER_HELLO_DONE, third.header.msg_type);
    try std.testing.expectEqual(@as(?Fragment, null), try iterator.next());
}

test "tlz dtls handshake: FragmentIterator, a fragment past the record is truncated" {
    var body: [handshake.HEADER_LEN + 4]u8 = undefined;

    handshake.writeHeader(&body, .{
        .msg_type = .CERTIFICATE,
        .length = 100,
        .message_seq = 0,
        .fragment_offset = 0,
        .fragment_length = 100,
    });
    var iterator: Self = .{ .body = &body };

    try std.testing.expectError(Error.Tlz_DtlsFragmentIterator_Truncated, iterator.next());
}

test "tlz dtls handshake: FragmentIterator, a stub shorter than a header is truncated" {
    var iterator: Self = .{ .body = &[_]u8{ 1, 0, 0 } };

    try std.testing.expectError(Error.Tlz_DtlsFragmentIterator_Truncated, iterator.next());
}

test "tlz dtls handshake: FragmentIterator, an empty body gives null" {
    var iterator: Self = .{ .body = "" };

    try std.testing.expectEqual(@as(?Fragment, null), try iterator.next());
}

