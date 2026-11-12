//! TLZ dtls flight Timer
//!
//! ### file: src/tlz/src/dtls/flight/Timer.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Exponential retransmission backoff for one DTLS handshake (RFC 6347 4.2.4.1).
//!
//! ### note:
//!
//! Time comes in as a parameter, never from a clock inside. That keeps the schedule
//! testable and leaves the choice of clock to the engine that owns the loop.
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
const flight = @import("../flight.zig");

// --------------------------------------------------------- //
// Fields:

/// Current delay. Doubles on every expiry, capped at MAX_TIMEOUT_MS.
timeout_ms: u64 = flight.INITIAL_TIMEOUT_MS,
/// When the current wait ends, or null when no flight is outstanding.
deadline_ms: ?u64 = null,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Start waiting, at the current delay.
///
/// Param:
/// now_ms - u64 (monotonic milliseconds, the caller's clock)
///
/// Return:
/// - void
pub fn arm(self: *Self, now_ms: u64) void {
    self.deadline_ms = now_ms + self.timeout_ms;
}

/// Stop waiting without changing the delay.
///
/// Return:
/// - void
pub fn disarm(self: *Self) void {
    self.deadline_ms = null;
}

/// Whether the wait is over.
///
/// Param:
/// now_ms - u64 (monotonic milliseconds, the caller's clock)
///
/// Return:
/// - bool (false when nothing is armed)
pub fn expired(self: *const Self, now_ms: u64) bool {
    const deadline = self.deadline_ms orelse return false;

    return now_ms >= deadline;
}

/// Double the delay for the next attempt, up to the ceiling.
///
/// Return:
/// - void
pub fn backoff(self: *Self) void {
    self.timeout_ms = @min(self.timeout_ms * 2, flight.MAX_TIMEOUT_MS);
}

/// Back to the initial delay, disarmed. Called when a flight gets through, since the
/// current delay is evidence about a loss that is no longer happening.
///
/// Return:
/// - void
pub fn reset(self: *Self) void {
    self.timeout_ms = flight.INITIAL_TIMEOUT_MS;
    self.deadline_ms = null;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls flight: Timer, the delay doubles to the ceiling and stays there" {
    var timer: Self = .{};
    const expected = [_]u64{ 2000, 4000, 8000, 16000, 32000, 60000, 60000, 60000 };

    try std.testing.expectEqual(flight.INITIAL_TIMEOUT_MS, timer.timeout_ms);

    for (expected) |delay| {
        timer.backoff();
        try std.testing.expectEqual(delay, timer.timeout_ms);
    }
}

test "tlz dtls flight: Timer, nothing armed never expires" {
    const timer: Self = .{};

    try std.testing.expect(!timer.expired(0));
    try std.testing.expect(!timer.expired(999999));
}

test "tlz dtls flight: Timer, expiry is on the deadline not before" {
    var timer: Self = .{};
    timer.arm(5000);

    try std.testing.expect(!timer.expired(5999));
    try std.testing.expect(timer.expired(6000));
    try std.testing.expect(timer.expired(9000));
}

test "tlz dtls flight: Timer, disarm keeps the delay" {
    var timer: Self = .{};
    timer.backoff();
    timer.arm(0);
    timer.disarm();

    try std.testing.expect(!timer.expired(9000));
    try std.testing.expectEqual(@as(u64, 2000), timer.timeout_ms);
}

test "tlz dtls flight: Timer, reset restores the initial delay" {
    var timer: Self = .{};
    timer.backoff();
    timer.arm(0);
    timer.reset();

    try std.testing.expectEqual(flight.INITIAL_TIMEOUT_MS, timer.timeout_ms);
    try std.testing.expectEqual(@as(?u64, null), timer.deadline_ms);
}

