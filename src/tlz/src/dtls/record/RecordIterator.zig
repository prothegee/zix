//! TLZ dtls record RecordIterator
//!
//! ### file: src/tlz/src/dtls/record/RecordIterator.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Walks the DTLS records packed back to back in one datagram (RFC 6347 4.1.1).
//!
//! ### note:
//!
//! A record never spans datagrams, and the first byte is always the start of one.
//! The walk stops at the first malformed length rather than guessing where the next
//! record starts.
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
const record = @import("../record.zig");

// --------------------------------------------------------- //
// Fields:

datagram: []const u8,
pos: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_DtlsRecordIterator_Truncated,
};

/// The next whole record, header included, ready for `record.deprotect`.
///
/// Return:
/// - []const u8 (the record, borrowing the datagram)
/// - null when the datagram is fully walked
/// - Error.Tlz_DtlsRecordIterator_Truncated when a header or length runs past the end
pub fn next(self: *Self) Error!?[]const u8 {
    if (self.pos == self.datagram.len) return null;

    const header = record.parseHeader(self.datagram[self.pos..]) catch |err| switch (err) {
        error.Tlz_DtlsRecord_Truncated => return Error.Tlz_DtlsRecordIterator_Truncated,
    };
    const total = record.HEADER_LEN + header.length;
    if (self.pos + total > self.datagram.len) return Error.Tlz_DtlsRecordIterator_Truncated;

    const bytes = self.datagram[self.pos..][0..total];
    self.pos += total;

    return bytes;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const TEST_KEY: [16]u8 = @splat(0xAB);
const TEST_SALT: [record.SALT_LEN]u8 = @splat(0xDE);

test "tlz dtls record: RecordIterator, several records ride one datagram" {
    var datagram: [512]u8 = undefined;
    var used: usize = 0;
    const fragments = [_][]const u8{ "first", "second", "third" };

    for (fragments, 0..) |fragment, i| {
        const bytes = try record.protect(
            datagram[used..],
            fragment,
            .HANDSHAKE,
            0,
            @intCast(i),
            TEST_KEY,
            TEST_SALT,
        );
        used += bytes.len;
    }

    var iterator: Self = .{ .datagram = datagram[0..used] };
    var seen: usize = 0;

    while (try iterator.next()) |bytes| : (seen += 1) {
        var plain: [64]u8 = undefined;
        const opened = try record.deprotect(&plain, bytes, TEST_KEY, TEST_SALT);

        try std.testing.expectEqualStrings(fragments[seen], opened.data);
    }

    try std.testing.expectEqual(@as(usize, 3), seen);
}

test "tlz dtls record: RecordIterator, a length past the end is truncated" {
    var datagram: [128]u8 = undefined;
    const bytes = try record.protect(
        &datagram,
        "payload",
        .HANDSHAKE,
        0,
        0,
        TEST_KEY,
        TEST_SALT,
    );

    var iterator: Self = .{ .datagram = datagram[0 .. bytes.len - 2] };

    try std.testing.expectError(Error.Tlz_DtlsRecordIterator_Truncated, iterator.next());
}

test "tlz dtls record: RecordIterator, a stub shorter than a header is truncated" {
    var iterator: Self = .{ .datagram = &[_]u8{ 22, 0xFE } };

    try std.testing.expectError(Error.Tlz_DtlsRecordIterator_Truncated, iterator.next());
}

test "tlz dtls record: RecordIterator, an empty datagram gives null" {
    var iterator: Self = .{ .datagram = "" };

    try std.testing.expectEqual(@as(?[]const u8, null), try iterator.next());
}

