//! QUIC loss-detection PoC, phase L1 (http3-plan.md): RFC 9002 section 5 (estimating the RTT) and
//! section 6.1 (acknowledgment-based loss detection).
//!
//! Note:
//! - Layers C / Q / T / P / H proved correctness on the wire. Layer L is the timing brain: how the
//!   sender estimates the round-trip time and decides a packet is lost. L1 is the RTT estimator
//!   (latest / smoothed / min plus the variation, with the acknowledgment-delay adjustment) and the
//!   two loss thresholds (packet reordering and elapsed time).
//! - The oracle is the RFC algorithms and constants: 5.1-5.3 fix the first-sample initialization and
//!   the 7/8 + 1/8 smoothing, 6.1.1 fixes kPacketThreshold = 3, and 6.1.2 fixes the time threshold
//!   max(9/8 * max(smoothed, latest), kGranularity) with kGranularity = 1 ms. Times are integer
//!   microseconds so the EWMA is exact and reproducible.
//! - This is sender-side timing logic, no crypto and no wire bytes; it consumes the RTT samples and
//!   acknowledgements that Q4's ACK frames carry.
//!
//! Run:    zig run rnd/0.5.x/quic_loss_l1_poc.zig
//! Verify: bash rnd/0.5.x/verify-quic-loss-l1.sh

const std = @import("std");

// --------------------------------------------------------------- //

/// The local timer granularity (RFC 9002 6.1.2): 1 millisecond, in microseconds.
const granularity_us: u64 = 1000;

/// The packet reordering threshold (RFC 9002 6.1.1).
const packet_threshold: u64 = 3;

/// The RTT estimator for one path (RFC 9002 5). All times are microseconds.
const RttEstimator = struct {
    smoothed_rtt: u64 = 0,
    rttvar: u64 = 0,
    min_rtt: u64 = 0,
    has_sample: bool = false,

    /// Fold one RTT sample into the estimate (RFC 9002 5.1-5.3). The first sample resets the
    /// estimator; later samples evolve smoothed_rtt and rttvar after the ack-delay adjustment.
    ///
    /// Param:
    /// latest_rtt - the raw sample (ack time minus send time of the largest acked)
    /// ack_delay - the peer-reported acknowledgment delay
    /// max_ack_delay - the peer's advertised maximum
    /// handshake_confirmed - whether to cap ack_delay at max_ack_delay
    fn onSample(self: *RttEstimator, latest_rtt: u64, ack_delay: u64, max_ack_delay: u64, handshake_confirmed: bool) void {
        if (!self.has_sample) {
            self.min_rtt = latest_rtt;
            self.smoothed_rtt = latest_rtt;
            self.rttvar = latest_rtt / 2;
            self.has_sample = true;

            return;
        }

        self.min_rtt = @min(self.min_rtt, latest_rtt);

        var delay = ack_delay;
        if (handshake_confirmed) delay = @min(delay, max_ack_delay);

        var adjusted = latest_rtt;
        if (latest_rtt >= self.min_rtt + delay) adjusted = latest_rtt - delay;

        self.smoothed_rtt = (7 * self.smoothed_rtt + adjusted) / 8;
        const sample = if (self.smoothed_rtt > adjusted) self.smoothed_rtt - adjusted else adjusted - self.smoothed_rtt;
        self.rttvar = (3 * self.rttvar + sample) / 4;
    }
};

/// The time-threshold for loss (RFC 9002 6.1.2): max(9/8 * max(smoothed, latest), kGranularity).
fn lossTimeThreshold(smoothed_rtt: u64, latest_rtt: u64) u64 {
    const base = @max(smoothed_rtt, latest_rtt);

    return @max(9 * base / 8, granularity_us);
}

