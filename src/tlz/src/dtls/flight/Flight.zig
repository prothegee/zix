//! TLZ dtls flight Flight
//!
//! ### file: src/tlz/src/dtls/flight/Flight.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The DTLS timeout and retransmission state machine (RFC 6347 4.2.4).
//!
//! ### note:
//!
//! Flights are retransmitted whole, never message by message. The peer resending a
//! flight already processed means part of ours was lost, so it is answered at once.
//! The side that sent the last flight keeps answering even after FINISHED, or a lost
//! final Finished deadlocks both ends.
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
const Timer = @import("Timer.zig");
const State = @import("state.zig").State;
const TimeoutAction = @import("timeout_action.zig").TimeoutAction;

// --------------------------------------------------------- //
// Fields:

state: State,
timer: Timer = .{},
/// Retransmissions of the current flight so far.
retransmits: usize = 0,
max_retransmits: usize = flight.DEFAULT_MAX_RETRANSMITS,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// A client sends first, so it starts by building a flight.
///
/// Return:
/// - Self (in PREPARING)
pub fn initClient() Self {
    return .{ .state = .PREPARING };
}

/// A server waits first, with nothing outstanding and no timer running.
///
/// Return:
/// - Self (in WAITING, timer disarmed)
pub fn initServer() Self {
    return .{ .state = .WAITING };
}

/// The next flight is buffered and about to be written to the wire.
///
/// Return:
/// - void
pub fn sending(self: *Self) void {
    self.state = .SENDING;
}

/// The flight is on the wire.
///
/// Param:
/// now_ms - u64 (monotonic milliseconds, the caller's clock)
/// more_expected - bool (false when this was the last flight of the handshake)
///
/// Return:
/// - void
pub fn sent(self: *Self, now_ms: u64, more_expected: bool) void {
    if (!more_expected) {
        self.state = .FINISHED;
        self.timer.disarm();

        return;
    }

    self.state = .WAITING;
    self.timer.arm(now_ms);
}

/// Check the retransmission deadline. Cheap enough for every loop tick.
///
/// Note:
/// - GIVE_UP does not change state, it stays true on every later call. The caller
///   tears the association down on the first one.
///
/// Param:
/// now_ms - u64 (monotonic milliseconds, the caller's clock)
///
/// Usage:
/// ```zig
/// if (flight.onTick(now_ms)) |action| switch (action) {
///     .RETRANSMIT => {
///         try sendFlight();
///         flight.sent(now_ms, true);
///     },
///     .GIVE_UP => dropAssociation(),
/// };
/// ```
///
/// Return:
/// - TimeoutAction when the timer fired
/// - null while there is still time, or when nothing is outstanding
pub fn onTick(self: *Self, now_ms: u64) ?TimeoutAction {
    if (self.state != .WAITING) return null;
    if (!self.timer.expired(now_ms)) return null;
    if (self.retransmits >= self.max_retransmits) return .GIVE_UP;

    self.retransmits += 1;
    self.timer.backoff();
    self.state = .SENDING;

    return .RETRANSMIT;
}

/// The peer resent a flight already processed, which means part of ours was lost.
///
/// Note:
/// - Applies in FINISHED too, for as long as the association is kept.
///
/// Return:
/// - true when the caller should send its buffered flight again
pub fn onPeerRetransmit(self: *Self) bool {
    switch (self.state) {
        .WAITING, .FINISHED => {
            self.state = .SENDING;

            return true;
        },
        .PREPARING, .SENDING => return false,
    }
}

