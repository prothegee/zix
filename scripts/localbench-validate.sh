#!/usr/bin/env bash
# localbench-validate.sh - Check that a localbench entry answers its profiles correctly.
#
# Correctness gate before any number is quoted. Starts the entry, probes every endpoint
# the profiles in its meta.json depend on, and reports PASS or FAIL per check. A wrong
# answer here makes the matching localbench-run.sh number meaningless, so run this first.
#
# The checks mirror HttpArena scripts/validate.sh: same paths, same expected shapes, same
# schema assertions. Fixtures come from an HttpArena checkout, nothing is copied here.
#
# Lifecycle (trap-driven, runs on every exit including Ctrl-C):
#   start sidecar -> start server -> probe -> stop server -> stop sidecar
#
# Args (flags anywhere, positionals are <entry> [profile] [httparena-dir]):
#   <entry>           Required. An entry directory name under localbench/.
#   [profile]         Optional. Check only this profile. Validated against meta.json first.
#   [httparena-dir]   Optional. HttpArena checkout (default: sibling HttpArena next to this one).
#   --out-dir DIR     Optional. Report directory (default: logs/localbench).
#   --keep-sidecars   Optional. Leave postgres up after the run (default: removed).
#
# Usage:
#   ./scripts/localbench-validate.sh http1-uring
#   ./scripts/localbench-validate.sh http1-uring json
#   ./scripts/localbench-validate.sh http1-uring /path/HttpArena --out-dir logs/localbench

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SELF_DIR/.." && pwd)"
BENCH_DIR="$ROOT_DIR/localbench"
CERTS_DIR="$BENCH_DIR/certs"

PORT=8080
TLS_PORT=8081
H2C_PORT=8082
H2_PORT=8443
H3_PORT=8443

PG_CONTAINER="localbench-validate-postgres"
DATABASE_URL="postgres://bench:bench@localhost:5432/benchmark"

SERVER_PID=""
SIDECAR_UP=0
EDGE_UP=0
KEEP_SIDECARS=0
PASS=0
FAIL=0

info() { echo "[validate] $*"; }
die() { echo "[validate] error: $*" >&2; exit 1; }

cleanup() {
    local status=$?

    # The edge is a daemon this script spawned, so it outlives the shell unless
    # it is stopped by name. Stop it before the origin, so no request is in
    # flight to a backend that is already gone. `daemon stop` rather than
    # `stop gateway.cfg`: stopping the site alone unbinds the port but leaves
    # the daemon resident.
    if [ "$EDGE_UP" -eq 1 ]; then
        "$ZIXER_BIN" --dir "$ENTRY_DIR" daemon stop >/dev/null 2>&1 || true
        EDGE_UP=0
    fi

    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi

    if [ "$SIDECAR_UP" -eq 1 ] && [ "$KEEP_SIDECARS" -eq 0 ]; then
        docker rm -f -v "$PG_CONTAINER" >/dev/null 2>&1 || true
    fi

    return "$status"
}
trap cleanup EXIT INT TERM

OUT_DIR=""
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --out-dir)
            [ "$#" -ge 2 ] || die "--out-dir needs a value"
            OUT_DIR="$2"; shift 2 ;;
        --out-dir=*) OUT_DIR="${1#*=}"; shift ;;
        --keep-sidecars) KEEP_SIDECARS=1; shift ;;
        -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
        -*) die "unknown flag '$1'" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

[ "${#POSITIONAL[@]}" -gt 0 ] || {
    echo "usage: $(basename "$0") <entry> [httparena-dir] [--out-dir DIR]" >&2
    exit 1
}

ENTRY="${POSITIONAL[0]}"
ENTRY_DIR="$BENCH_DIR/$ENTRY"

[ -f "$ENTRY_DIR/meta.json" ] || die "localbench/$ENTRY has no meta.json"

# The second and third positionals are order-independent: a directory is the
# checkout, anything else is a profile name, checked against meta.json below.
ONLY_PROFILE=""
ARENA_DIR=""
for arg in "${POSITIONAL[@]:1}"; do
    if [ -d "$arg" ]; then
        ARENA_DIR="$arg"
    else
        ONLY_PROFILE="$arg"
    fi
done
ARENA_DIR="${ARENA_DIR:-$ROOT_DIR/../HttpArena}"
[ -d "$ARENA_DIR/data" ] || die "no fixtures at $ARENA_DIR/data (run localbench-build.sh first)"
ARENA_DIR="$(cd "$ARENA_DIR" && pwd)"
DATA_DIR="$ARENA_DIR/data"
REQUESTS_DIR="$ARENA_DIR/requests"

SERVER_BIN="$ENTRY_DIR/zig-out/bin/zix-localbench-$ENTRY"
[ -x "$SERVER_BIN" ] || die "no binary at $SERVER_BIN (run localbench-build.sh $ENTRY)"
[ -s "$CERTS_DIR/server.crt" ] || die "no certificate (run localbench-build.sh first)"

# A gateway entry is two processes: the zixer edge and the origin behind it.
# zixer names its binary after the target triplet and the optimize mode, so the
# name is discovered rather than assumed.
ZIXER_BIN=""
case "$ENTRY" in
    gateway-*)
        ZIXER_BIN="$(find "$ROOT_DIR/zig-out/bin" -maxdepth 1 -name 'zixer-*' -not -name 'zixer-example-*' -type f 2>/dev/null | sort | head -1)"
        [ -n "$ZIXER_BIN" ] || die "no zixer binary in zig-out/bin (run localbench-build.sh $ENTRY)"
        [ -f "$ENTRY_DIR/sites/gateway.cfg" ] || die "localbench/$ENTRY has no sites/gateway.cfg"
        ;;
esac

OUT_DIR="${OUT_DIR:-$ROOT_DIR/logs/localbench}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$OUT_DIR/validate-$ENTRY-$STAMP.txt"
SERVER_LOG="$OUT_DIR/validate-server-$ENTRY-$STAMP.txt"

