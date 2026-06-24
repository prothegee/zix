#!/usr/bin/env bash
#
# QUIC ChaCha20-Poly1305 short-header + key-update oracle for the zix HTTP/3 crypto layer
# (http3-plan.md, phase C3). The oracle is RFC 9001 section 5.4.4 + 6.1 + Appendix A.5: the RFC
# publishes the application secret, the four derived values (key / iv / hp / ku), and the protected
# short-header packet, so the PoC checks every value against the RFC text. Same self-contained
# approach as C1 / C2: no live tool emits this exact packet.
#
# Usage:  bash rnd/0.5.x/verify-quic-keyupdate.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 10 vectors and "PASS: all RFC 9001 Appendix A.5 vectors match",
#         and exits 0. Any mismatch prints "FAIL" with want / got and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/quic_keyupdate_poc.zig"

echo "=== RFC 9001 5.4.4 + 6.1 + Appendix A.5 worked-vector self-check (the deterministic oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QUIC ChaCha20-Poly1305 + key update is byte-exact with RFC 9001"
else
    echo "  FAIL: zix QUIC ChaCha20-Poly1305 + key update diverged from RFC 9001"
    exit 1
fi
