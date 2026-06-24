#!/usr/bin/env bash
#
# QPACK decoder-feedback oracle for the zix HTTP/3 header compression (http3-plan.md, phase P3). The
# oracle is RFC 9204 section 4.4 (the three decoder-stream instructions: Section Acknowledgment '1'
# + 7-bit stream id, Stream Cancellation '01' + 6-bit stream id, Insert Count Increment '00' + 6-bit
# increment, with a zero increment being QPACK_DECODER_STREAM_ERROR) and section 6 (the three QPACK
# error code values 0x0200 / 0x0201 / 0x0202). Instructions are encoded / decoded in process.
#
# Usage:  bash rnd/0.5.x/verify-qpack-p3.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 12 checks and "PASS: all RFC 9204 P3 decoder-instruction +
#         error-code checks hold", and exits 0. Any mismatch prints "FAIL" and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/qpack_p3_poc.zig"

echo "=== RFC 9204 4.4 / section 6 decoder-instruction + error-code self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QPACK decoder instructions + error codes match RFC 9204"
else
    echo "  FAIL: zix QPACK decoder feedback diverged from RFC 9204"
    exit 1
fi