mapfile -t TESTS < <(python3 -c "
import json
print('\n'.join(json.load(open('$ENTRY_DIR/meta.json'))['tests']))
")

# What the entry subscribes to, kept before ONLY_PROFILE narrows TESTS. A check
# asking what the entry CAN do (does it open a TLS listener) has to read this,
# not the filtered list, or naming one profile would hide the entry's other
# listeners from the checks that share a profile with them.
ENTRY_TESTS=("${TESTS[@]}")

if [ -n "$ONLY_PROFILE" ]; then
    printf '%s\n' "${TESTS[@]}" | grep -qx "$ONLY_PROFILE" ||
        die "$ENTRY does not subscribe to '$ONLY_PROFILE' (it has: ${TESTS[*]})"

    TESTS=("$ONLY_PROFILE")
fi

# has_test NAME
# Whether this run drives NAME.
has_test() {
    printf '%s\n' "${TESTS[@]}" | grep -qx "$1"
}

# entry_has NAME
# Whether the entry subscribes to NAME at all, whatever this run was narrowed to.
entry_has() {
    printf '%s\n' "${ENTRY_TESTS[@]}" | grep -qx "$1"
}

# ok LABEL
ok() {
    PASS=$((PASS + 1))
    echo "  PASS $1" | tee -a "$REPORT"
}

# no LABEL DETAIL
no() {
    FAIL=$((FAIL + 1))
    echo "  FAIL $1: $2" | tee -a "$REPORT"
}

# expect LABEL EXPECTED ACTUAL
expect() {
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        no "$1" "expected '$2', got '$3'"
    fi
}

# --------------------------------------------------------- #

# needs_db
# Whether any subscribed profile touches postgres.
needs_db() {
    has_test async-db || has_test crud || has_test api-4 || has_test api-16 || has_test gateway-64
}

# port_owner PORT
# The command holding a listening TCP port, or empty when the port is free. Used
# to name the process in a collision rather than reporting an unexplained hang.
port_owner() {
    ss -ltnp 2>/dev/null | awk -v want=":$1\$" '$4 ~ want {print $NF; exit}'
}

start_sidecar() {
    command -v docker >/dev/null 2>&1 || die "docker (or the podman shim) is not installed"

    # The sidecar runs on the host network, so anything already holding 5432 keeps it and the
    # sidecar silently serves nobody. This is not hypothetical: an unrelated project's postgres
    # left running is enough, and the failure then reads as broken database endpoints in the
    # engine. Named here, before the container is started, rather than diagnosed afterwards.
    local owner
    owner="$(port_owner 5432)"
    if [ -n "$owner" ] && ! docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" >/dev/null 2>&1; then
        die "port 5432 is already taken by $owner, stop it first: the sidecar shares the host network and cannot bind a port something else owns"
    fi

    SIDECAR_UP=1
    info "starting postgres sidecar"
    docker rm -f -v "$PG_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --rm --name "$PG_CONTAINER" --network host \
        --tmpfs /var/lib/postgresql:rw,size=2g \
        -e POSTGRES_USER=bench -e POSTGRES_PASSWORD=bench -e POSTGRES_DB=benchmark \
        -v "$DATA_DIR/pgdb-seed.sql:/docker-entrypoint-initdb.d/seed.sql:ro" \
        postgres:18 -c max_connections=256 >/dev/null

    # The probe dials 127.0.0.1 rather than the container's own unix socket, because that is the
    # route the server takes. A socket probe passes whenever postgres is alive at all, so it
    # reported ready while the server was reaching a different database entirely on the same port.
    local waited=0
    while [ "$waited" -lt 120 ]; do
        if docker exec "$PG_CONTAINER" env PGPASSWORD=bench psql -h 127.0.0.1 -p 5432 -U bench \
               -d benchmark -tAc 'SELECT 1 FROM items LIMIT 1' 2>/dev/null | grep -q 1; then
            info "postgres ready and seeded, reachable at 127.0.0.1:5432"
            return 0
        fi

        sleep 1
        waited=$((waited + 1))
    done

    die "postgres did not answer on 127.0.0.1:5432 within 120s (owner: ${owner:-none})"
}

# grpc_call METHOD JSON_REQUEST
# One gRPC call against the h2c listener, answered as JSON on stdout. The server
# carries no reflection service, so the schema comes from the arena's own
# benchmark.proto: the same file ghz drives the stream profile with.
grpc_call() {
    grpcurl -plaintext -import-path "$REQUESTS_DIR" -proto benchmark.proto \
        -d "$2" "localhost:$PORT" "benchmark.BenchmarkService/$1" 2>/dev/null
}

# server_ready
# One probe against a listener the entry actually opens. Any answer counts,
# including a 404: the question is whether the socket is serving yet.
server_ready() {
    if has_test gateway-64; then
        curl -sk -o /dev/null --max-time 2 --http2 \
            "https://localhost:$H2_PORT/static/reset.css" 2>/dev/null

        return
    fi

    if has_test baseline-h3 || has_test static-h3; then
        curl -sk -o /dev/null --max-time 2 --http3-only \
            "https://localhost:$H3_PORT/baseline2?a=1&b=1" 2>/dev/null

        return
    fi

    if has_test unary-grpc || has_test stream-grpc; then
        grpc_call GetSum '{"a":1,"b":2}' >/dev/null 2>&1

        return
    fi

    if has_test baseline-h2c || has_test json-h2c; then
        curl -s -o /dev/null --max-time 1 --http2-prior-knowledge \
            "http://localhost:$H2C_PORT/baseline2?a=1&b=1" 2>/dev/null

        return
    fi

    if has_test baseline-h2 || has_test static-h2; then
        curl -sk -o /dev/null --max-time 1 --http2 \
            "https://localhost:$H2_PORT/baseline2?a=1&b=1" 2>/dev/null

        return
    fi

    curl -s -o /dev/null --max-time 1 "http://localhost:$PORT/pipeline" 2>/dev/null
}

# start_edge
# Bring up the zixer edge in front of the origin, for a gateway entry only.
# Every other entry serves its own listener and this is a no-op.
start_edge() {
    [ -n "$ZIXER_BIN" ] || return 0

    mkdir -p "$ENTRY_DIR/logs"

    # A daemon left over from an interrupted run still holds 8443, and its
    # upstream would be a backend that no longer exists.
    "$ZIXER_BIN" --dir "$ENTRY_DIR" daemon stop >/dev/null 2>&1 || true

    info "starting the zixer edge"
    "$ZIXER_BIN" --dir "$ENTRY_DIR" start gateway.cfg >>"$SERVER_LOG" 2>&1 ||
        die "the zixer edge did not start, see $SERVER_LOG"

    EDGE_UP=1
}

start_server() {
    # The entry names localbench/data and localbench/certs, so it runs from the
    # repository root the way an arena entry runs against its container mounts.
    cd "$ROOT_DIR"

    local -a env_args=()
    needs_db && env_args+=("DATABASE_URL=$DATABASE_URL" "DATABASE_MAX_CONN=64")

    env "${env_args[@]+"${env_args[@]}"}" "$SERVER_BIN" >"$SERVER_LOG" 2>&1 &
    SERVER_PID=$!

    start_edge

    local waited=0
    while [ "$waited" -lt 100 ]; do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "--- server log ---" >&2
            tail -20 "$SERVER_LOG" >&2

            die "server exited during startup"
        fi
        server_ready && return 0

        sleep 0.2
        waited=$((waited + 1))
    done

    die "server did not answer within 20s, see $SERVER_LOG"
}

# --------------------------------------------------------- #

check_baseline() {
    echo "[test] baseline" | tee -a "$REPORT"
    expect "GET /baseline11 sum" "55" \
        "$(curl -s --max-time 10 "http://localhost:$PORT/baseline11?a=13&b=42")"
    expect "POST /baseline11 sum with body" "75" \
        "$(curl -s --max-time 10 -X POST -d '20' "http://localhost:$PORT/baseline11?a=13&b=42")"

    # Randomized inputs, so an answer memoized against the fixed pair above is
    # caught. The fixed pair alone cannot tell a sum from a constant.
    local a b body
    a=$((RANDOM % 900 + 100))
    b=$((RANDOM % 900 + 100))
    expect "GET /baseline11?a=$a&b=$b (random)" "$((a + b))" \
        "$(curl -s --max-time 10 "http://localhost:$PORT/baseline11?a=$a&b=$b")"

    body=$((RANDOM % 900 + 100))
    expect "POST /baseline11 with random body $body" "$((a + b + body))" \
        "$(curl -s --max-time 10 -X POST -d "$body" "http://localhost:$PORT/baseline11?a=$a&b=$b")"
}

check_pipeline() {
    echo "[test] pipelined" | tee -a "$REPORT"
    expect "GET /pipeline" "ok" "$(curl -s --max-time 10 "http://localhost:$PORT/pipeline")"
}

# json_verdict MULTIPLIER URL [curl-opts...]
# Fetch a /json response and print its count field, or one word saying why it is
# not acceptable. Every item must carry the full schema and a total that is
# price * quantity * MULTIPLIER, so a memoized or pre-rendered body is caught.
json_verdict() {
    local multiplier="$1" url="$2"
    shift 2

    curl -s --max-time 20 "$@" "$url" | python3 -c "
import sys, json
multiplier = $multiplier
try:
    doc = json.load(sys.stdin)
except Exception:
    print('unreadable'); raise SystemExit
items = doc.get('items', [])
def valid(item):
    rating = item.get('rating')
    return ('id' in item and 'name' in item and 'category' in item and 'price' in item
            and 'quantity' in item and 'total' in item
            and isinstance(item.get('tags'), list) and isinstance(item.get('active'), bool)
            and isinstance(rating, dict) and 'score' in rating and 'count' in rating)
if not items or not all(valid(i) for i in items):
    print('badschema')
elif any(i['total'] != i['price'] * i['quantity'] * multiplier for i in items):
    print('badtotal')
else:
    print(doc.get('count'))
" 2>/dev/null || echo unreadable
}

# header_value HEADER URL [curl-opts...]
# One response header value, lowercased name match, parameters stripped.
header_value() {
    local header="$1" url="$2"
    shift 2

    curl -s --max-time 10 -D- -o /dev/null "$@" "$url" |
        grep -i "^$header:" | tr -d '\r' | awk '{print $2}' | cut -d';' -f1
}

check_json() {
    echo "[test] json" | tee -a "$REPORT"

    local params count multiplier
    for params in "12:3" "22:7" "31:2" "50:5"; do
        count="${params%%:*}"
        multiplier="${params##*:}"

        expect "GET /json/$count?m=$multiplier" "$count" \
            "$(json_verdict "$multiplier" "http://localhost:$PORT/json/$count?m=$multiplier")"
    done

    expect "GET /json Content-Type" "application/json" \
        "$(header_value content-type "http://localhost:$PORT/json/50?m=1")"
}

check_json_comp() {
    echo "[test] json-comp" | tee -a "$REPORT"

    local encoding
    encoding="$(curl -s --max-time 20 -D- -o /dev/null -H "Accept-Encoding: gzip, br" \
        "http://localhost:$PORT/json/50?m=1" | grep -i '^content-encoding:' |
        tr -d '\r' | awk '{print $2}')"
    case "$encoding" in
        gzip|br) ok "json-comp Content-Encoding: $encoding" ;;
        *) no "json-comp" "expected gzip or br, got '${encoding:-none}'" ;;
    esac
}

