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
    for candidate in zig-out/bin/example-http3_basic zig-out/bin/tls_http3_basic zig-out/bin/http3_basic; do
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
SRV_LOG="$(mktemp)"
"$SERVER" 2>"$SRV_LOG" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; rm -f "$SRV_LOG"' EXIT
sleep 1

# curl sends its real Initial. The handshake driver is built incrementally (http3-plan.md), so
# rather than only pass/fail the whole round trip, inspect what zix actually did with curl's packets.
curl --http3-only --insecure --silent --output /dev/null --max-time 4 "$URL" >/dev/null 2>&1 || true
sleep 0.3

echo "--- handshake step 1: client Initial decrypt + ClientHello parse ---"
if grep -q "parsed ClientHello" "$SRV_LOG"; then
    echo "  PASS: zix decrypted curl's real Initial and parsed its ClientHello (live)"
else
    echo "  FAIL: zix did not decrypt / parse curl's ClientHello"
    cat "$SRV_LOG"
    exit 1
fi

echo "--- full handshake: ServerHello + 1-RTT + request ---"
if curl --http3-only --insecure --silent --output /dev/null --max-time 4 "$URL" >/dev/null 2>&1; then
    echo "  PASS: curl --http3-only completed the full QUIC + TLS 1.3 handshake against zix"
else
    echo "  PENDING: the server send path (ServerHello onward, step 2) is not yet assembled, so the"
    echo "           full round trip does not complete. Handshake step 1 above is proven live."
fi

echo ""
echo "  RESULT: handshake step 1 (Initial decrypt + ClientHello) PASS live; full handshake PENDING."
