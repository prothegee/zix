#!/usr/bin/env bash
#
# QUIC frame parse / type-rule oracle for the zix HTTP/3 transport layer (http3-plan.md, phase Q2).
# The oracle is RFC 9000 section 12.4 / 12.5 + section 19: the Table 3 "Pkts" column fixes which
# frames may appear in each packet number space, 12.4 fixes the unknown-type (FRAME_ENCODING_ERROR)
# and shortest-encoding (PROTOCOL_VIOLATION) rules, and section 19 fixes each frame's field layout.
# Crafted frames are parsed in process, no live tool needed until the handshake (phase T).
#
# Usage:  bash rnd/0.5.x/verify-quic-transport-q2.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 32 checks and "PASS: all RFC 9000 Q2 frame rules hold",
#         and exits 0. Any mismatch prints "FAIL" and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/quic_transport_q2_poc.zig"

echo "=== RFC 9000 section 12 / 19 frame-rule self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QUIC frame parse + permission matrix match RFC 9000"
else
    echo "  FAIL: zix QUIC frame handling diverged from RFC 9000"
    exit 1
fi