/// Whether a packet is declared lost (RFC 9002 6.1): it must be unacknowledged and sent before the
/// largest acknowledged, and then either kPacketThreshold packets earlier or past the time threshold.
fn packetLost(packet_number: u64, largest_acked: u64, time_since_sent: u64, smoothed_rtt: u64, latest_rtt: u64) bool {
    if (packet_number >= largest_acked) return false;
    if (largest_acked - packet_number >= packet_threshold) return true;

    return time_since_sent >= lossTimeThreshold(smoothed_rtt, latest_rtt);
}

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

    std.debug.print("RFC 9002 5.1-5.3: RTT estimation\n", .{});

    // First sample (100 ms): the estimator resets to it, rttvar is half.
    var rtt = RttEstimator{};
    rtt.onSample(100_000, 0, 25_000, true);
    expectEq(&failures, "first sample smoothed_rtt = latest", rtt.smoothed_rtt, 100_000);
    expectEq(&failures, "first sample rttvar = latest / 2", rtt.rttvar, 50_000);
    expectEq(&failures, "first sample sets min_rtt", rtt.min_rtt, 100_000);

    // Second sample (120 ms) with 10 ms ack delay, handshake confirmed, max_ack_delay 25 ms.
    // ack_delay = min(10, 25) = 10 ms; latest (120) >= min (100) + delay (10) so adjusted = 110 ms.
    // smoothed = (7*100000 + 110000) / 8 = 101250; rttvar = (3*50000 + 8750) / 4 = 39687.
    rtt.onSample(120_000, 10_000, 25_000, true);
    expectEq(&failures, "min_rtt stays the lesser (100 ms)", rtt.min_rtt, 100_000);
    expectEq(&failures, "smoothed_rtt EWMA (7/8) = 101250", rtt.smoothed_rtt, 101_250);
    expectEq(&failures, "rttvar update (3/4) = 39687", rtt.rttvar, 39_687);

    // ack_delay is NOT subtracted when latest_rtt < min_rtt + ack_delay.
    var rtt2 = RttEstimator{};
    rtt2.onSample(100_000, 0, 25_000, true);
    rtt2.onSample(105_000, 50_000, 50_000, true);
    // latest (105) < min (100) + delay (50) = 150, so adjusted = latest = 105000.
    expectEq(&failures, "no ack-delay subtraction when latest < min + delay", rtt2.smoothed_rtt, (7 * 100_000 + 105_000) / 8);

    // ack_delay is capped at max_ack_delay once the handshake is confirmed.
    var rtt3 = RttEstimator{};
    rtt3.onSample(100_000, 0, 20_000, true);
    rtt3.onSample(200_000, 80_000, 20_000, true);
    // delay = min(80, 20) = 20 ms; adjusted = 200 - 20 = 180 ms.
    expectEq(&failures, "ack_delay capped at max_ack_delay", rtt3.smoothed_rtt, (7 * 100_000 + 180_000) / 8);

    std.debug.print("RFC 9002 6.1.1: packet threshold\n", .{});

    expectEq(&failures, "kPacketThreshold = 3", packet_threshold, 3);
    expect(&failures, "packet 3 before largest acked -> lost", packetLost(7, 10, 0, 100_000, 100_000));
    expect(&failures, "packet 2 before largest -> not lost by packet threshold", !packetLost(8, 10, 0, 100_000, 100_000));
    expect(&failures, "packet at/after largest acked -> not lost", !packetLost(10, 10, 999_999_999, 100_000, 100_000));

    std.debug.print("RFC 9002 6.1.2: time threshold\n", .{});

    expectEq(&failures, "kGranularity = 1 ms", granularity_us, 1000);
    // 9/8 * max(100ms, 120ms) = 9/8 * 120000 = 135000 us.
    expectEq(&failures, "time threshold = 9/8 * max(smoothed, latest)", lossTimeThreshold(100_000, 120_000), 135_000);
    expect(&failures, "old packet beyond time threshold -> lost", packetLost(9, 10, 140_000, 100_000, 120_000));
    expect(&failures, "recent packet within time threshold -> not lost", !packetLost(9, 10, 100_000, 100_000, 120_000));
    // With tiny RTTs the granularity floor applies.
    expectEq(&failures, "time threshold floored at kGranularity", lossTimeThreshold(100, 200), 1000);

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9002 L1 RTT + loss checks hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
