#!/usr/bin/env bash
#
# HTTP/3 lifecycle + error-code oracle for the zix HTTP/3 framing layer (http3-plan.md, phase H3).
# The oracle is RFC 9114 section 5.2 (GOAWAY identifiers only decrease, a larger one is H3_ID_ERROR),
# 7.2.7 (MAX_PUSH_ID is client-only and only increases, a server MUST NOT send it) / 7.2.5
# (PUSH_PROMISE is server-only), and 8.1 (the seventeen HTTP/3 error code values plus the reserved
# grease range that maps to H3_NO_ERROR). State and code values are exercised in process.
#
# Usage:  bash rnd/0.5.x/verify-http3-h3.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 30 checks and "PASS: all RFC 9114 H3 GOAWAY / direction /
#         error-code checks hold", and exits 0. Any mismatch prints "FAIL" and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/http3_h3_poc.zig"

echo "=== RFC 9114 5.2 / 7.2.7 / 8.1 lifecycle + error-code self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix HTTP/3 GOAWAY + direction + error codes match RFC 9114"
else
    echo "  FAIL: zix HTTP/3 lifecycle handling diverged from RFC 9114"
    exit 1
fi
