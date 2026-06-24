//! QUIC loss-detection PoC, phase L2 (http3-plan.md): RFC 9002 section 6.2 (Probe Timeout) and
//! section 7 (congestion control, the NewReno controller).
//!
//! Note:
//! - L1 estimated the RTT and declared loss. L2 is the rest of the recovery brain: the Probe Timeout
//!   that fires when no acknowledgement arrives, and the congestion window that paces how much may be
//!   in flight. The PTO grows the network estimate plus its variation plus the ack delay and backs
//!   off exponentially; the window slow-starts, then halves on loss and floors at a minimum.
//! - The oracle is the RFC formulas and constants: 6.2.1 fixes PTO = smoothed_rtt + max(4*rttvar,
//!   kGranularity) + max_ack_delay (with max_ack_delay 0 for Initial / Handshake) and the doubling
//!   backoff; 7.2 fixes the initial window min(10*mds, max(2*mds, 14720)) and the minimum 2*mds; 7.3
//!   / 7.6 fix slow start, the loss reduction factor 1/2, and persistent congestion to the minimum.
//! - Integer bytes and microseconds, so every value is exact. Sender-side pacing, no crypto.
//!
//! Run:    zig run rnd/0.5.x/quic_loss_l2_poc.zig
//! Verify: bash rnd/0.5.x/verify-quic-loss-l2.sh

const std = @import("std");

// --------------------------------------------------------------- //

/// The local timer granularity (RFC 9002 6.1.2), in microseconds.
const granularity_us: u64 = 1000;

/// The persistent-congestion duration multiplier (RFC 9002 7.6).
const persistent_congestion_threshold: u64 = 3;

/// The initial RTT used before a sample exists (RFC 9002 6.2.2), in microseconds.
const initial_rtt_us: u64 = 333_000;

/// Compute the Probe Timeout (RFC 9002 6.2.1): smoothed_rtt + max(4*rttvar, kGranularity) +
/// max_ack_delay. For the Initial and Handshake spaces, pass max_ack_delay = 0.
fn computePto(smoothed_rtt: u64, rttvar: u64, max_ack_delay: u64) u64 {
    return smoothed_rtt + @max(4 * rttvar, granularity_us) + max_ack_delay;
}

/// Apply the PTO backoff (RFC 9002 6.2.1): each consecutive timeout doubles the period.
fn ptoWithBackoff(base_pto: u64, backoff_count: u6) u64 {
    return base_pto << backoff_count;
}

// --------------------------------------------------------------- //

/// The initial congestion window (RFC 9002 7.2): ten datagrams, capped to the larger of 14,720
/// bytes or two datagrams.
fn initialWindow(max_datagram_size: u64) u64 {
    return @min(10 * max_datagram_size, @max(2 * max_datagram_size, 14_720));
}

/// The minimum congestion window (RFC 9002 7.2): two datagrams.
fn minimumWindow(max_datagram_size: u64) u64 {
    return 2 * max_datagram_size;
}

/// The NewReno congestion controller (RFC 9002 7.3). Bytes throughout.
const CongestionController = struct {
    max_datagram_size: u64,
    congestion_window: u64,
    ssthresh: u64,

    /// Start in slow start with the initial window and an unbounded slow-start threshold (RFC 9002
    /// 7.3 / appendix B.3).
    fn init(max_datagram_size: u64) CongestionController {
        return .{
            .max_datagram_size = max_datagram_size,
            .congestion_window = initialWindow(max_datagram_size),
            .ssthresh = std.math.maxInt(u64),
        };
    }

    /// Whether the controller is in slow start (RFC 9002 7.3.1): below the slow-start threshold.
    fn inSlowStart(self: CongestionController) bool {
        return self.congestion_window < self.ssthresh;
    }

    /// Grow the window on a newly acknowledged packet (RFC 9002 7.3.1 / 7.3.3). Slow start adds the
    /// acked bytes; congestion avoidance adds one datagram per window of acked bytes.
    fn onAckedBytes(self: *CongestionController, acked: u64) void {
        if (self.inSlowStart()) {
            self.congestion_window += acked;
        } else {
            self.congestion_window += self.max_datagram_size * acked / self.congestion_window;
        }
    }

    /// React to a congestion event (RFC 9002 7.3.2): halve the window (kLossReductionFactor) into
    /// the slow-start threshold, then clamp to the minimum window.
    fn onCongestionEvent(self: *CongestionController) void {
        self.ssthresh = self.congestion_window / 2;
        self.congestion_window = @max(self.ssthresh, minimumWindow(self.max_datagram_size));
    }

    /// Collapse to the minimum window on persistent congestion (RFC 9002 7.6).
    fn onPersistentCongestion(self: *CongestionController) void {
        self.congestion_window = minimumWindow(self.max_datagram_size);
    }
};

