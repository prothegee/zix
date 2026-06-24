#!/usr/bin/env bash
#
# QUIC Initial packet-protection oracle for the zix HTTP/3 crypto layer (http3-plan.md, phase C1).
# The oracle is RFC 9001 Appendix A itself: the RFC publishes a complete worked example (Initial
# secrets, per-direction key / iv / hp, and a byte-exact protected client Initial packet), so the
# PoC checks every value against the RFC text. This mirrors the TLS 1.3 key schedule, which is
# verified against the in-RFC RFC 8448 trace rather than an external tool. No CLI reproduces these
# exact packets, because a live QUIC endpoint picks random connection IDs.
#
# Usage:  bash rnd/0.5.x/verify-quic-initial.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 15 vectors and "PASS: all RFC 9001 Appendix A vectors match",
#         and exits 0. Any mismatch prints "FAIL" with want / got and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/quic_initial_poc.zig"

echo "=== RFC 9001 Appendix A worked-vector self-check (the deterministic oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QUIC Initial protection is byte-exact with RFC 9001 Appendix A"
else
    echo "  FAIL: zix QUIC Initial protection diverged from RFC 9001 Appendix A"
    exit 1
fi