check_json_tls() {
    echo "[test] json-tls" | tee -a "$REPORT"
    expect "GET https /json/5 count" "5" \
        "$(curl -sk --max-time 20 "https://localhost:$TLS_PORT/json/5?m=1" |
           python3 -c 'import sys,json; print(json.load(sys.stdin)["count"])' 2>/dev/null || echo unreadable)"
}

check_static() {
    echo "[test] static" | tee -a "$REPORT"

    expect "GET /static/theme.css" "200" \
        "$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "http://localhost:$PORT/static/theme.css")"
    expect "GET /static missing file" "404" \
        "$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "http://localhost:$PORT/static/absent-file.txt")"

    local size expected
    size="$(curl -s --max-time 20 -o /dev/null -w '%{size_download}' "http://localhost:$PORT/static/components.css")"
    expected="$(stat -c%s "$DATA_DIR/static/components.css" 2>/dev/null || echo 0)"
    expect "GET /static/components.css size" "$expected" "$size"

    # Precompressed siblings are negotiated only when the engine static window is above
    # zero, so this is the check that catches the window being turned off by accident.
    local encoding
    encoding="$(curl -s --max-time 10 -D- -o /dev/null -H "Accept-Encoding: br;q=1, gzip;q=0.8" \
        "http://localhost:$PORT/static/app.js" | grep -i '^content-encoding:' |
        tr -d '\r' | awk '{print $2}')"
    expect "GET /static/app.js negotiates br" "br" "${encoding:-none}"
}

