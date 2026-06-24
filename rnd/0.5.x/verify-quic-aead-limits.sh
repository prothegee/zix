#!/usr/bin/env bash
#
# QUIC AEAD usage-limit + constant-time tamper-rejection oracle for the zix HTTP/3 crypto layer
# (http3-plan.md, phase C4). Unlike C1 to C3 this has no Appendix-A byte vector: RFC 9001 section
# 6.6 fixes normative limit constants (confidentiality 2^23, integrity 2^52 for AES-GCM, 2^36 for
# ChaCha20-Poly1305), and section 9.5 fixes a behavioral property (a flipped bit under the
# authentication MUST be rejected, in constant time). The PoC asserts those constants and the
# send / receive accounting, and exercises std.crypto's constant-time authenticated decrypt.
#
# Usage:  bash rnd/0.5.x/verify-quic-aead-limits.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 20 checks and "PASS: all RFC 9001 6.6 + 9.5 checks hold",
#         and exits 0. Any mismatch prints "FAIL" with want / got and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/quic_aead_limits_poc.zig"

echo "=== RFC 9001 6.6 + 9.5 normative-limit + constant-time self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QUIC AEAD limits + tamper rejection match RFC 9001"
else
    echo "  FAIL: zix QUIC AEAD limits + tamper rejection diverged from RFC 9001"
    exit 1
fi
