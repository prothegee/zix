//! TLZ dtls record AntiReplay
//!
//! ### file: src/tlz/src/dtls/record/AntiReplay.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Sliding replay window for one DTLS epoch (RFC 6347 4.1.2.6, the RFC 4303 3.4.3
//! procedure).
//!
//! ### note:
//!
//! Two steps on purpose. `isNew` runs before the AEAD, `accept` runs only after the
//! tag verifies. Accepting on the sequence number alone would let a forged datagram
//! slide the window and lock out the real record that follows. Sequence numbers
//! restart per epoch, so keep one window per epoch.
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
// Fields:

/// Highest sequence number that has verified so far, the right edge of the window.
highest: u48 = 0,
/// Bit i marks (highest - i) as already seen. Bit 0 is `highest` itself, so
/// sequence number 0 is accepted exactly once.
window: u64 = 0,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Sliding window width in records. RFC 6347 4.1.2.6 requires at least 32 and
/// prefers 64.
pub const REPLAY_WINDOW_BITS: u48 = 64;

/// Whether a sequence number is worth the cost of opening the record.
///
/// Param:
/// sequence_number - u48 (from the record header)
///
/// Return:
/// - true when it is ahead of the window, or inside it and not yet seen
/// - false when it duplicates a record or falls off the left edge
pub fn isNew(self: *const Self, sequence_number: u48) bool {
    if (sequence_number > self.highest) return true;

    const behind = self.highest - sequence_number;
    if (behind >= REPLAY_WINDOW_BITS) return false;

    return (self.window >> @intCast(behind)) & 1 == 0;
}

/// Record a sequence number as seen. Call only after the AEAD tag verifies.
///
/// Param:
/// sequence_number - u48 (from a record that opened)
///
/// Return:
/// - void
pub fn accept(self: *Self, sequence_number: u48) void {
    if (sequence_number > self.highest) {
        const advance = sequence_number - self.highest;

        self.window = if (advance >= REPLAY_WINDOW_BITS) 0 else self.window << @intCast(advance);
        self.window |= 1;
        self.highest = sequence_number;

        return;
    }

    const behind = self.highest - sequence_number;

    if (behind < REPLAY_WINDOW_BITS) self.window |= @as(u64, 1) << @intCast(behind);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls record: AntiReplay, sequence zero is accepted once" {
    var replay: Self = .{};

    try std.testing.expect(replay.isNew(0));

    replay.accept(0);

    try std.testing.expect(!replay.isNew(0));
}

test "tlz dtls record: AntiReplay, in-order records become duplicates" {
    var replay: Self = .{};

    for (0..10) |i| {
        const sequence_number: u48 = @intCast(i);

        try std.testing.expect(replay.isNew(sequence_number));
        replay.accept(sequence_number);
    }

    for (0..10) |i| {
        try std.testing.expect(!replay.isNew(@intCast(i)));
    }
}

test "tlz dtls record: AntiReplay, a gap ahead leaves the skipped numbers open" {
    var replay: Self = .{};
    replay.accept(9);
    replay.accept(20);

    try std.testing.expect(replay.isNew(15));

    replay.accept(15);

    try std.testing.expect(!replay.isNew(15));
    try std.testing.expect(replay.isNew(16));
}

test "tlz dtls record: AntiReplay, a record off the left edge is rejected" {
    var replay: Self = .{};
    replay.accept(100);

    try std.testing.expect(replay.isNew(100 - REPLAY_WINDOW_BITS + 1));
    try std.testing.expect(!replay.isNew(100 - REPLAY_WINDOW_BITS));
    try std.testing.expect(!replay.isNew(0));
}

test "tlz dtls record: AntiReplay, a jump past the window clears it" {
    var replay: Self = .{};
    replay.accept(100);
    replay.accept(100 + REPLAY_WINDOW_BITS + 5);

    try std.testing.expect(!replay.isNew(100));
    try std.testing.expect(replay.isNew(100 + REPLAY_WINDOW_BITS + 4));
}

test "tlz dtls record: AntiReplay, isNew alone does not move the window" {
    var replay: Self = .{};
    replay.accept(5);

    try std.testing.expect(replay.isNew(9999));
    try std.testing.expectEqual(@as(u48, 5), replay.highest);
    try std.testing.expect(replay.isNew(6));
}

test "tlz dtls record: AntiReplay, the window is at least 32 records wide" {
    try std.testing.expect(REPLAY_WINDOW_BITS >= 32);
}

