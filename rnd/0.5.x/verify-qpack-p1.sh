#!/usr/bin/env bash
#
# QPACK static-half oracle for the zix HTTP/3 header compression (http3-plan.md, phase P1). The
# oracle is RFC 9204 section 4.1.1 / 4.2 / 4.5 / Appendix A plus the RFC 7541 Appendix C.1 integer
# vectors (QPACK reuses the HPACK prefixed integer unmodified): 10 and 1337 on a 5-bit prefix, 42 on
# an 8-bit prefix. The static table indices, the stream types (0x02 encoder, 0x03 decoder, at most
# one each), and the field line bit patterns are from RFC 9204 directly. Crafted in process.
#
# Usage:  bash rnd/0.5.x/verify-qpack-p1.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 24 checks and "PASS: all RFC 9204 P1 QPACK static checks
#         hold", and exits 0. Any mismatch prints "FAIL" with want / got and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/qpack_p1_poc.zig"

echo "=== RFC 9204 4.1.1 / 4.2 / 4.5 / Appendix A + RFC 7541 C.1 self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QPACK prefixed integers + static table + streams match RFC 9204"
else
    echo "  FAIL: zix QPACK static half diverged from RFC 9204"
    exit 1
fi