# The 20 fixtures the arena's static profiles drive, in its own order. Three of them are past the
# engine's TLS response staging (header.html 120K, components.css 200K, vendor.js 300K), and
# vendor.js is past it even as its precompressed sibling, which is what makes the full list a
# regression check over TLS rather than a smoke test.
STATIC_FILES=(
    reset.css layout.css theme.css components.css utilities.css
    analytics.js helpers.js app.js vendor.js router.js
    header.html footer.html regular.woff2 bold.woff2 logo.svg
    icon-sprite.svg hero.webp thumb1.webp thumb2.webp manifest.json
)

# check_static_tls
# The static contract over the h1 TLS listener, the arena's static-tls profile.
#
# Note:
# - The host is localhost, never 127.0.0.1: the cert SAN is localhost, and an IP literal earns a 421
#   that says nothing about static files.
# - The size sweep sends no Accept-Encoding on purpose. With one, a precompressed sibling stands in
#   for the file and the response shrinks under the boundary the sweep exists to cross.
check_static_tls() {
    echo "[test] static-tls" | tee -a "$REPORT"

    # ALPN has to land on http/1.1 here. A server offering h2 on this port would be answering a
    # different engine's checks with the same fixtures.
    expect "https /static negotiates HTTP/1.1" "1.1" \
        "$(curl -sk --max-time 10 --http1.1 -o /dev/null -w '%{http_version}' "https://localhost:$TLS_PORT/static/reset.css")"

    expect "GET https /static/reset.css Content-Type" "text/css" \
        "$(header_value content-type "https://localhost:$TLS_PORT/static/reset.css" -k)"
    expect "GET https /static/manifest.json Content-Type" "application/json" \
        "$(header_value content-type "https://localhost:$TLS_PORT/static/manifest.json" -k)"
    expect "GET https /static missing file" "404" \
        "$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "https://localhost:$TLS_PORT/static/absent-file.txt")"

    local file expected actual short=0
    for file in "${STATIC_FILES[@]}"; do
        expected="$(wc -c < "$DATA_DIR/static/$file" 2>/dev/null || echo 0)"
        actual="$(curl -sk --max-time 30 -o /dev/null -w '%{size_download}' "https://localhost:$TLS_PORT/static/$file" || echo 0)"

        if [ "$actual" != "$expected" ]; then
            no "GET https /static/$file size" "expected $expected bytes, got $actual"
            short=1
        fi
    done

    if [ "$short" -eq 0 ]; then
        ok "static-tls serves all ${#STATIC_FILES[@]} files at full size"
    fi

    # A negotiated sibling still has to decompress back to the original. vendor.js is the one that
    # earns its place: its .br is itself larger than the response staging, so the compressed answer
    # crosses the same boundary the identity one does.
    local encoding decoded
    for file in header.html components.css vendor.js; do
        expected="$(wc -c < "$DATA_DIR/static/$file" 2>/dev/null || echo 0)"
        encoding="$(header_value content-encoding "https://localhost:$TLS_PORT/static/$file" -k -H 'Accept-Encoding: br')"
        decoded="$(curl -sk --max-time 30 --compressed "https://localhost:$TLS_PORT/static/$file" | wc -c)"

        expect "GET https /static/$file negotiates br" "br" "${encoding:-none}"
        expect "GET https /static/$file decompressed size" "$expected" "$decoded"
    done

    # One connection, an oversized response, then a small one. A response that leaves in pieces has
    # to put the session's record sequence exactly where a buffered one would, and a reused
    # connection is the only place that shows.
    local after
    after="$(curl -sk --max-time 40 -w '%{num_connects} %{http_code} %{size_download}\n' \
        -o /dev/null "https://localhost:$TLS_PORT/static/vendor.js" \
        -o /dev/null "https://localhost:$TLS_PORT/static/theme.css" | tail -1)"
    expect "static-tls answers on the same connection after an oversized response" \
        "0 200 $(wc -c < "$DATA_DIR/static/theme.css")" "$after"
}

check_baseline_h2() {
    echo "[test] baseline-h2" | tee -a "$REPORT"

    expect "https /baseline2 negotiates HTTP/2" "2" \
        "$(curl -sk --max-time 10 --http2 -o /dev/null -w '%{http_version}' "https://localhost:$H2_PORT/baseline2?a=1&b=1")"
    expect "GET https /baseline2 sum" "55" \
        "$(curl -sk --max-time 10 --http2 "https://localhost:$H2_PORT/baseline2?a=13&b=42")"
    expect "POST https /baseline2 sum with body" "75" \
        "$(curl -sk --max-time 10 --http2 -X POST -d '20' "https://localhost:$H2_PORT/baseline2?a=13&b=42")"
    local a b
    a=$((RANDOM % 900 + 100))
    b=$((RANDOM % 900 + 100))
    expect "GET https /baseline2?a=$a&b=$b (random)" "$((a + b))" \
        "$(curl -sk --max-time 10 --http2 "https://localhost:$H2_PORT/baseline2?a=$a&b=$b")"

    expect "GET https /baseline2 Content-Type" "text/plain" \
        "$(header_value content-type "https://localhost:$H2_PORT/baseline2?a=1&b=1" -k --http2)"
}

