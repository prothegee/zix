#!/usr/bin/env bash
#
# QUIC transport base-codec oracle for the zix HTTP/3 transport layer (http3-plan.md, phase Q1).
# The oracle is RFC 9000 Appendix A: A.1 publishes variable-length integer decodings, A.2 the
# packet-number encoding-length examples, and A.3 a packet-number decode. The header cases are
# crafted from the section 17 field diagrams and check the version-1 invariants (Fixed Bit MUST be
# 1, connection ID length MUST NOT exceed 20). Same self-contained approach as Layer C: crafted
# packets in process, no live tool needed until the handshake (phase T).
#
# Usage:  bash rnd/0.5.x/verify-quic-transport-q1.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 34 checks and "PASS: all RFC 9000 Q1 vectors + invariants
#         hold", and exits 0. Any mismatch prints "FAIL" with want / got and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/quic_transport_q1_poc.zig"

echo "=== RFC 9000 section 16 / 17 + Appendix A worked-vector self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QUIC varint + packet number + header parse match RFC 9000"
else
    echo "  FAIL: zix QUIC base codec diverged from RFC 9000"
    exit 1
fi
