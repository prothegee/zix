#!/usr/bin/env bash
#
# QUIC RTT + loss-detection oracle for the zix HTTP/3 recovery layer (http3-plan.md, phase L1). The
# oracle is RFC 9002 section 5 (RTT estimation: first-sample reset, the 7/8 + 1/8 smoothed_rtt, the
# 3/4 + 1/4 rttvar, min_rtt, the ack-delay adjustment capped at max_ack_delay) and section 6.1 (loss:
# kPacketThreshold 3, time threshold max(9/8 * max(smoothed, latest), kGranularity 1 ms)). Times are
# integer microseconds so the EWMA is exact. Exercised in process.
#
# Usage:  bash rnd/0.5.x/verify-quic-loss-l1.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 17 checks and "PASS: all RFC 9002 L1 RTT + loss checks hold",
#         and exits 0. Any mismatch prints "FAIL" with want / got and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/quic_loss_l1_poc.zig"

echo "=== RFC 9002 section 5 / 6.1 RTT + loss self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QUIC RTT estimation + loss detection match RFC 9002"
else
    echo "  FAIL: zix QUIC loss detection diverged from RFC 9002"
    exit 1
fi