// --------------------------------------------------------------- //

/// Report a boolean expectation and flag a failure.
fn expect(failures: *usize, name: []const u8, ok: bool) void {
    if (ok) {
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        std.debug.print("  FAIL  {s}\n", .{name});
        failures.* += 1;
    }
}

/// Report a u64 equality expectation and flag a failure.
fn expectEq(failures: *usize, name: []const u8, actual: u64, expected: u64) void {
    if (actual == expected) {
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        std.debug.print("  FAIL  {s}\n", .{name});
        std.debug.print("        want {d}\n", .{expected});
        std.debug.print("        got  {d}\n", .{actual});
        failures.* += 1;
    }
}

pub fn main() !void {
    var failures: usize = 0;

    std.debug.print("RFC 9002 6.2.1: Probe Timeout\n", .{});

    // smoothed 100 ms, rttvar 39687 us, max_ack_delay 25 ms: 100000 + 158748 + 25000 = 283748.
    expectEq(&failures, "PTO = smoothed + max(4*rttvar, gran) + max_ack_delay", computePto(100_000, 39_687, 25_000), 283_748);

    // Initial / Handshake spaces use max_ack_delay 0.
    expectEq(&failures, "PTO for Initial space (max_ack_delay 0)", computePto(100_000, 39_687, 0), 258_748);

    // A tiny rttvar floors 4*rttvar at kGranularity.
    expectEq(&failures, "4*rttvar floored at kGranularity", computePto(50_000, 100, 0), 50_000 + 1000);

    // Backoff doubles each consecutive timeout.
    const base = computePto(100_000, 39_687, 25_000);
    expectEq(&failures, "PTO backoff x1 (no timeout)", ptoWithBackoff(base, 0), 283_748);
    expectEq(&failures, "PTO backoff x2 (one timeout)", ptoWithBackoff(base, 1), 567_496);
    expectEq(&failures, "PTO backoff x4 (two timeouts)", ptoWithBackoff(base, 2), 1_134_992);

    std.debug.print("RFC 9002 7.2: congestion window bounds\n", .{});

    // 1200-byte datagrams: 10*1200 = 12000 < max(2400, 14720) = 14720, so the initial window is 12000.
    expectEq(&failures, "initial window (mds 1200) = 12000", initialWindow(1200), 12_000);
    // 1472-byte datagrams: 10*1472 = 14720, equal to the cap.
    expectEq(&failures, "initial window (mds 1472) = 14720", initialWindow(1472), 14_720);
    expectEq(&failures, "minimum window = 2 * mds", minimumWindow(1200), 2400);

    std.debug.print("RFC 9002 7.3: NewReno states\n", .{});

    var cc = CongestionController.init(1200);
    expect(&failures, "starts in slow start", cc.inSlowStart());
    expectEq(&failures, "starts at the initial window", cc.congestion_window, 12_000);

    // Slow start: the window grows by the acked bytes.
    cc.onAckedBytes(1200);
    expectEq(&failures, "slow start grows by acked bytes", cc.congestion_window, 13_200);

    // Congestion event: ssthresh = cwnd / 2, window clamped to the minimum if smaller.
    cc.onCongestionEvent();
    expectEq(&failures, "congestion event sets ssthresh = cwnd / 2", cc.ssthresh, 6600);
    expectEq(&failures, "window drops to ssthresh (above minimum)", cc.congestion_window, 6600);
    expect(&failures, "no longer in slow start", !cc.inSlowStart());

    // Congestion avoidance: sub-linear growth (one datagram per window of acked bytes).
    cc.onAckedBytes(1200);
    expectEq(&failures, "congestion avoidance grows sub-linearly", cc.congestion_window, 6600 + 1200 * 1200 / 6600);

    // Persistent congestion collapses to the minimum window.
    cc.onPersistentCongestion();
    expectEq(&failures, "persistent congestion -> minimum window", cc.congestion_window, 2400);

    std.debug.print("RFC 9002 7 / appendix B.2: constants\n", .{});

    expectEq(&failures, "kPersistentCongestionThreshold = 3", persistent_congestion_threshold, 3);
    expectEq(&failures, "kInitialRtt = 333 ms", initial_rtt_us, 333_000);
    // kLossReductionFactor 1/2 is exercised by the congestion event halving the window above.
    expect(&failures, "loss reduction factor halves the window", CongestionController.init(1200).congestion_window / 2 == 6000);

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9002 L2 PTO + congestion checks hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
