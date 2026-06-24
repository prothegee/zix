#!/usr/bin/env bash
#
# HTTP/3 stream + frame oracle for the zix HTTP/3 framing layer (http3-plan.md, phase H1). The
# oracle is RFC 9114 section 6.2 (control stream type 0x00, SETTINGS as the first frame else
# H3_MISSING_SETTINGS, one control stream else H3_STREAM_CREATION_ERROR) and section 7.2 (the seven
# frame type values and which frames are legal on which stream, with H3_FRAME_UNEXPECTED for the
# rest, plus the legal request frame order). State machines are exercised in process.
#
# Usage:  bash rnd/0.5.x/verify-http3-h1.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 24 checks and "PASS: all RFC 9114 H1 stream + frame checks
#         hold", and exits 0. Any mismatch prints "FAIL" and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/http3_h1_poc.zig"

echo "=== RFC 9114 6.2 / 7.2 stream + frame self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix HTTP/3 stream mapping + frame matrix match RFC 9114"
else
    echo "  FAIL: zix HTTP/3 framing diverged from RFC 9114"
    exit 1
fi
