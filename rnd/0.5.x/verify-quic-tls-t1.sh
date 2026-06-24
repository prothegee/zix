#!/usr/bin/env bash
#
# QUIC-TLS join oracle for the zix HTTP/3 handshake layer (http3-plan.md, phase T1). The oracle is
# RFC 9001 section 4 (TLS handshake messages carried directly in CRYPTO frames, no TLS record
# protection) and 5.1 (the per-level "quic key" / "quic iv" / "quic hp" derivation). The CRYPTO
# reassembly and no-record-framing property are crafted in process, and the per-level key derivation
# reduces to the C1 (Initial) and C3 (1-RTT) published vectors. No live tool needed yet.
#
# Usage:  bash rnd/0.5.x/verify-quic-tls-t1.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 11 checks and "PASS: all RFC 9001 T1 CRYPTO + per-level key
#         checks hold", and exits 0. Any mismatch prints "FAIL" and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/quic_tls_t1_poc.zig"

echo "=== RFC 9001 section 4 / 5.1 CRYPTO + per-level key self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QUIC-TLS CRYPTO carriage + per-level keys match RFC 9001"
else
    echo "  FAIL: zix QUIC-TLS join diverged from RFC 9001"
    exit 1
fi