check_baseline_h2c() {
    echo "[test] baseline-h2c" | tee -a "$REPORT"

    expect "h2c /baseline2 prior-knowledge negotiates HTTP/2" "2" \
        "$(curl -s --max-time 10 --http2-prior-knowledge -o /dev/null -w '%{http_version}' "http://localhost:$H2C_PORT/baseline2?a=1&b=1")"

    # The h2c port must not also answer HTTP/1.1, or a run labelled h2c could be
    # measuring h1 throughput instead.
    local h1_code
    h1_code="$(curl -s --max-time 5 --http1.1 -o /dev/null -w '%{http_code}' "http://localhost:$H2C_PORT/baseline2?a=1&b=1" 2>/dev/null || echo 000)"
    if [ "$h1_code" != "200" ]; then
        ok "h2c port $H2C_PORT refuses HTTP/1.1 (got $h1_code)"
    else
        no "h2c-only" "port $H2C_PORT answered HTTP/1.1 with 200"
    fi

    expect "GET /baseline2 sum over h2c" "55" \
        "$(curl -s --max-time 10 --http2-prior-knowledge "http://localhost:$H2C_PORT/baseline2?a=13&b=42")"
    expect "POST /baseline2 sum with body over h2c" "75" \
        "$(curl -s --max-time 10 --http2-prior-knowledge -X POST -d '20' "http://localhost:$H2C_PORT/baseline2?a=13&b=42")"

    local a b
    a=$((RANDOM % 900 + 100))
    b=$((RANDOM % 900 + 100))
    expect "GET /baseline2?a=$a&b=$b over h2c (random)" "$((a + b))" \
        "$(curl -s --max-time 10 --http2-prior-knowledge "http://localhost:$H2C_PORT/baseline2?a=$a&b=$b")"

    expect "GET /baseline2 Content-Type (h2c)" "text/plain" \
        "$(header_value content-type "http://localhost:$H2C_PORT/baseline2?a=1&b=1" --http2-prior-knowledge)"
}

check_json_h2c() {
    echo "[test] json-h2c" | tee -a "$REPORT"

    expect "h2c /json prior-knowledge negotiates HTTP/2" "2" \
        "$(curl -s --max-time 10 --http2-prior-knowledge -o /dev/null -w '%{http_version}' "http://localhost:$H2C_PORT/json/1?m=1")"

    local params count multiplier
    for params in "12:3" "22:7" "31:2" "50:5"; do
        count="${params%%:*}"
        multiplier="${params##*:}"

        expect "GET /json/$count?m=$multiplier over h2c" "$count" \
            "$(json_verdict "$multiplier" "http://localhost:$H2C_PORT/json/$count?m=$multiplier" --http2-prior-knowledge)"
    done

    expect "GET /json Content-Type (h2c)" "application/json" \
        "$(header_value content-type "http://localhost:$H2C_PORT/json/50?m=1" --http2-prior-knowledge)"
}

check_static_h2() {
    echo "[test] static-h2" | tee -a "$REPORT"

    expect "GET https /static/theme.css" "200" \
        "$(curl -sk --max-time 10 --http2 -o /dev/null -w '%{http_code}' "https://localhost:$H2_PORT/static/theme.css")"
    expect "GET https /static missing file" "404" \
        "$(curl -sk --max-time 10 --http2 -o /dev/null -w '%{http_code}' "https://localhost:$H2_PORT/static/absent-file.txt")"

    local size expected
    size="$(curl -sk --max-time 20 --http2 -o /dev/null -w '%{size_download}' "https://localhost:$H2_PORT/static/components.css")"
    expected="$(stat -c%s "$DATA_DIR/static/components.css" 2>/dev/null || echo 0)"
    expect "GET https /static/components.css size" "$expected" "$size"

    expect "GET https /static/manifest.json Content-Type" "application/json" \
        "$(header_value content-type "https://localhost:$H2_PORT/static/manifest.json" -k --http2)"

    # Precompressed siblings are negotiated only when the engine static window is
    # above zero, so this is the check that catches it being turned off.
    local encoding
    encoding="$(curl -sk --max-time 10 --http2 -D- -o /dev/null -H "Accept-Encoding: br;q=1, gzip;q=0.8" \
        "https://localhost:$H2_PORT/static/app.js" | grep -i '^content-encoding:' |
        tr -d '\r' | awk '{print $2}')"
    expect "GET https /static/app.js negotiates br" "br" "${encoding:-none}"
}

check_baseline_h3() {
    echo "[test] baseline-h3" | tee -a "$REPORT"

    # --http3-only refuses to fall back to TCP, so a pass here is QUIC and
    # nothing else. There is no TCP listener on this entry to fall back to.
    expect "https /baseline2 negotiates HTTP/3" "3" \
        "$(curl -sk --max-time 10 --http3-only -o /dev/null -w '%{http_version}' "https://localhost:$H3_PORT/baseline2?a=1&b=1")"
    expect "GET /baseline2 sum over h3" "55" \
        "$(curl -sk --max-time 10 --http3-only "https://localhost:$H3_PORT/baseline2?a=13&b=42")"

    # The same POST assertion the h1 and h2 baselines carry, and the reason this
    # block exists: curl writes the headers and the body as two packets on one
    # stream, so a 55 here means the engine answered the first packet and the
    # body landed after the response.
    expect "POST /baseline2 sum with body over h3" "75" \
        "$(curl -sk --max-time 10 --http3-only -X POST -d '20' "https://localhost:$H3_PORT/baseline2?a=13&b=42")"

    # A body several packets long, still inside max_request_stream_bytes. The
    # handler refuses anything it only received part of, so a sum here is proof
    # the whole upload was reassembled and not just its first datagram.
    local spanning_body
    spanning_body="20$(head -c 4000 /dev/zero | tr '\0' 'x')"
    expect "POST /baseline2 body spanning packets over h3" "75" \
        "$(curl -sk --max-time 10 --http3-only -X POST --data-binary "$spanning_body" "https://localhost:$H3_PORT/baseline2?a=13&b=42")"

    # Past max_request_stream_bytes: delivered cut, so the handler refuses it
    # rather than summing a fragment. A 200 here would be the silent wrong
    # answer this whole path exists to prevent.
    local oversize_body
    oversize_body="20$(head -c 32000 /dev/zero | tr '\0' 'x')"
    expect "POST /baseline2 body past the pool size over h3" "413" \
        "$(curl -sk --max-time 10 --http3-only -X POST --data-binary "$oversize_body" -o /dev/null -w '%{http_code}' "https://localhost:$H3_PORT/baseline2?a=13&b=42")"

    # Past the per-stream credit the handshake grants (256 KiB). The answer
    # matters less than getting one: without a rolling MAX_STREAM_DATA the
    # client blocks waiting for credit, the engine waits for the rest of the
    # request, and this check times out with no response at all. The body goes
    # through a file: an argument this long never reaches curl.
    local past_credit_file
    past_credit_file="$(mktemp)"
    { printf '20'; head -c 400000 /dev/zero | tr '\0' 'x'; } > "$past_credit_file"
    expect "POST /baseline2 body past the stream credit over h3" "413" \
        "$(curl -sk --max-time 30 --http3-only -X POST --data-binary "@$past_credit_file" -o /dev/null -w '%{http_code}' "https://localhost:$H3_PORT/baseline2?a=13&b=42")"
    rm -f "$past_credit_file"

    # Empty POST: no body to add and nothing missing either, so it answers the
    # query sum rather than the 413 an incomplete body gets.
    expect "POST /baseline2 empty body over h3" "55" \
        "$(curl -sk --max-time 10 --http3-only -X POST -d '' "https://localhost:$H3_PORT/baseline2?a=13&b=42")"

    local a b
    a=$((RANDOM % 900 + 100))
    b=$((RANDOM % 900 + 100))
    expect "GET /baseline2?a=$a&b=$b over h3" "$((a + b))" \
        "$(curl -sk --max-time 10 --http3-only "https://localhost:$H3_PORT/baseline2?a=$a&b=$b")"
}

