//! TLZ dtls handshake reassembler
//!
//! ### file: src/tlz/src/dtls/handshake/reassembler.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! `Reassembler`: buffers the fragments of one DTLS handshake message until every
//! byte has arrived (RFC 6347 4.2.3).
//!
//! ### note:
//!
//! Tracks which BYTES arrived, in a bitmap, rather than counting them. Overlapping
//! fragments are legal, so a byte counter would reach the message length with holes
//! still in it. Holds one message at a time, a caller resets between messages.
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
const MessageType = @import("message_type.zig").MessageType;

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_DtlsReassembler_Truncated,
    Tlz_DtlsReassembler_BadFragment,
    Tlz_DtlsReassembler_LengthMismatch,
    Tlz_DtlsReassembler_SequenceMismatch,
    Tlz_DtlsReassembler_MessageTooLarge,
};

/// A reassembler for messages up to `max_message_len` bytes.
///
/// Param:
/// max_message_len - usize (largest message it can hold, sized for the biggest
///   message the caller expects, usually the certificate)
///
/// Usage:
/// ```zig
/// var reassembler: Reassembler(4096) = .{};
///
/// try reassembler.accept(fragment);
/// if (reassembler.message()) |whole| try handle(whole);
/// reassembler.reset();
/// ```
///
/// Return:
/// - type
pub fn Reassembler(comptime max_message_len: usize) type {
    return struct {
        msg_type: MessageType = .HELLO_REQUEST,
        message_seq: u16 = 0,
        length: usize = 0,
        started: bool = false,
        /// Distinct message bytes received so far.
        have: usize = 0,
        buf: [max_message_len]u8 = undefined,
        received: [(max_message_len + 7) / 8]u8 = @splat(0),

        const Self = @This();

        /// Mark a byte range as arrived, counting only bytes not already held.
        fn markReceived(self: *Self, offset: u24, len: u24) void {
            for (offset..@as(usize, offset) + len) |index| {
                const mask: u8 = @as(u8, 1) << @intCast(index % 8);
                if (self.received[index / 8] & mask != 0) continue;

                self.received[index / 8] |= mask;
                self.have += 1;
            }
        }

        /// Largest message this reassembler accepts.
        pub const CAPACITY: usize = max_message_len;

        /// Take one fragment.
        ///
        /// Note:
        /// - The first fragment fixes the message being collected. Every later one
        ///   must agree on sequence and length.
        ///
        /// Param:
        /// fragment - Fragment (one fragment, data borrowed only for this call)
        ///
        /// Return:
        /// - void
        /// - Error.Tlz_DtlsReassembler_Truncated when the data is shorter than
        ///   fragment_length says
        /// - Error.Tlz_DtlsReassembler_BadFragment when the fragment reaches past the
        ///   end of the message
        /// - Error.Tlz_DtlsReassembler_MessageTooLarge when the message does not fit
        ///   CAPACITY
        /// - Error.Tlz_DtlsReassembler_SequenceMismatch when it belongs to another
        ///   message
        /// - Error.Tlz_DtlsReassembler_LengthMismatch when its message length
        ///   disagrees with the message in progress
        pub fn accept(self: *Self, fragment: Fragment) Error!void {
            const header = fragment.header;
            const fragment_end = @as(usize, header.fragment_offset) + header.fragment_length;
            if (fragment.data.len != header.fragment_length) {
                return Error.Tlz_DtlsReassembler_Truncated;
            }
            if (fragment_end > header.length) return Error.Tlz_DtlsReassembler_BadFragment;

            if (!self.started) {
                if (header.length > CAPACITY) return Error.Tlz_DtlsReassembler_MessageTooLarge;

                self.msg_type = header.msg_type;
                self.message_seq = header.message_seq;
                self.length = header.length;
                self.started = true;
            } else {
                if (header.message_seq != self.message_seq) {
                    return Error.Tlz_DtlsReassembler_SequenceMismatch;
                }
                if (header.length != self.length) {
                    return Error.Tlz_DtlsReassembler_LengthMismatch;
                }
            }

            @memcpy(self.buf[header.fragment_offset..fragment_end], fragment.data);
            self.markReceived(header.fragment_offset, header.fragment_length);
        }

        /// Whether every byte of the message has arrived.
        ///
        /// Return:
        /// - bool
        pub fn isComplete(self: *const Self) bool {
            return self.started and self.have == self.length;
        }

        /// The reassembled message.
        ///
        /// Return:
        /// - []const u8 (borrowing the reassembler)
        /// - null while bytes are still missing
        pub fn message(self: *const Self) ?[]const u8 {
            if (!self.isComplete()) return null;

            return self.buf[0..self.length];
        }

        /// Drop everything and wait for a new message.
        ///
        /// Return:
        /// - void
        pub fn reset(self: *Self) void {
            self.started = false;
            self.length = 0;
            self.have = 0;
            self.received = @splat(0);
        }
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn fragmentOf(body: []const u8, message_seq: u16, offset: u24, len: u24) Fragment {
    return .{
        .header = .{
            .msg_type = .CERTIFICATE,
            .length = @intCast(body.len),
            .message_seq = message_seq,
            .fragment_offset = offset,
            .fragment_length = len,
        },
        .data = body[offset..][0..len],
    };
}

fn patternBody(comptime len: usize, comptime step: usize) [len]u8 {
    var body: [len]u8 = undefined;
    for (&body, 0..) |*byte, i| byte.* = @intCast((i * step) % 251);

    return body;
}

test "tlz dtls handshake: Reassembler, in-order fragments rebuild the message" {
    const body = patternBody(300, 1);
    var reassembler: Reassembler(1024) = .{};

    try reassembler.accept(fragmentOf(&body, 7, 0, 100));
    try std.testing.expectEqual(@as(?[]const u8, null), reassembler.message());

    try reassembler.accept(fragmentOf(&body, 7, 100, 100));
    try reassembler.accept(fragmentOf(&body, 7, 200, 100));

    try std.testing.expectEqualSlices(u8, &body, reassembler.message().?);
    try std.testing.expectEqual(MessageType.CERTIFICATE, reassembler.msg_type);
    try std.testing.expectEqual(@as(u16, 7), reassembler.message_seq);
}

test "tlz dtls handshake: Reassembler, out-of-order fragments rebuild the message" {
    const body = patternBody(300, 1);
    var reassembler: Reassembler(1024) = .{};

    try reassembler.accept(fragmentOf(&body, 1, 200, 100));
    try reassembler.accept(fragmentOf(&body, 1, 0, 100));
    try std.testing.expect(!reassembler.isComplete());

    try reassembler.accept(fragmentOf(&body, 1, 100, 100));

    try std.testing.expectEqualSlices(u8, &body, reassembler.message().?);
}

test "tlz dtls handshake: Reassembler, overlapping fragments do not fake completeness" {
    const body = patternBody(300, 1);
    var reassembler: Reassembler(1024) = .{};

    try reassembler.accept(fragmentOf(&body, 2, 0, 150));
    try reassembler.accept(fragmentOf(&body, 2, 100, 100));

    try std.testing.expect(!reassembler.isComplete());
    try std.testing.expectEqual(@as(usize, 200), reassembler.have);

    try reassembler.accept(fragmentOf(&body, 2, 150, 150));

    try std.testing.expectEqualSlices(u8, &body, reassembler.message().?);
}

test "tlz dtls handshake: Reassembler, a duplicate fragment is counted once" {
    const body = patternBody(100, 1);
    var reassembler: Reassembler(256) = .{};

    try reassembler.accept(fragmentOf(&body, 0, 0, 50));
    try reassembler.accept(fragmentOf(&body, 0, 0, 50));
    try reassembler.accept(fragmentOf(&body, 0, 0, 50));

    try std.testing.expectEqual(@as(usize, 50), reassembler.have);
    try std.testing.expect(!reassembler.isComplete());
}

test "tlz dtls handshake: Reassembler, short data is truncated" {
    const body = patternBody(100, 1);
    var reassembler: Reassembler(256) = .{};
    var lying = fragmentOf(&body, 0, 0, 50);
    lying.data = body[0..10];

    try std.testing.expectError(Error.Tlz_DtlsReassembler_Truncated, reassembler.accept(lying));
}

test "tlz dtls handshake: Reassembler, a fragment past its message is a bad fragment" {
    const body = patternBody(100, 1);
    var reassembler: Reassembler(256) = .{};
    var overrun = fragmentOf(&body, 0, 60, 40);
    overrun.header.length = 80;

    try std.testing.expectError(
        Error.Tlz_DtlsReassembler_BadFragment,
        reassembler.accept(overrun),
    );
}

test "tlz dtls handshake: Reassembler, a message past CAPACITY is too large" {
    const body = patternBody(100, 1);
    var reassembler: Reassembler(256) = .{};
    var oversized = fragmentOf(&body, 0, 0, 100);
    oversized.header.length = 1000;

    try std.testing.expectError(
        Error.Tlz_DtlsReassembler_MessageTooLarge,
        reassembler.accept(oversized),
    );
}

test "tlz dtls handshake: Reassembler, a foreign message_seq is a sequence mismatch" {
    const body = patternBody(100, 1);
    var reassembler: Reassembler(256) = .{};

    try reassembler.accept(fragmentOf(&body, 4, 0, 50));

    try std.testing.expectError(
        Error.Tlz_DtlsReassembler_SequenceMismatch,
        reassembler.accept(fragmentOf(&body, 5, 50, 50)),
    );
}

test "tlz dtls handshake: Reassembler, a different message length is a length mismatch" {
    const body = patternBody(100, 1);
    var reassembler: Reassembler(256) = .{};
    var wrong_length = fragmentOf(&body, 4, 50, 40);
    wrong_length.header.length = 90;

    try reassembler.accept(fragmentOf(&body, 4, 0, 50));

    try std.testing.expectError(
        Error.Tlz_DtlsReassembler_LengthMismatch,
        reassembler.accept(wrong_length),
    );
}

test "tlz dtls handshake: Reassembler, reset takes the next message" {
    const body = patternBody(100, 1);
    var reassembler: Reassembler(256) = .{};

    try reassembler.accept(fragmentOf(&body, 1, 0, 50));
    reassembler.reset();

    try std.testing.expectEqual(@as(usize, 0), reassembler.have);

    try reassembler.accept(fragmentOf(&body, 2, 0, 100));

    try std.testing.expect(reassembler.isComplete());
    try std.testing.expectEqual(@as(u16, 2), reassembler.message_seq);
}

test "tlz dtls handshake: Reassembler, a zero-length message completes at once" {
    var reassembler: Reassembler(64) = .{};

    try reassembler.accept(.{
        .header = .{
            .msg_type = .SERVER_HELLO_DONE,
            .length = 0,
            .message_seq = 3,
            .fragment_offset = 0,
            .fragment_length = 0,
        },
        .data = "",
    });

    try std.testing.expectEqual(@as(usize, 0), reassembler.message().?.len);
}

test "tlz dtls handshake: Reassembler, fragmenter output rebuilds the message" {
    const body = patternBody(2000, 7);
    var fragmenter: handshake.Fragmenter = .{
        .msg_type = .CERTIFICATE,
        .message_seq = 2,
        .body = &body,
        .max_fragment_len = 300,
    };
    var reassembler: Reassembler(4096) = .{};
    var out: [512]u8 = undefined;
    var pieces: usize = 0;

    while (fragmenter.next(&out)) |piece| : (pieces += 1) {
        var iterator: handshake.FragmentIterator = .{ .body = piece };
        try reassembler.accept((try iterator.next()).?);
    }

    try std.testing.expectEqual(@as(usize, 7), pieces);
    try std.testing.expectEqualSlices(u8, &body, reassembler.message().?);
}

test "tlz dtls handshake: Reassembler, a retransmit with smaller fragments completes" {
    const body = patternBody(1000, 1);
    var reassembler: Reassembler(2048) = .{};
    var out: [512]u8 = undefined;
    var first_try: handshake.Fragmenter = .{
        .msg_type = .CERTIFICATE,
        .message_seq = 2,
        .body = &body,
        .max_fragment_len = 400,
    };
    var retry: handshake.Fragmenter = .{
        .msg_type = .CERTIFICATE,
        .message_seq = 2,
        .body = &body,
        .max_fragment_len = 150,
    };

    var arrived: handshake.FragmentIterator = .{ .body = first_try.next(&out).? };
    try reassembler.accept((try arrived.next()).?);

    while (retry.next(&out)) |piece| {
        var walk: handshake.FragmentIterator = .{ .body = piece };
        try reassembler.accept((try walk.next()).?);
    }

    try std.testing.expectEqualSlices(u8, &body, reassembler.message().?);
}

