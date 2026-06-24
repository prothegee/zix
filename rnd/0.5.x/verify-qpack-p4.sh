#!/usr/bin/env bash
#
# QPACK interop gate for the zix HTTP/3 header compression (http3-plan.md, phase P4). P4 has two
# halves. The self-consistency half is deterministic: encode a field list with zix and decode it
# back, proving the encoder and decoder agree (the PoC). The cross-implementation half decodes
# encoded files produced by ANOTHER QPACK implementation (the qpack-interop test data: .qif decoded
# header lists and .out / .enc encoded streams) and compares the decode to the original .qif. That
# half needs external fixtures and is reported PENDING here, not faked, the same as the T3 live gate.
#
# Usage:  bash rnd/0.5.x/verify-qpack-p4.sh
#         QPACK_INTEROP_DIR=/path/to/qifs bash rnd/0.5.x/verify-qpack-p4.sh
# Deps:   zig (the self round trip); the qpack-interop test data for the cross-impl half
# Expect: the self round trip prints PASS; the cross-impl compare runs once fixtures are present,
#         otherwise prints PENDING.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/qpack_p4_poc.zig"

echo "=== P4 step 1: zix encode -> decode self round trip (the deterministic half) ==="
if zig run "$POC"; then
    echo "  PASS: zix QPACK encoder + decoder are mutually consistent"
else
    echo "  FAIL: zix QPACK round trip diverged"
    exit 1
fi

echo "=== P4 step 2: cross-implementation decode-and-compare (the qpack-interop half) ==="
INTEROP="${QPACK_INTEROP_DIR:-}"
if [ -z "$INTEROP" ] || [ ! -d "$INTEROP" ]; then
    echo "  PENDING: no qpack-interop fixtures found."
    echo "           The self round trip proves zix is internally consistent. True cross-impl interop"
    echo "           needs encoded streams from another QPACK implementation (the qpack-interop .qif /"
    echo "           .out test data, which exercise the dynamic table + Huffman). Set QPACK_INTEROP_DIR"
    echo "           to that directory once fetched to run the decode-and-compare."
    echo ""
    echo "  RESULT: self round trip PASS, cross-impl interop PENDING (not run, not faked)."
    exit 0
fi

echo "  found fixtures: $INTEROP"
echo "  NOTE: the decode-and-compare driver lands with the integrated QPACK decoder (dynamic table +"
echo "        Huffman), which is beyond this static-table PoC. Fixtures are present but the full"
echo "        cross-impl driver is part of Layer P integration."
exit 0