check_static_h3() {
    echo "[test] static-h3" | tee -a "$REPORT"

    expect "GET https /static/theme.css over h3" "200" \
        "$(curl -sk --max-time 20 --http3-only -o /dev/null -w '%{http_code}' "https://localhost:$H3_PORT/static/theme.css")"
    expect "GET https /static missing file over h3" "404" \
        "$(curl -sk --max-time 20 --http3-only -o /dev/null -w '%{http_code}' "https://localhost:$H3_PORT/static/absent-file.txt")"

    local size expected
    size="$(curl -sk --max-time 30 --http3-only -o /dev/null -w '%{size_download}' "https://localhost:$H3_PORT/static/components.css")"
    expected="$(stat -c%s "$DATA_DIR/static/components.css" 2>/dev/null || echo 0)"
    expect "GET https /static/components.css size over h3" "$expected" "$size"

    # This engine cannot serve a static file at all with the cache window at
    # zero, so a br answer proves both the window and the negotiation.
    local encoding
    encoding="$(curl -sk --max-time 20 --http3-only -D- -o /dev/null -H "Accept-Encoding: br;q=1, gzip;q=0.8" \
        "https://localhost:$H3_PORT/static/app.js" | grep -i '^content-encoding:' |
        tr -d '\r' | awk '{print $2}')"
    expect "GET https /static/app.js negotiates br over h3" "br" "${encoding:-none}"
}

check_gateway() {
    echo "[test] gateway-64" | tee -a "$REPORT"

    local base="https://localhost:$H2_PORT"

    expect "gateway negotiates HTTP/2" "2" \
        "$(curl -sk --max-time 10 --http2 -o /dev/null -w '%{http_version}' "$base/static/reset.css")"

    # Static is answered by the edge itself from public_dir, everything below it
    # is re-originated to the origin, so the two halves are checked separately.
    expect "gateway /static/reset.css Content-Type" "text/css" \
        "$(header_value content-type "$base/static/reset.css" -k --http2)"
    expect "gateway /static/app.js Content-Type" "application/javascript" \
        "$(header_value content-type "$base/static/app.js" -k --http2)"

    local size expected
    size="$(curl -sk --max-time 30 --http2 -o /dev/null -w '%{size_download}' "$base/static/components.css")"
    expected="$(stat -c%s "$DATA_DIR/static/components.css" 2>/dev/null || echo 0)"
    expect "gateway /static/components.css size" "$expected" "$size"

    expect "gateway /static missing file" "404" \
        "$(curl -sk --max-time 10 --http2 -o /dev/null -w '%{http_code}' "$base/static/absent-file.txt")"

    expect "gateway /baseline2?a=13&b=42" "55" \
        "$(curl -sk --max-time 10 --http2 "$base/baseline2?a=13&b=42")"

    local a b
    a=$((RANDOM % 900 + 100))
    b=$((RANDOM % 900 + 100))
    expect "gateway /baseline2?a=$a&b=$b" "$((a + b))" \
        "$(curl -sk --max-time 10 --http2 "$base/baseline2?a=$a&b=$b")"

    # The profile's templates ask for /json/{count} with no m, so the multiplier
    # falls back to 1 and total is price * quantity.
    expect "gateway /json/50" "50" \
        "$(json_verdict 1 "$base/json/50" -k --http2)"
    expect "gateway /json Content-Type" "application/json" \
        "$(header_value content-type "$base/json/50" -k --http2)"

    local count
    count="$(curl -sk --max-time 30 --http2 "$base/async-db?min=10&max=50&limit=50" |
        python3 -c 'import sys,json; print(json.load(sys.stdin)["count"])' 2>/dev/null || echo unreadable)"
    if [ "$count" = "unreadable" ]; then
        no "gateway /async-db" "response was not the expected JSON"
    elif [ "$count" -gt 0 ] 2>/dev/null && [ "$count" -le 50 ]; then
        ok "gateway /async-db returned $count rows"
    else
        no "gateway /async-db" "unexpected count '$count'"
    fi

    expect "gateway /async-db empty range" "0" \
        "$(curl -sk --max-time 30 --http2 "$base/async-db?min=9999&max=9999&limit=50" |
           python3 -c 'import sys,json; print(json.load(sys.stdin)["count"])' 2>/dev/null || echo unreadable)"
}

check_grpc_unary() {
    echo "[test] unary-grpc" | tee -a "$REPORT"

    local pair a b
    for pair in "13:42" "1:2" "1000:-1000" "2147483646:1"; do
        a="${pair%%:*}"
        b="${pair##*:}"

        # proto3 omits a zero field, so a sum of 0 reads back as no result key.
        expect "GetSum($a, $b)" "$((a + b))" \
            "$(grpc_call GetSum "{\"a\":$a,\"b\":$b}" |
               python3 -c 'import sys,json; print(json.load(sys.stdin).get("result", 0))' 2>/dev/null || echo unreadable)"
    done
}

