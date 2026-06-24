#!/usr/bin/env bash
#
# QUIC-TLS guard-rule oracle for the zix HTTP/3 handshake layer (http3-plan.md, phase T2). The
# oracle is RFC 9001 section 4.2 (QUIC is TLS 1.3 only, a lower negotiated version MUST terminate),
# 4.9.1 (Initial keys discarded on first Handshake use, role-split between client send and server
# process, no Initial packets after), and 4.6.2 (a server rejecting 0-RTT omits early_data and MUST
# NOT process 0-RTT packets). These are policy and state, exercised in process.
#
# Usage:  bash rnd/0.5.x/verify-quic-tls-t2.sh
# Deps:   zig (the PoC self-checks, no external tool needed for this layer)
# Expect: the PoC prints "ok" for all 15 checks and "PASS: all RFC 9001 T2 version / key-discard /
#         0-RTT checks hold", and exits 0. Any mismatch prints "FAIL" and exits non-zero.

set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
POC="$ROOT/rnd/0.5.x/quic_tls_t2_poc.zig"

echo "=== RFC 9001 section 4.2 / 4.9.1 / 4.6.2 guard-rule self-check (the oracle) ==="
if zig run "$POC"; then
    echo "  PASS: zix QUIC-TLS version + key-discard + 0-RTT rules match RFC 9001"
else
    echo "  FAIL: zix QUIC-TLS guard rules diverged from RFC 9001"
    exit 1
fi
