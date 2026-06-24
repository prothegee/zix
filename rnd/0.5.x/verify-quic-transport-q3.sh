#!/usr/bin/env bash
#
# QUIC stream + connection-id oracle for the zix HTTP/3 transport layer (http3-plan.md, phase Q3).
# The oracle is RFC 9000 section 2.1 (Table 1 stream types), section 3 (Figure 2 / Figure 3 stream
# state machines), and section 5.1.1 / 19.15 (NEW_CONNECTION_ID validation + active_connection_id
# _limit). Crafted ids, events, and frames are exercised in process, no live tool needed until the
# handshake (phase T).
#
# Usage:  bash rnd/0.5.x/verify-quic-transport-q3.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 29 checks and "PASS: all RFC 9000 Q3 stream + connection-id
#         rules hold", and exits 0. Any mismatch prints "FAIL" and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/quic_transport_q3_poc.zig"

echo "=== RFC 9000 section 2 / 3 / 5 stream + connection-id self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QUIC stream + connection-id rules match RFC 9000"
else
    echo "  FAIL: zix QUIC stream + connection-id handling diverged from RFC 9000"
    exit 1
fi
