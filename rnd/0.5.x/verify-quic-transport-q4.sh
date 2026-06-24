#!/usr/bin/env bash
#
# QUIC flow-control / ACK / path oracle for the zix HTTP/3 transport layer (http3-plan.md, phase
# Q4). The oracle is RFC 9000 section 4 (the FLOW_CONTROL_ERROR rule + only-increasing MAX_DATA /
# MAX_STREAM_DATA), section 19.3 (the ACK frame and its relative range arithmetic, with a negative
# computed packet number being FRAME_ENCODING_ERROR), and 19.17 / 19.18 (the 8-byte PATH_CHALLENGE
# echoed by PATH_RESPONSE). Crafted frames are exercised in process.
#
# Usage:  bash rnd/0.5.x/verify-quic-transport-q4.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 20 checks and "PASS: all RFC 9000 Q4 flow / ACK / path rules
#         hold", and exits 0. Any mismatch prints "FAIL" and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/quic_transport_q4_poc.zig"

echo "=== RFC 9000 section 4 / 19.3 / 19.17 flow + ACK + path self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QUIC flow control + ACK + path match RFC 9000"
else
    echo "  FAIL: zix QUIC flow / ACK / path handling diverged from RFC 9000"
    exit 1
fi