/// A complete new flight arrived from the peer. This is the only progress signal,
/// so it is where the backoff resets (RFC 6347 4.2.4.1).
///
/// Param:
/// final - bool (true when that flight ends the handshake)
///
/// Return:
/// - void
pub fn onPeerFlight(self: *Self, final: bool) void {
    self.retransmits = 0;
    self.timer.reset();
    self.state = if (final) .FINISHED else .PREPARING;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn sentClient() Self {
    var client = initClient();
    client.sending();
    client.sent(0, true);

    return client;
}

test "tlz dtls flight: Flight, a client starts preparing" {
    try std.testing.expectEqual(State.PREPARING, initClient().state);
}

test "tlz dtls flight: Flight, a server starts waiting with no timer" {
    var server = initServer();

    try std.testing.expectEqual(State.WAITING, server.state);
    try std.testing.expectEqual(@as(?TimeoutAction, null), server.onTick(1_000_000));
}

test "tlz dtls flight: Flight, an unanswered flight retransmits on the growing delay" {
    var client = sentClient();

    try std.testing.expectEqual(@as(?TimeoutAction, null), client.onTick(999));
    try std.testing.expectEqual(TimeoutAction.RETRANSMIT, client.onTick(1000).?);
    try std.testing.expectEqual(State.SENDING, client.state);

    client.sent(1000, true);

    try std.testing.expectEqual(@as(?TimeoutAction, null), client.onTick(2999));
    try std.testing.expectEqual(TimeoutAction.RETRANSMIT, client.onTick(3000).?);
}

test "tlz dtls flight: Flight, a dead peer is given up on" {
    var client = sentClient();
    var now: u64 = 0;

    for (0..flight.DEFAULT_MAX_RETRANSMITS) |_| {
        now += client.timer.timeout_ms;
        try std.testing.expectEqual(TimeoutAction.RETRANSMIT, client.onTick(now).?);
        client.sent(now, true);
    }

    now += client.timer.timeout_ms;

    try std.testing.expectEqual(TimeoutAction.GIVE_UP, client.onTick(now).?);
    try std.testing.expectEqual(flight.DEFAULT_MAX_RETRANSMITS, client.retransmits);
}

test "tlz dtls flight: Flight, GIVE_UP repeats on every later tick" {
    var client = sentClient();
    client.max_retransmits = 0;

    try std.testing.expectEqual(TimeoutAction.GIVE_UP, client.onTick(1000).?);
    try std.testing.expectEqual(TimeoutAction.GIVE_UP, client.onTick(1001).?);
}

test "tlz dtls flight: Flight, a flight from the peer resets the backoff" {
    var client = sentClient();
    _ = client.onTick(1000);
    client.sent(1000, true);
    _ = client.onTick(3000);
    client.sent(3000, true);

    client.onPeerFlight(false);

    try std.testing.expectEqual(State.PREPARING, client.state);
    try std.testing.expectEqual(flight.INITIAL_TIMEOUT_MS, client.timer.timeout_ms);
    try std.testing.expectEqual(@as(usize, 0), client.retransmits);
}

test "tlz dtls flight: Flight, a peer retransmission triggers an immediate resend" {
    var client = sentClient();

    try std.testing.expect(client.onPeerRetransmit());
    try std.testing.expectEqual(State.SENDING, client.state);
    try std.testing.expectEqual(@as(usize, 0), client.retransmits);
}

test "tlz dtls flight: Flight, the last flight is still resent after finishing" {
    var server = initServer();
    server.onPeerFlight(false);
    server.sending();
    server.sent(0, false);

    try std.testing.expectEqual(State.FINISHED, server.state);
    try std.testing.expectEqual(@as(?TimeoutAction, null), server.onTick(1_000_000));
    try std.testing.expect(server.onPeerRetransmit());
    try std.testing.expectEqual(State.SENDING, server.state);
}

test "tlz dtls flight: Flight, a resend request while building or sending is ignored" {
    var client = initClient();

    try std.testing.expect(!client.onPeerRetransmit());

    client.sending();

    try std.testing.expect(!client.onPeerRetransmit());
    try std.testing.expectEqual(@as(?TimeoutAction, null), client.onTick(1_000_000));
}

test "tlz dtls flight: Flight, a full client handshake walks the states in order" {
    var client = sentClient();

    client.onPeerFlight(false);
    try std.testing.expectEqual(State.PREPARING, client.state);

    client.sending();
    client.sent(100, true);
    client.onPeerFlight(false);
    client.sending();
    client.sent(200, true);
    try std.testing.expectEqual(State.WAITING, client.state);

    client.onPeerFlight(true);

    try std.testing.expectEqual(State.FINISHED, client.state);
    try std.testing.expectEqual(@as(?TimeoutAction, null), client.onTick(1_000_000));
}

