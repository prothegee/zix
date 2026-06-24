#!/usr/bin/env bash
#
# QUIC PTO + congestion-control oracle for the zix HTTP/3 recovery layer (http3-plan.md, phase L2).
# The oracle is RFC 9002 section 6.2 (PTO = smoothed_rtt + max(4*rttvar, kGranularity) + max_ack_delay,
# with max_ack_delay 0 for Initial / Handshake, and doubling backoff) and section 7 (initial window
# min(10*mds, max(2*mds, 14720)), minimum 2*mds, slow start, loss halving the window into ssthresh,
# persistent congestion to the minimum). Integer bytes and microseconds, exercised in process.
#
# Usage:  bash rnd/0.5.x/verify-quic-loss-l2.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 20 checks and "PASS: all RFC 9002 L2 PTO + congestion checks
#         hold", and exits 0. Any mismatch prints "FAIL" with want / got and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/quic_loss_l2_poc.zig"

echo "=== RFC 9002 section 6.2 / 7 PTO + congestion self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QUIC PTO + congestion control match RFC 9002"
else
    echo "  FAIL: zix QUIC congestion control diverged from RFC 9002"
    exit 1
fi
