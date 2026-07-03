#!/usr/bin/env bash
# HTTP/3 full-body correctness gate for zix.Http3 (.URING).
#
# Fires N concurrent GET requests over an h3 connection (curl multiplexes streams on it) and verifies
# EVERY response is the full expected size. This catches the failure req/s alone hides: a send-path
# change that truncates large multi-packet bodies but still returns 2xx (h2load / curl count a truncated
# response as "done", so throughput looks great while bytes-per-response collapses).
#
# Why per-URL output files: curl --parallel with a single -o writes only the first URL there and streams
# the rest to stdout, mixing body bytes into the size report. Each URL gets its own -o here, and sizes
# are read from disk, not from curl -w.
#
# Needs: curl built with HTTP/3 (ngtcp2). Point it at any h3 server serving a known-size body, e.g. the
# HttpArena zix_uring_http3 container on 8443 (/static/vendor.js is 307200), or an http3 example with a
# temporary large route.
#
# Usage: h3-fullbody-gate.sh <concurrency> <count> <expected_bytes> [port] [path]
set -u
CONNS="${1:-64}"; COUNT="${2:-200}"; EXP="${3:?expected byte size required}"
PORT="${4:-8443}"; REQ_PATH="${5:-/static/vendor.js}"
DIR="$(mktemp -d)"

args=()
for i in $(seq 1 "$COUNT"); do args+=(-o "$DIR/r$i" "https://127.0.0.1:$PORT$REQ_PATH"); done

timeout 60 curl --http3-only --parallel --parallel-max "$CONNS" --max-time 30 -sk "${args[@]}" >/dev/null 2>&1
curl_rc=$?

full=0; short=0; missing=0; smallest=99999999
for i in $(seq 1 "$COUNT"); do
    if [ -f "$DIR/r$i" ]; then
        sz=$(stat -c '%s' "$DIR/r$i")
        if [ "$sz" -eq "$EXP" ]; then full=$((full + 1)); else short=$((short + 1)); [ "$sz" -lt "$smallest" ] && smallest=$sz; fi
    else
        missing=$((missing + 1))
    fi
done
rm -rf "$DIR"

echo "conns=$CONNS count=$COUNT expected=$EXP curl_rc=$curl_rc -> full=$full short=$short missing=$missing$([ $short -gt 0 ] && echo " smallest_short=$smallest")"
[ "$full" -eq "$COUNT" ] && { echo "PASS (all full-size)"; exit 0; } || { echo "FAIL (truncation or loss under concurrency)"; exit 1; }
