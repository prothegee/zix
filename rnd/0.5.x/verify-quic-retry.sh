#!/usr/bin/env bash
#
# QUIC Retry integrity-tag oracle for the zix HTTP/3 crypto layer (http3-plan.md, phase C2). The
# oracle is RFC 9001 section 5.8 + Appendix A.4: the RFC fixes the version-1 Retry key / nonce (and
# the secret they derive from) and publishes a worked Retry packet, so the PoC checks every value
# against the RFC text. Same self-contained approach as the C1 Initial vectors: no live tool emits
# this exact packet, because the Original Destination Connection ID is client-chosen.
#
# Usage:  bash rnd/0.5.x/verify-quic-retry.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 4 vectors and "PASS: all RFC 9001 Retry vectors match",
#         and exits 0. Any mismatch prints "FAIL" with want / got and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/quic_retry_poc.zig"

echo "=== RFC 9001 5.8 + Appendix A.4 worked-vector self-check (the deterministic oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QUIC Retry integrity is byte-exact with RFC 9001"
else
    echo "  FAIL: zix QUIC Retry integrity diverged from RFC 9001"
    exit 1
fi
