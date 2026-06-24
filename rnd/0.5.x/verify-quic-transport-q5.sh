#!/usr/bin/env bash
#
# QUIC close / reset / anti-amplification oracle for the zix HTTP/3 transport layer (http3-plan.md,
# phase Q5). The oracle is RFC 9000 section 19.19 (CONNECTION_CLOSE field layout, only 0x1c carries
# a Frame Type), section 10.2 (closing / draining states, draining sends nothing), section 10.3
# (trailing-16-byte stateless reset detection + the 3x size cap and 21-byte floor), and section 8.1
# (the 3x send cap before validation + the 1200-byte client Initial floor). Crafted frames, byte
# counts, and datagrams are exercised in process.
#
# Usage:  bash rnd/0.5.x/verify-quic-transport-q5.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 25 checks and "PASS: all RFC 9000 Q5 close / reset /
#         amplification rules hold", and exits 0. Any mismatch prints "FAIL" and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/quic_transport_q5_poc.zig"

echo "=== RFC 9000 section 8 / 10 / 19.19 close + reset + amplification self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QUIC close + reset + anti-amplification match RFC 9000"
else
    echo "  FAIL: zix QUIC termination handling diverged from RFC 9000"
    exit 1
fi