check_grpc_stream() {
    echo "[test] stream-grpc" | tee -a "$REPORT"

    local pair a b count
    for pair in "10:5:4" "1:2:1" "7:7:16"; do
        a="$(echo "$pair" | cut -d: -f1)"
        b="$(echo "$pair" | cut -d: -f2)"
        count="$(echo "$pair" | cut -d: -f3)"

        # grpcurl prints one JSON object per reply, so the whole stream is read
        # as a concatenated document: reply i must be a + b + i.
        expect "StreamSum($a, $b, count=$count)" "ok" \
            "$(grpc_call StreamSum "{\"a\":$a,\"b\":$b,\"count\":$count}" | python3 -c "
import sys, json
base, count = $a + $b, $count
decoder, text, pos, seen = json.JSONDecoder(), sys.stdin.read(), 0, []
while pos < len(text):
    while pos < len(text) and text[pos].isspace():
        pos += 1
    if pos >= len(text):
        break
    doc, pos = decoder.raw_decode(text, pos)
    seen.append(doc.get('result', 0))
if len(seen) != count:
    print('got %d replies, expected %d' % (len(seen), count))
elif seen != [base + i for i in range(count)]:
    print('wrong values: %s' % seen)
else:
    print('ok')
" 2>/dev/null || echo unreadable)"
    done
}

check_upload() {
    echo "[test] upload" | tee -a "$REPORT"

    local small
    small="Hello, HttpArena!"
    expect "POST /upload small body" "${#small}" \
        "$(curl -s --max-time 30 -X POST -H "Content-Type: application/octet-stream" \
            --data-binary "$small" "http://localhost:$PORT/upload")"

    # Random payload, so a count answered from a cache or a constant is caught.
    # A fixture file cannot do this: the same bytes every run are exactly what a
    # memoized answer needs to look correct.
    local rnd
    rnd="$(head -c 64 /dev/urandom | base64 | head -c 48)"
    expect "POST /upload random body" "${#rnd}" \
        "$(curl -s --max-time 30 -X POST -H "Content-Type: application/octet-stream" \
            --data-binary "$rnd" "http://localhost:$PORT/upload")"

    # The four sizes the upload profile drives, each straight from /dev/urandom
    # so no two runs send the same bytes.
    local spec label size got
    for spec in "500K:512000" "2M:2097152" "10M:10485760" "20M:20971520"; do
        label="${spec%%:*}"
        size="${spec##*:}"
        got="$({ dd if=/dev/urandom bs=1024 count=$((size / 1024)) 2>/dev/null |
            curl -s --max-time 120 -X POST -H "Content-Type: application/octet-stream" \
                --data-binary @- "http://localhost:$PORT/upload"; } || true)"

        expect "POST /upload $label" "$size" "$got"
    done

    # A peer that declares a length and then stops. Every model must answer:
    # .ASYNC runs the handler on what arrived, .EPOLL and .URING hold the
    # request until its body is whole and so refuse this one with 400. A closed
    # connection and no bytes is the defect this replaced, because the client
    # cannot tell that apart from a crash.
    local status body
    read -r status body <<< "$(python3 - "$PORT" <<'PY'
import socket, sys

sock = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=10)
sock.sendall(b"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\nhello")
sock.shutdown(socket.SHUT_WR)

raw = b""
while True:
    chunk = sock.recv(4096)
    if not chunk:
        break
    raw += chunk

if not raw:
    print("no-reply")
elif b"\r\n\r\n" in raw:
    head, payload = raw.split(b"\r\n\r\n", 1)
    print(head.split(b"\r\n", 1)[0].split(b" ")[1].decode(), payload.decode(errors="replace").strip())
else:
    print("unparsed")
PY
)"
    case "$status" in
        200) expect "POST /upload truncated body counts what arrived" "5" "$body" ;;
        400) ok "POST /upload truncated body refused with 400" ;;
        no-reply) no "POST /upload truncated body" "the connection closed without an answer" ;;
        *) no "POST /upload truncated body" "unexpected status '$status'" ;;
    esac

    if entry_has json-tls || entry_has static-tls; then
        check_upload_tls
    fi
}

# check_upload_tls
# The same upload contract over the TLS listener. Separate because the transport
# has its own request path on every dispatch model, and it used to cap uploads
# near 17 KB while cleartext carried 20 MiB. Only entries that open a TLS
# listener reach this.
#
# Note:
# - The host is localhost, never 127.0.0.1: the cert SAN is localhost, and an IP
#   literal earns a 421 that says nothing about uploads.
check_upload_tls() {
    echo "[test] upload over tls" | tee -a "$REPORT"

    local small
    small="Hello, HttpArena!"
    expect "POST https /upload small body" "${#small}" \
        "$(curl -sk --max-time 30 --http1.1 -X POST -H "Content-Type: application/octet-stream" \
            --data-binary "$small" "https://localhost:$TLS_PORT/upload")"

    # Past the buffer the whole request used to have to fit, and the largest size
    # the arena upload profile drives.
    local spec label size got
    for spec in "20K:20480" "20M:20971520"; do
        label="${spec%%:*}"
        size="${spec##*:}"
        got="$({ dd if=/dev/urandom bs=1024 count=$((size / 1024)) 2>/dev/null |
            curl -sk --max-time 180 --http1.1 -X POST -H "Content-Type: application/octet-stream" \
                --data-binary @- "https://localhost:$TLS_PORT/upload"; } || true)"

        expect "POST https /upload $label" "$size" "$got"
    done

    # A peer that declares a length and then stops, and one that declares more
    # than the server accepts. Both must answer: a silent close over TLS is what
    # this check exists to catch.
    local truncated_status oversize_status
    read -r truncated_status oversize_status <<< "$(python3 - "$TLS_PORT" <<'PY'
import os, socket, ssl, sys

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


def probe(port, head, body):
    """Send a request the peer never finishes, then half close and read the answer."""
    try:
        sock = socket.create_connection(("localhost", port), timeout=30)

        # A dup of the fd: wrap_socket detaches the original and SSLSocket.shutdown
        # drops the ssl object, so neither can half close and still read.
        half = socket.socket(fileno=os.dup(sock.fileno()))
        tls = ctx.wrap_socket(sock, server_hostname="localhost")
        tls.sendall(head + body)
        half.shutdown(socket.SHUT_WR)

        raw = b""
        while True:
            try:
                chunk = tls.recv(4096)
            except Exception:
                break
            if not chunk:
                break
            raw += chunk
    except Exception:
        return "error"

    if not raw:
        return "no-reply"

    return raw.split(b"\r\n", 1)[0].split(b" ")[1].decode()


