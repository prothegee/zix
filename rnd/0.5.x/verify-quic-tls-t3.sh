#!/usr/bin/env bash
#
# QUIC-TLS live handshake gate for the zix HTTP/3 stack (http3-plan.md, phase T3). Unlike T1 / T2
# and every Layer C / Q phase, T3 is NOT a self-contained deterministic check: it is the first LIVE
# gate, where the oracle is a real curl --http3 handshake against a running zix server. That server
# is the integration milestone (Layer I): UDP I/O, packet protection, the transport state machine,
# and the TLS handshake driven over CRYPTO frames, all assembled. Until it exists this gate confirms
# the oracle tool is present and ready, and reports the handshake itself as PENDING (it does not fake
# a pass). Once a server binary exists, point ZIX_HTTP3_SERVER at it (or it is auto-detected) and the
# gate runs the real handshake.
#
# Usage:  bash rnd/0.5.x/verify-quic-tls-t3.sh
#         ZIX_HTTP3_SERVER=/path/to/server bash rnd/0.5.x/verify-quic-tls-t3.sh
# Deps:   curl with HTTP/3 (ngtcp2 / nghttp3 or quiche), the assembled zix HTTP/3 server (Layer I)
# Expect: capability confirmed; the live handshake runs and prints PASS once the server exists,
#         otherwise prints PENDING (the server is not yet assembled) and does not claim a pass.

set -u

PORT=9063
URL="https://127.0.0.1:${PORT}/"

echo "=== T3 step 1: curl --http3 capability (the live oracle) ==="
if curl --version | grep -q 'HTTP3'; then
    echo "  PASS: curl reports HTTP3 support ($(curl --version | grep -o 'ngtcp2[^ ]*\|quiche[^ ]*' | head -1))"
else
    echo "  FAIL: this curl has no HTTP/3 support, the T3 oracle is unavailable"
    exit 1
fi

echo "=== T3 step 2: locate the assembled zix HTTP/3 server (Layer I) ==="
SERVER="${ZIX_HTTP3_SERVER:-}"
if [ -z "$SERVER" ]; then
    for candidate in zig-out/bin/tls_http3_basic zig-out/bin/http3_basic; do
        if [ -x "$candidate" ]; then SERVER="$candidate"; break; fi
    done
fi

if [ -z "$SERVER" ] || [ ! -x "$SERVER" ]; then
    echo "  PENDING: no assembled zix HTTP/3 server found."
    echo "           T1 (CRYPTO carriage + per-level keys) and T2 (version / key-discard / 0-RTT)"
    echo "           are proven deterministically. The live handshake is gated on Layer I assembling"
    echo "           the engine. Re-run with ZIX_HTTP3_SERVER set once that server exists."
    echo ""
    echo "  RESULT: capability confirmed, live handshake PENDING (not run, not faked)."
    exit 0
fi

echo "  found server: $SERVER"
echo "=== T3 step 3: drive a real curl --http3-only handshake ==="
"$SERVER" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null' EXIT
sleep 1

if curl --http3-only --insecure --silent --output /dev/null --max-time 5 "$URL"; then
    echo "  PASS: curl --http3-only completed the QUIC + TLS 1.3 handshake against zix"
else
    echo "  FAIL: curl --http3-only could not complete the handshake against zix"
    exit 1
fi
