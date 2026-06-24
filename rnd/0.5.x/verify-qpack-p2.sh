#!/usr/bin/env bash
#
# QPACK dynamic-table oracle for the zix HTTP/3 header compression (http3-plan.md, phase P2). The
# oracle is RFC 9204 section 3.2 (entry size = name + value + 32, capacity, eviction from the oldest
# end, absolute indexing) and 4.5.1 (Required Insert Count transform + Base). Both RFC worked
# examples are checked: a 100-byte table (MaxEntries 3) encodes RIC 9 to 4 and decodes it back given
# 10 inserts, and RIC 9 with Sign 1 / Delta Base 2 resolves to Base 6. Crafted in process.
#
# Usage:  bash rnd/0.5.x/verify-qpack-p2.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 20 checks and "PASS: all RFC 9204 P2 dynamic-table + RIC
#         checks hold", and exits 0. Any mismatch prints "FAIL" and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/qpack_p2_poc.zig"

echo "=== RFC 9204 3.2 / 4.5.1 dynamic-table + Required Insert Count self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QPACK dynamic table + RIC / Base match RFC 9204"
else
    echo "  FAIL: zix QPACK dynamic table diverged from RFC 9204"
    exit 1
fi