port = int(sys.argv[1])
print(
    probe(port, b"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\n", b"hello"),
    probe(port, b"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 99999999\r\n\r\n", b""),
)
PY
)"
    expect "POST https /upload truncated body refused with 400" "400" "$truncated_status"
    expect "POST https /upload past max_request_body refused with 413" "413" "$oversize_status"
}

check_async_db() {
    echo "[test] async-db" | tee -a "$REPORT"

    local count
    count="$(curl -s --max-time 30 "http://localhost:$PORT/async-db?min=10&max=50&limit=5" |
        python3 -c 'import sys,json; print(json.load(sys.stdin)["count"])' 2>/dev/null || echo unreadable)"
    if [ "$count" = "unreadable" ]; then
        no "GET /async-db" "response was not the expected JSON"
    elif [ "$count" -ge 0 ] 2>/dev/null; then
        ok "GET /async-db returned $count rows"
    else
        no "GET /async-db" "unexpected count '$count'"
    fi

    expect "GET /async-db Content-Type" "application/json" \
        "$(header_value content-type "http://localhost:$PORT/async-db?min=10&max=50&limit=50")"

    # A range that matches nothing must answer zero rows. A canned list passes
    # every check above and fails this one.
    local empty
    empty="$(curl -s --max-time 30 "http://localhost:$PORT/async-db?min=9999&max=9999&limit=50" |
        python3 -c 'import sys,json; print(json.load(sys.stdin).get("count","-1"))' 2>/dev/null || echo -1)"
    expect "GET /async-db empty range returns 0" "0" "$empty"
}

check_crud() {
    echo "[test] crud" | tee -a "$REPORT"

    expect "GET /crud/items/1 id" "1" \
        "$(curl -s --max-time 30 "http://localhost:$PORT/crud/items/1" |
           python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])' 2>/dev/null || echo unreadable)"

    local first second
    first="$(curl -s --max-time 30 -D- -o /dev/null "http://localhost:$PORT/crud/items/42" |
        grep -i '^x-cache:' | tr -d '\r' | awk '{print $2}')"
    second="$(curl -s --max-time 30 -D- -o /dev/null "http://localhost:$PORT/crud/items/42" |
        grep -i '^x-cache:' | tr -d '\r' | awk '{print $2}')"
    expect "crud cache-aside MISS then HIT" "MISS HIT" "$first $second"

    expect "GET /crud/items/999999" "404" \
        "$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' "http://localhost:$PORT/crud/items/999999")"

    expect "POST /crud/items" "201" \
        "$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -X POST \
           -H 'Content-Type: application/json' \
           -d '{"id":200001,"name":"ValidateItem","category":"test","price":42,"quantity":7}' \
           "http://localhost:$PORT/crud/items")"

    expect "GET back the created item" "200001" \
        "$(curl -s --max-time 30 "http://localhost:$PORT/crud/items/200001" |
           python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])' 2>/dev/null || echo unreadable)"

    curl -s --max-time 30 -o /dev/null "http://localhost:$PORT/crud/items/200001"
    local put_status after_put
    put_status="$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -X PUT \
        -H 'Content-Type: application/json' \
        -d '{"name":"UpdatedItem","category":"test","price":99,"quantity":1}' \
        "http://localhost:$PORT/crud/items/200001")"
    after_put="$(curl -s --max-time 30 -D- -o /dev/null "http://localhost:$PORT/crud/items/200001" |
        grep -i '^x-cache:' | tr -d '\r' | awk '{print $2}')"
    expect "PUT invalidates the cached row" "200 MISS" "$put_status $after_put"
}

check_ws() {
    echo "[test] echo-ws" | tee -a "$REPORT"

    local script="$ARENA_DIR/scripts/validate-ws.py"
    if [ ! -f "$script" ]; then
        no "websocket" "no validate-ws.py in $ARENA_DIR/scripts"

        return
    fi

    # The arena's own websocket suite: upgrade, text echo, binary echo, several
    # messages in a row, close, and a rejected bad upgrade.
    local output
    output="$(python3 "$script" localhost "$PORT" /ws 2>&1 || true)"
    echo "$output" | grep -E '^\s+(PASS|FAIL)' | tee -a "$REPORT" || true

    local passed failed
    passed="$(echo "$output" | grep -oP '(\d+)(?= passed)' | tail -1)"
    failed="$(echo "$output" | grep -oP '(\d+)(?= failed)' | tail -1)"
    PASS=$((PASS + ${passed:-0}))
    FAIL=$((FAIL + ${failed:-0}))
}

# --------------------------------------------------------- #

{
    echo "localbench validate"
    echo "entry:     $ENTRY"
    echo "profiles:  ${TESTS[*]}"
    echo "fixtures:  $DATA_DIR"
    echo "started:   $(date '+%Y-%m-%d %H:%M:%S')"
    echo
} | tee "$REPORT"

if has_test unary-grpc || has_test stream-grpc; then
    command -v grpcurl >/dev/null 2>&1 ||
        die "grpcurl is not on PATH, the gRPC profiles need it to speak the benchmark service"
fi

needs_db && start_sidecar
start_server

has_test baseline && check_baseline
has_test pipelined && check_pipeline
has_test limited-conn && check_baseline
{ has_test json || has_test api-4 || has_test api-16; } && check_json
has_test json-comp && check_json_comp
has_test json-tls && check_json_tls
has_test static && check_static
has_test static-tls && check_static_tls
has_test baseline-h2 && check_baseline_h2
has_test baseline-h2c && check_baseline_h2c
has_test json-h2c && check_json_h2c
has_test static-h2 && check_static_h2
has_test baseline-h3 && check_baseline_h3
has_test static-h3 && check_static_h3
has_test gateway-64 && check_gateway
has_test unary-grpc && check_grpc_unary
has_test stream-grpc && check_grpc_stream
has_test upload && check_upload
has_test async-db && check_async_db
has_test crud && check_crud
{ has_test echo-ws || has_test echo-ws-pipeline || has_test echo-ws-limited; } && check_ws

{
    echo
    echo "$PASS passed, $FAIL failed"
    echo "finished:  $(date '+%Y-%m-%d %H:%M:%S')"
} | tee -a "$REPORT"

info "report: $REPORT"

[ "$FAIL" -eq 0 ]
