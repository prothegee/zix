#!/usr/bin/env bash
#
# HTTP/3 message-validation oracle for the zix HTTP/3 framing layer (http3-plan.md, phase H2). The
# oracle is RFC 9114 section 4.1.2 (malformed conditions), 4.2 (lowercase field names, prohibited
# connection-specific fields) and 4.3 (mandatory request pseudo-headers :method / :scheme / :path,
# and :authority unless CONNECT; response :status). Any malformed message is a stream error of type
# H3_MESSAGE_ERROR. Decompressed header lists are validated in process.
#
# Usage:  bash rnd/0.5.x/verify-http3-h2.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 16 checks and "PASS: all RFC 9114 H2 message validation checks
#         hold", and exits 0. Any mismatch prints "FAIL" and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/http3_h2_poc.zig"

echo "=== RFC 9114 4.1.2 / 4.2 / 4.3 message-validation self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix HTTP/3 message semantics match RFC 9114"
else
    echo "  FAIL: zix HTTP/3 message validation diverged from RFC 9114"
    exit 1
fi
