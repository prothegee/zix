#!/usr/bin/env bash
# localbench-run.sh - Run one localbench entry against one or every profile it subscribes to.
#
# The measurement is the one scripts/httparena-benchmark-isolate.sh performs, with the
# entries taken from localbench/ instead of an HttpArena frameworks/ folder. Everything
# that decides what a number means is shared or mirrored: the SMT-aware CPU split and the
# host quiesce come from scripts/lib/bench-host.sh, the driver output is read by
# scripts/lib/bench-metrics.sh, and the server-side cost by scripts/lib/bench-sample.sh.
# The closing table is laid out by scripts/lib/bench-summary.sh, kept apart from all of
# it so a change to how a result is printed cannot reach how it was measured.
#
# What that buys, and why each piece is not optional:
#   - rps is successful responses over the measured duration, never the driver's own
#     throughput line. A driver counts 4xx and 5xx as completed requests, so a server
#     that has started answering 404 would otherwise read as the faster one.
#   - The server is pinned to one half of the machine and the load generator to the
#     other, siblings kept together, so neither side is measuring the other's stalls.
#   - CPU and peak memory are sampled per pass and travel with the pass that produced
#     the best throughput, so all three numbers on a result describe one run.
#   - The server is restarted for every connection count, and postgres is re-seeded
#     before every database profile after the first, so no tier inherits the previous
#     one's warm buffers.
#
# Only the server is native: the database and cache sidecars a profile needs are
# containers, so the seeded data is the arena's own. Profiles come from the entry's
# meta.json, so an entry measures only what it claims to serve. Request templates and
# fixtures come from an HttpArena checkout, nothing is copied into this repository.
#
# Lifecycle (trap-driven, runs on every exit including Ctrl-C):
#   quiesce -> sidecars -> per tier: server up, load, server down -> restore
#
# Args (flags anywhere, positionals are <entry> [profile] [httparena-dir]):
#   <entry>           Required. An entry directory name under localbench/.
#   [profile]         Optional. Run only this profile. Validated against meta.json first.
#   [httparena-dir]   Optional. HttpArena checkout (default: sibling HttpArena next to this one).
#   --out-dir DIR     Optional. Result directory (default: logs/localbench).
#   --runs N          Optional. Load passes per connection count, best wins (default: 3).
#   --duration SPEC   Optional. Load duration per pass (default: 5s).
#   --load-threads N  Optional. Override the derived load generator thread count.
#   --save            Optional. Write results/<profile>/<conns>/<entry>.json (default: dry run).
#   --summarize       Optional. End with a markdown table instead of the aligned text one.
#   --quiesce         Optional. Tune the host the way the arena does. Needs root, restored on exit.
#   --freq HZ         Optional. Pin a fixed frequency. A DEVIATION from the arena, off by default.
#   --probe           Optional. Noise-floor gate. Refuses to measure if the box varies over 1%.
#   --sample-mem      Optional. Poll the server's memory (total, anon/file/pss, smaps) during the run.
#   --settle SECS     Optional. Wait before restoring the host knobs (default: 5).
#   --keep-sidecars   Optional. Leave postgres and redis up after the run (default: removed).
#
# Usage:
#   ./scripts/localbench-run.sh http1-uring
#   ./scripts/localbench-run.sh http1-uring json
#   ./scripts/localbench-run.sh http1-uring --summarize
#   sudo ./scripts/localbench-run.sh http1-uring ../HttpArena --quiesce --save

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SELF_DIR/.." && pwd)"
BENCH_DIR="$ROOT_DIR/localbench"
CERTS_DIR="$BENCH_DIR/certs"

# Record the full invocation so a result file says how to reproduce itself.
INVOCATION="$(printf '%q ' "$0" "$@")"
INVOCATION="${INVOCATION% }"

# Ports, matching HttpArena so a template written for one works for the other. The uri
# list files under requests/ carry these numbers literally, so they are not tunable here.
PORT=8080
TLS_PORT=8081
H2C_PORT=8082
H2_PORT=8443

# HTTP/3 load generator image. The host h2load links ngtcp2 and advertises
# --h3, but every QUIC request errors instantly here with "0 started", so the
# container is the driver rather than a fallback. Build it from the arena:
#   docker build -t h2load-h3:local -f docker/h2load-h3.Dockerfile docker
H2LOAD_H3_IMAGE="${H2LOAD_H3_IMAGE:-h2load-h3:local}"

PG_CONTAINER="localbench-postgres"
REDIS_CONTAINER="localbench-redis"
DATABASE_URL="postgres://bench:bench@localhost:5432/benchmark"

SERVER_PID=""
SIDECARS_UP=0
KEEP_SIDECARS=0
EDGE_UP=0
ZIXER_BIN=""
PG_DIRTY=false

# Logging, worded the way the arena words it so a transcript from either side reads
# the same. Host-preparation lines carry a [run] tag instead, matching the [isol] tag
# the arena's own wrapper uses around its bench.
info()   { echo "[info] $*"; }
warn()   { echo "[warn] $*" >&2; }
fail()   { echo "[FAIL] $*" >&2; exit 1; }
banner() {
    echo ""
    echo "=============================================="
    echo "=== $* ==="
    echo "=============================================="
}

# cleanup
# Runs on every exit path including Ctrl-C, so a killed run never leaves a bound port or
# a container behind.
cleanup() {
    local status=$?

    # A background poller outlives the shell that spawned it, so it goes first.
    if declare -F memlog_stop >/dev/null; then
        memlog_stop
    fi

    # The edge is a daemon this script spawned, so it outlives the shell unless
    # it is stopped by name. Stop it before the origin. `daemon stop` rather
    # than `stop gateway.cfg`: stopping the site alone unbinds the port but
    # leaves the daemon resident.
    if [ "$EDGE_UP" -eq 1 ]; then
        "$ZIXER_BIN" --dir "$ENTRY_DIR" daemon stop >/dev/null 2>&1 || true
        EDGE_UP=0
        echo "[run] edge stopped" >&2
    fi

    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        echo "[run] server stopped" >&2
    fi

    if [ "$SIDECARS_UP" -eq 1 ] && [ "$KEEP_SIDECARS" -eq 0 ]; then
        docker rm -f -v "$PG_CONTAINER" >/dev/null 2>&1 || true
        docker rm -f -v "$REDIS_CONTAINER" >/dev/null 2>&1 || true
        echo "[run] sidecars removed" >&2
    fi

    # Every host knob this run touched goes back, whether the run finished or
    # was interrupted. The settle first: the load generator's sockets are still
    # draining, and restoring the governor under that traffic would let the
    # teardown, not the bench, decide the last frequency the box ran at.
    if [ "$DO_QUIESCE" -eq 1 ]; then
        echo "[run] settling ${SETTLE}s before restore" >&2
        sleep "$SETTLE"
    fi

    if declare -F restore_state >/dev/null; then
        restore_state
    fi

    return "$status"
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------- #
# Profiles: pipeline|req_per_conn|connections|endpoint
# Same shapes HttpArena drives. The endpoint key picks the tool and the request shape.

declare -A PROFILES=(
    [baseline]="1|0|512,4096|"
    [pipelined]="16|0|512,4096|pipeline"
    [limited-conn]="1|10|512,4096|"
    [json]="1|0|4096|json"
    [json-comp]="1|0|512,4096,16384|json-compressed"
    [json-tls]="1|0|4096|json-tls"
    [upload]="1|0|32,256|upload"
    [api-4]="1|5|256|api-4"
    [api-16]="1|5|1024|api-16"
    [static]="1|200|1024,4096,6800|static"
    [static-tls]="1|200|1024,4096,6800|static-tls"
    [async-db]="1|0|1024|async-db"
    [crud]="1|200|4096|crud"
    [baseline-h2]="1|0|256,1024|h2"
    [static-h2]="1|0|256,1024|static-h2"
    [baseline-h2c]="1|0|256,1024,4096|h2c"
    [json-h2c]="1|0|1024,4096|json-h2c"
    [baseline-h3]="1|0|64|h3"
    [static-h3]="1|0|64|static-h3"
    [unary-grpc]="1|0|256,1024|grpc"
    [stream-grpc]="1|0|64|grpc-stream"
    [gateway-64]="1|0|512,1024|gateway-64"
    [echo-ws]="1|0|512,4096,16384|ws-echo"
    [echo-ws-pipeline]="16|0|512,4096,16384|ws-echo"
    [echo-ws-limited]="1|10|512,4096|ws-echo"
)

# Profiles that need a database, and the ones that also need redis.
NEEDS_PG=" async-db crud api-4 api-16 gateway-64 "
NEEDS_REDIS=" crud "

# Database profiles that get a freshly seeded postgres before every tier after the
# first. Without the reset the previous profile's warm buffers, planner statistics,
# and table bloat carry into this one, and the effect is not small: on the arena a
# contaminated crud tier reads roughly a third of a clean one. A gateway profile is
# absent on purpose, matching the arena's own list.
RESETS_PG=" async-db crud api-4 api-16 "

# endpoint_tool ENDPOINT
endpoint_tool() {
    case "$1" in
        static|static-tls|json-tls) echo "wrk" ;;
        h2|static-h2|h2c|json-h2c|gateway-64|grpc) echo "h2load" ;;
        h3|static-h3) echo "h2load-h3" ;;
        grpc-stream) echo "ghz" ;;
        *) echo "gcannon" ;;
    esac
}

# --------------------------------------------------------- #

OUT_DIR=""
RUNS=3
DURATION="5s"
SAVE_RESULTS=0
LOAD_THREADS=""
SUMMARY_MODE="text"

# Off by default: a run that tunes the host has to be asked for, since it needs
# root and it changes machine-wide state until the restore on exit.
DO_QUIESCE=0
FREQ_HZ=""
DO_PROBE=0
DO_SAMPLE_MEM=0
SETTLE=5

POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --out-dir)
            [ "$#" -ge 2 ] || fail "--out-dir needs a value"
            OUT_DIR="$2"; shift 2 ;;
        --out-dir=*) OUT_DIR="${1#*=}"; shift ;;
        --runs)
            [ "$#" -ge 2 ] || fail "--runs needs a value"
            RUNS="$2"; shift 2 ;;
        --runs=*) RUNS="${1#*=}"; shift ;;
        --duration)
            [ "$#" -ge 2 ] || fail "--duration needs a value"
            DURATION="$2"; shift 2 ;;
        --duration=*) DURATION="${1#*=}"; shift ;;
        --load-threads)
            [ "$#" -ge 2 ] || fail "--load-threads needs a value"
            LOAD_THREADS="$2"; shift 2 ;;
        --load-threads=*) LOAD_THREADS="${1#*=}"; shift ;;
        --save) SAVE_RESULTS=1; shift ;;
        --summarize) SUMMARY_MODE="markdown"; shift ;;
        --keep-sidecars) KEEP_SIDECARS=1; shift ;;
        --quiesce) DO_QUIESCE=1; shift ;;
        --freq)
            [ "$#" -ge 2 ] || fail "--freq needs a value (Hz)"
            FREQ_HZ="$2"; shift 2 ;;
        --freq=*) FREQ_HZ="${1#*=}"; shift ;;
        --probe) DO_PROBE=1; shift ;;
        --sample-mem) DO_SAMPLE_MEM=1; shift ;;
        --settle)
            [ "$#" -ge 2 ] || fail "--settle needs a value"
            SETTLE="$2"; shift 2 ;;
        --settle=*) SETTLE="${1#*=}"; shift ;;
        -h|--help) sed -n '2,53p' "$0"; exit 0 ;;
        -*) fail "unknown flag '$1'" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

if [ "${#POSITIONAL[@]}" -eq 0 ]; then
    echo "usage: $(basename "$0") <entry> [profile] [httparena-dir] [flags]" >&2
    echo "       see the header comment for the full flag list" >&2
    exit 1
fi

ENTRY="${POSITIONAL[0]}"
ENTRY_DIR="$BENCH_DIR/$ENTRY"
[ -d "$ENTRY_DIR" ] || fail "no entry directory localbench/$ENTRY"
[ -f "$ENTRY_DIR/meta.json" ] || fail "localbench/$ENTRY has no meta.json"

# The second and third positionals are order-independent: a profile name is a known key,
# anything else is a path.
ONLY_PROFILE=""
ARENA_DIR=""
for arg in "${POSITIONAL[@]:1}"; do
    if [ -n "${PROFILES[$arg]+x}" ]; then
        ONLY_PROFILE="$arg"
    elif [ -d "$arg" ]; then
        ARENA_DIR="$arg"
    else
        # Without this, a mistyped profile name falls through to the path branch
        # and the run dies with a confusing "no fixtures at <typo>/data".
        fail "'$arg' is neither a known profile nor a directory (profiles: $(printf '%s\n' "${!PROFILES[@]}" | sort | tr '\n' ' '))"
    fi
done
ARENA_DIR="${ARENA_DIR:-$ROOT_DIR/../HttpArena}"

[ -d "$ARENA_DIR/data" ] || fail "no fixtures at $ARENA_DIR/data (run localbench-build.sh first)"
[ -d "$ARENA_DIR/requests" ] || fail "no templates at $ARENA_DIR/requests"
ARENA_DIR="$(cd "$ARENA_DIR" && pwd)"
DATA_DIR="$ARENA_DIR/data"
REQUESTS_DIR="$ARENA_DIR/requests"

[ -s "$CERTS_DIR/server.crt" ] || fail "no certificate (run localbench-build.sh first)"

SERVER_BIN="$ENTRY_DIR/zig-out/bin/zix-localbench-$ENTRY"
[ -x "$SERVER_BIN" ] || fail "no binary at $SERVER_BIN (run localbench-build.sh $ENTRY)"

# A gateway entry is two processes: the zixer edge and the origin behind it.
# zixer names its binary after the target triplet and the optimize mode, so the
# name is discovered rather than assumed.
case "$ENTRY" in
    gateway-*)
        ZIXER_BIN="$(find "$ROOT_DIR/zig-out/bin" -maxdepth 1 -name 'zixer-*' -not -name 'zixer-example-*' -type f 2>/dev/null | sort | head -1)"
        [ -n "$ZIXER_BIN" ] || fail "no zixer binary in zig-out/bin (run localbench-build.sh $ENTRY)"
        [ -f "$ENTRY_DIR/sites/gateway.cfg" ] || fail "localbench/$ENTRY has no sites/gateway.cfg"
        ;;
esac

DISPLAY_NAME="$(python3 -c "
import json
print(json.load(open('$ENTRY_DIR/meta.json')).get('display_name', '$ENTRY'))
")"
LANGUAGE="$(python3 -c "
import json
print(json.load(open('$ENTRY_DIR/meta.json')).get('language', ''))
")"

OUT_DIR="${OUT_DIR:-$ROOT_DIR/logs/localbench}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
RESULTS_DIR="$OUT_DIR/results"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_FILE="$OUT_DIR/run-$ENTRY-$STAMP.txt"
MEM_LOG="$OUT_DIR/mem-$ENTRY-$STAMP.txt"
SMAPS_FILE="$OUT_DIR/smaps-$ENTRY-$STAMP.txt"

# cpu_list_count LIST
# How many cpus a taskset list names, e.g. "6-11,14" is 7. Only needed when
# LOCALBENCH_LOADGEN_CPUS overrides the derived split: nproc would report this
# process's own mask, which is not the load generator's half.
cpu_list_count() {
    local total=0 part
    local IFS=','
    for part in $1; do
        case "$part" in
            *-*) total=$((total + ${part#*-} - ${part%-*} + 1)) ;;
            *) total=$((total + 1)) ;;
        esac
    done

    echo "$total"
}

# The CPU split and the host tuning come from the same file the arena isolate
# runner uses, so both prepare this box identically and their numbers are read
# against each other rather than against two different machines. The metric
# parsers and the cost sampler are this side's equivalents of the arena's
# lib/tools/*.sh and lib/stats.sh.
LOG_TAG="run"
IS_ROOT=0
[ "${EUID:-$(id -u)}" -eq 0 ] && IS_ROOT=1
source "$SELF_DIR/lib/bench-host.sh"
source "$SELF_DIR/lib/bench-metrics.sh"
source "$SELF_DIR/lib/bench-sample.sh"
source "$SELF_DIR/lib/bench-memlog.sh"
source "$SELF_DIR/lib/bench-summary.sh"

# SMT-aware halves: server on one, load generator on the other, siblings kept
# together. The naive core/2 split this replaced put SMT siblings of the same
# physical core on opposite sides, so the server and the load generator
# contended for one core's execution units while appearing to be pinned apart.
derive_split

if [ -n "${LOCALBENCH_LOADGEN_CPUS:-}" ]; then
    LOADGEN_CPUS="$LOCALBENCH_LOADGEN_CPUS"
    LOADGEN_THREAD_COUNT="$(cpu_list_count "$LOADGEN_CPUS")"
fi
[ -n "${LOCALBENCH_SERVER_CPUS:-}" ] && SERVER_CPUS="$LOCALBENCH_SERVER_CPUS"

# One load generator thread per load generator hardware thread, which is the
# ratio the arena runs (64 threads on its 64-thread half). No count is fixed
# anywhere: it follows whatever this machine has, and --load-threads is the
# only thing that overrides it.
THREADS="${LOAD_THREADS:-$LOADGEN_THREAD_COUNT}"

mapfile -t SUBSCRIBED < <(python3 -c "
import json
print('\n'.join(json.load(open('$ENTRY_DIR/meta.json'))['tests']))
")
[ "${#SUBSCRIBED[@]}" -gt 0 ] || fail "$ENTRY subscribes to no profile"

if [ -n "$ONLY_PROFILE" ]; then
    printf '%s\n' "${SUBSCRIBED[@]}" | grep -qx "$ONLY_PROFILE" ||
        fail "$ENTRY does not subscribe to '$ONLY_PROFILE' (it has: ${SUBSCRIBED[*]})"

    SUBSCRIBED=("$ONLY_PROFILE")
fi

# --------------------------------------------------------- #

# needs_pg PROFILE
needs_pg() { [[ "$NEEDS_PG" == *" $1 "* ]]; }

# needs_redis PROFILE
needs_redis() { [[ "$NEEDS_REDIS" == *" $1 "* ]]; }

# resets_pg PROFILE
resets_pg() { [[ "$RESETS_PG" == *" $1 "* ]]; }

# any_needs_pg
# Whether any profile in this run wants a database, so the sidecar starts once.
any_needs_pg() {
    local profile
    for profile in "${SUBSCRIBED[@]}"; do
        needs_pg "$profile" && return 0
    done

    return 1
}

any_needs_redis() {
    local profile
    for profile in "${SUBSCRIBED[@]}"; do
        needs_redis "$profile" && return 0
    done

    return 1
}

# postgres_start
# A freshly seeded database from the arena's own dump, on host networking so the
# native server reaches it at localhost. Called again between database profiles,
# which is why it removes any existing container first rather than reusing one.
postgres_start() {
    command -v docker >/dev/null 2>&1 || fail "docker (or the podman shim) is not installed"

    SIDECARS_UP=1

    info "starting postgres sidecar"
    docker rm -f -v "$PG_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --rm --name "$PG_CONTAINER" --network host \
        --tmpfs /var/lib/postgresql:rw,size=2g \
        -e POSTGRES_USER=bench -e POSTGRES_PASSWORD=bench -e POSTGRES_DB=benchmark \
        -v "$DATA_DIR/pgdb-seed.sql:/docker-entrypoint-initdb.d/seed.sql:ro" \
        postgres:18 -c max_connections=256 >/dev/null

    local waited=0
    while [ "$waited" -lt 120 ]; do
        if docker exec "$PG_CONTAINER" pg_isready -U bench -d benchmark >/dev/null 2>&1 &&
           docker exec "$PG_CONTAINER" psql -U bench -d benchmark -tAc \
               'SELECT 1 FROM items LIMIT 1' 2>/dev/null | grep -q 1; then
            info "postgres ready (seeded)"

            return 0
        fi

        sleep 1
        waited=$((waited + 1))
    done

    fail "postgres did not become ready within 120s"
}

# redis_start
redis_start() {
    info "starting redis sidecar"

    docker rm -f -v "$REDIS_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --rm --name "$REDIS_CONTAINER" --network host redis:7-alpine >/dev/null
}

# server_ready PROFILE
# One probe against a listener this profile actually drives. Any answer counts,
# including a 404: the question is whether the socket is serving yet.
server_ready() {
    case "$1" in
        gateway-64)
            curl -sk -o /dev/null --max-time 1 --http2 "https://localhost:$H2_PORT/static/reset.css" 2>/dev/null
            ;;
        baseline-h3|static-h3)
            curl -sk -o /dev/null --max-time 2 --http3-only "https://localhost:$H2_PORT/baseline2?a=1&b=1" 2>/dev/null
            ;;
        unary-grpc|stream-grpc)
            # No HTTP surface to probe, so this checks the listener is accepting.
            (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null
            ;;
        baseline-h2c|json-h2c)
            curl -s -o /dev/null --max-time 1 --http2-prior-knowledge "http://localhost:$H2C_PORT/baseline2?a=1&b=1" 2>/dev/null
            ;;
        baseline-h2|static-h2)
            curl -sk -o /dev/null --max-time 1 --http2 "https://localhost:$H2_PORT/baseline2?a=1&b=1" 2>/dev/null
            ;;
        *)
            curl -s -o /dev/null --max-time 1 "http://localhost:$PORT/pipeline" 2>/dev/null
            ;;
    esac
}

# start_edge LOGFILE
# Bring up the zixer edge in front of the origin, for a gateway entry only.
# Every other entry serves its own listener and this is a no-op.
start_edge() {
    [ -n "$ZIXER_BIN" ] || return 0

    mkdir -p "$ENTRY_DIR/logs"

    # A daemon left over from an interrupted run still holds 8443, and its
    # upstream would be a backend that no longer exists.
    "$ZIXER_BIN" --dir "$ENTRY_DIR" daemon stop >/dev/null 2>&1 || true

    # The edge is the other half of the server side, so it shares the server
    # cpuset with the origin rather than spilling onto the load generator.
    taskset -c "$SERVER_CPUS" "$ZIXER_BIN" --dir "$ENTRY_DIR" start gateway.cfg >>"$1" 2>&1 ||
        fail "the zixer edge did not start, see $1"

    EDGE_UP=1
}

# stop_edge
# `daemon stop` rather than `stop gateway.cfg`: stopping the site alone unbinds
# the port but leaves the daemon resident, so a sweep over several entries would
# accumulate one stray daemon per entry.
stop_edge() {
    [ "$EDGE_UP" -eq 1 ] || return 0

    "$ZIXER_BIN" --dir "$ENTRY_DIR" daemon stop >/dev/null 2>&1 || true
    EDGE_UP=0
}

# start_server PROFILE CONNS
# One server per connection tier, the way the arena starts one container per
# tier, so no tier inherits the allocator state or warm caches of the one
# before it.
#
# Return:
# - 0 once a listener this profile drives is answering
# - 1 if it exited or never answered, with the tail of its log printed
start_server() {
    local profile="$1" conns="$2"
    local log="$OUT_DIR/server-$ENTRY-$profile-$conns-$STAMP.txt"

    # The entry names localbench/data and localbench/certs, so it runs from the
    # repository root the way an arena entry runs against its container mounts.
    cd "$ROOT_DIR"

    local -a env_args=()
    if needs_pg "$profile"; then
        env_args+=("DATABASE_URL=$DATABASE_URL" "DATABASE_MAX_CONN=256")
    fi

    # Pinned to the server half, so the load generator never competes with it for
    # a core. Without this the CPU reading counts both sides of the box.
    env "${env_args[@]+"${env_args[@]}"}" taskset -c "$SERVER_CPUS" "$SERVER_BIN" >"$log" 2>&1 &
    SERVER_PID=$!

    start_edge "$log"

    local waited=0
    while [ "$waited" -lt 100 ]; do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            dump_server_log "$log" "exited during startup"

            return 1
        fi
        server_ready "$profile" && return 0

        sleep 0.2
        waited=$((waited + 1))
    done

    dump_server_log "$log" "did not answer within 20s"

    return 1
}

# dump_server_log LOGFILE REASON
# The server log is the only evidence of why a start failed, and the next tier
# overwrites nothing but is easy to miss, so print the tail while it matters.
dump_server_log() {
    local log="$1" reason="$2" tail_lines="${FAIL_LOG_TAIL:-40}"

    echo ""
    echo "--- $ENTRY - $reason, last $tail_lines lines of $(basename "$log")"
    tail -"$tail_lines" "$log" 2>/dev/null | sed 's/^/  | /' || true
    echo "--- $ENTRY - end of log"
}

# stop_server
stop_server() {
    # The edge goes first, so no request is in flight to an origin that is
    # already gone.
    stop_edge

    [ -n "$SERVER_PID" ] || return 0

    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
}

# --------------------------------------------------------- #
# Load generator argument vectors. One token per line, the caller reads them
# into an array.

# gcannon_args ENDPOINT CONNS PIPELINE REQ_PER_CONN
gcannon_args() {
    local endpoint="$1" conns="$2" pipeline="$3" req="$4"
    local -a args

    case "$endpoint" in
        "")
            args=("http://localhost:$PORT"
                  --raw "$REQUESTS_DIR/get.raw,$REQUESTS_DIR/post_cl.raw,$REQUESTS_DIR/post_chunked.raw"
                  -c "$conns" -t "$THREADS" -d "$DURATION" -p "$pipeline")
            [ "$req" -gt 0 ] && args+=(-r "$req")
            ;;
        pipeline)
            args=("http://localhost:$PORT/pipeline"
                  -c "$conns" -t "$THREADS" -d "$DURATION" -p "$pipeline")
            ;;
        upload)
            args=("http://localhost:$PORT"
                  --raw "$REQUESTS_DIR/upload-500k.raw,$REQUESTS_DIR/upload-2m.raw,$REQUESTS_DIR/upload-10m.raw,$REQUESTS_DIR/upload-20m.raw"
                  -c "$conns" -t "$THREADS" -d "$DURATION" -p "$pipeline" -r 5)
            ;;
        api-4|api-16)
            args=("http://localhost:$PORT"
                  --raw "$REQUESTS_DIR/get.raw,$REQUESTS_DIR/get.raw,$REQUESTS_DIR/get.raw,$REQUESTS_DIR/json-get.raw,$REQUESTS_DIR/json-get.raw,$REQUESTS_DIR/json-get.raw,$REQUESTS_DIR/async-db-get.raw,$REQUESTS_DIR/async-db-get.raw"
                  -c "$conns" -t "$THREADS" -d 15s -p "$pipeline")
            [ "$req" -gt 0 ] && args+=(-r "$req")
            ;;
        async-db)
            args=("http://localhost:$PORT"
                  --raw "$REQUESTS_DIR/async-db-5.raw,$REQUESTS_DIR/async-db-10.raw,$REQUESTS_DIR/async-db-20.raw,$REQUESTS_DIR/async-db-35.raw,$REQUESTS_DIR/async-db-50.raw"
                  -c "$conns" -t "$THREADS" -d 10s -p "$pipeline" -r 25)
            ;;
        json)
            args=("http://localhost:$PORT"
                  --raw "$REQUESTS_DIR/json-1.raw,$REQUESTS_DIR/json-5.raw,$REQUESTS_DIR/json-10.raw,$REQUESTS_DIR/json-15.raw,$REQUESTS_DIR/json-25.raw,$REQUESTS_DIR/json-40.raw,$REQUESTS_DIR/json-50.raw"
                  -c "$conns" -t "$THREADS" -d "$DURATION" -p "$pipeline" -r 25)
            ;;
        json-compressed)
            args=("http://localhost:$PORT"
                  --raw "$REQUESTS_DIR/json-gzip-25.raw,$REQUESTS_DIR/json-gzip-40.raw,$REQUESTS_DIR/json-gzip-50.raw"
                  -c "$conns" -t "$THREADS" -d "$DURATION" -p "$pipeline" -r 25)
            ;;
        ws-echo)
            args=("http://localhost:$PORT/ws" --ws
                  -c "$conns" -t "$THREADS" -d "$DURATION" -p "$pipeline")
            [ "$req" -gt 0 ] && args+=(-r "$req")
            ;;
        crud)
            local files=""
            local file
            for file in $(ls "$REQUESTS_DIR"/crud-list-*.raw "$REQUESTS_DIR"/crud-get-*.raw \
                             "$REQUESTS_DIR"/crud-create-*.raw "$REQUESTS_DIR"/crud-update-*.raw 2>/dev/null | sort); do
                files="${files:+$files,}$file"
            done
            args=("http://localhost:$PORT" --raw "$files"
                  -c "$conns" -t "$THREADS" -d 15s -p "$pipeline")
            [ "$req" -gt 0 ] && args+=(-r "$req")
            ;;
        *)
            fail "gcannon_args: unknown endpoint '$endpoint'"
            ;;
    esac

    printf '%s\n' "${args[@]}"
}

# wrk_args ENDPOINT CONNS
wrk_args() {
    local endpoint="$1" conns="$2"

    case "$endpoint" in
        static)
            printf '%s\n' -t "$THREADS" -c "$conns" -d "$DURATION" \
                -s "$REQUESTS_DIR/static-rotate.lua" "http://localhost:$PORT"
            ;;
        static-tls)
            printf '%s\n' -t "$THREADS" -c "$conns" -d "$DURATION" \
                -s "$REQUESTS_DIR/static-rotate.lua" "https://localhost:$TLS_PORT"
            ;;
        json-tls)
            printf '%s\n' -t "$THREADS" -c "$conns" -d "$DURATION" \
                -s "$REQUESTS_DIR/json-tls-rotate.lua" "https://localhost:$TLS_PORT"
            ;;
        *)
            fail "wrk_args: unknown endpoint '$endpoint'"
            ;;
    esac
}

# h2load_args ENDPOINT CONNS
h2load_args() {
    local endpoint="$1" conns="$2"

    case "$endpoint" in
        h2)
            printf '%s\n' "https://localhost:$H2_PORT/baseline2?a=1&b=1" \
                -c "$conns" -m 100 -t "$THREADS" -D "$DURATION"
            ;;
        static-h2)
            printf '%s\n' -i "$REQUESTS_DIR/static-h2-uris.txt" \
                -H "Accept-Encoding: br;q=1, gzip;q=0.8" \
                -c "$conns" -m 32 -t "$THREADS" -D "$DURATION"
            ;;
        h2c)
            # -p h2c is explicit so a server that cannot do prior-knowledge h2c
            # downgrades to HTTP/1.1 visibly instead of scoring as h2.
            printf '%s\n' "http://localhost:$H2C_PORT/baseline2?a=1&b=1" \
                -p h2c -c "$conns" -m 100 -t "$THREADS" -D "$DURATION"
            ;;
        json-h2c)
            printf '%s\n' -i "$REQUESTS_DIR/json-h2c-uris.txt" \
                -p h2c -c "$conns" -m 32 -t "$THREADS" -D "$DURATION"
            ;;
        gateway-64)
            # A 20-URI mix across the whole edge: 6 static answered by the
            # gateway itself, 14 re-originated to the backend (4 baseline,
            # 7 json, 3 async-db).
            printf '%s\n' -i "$REQUESTS_DIR/gateway-64-uris.txt" \
                -H "Accept-Encoding: br;q=1, gzip;q=0.8" \
                -c "$conns" -m 32 -t "$THREADS" -D "$DURATION"
            ;;
        grpc)
            printf '%s\n' "http://localhost:$PORT/benchmark.BenchmarkService/GetSum" \
                -d "$REQUESTS_DIR/grpc-sum.bin" \
                -H 'content-type: application/grpc' -H 'te: trailers' \
                -c "$conns" -m 100 -t "$THREADS" -D "$DURATION"
            ;;
        *)
            fail "h2load_args: unknown endpoint '$endpoint'"
            ;;
    esac
}

# h2load_h3_args ENDPOINT CONNS
# Arguments for the containerized driver, so every path is the one inside it.
# The templates are bind-mounted at /requests, and --network host means the
# localhost in each URI is this machine.
h2load_h3_args() {
    local endpoint="$1" conns="$2"

    case "$endpoint" in
        h3)
            printf '%s\n' --alpn-list=h3 "https://localhost:$H2_PORT/baseline2?a=1&b=1" \
                -c "$conns" -m 64 -t "$THREADS" -D "$DURATION"
            ;;
        static-h3)
            # Same 20-file list the h2 static profile drives, so the two are
            # comparable across transports.
            printf '%s\n' --alpn-list=h3 -i /requests/static-h2-uris.txt \
                -H "Accept-Encoding: br;q=1, gzip;q=0.8" \
                -c "$conns" -m 64 -t "$THREADS" -D "$DURATION"
            ;;
        *)
            fail "h2load_h3_args: unknown endpoint '$endpoint'"
            ;;
    esac
}

# ghz_args ENDPOINT CONNS [DURATION]
# Four streams per connection, the shape the arena settled on for this profile.
# The duration is a parameter so the warm-up can borrow the same vector.
ghz_args() {
    local endpoint="$1" conns="$2" duration="${3:-$DURATION}"

    case "$endpoint" in
        grpc-stream)
            printf '%s\n' --insecure \
                --proto "$REQUESTS_DIR/benchmark.proto" \
                --call benchmark.BenchmarkService/StreamSum \
                -d "{\"a\":1,\"b\":2,\"count\":$GHZ_MSGS_PER_CALL}" \
                --connections "$conns" -c "$((conns * 4))" \
                -z "$duration" "localhost:$PORT"
            ;;
        *)
            fail "ghz_args: unknown endpoint '$endpoint'"
            ;;
    esac
}

# build_args TOOL ENDPOINT CONNS PIPELINE REQ
build_args() {
    local tool="$1" endpoint="$2" conns="$3" pipeline="$4" req="$5"

    case "$tool" in
        gcannon)   gcannon_args "$endpoint" "$conns" "$pipeline" "$req" ;;
        wrk)       wrk_args "$endpoint" "$conns" ;;
        h2load)    h2load_args "$endpoint" "$conns" ;;
        h2load-h3) h2load_h3_args "$endpoint" "$conns" ;;
        ghz)       ghz_args "$endpoint" "$conns" ;;
        *)         fail "no local driver for tool '$tool'" ;;
    esac
}

# tool_available TOOL
# Whether this machine can drive TOOL. Everything is a binary on PATH except the
# HTTP/3 driver, which is a container image.
tool_available() {
    case "$1" in
        h2load-h3) docker image inspect "$H2LOAD_H3_IMAGE" >/dev/null 2>&1 ;;
        *) command -v "$1" >/dev/null 2>&1 ;;
    esac
}

# The arena bounds every load pass at 45 seconds, which comfortably covers its
# longest profile (the 15s api and crud rotations). The KILL escalation is what
# its isolate wrapper adds on top through a PATH shim: a container client traps
# TERM to tear its container down, and a wedged teardown would otherwise leave
# `timeout` waiting forever inside a captured command substitution, hanging the
# sweep with no output at all. 15 seconds is teardown grace, then KILL.
LOAD_TIMEOUT=(timeout --kill-after=15 45)

# run_load TOOL ARG...
# One pass. Returns the driver's raw output on stdout. The load generator is
# pinned to its own half of the machine, so it never competes with the server
# for a core.
run_load() {
    local tool="$1"
    shift

    case "$tool" in
        gcannon)
            "${LOAD_TIMEOUT[@]}" taskset -c "$LOADGEN_CPUS" env LD_LIBRARY_PATH=/usr/lib gcannon "$@" 2>&1 || true
            ;;
        wrk)
            "${LOAD_TIMEOUT[@]}" taskset -c "$LOADGEN_CPUS" wrk "$@" 2>&1 || true
            ;;
        h2load)
            "${LOAD_TIMEOUT[@]}" taskset -c "$LOADGEN_CPUS" h2load "$@" 2>&1 || true
            ;;
        h2load-h3)
            # --cpuset-cpus rather than taskset: the work happens inside the
            # container, so pinning the client process would pin nothing.
            "${LOAD_TIMEOUT[@]}" docker run --rm --network host \
                --cpuset-cpus "$LOADGEN_CPUS" \
                -v "$REQUESTS_DIR:/requests:ro" \
                "$H2LOAD_H3_IMAGE" "$@" 2>&1 || true
            ;;
        ghz)
            "${LOAD_TIMEOUT[@]}" taskset -c "$LOADGEN_CPUS" ghz "$@" 2>&1 || true
            ;;
        *)
            fail "no local driver for tool '$tool'"
            ;;
    esac
}

# ghz_warmup CONNS
# A short unmeasured pass before the first measured one, so run 1 does not pay
# for a cold accept loop and a cold connection pool.
ghz_warmup() {
    info "ghz warm-up 2s"

    local -a args
    mapfile -t args < <(ghz_args grpc-stream "$1" 2s)

    taskset -c "$LOADGEN_CPUS" ghz "${args[@]}" >/dev/null 2>&1 || true
}

# stats_targets
# The label=pid pairs the cost sampler measures: the origin this script started,
# plus the zixer edge when the entry has one.
stats_targets() {
    [ -n "$SERVER_PID" ] && echo "server=$SERVER_PID"

    if [ -n "$ZIXER_BIN" ]; then
        local pid
        for pid in $(pgrep -f "$(basename "$ZIXER_BIN")" 2>/dev/null || true); do
            echo "edge=$pid"
        done
    fi
}

# --------------------------------------------------------- #

# run_one PROFILE CONNS
# One (profile, connection count) iteration: a fresh server, RUNS load passes,
# the best one kept.
#
# Return:
# - 0 when the tier was measured
# - 1 when the server never came up, so the caller moves to the next tier
run_one() {
    local profile="$1" conns="$2"
    local pipeline req conn_spec endpoint tool

    IFS='|' read -r pipeline req conn_spec endpoint <<< "${PROFILES[$profile]}"
    tool="$(endpoint_tool "$endpoint")"

    banner "$ENTRY / $profile / ${conns}c (tool=$tool)"

    # A database profile gets a freshly seeded server, so it is not measuring
    # the previous profile's warm buffers. The first one already has one from
    # the upfront start, hence the dirty flag.
    if resets_pg "$profile"; then
        if [ "$PG_DIRTY" = true ]; then
            info "resetting postgres for a clean per-profile baseline"
            postgres_start
        fi

        PG_DIRTY=true
    fi

    if ! start_server "$profile" "$conns"; then
        warn "$ENTRY did not come up for $profile, skipping"
        stop_server

        return 1
    fi

    local -a load_args
    mapfile -t load_args < <(build_args "$tool" "$endpoint" "$conns" "$pipeline" "$req")

    if [ "$tool" = "ghz" ]; then
        ghz_warmup "$conns"
    fi

    # The detail profile covers the whole tier rather than one pass, and the pids
    # are captured now: the server is restarted for every tier, so a sampler that
    # outlived one would be reading a process that no longer exists.
    local tier="$profile-${conns}c"
    if [ "$DO_SAMPLE_MEM" -eq 1 ]; then
        # shellcheck disable=SC2046
        memlog_start "$MEM_LOG" "$SMAPS_FILE" "$tier" $(stats_targets)
    fi

    # best_rps starts below zero so the first pass always wins, even when it
    # measured nothing: otherwise BEST_M would carry the previous tier's
    # metrics into a tier that scored zero.
    local best_rps=-1 best_cpu="0%" best_mem="0MiB" best_breakdown=""
    BEST_M=()

    local pass output line key
    for pass in $(seq 1 "$RUNS"); do
        echo ""
        echo "[run $pass/$RUNS]"

        # shellcheck disable=SC2046
        stats_start $(stats_targets)

        output="$(run_load "$tool" "${load_args[@]}")"
        stats_stop

        # The driver's own report, minus its per-thread spawn chatter.
        echo "$output" | grep -Ev '^(Warm-up|Main benchmark duration|Stopped all clients|progress: [0-9]+% of clients started|spawning thread #[0-9]+|[0-9]*Warm-up phase is over for thread #[0-9]+)' || true
        info "CPU $STATS_AVG_CPU | Mem $STATS_PEAK_MEM"
        [ -n "$STATS_BREAKDOWN" ] && info "  $STATS_BREAKDOWN"

        echo "$output" >>"$OUT_DIR/raw-$ENTRY-$profile-$conns-$STAMP.txt"

        local -A metrics=()
        while IFS= read -r line; do
            [[ "$line" == *=* ]] && metrics["${line%%=*}"]="${line#*=}"
        done < <("${tool//-/_}_parse" "$endpoint" "$output")

        local rps_int=${metrics[rps]:-0}
        if [ "$rps_int" -gt "$best_rps" ] 2>/dev/null; then
            best_rps=$rps_int
            best_cpu="$STATS_AVG_CPU"
            best_mem="$STATS_PEAK_MEM"
            best_breakdown="$STATS_BREAKDOWN"

            BEST_M=()
            for key in "${!metrics[@]}"; do BEST_M[$key]="${metrics[$key]}"; done
        fi

        sleep 2
    done

    memlog_stop

    echo ""
    echo "=== Best: ${best_rps} req/s (CPU: $best_cpu, Mem: $best_mem) ==="

    record_input_bw "$best_rps" "${load_args[@]}"

    # Summarized per tier, not once at the end: a 4096-connection tier and a
    # 512-connection one have different memory profiles, and one median across
    # both would describe neither.
    if [ "$DO_SAMPLE_MEM" -eq 1 ]; then
        memlog_summary "$MEM_LOG" "$SMAPS_FILE" "$tier"
    fi

    if [ "$SAVE_RESULTS" -eq 1 ]; then
        save_result "$profile" "$conns" "$best_rps" "$best_cpu" "$best_mem" "$best_breakdown"
    else
        info "dry-run - not saving (use --save to persist)"
    fi

    summary_row "$profile" "$conns" "$tool" "$best_rps" "$best_cpu" "$best_mem"

    stop_server

    return 0
}

# record_input_bw BEST_RPS LOAD_ARG...
# Bytes the server ingests per second, as throughput times the mean size of the
# request templates in rotation. It matters where the REQUEST body is the work
# (upload, the mixed api fixtures, crud writes) and response bandwidth alone
# understates what the server did. Endpoints that send no template body have
# nothing to average, so they get no line.
record_input_bw() {
    local best_rps="$1"
    shift

    local raw_arg="" prev_was_raw=false arg
    for arg in "$@"; do
        if [ "$prev_was_raw" = true ]; then
            raw_arg="$arg"
            break
        fi

        [ "$arg" = "--raw" ] && prev_was_raw=true || prev_was_raw=false
    done

    [ -n "$raw_arg" ] || return 0
    [ "$best_rps" -gt 0 ] 2>/dev/null || return 0

    local avg_tpl_size
    avg_tpl_size=$(IFS=','; total=0; count=0
        for file in $raw_arg; do
            size=$(wc -c < "$file" 2>/dev/null || echo 0)
            total=$((total + size))
            count=$((count + 1))
        done
        [ "$count" -gt 0 ] && echo "$((total / count))" || echo "0")

    BEST_M[input_bw]=$(awk -v bps="$(( best_rps * avg_tpl_size ))" 'BEGIN {
        if (bps >= 1073741824)   printf "%.2fGB/s", bps / 1073741824
        else if (bps >= 1048576) printf "%.2fMB/s", bps / 1048576
        else if (bps >= 1024)    printf "%.2fKB/s", bps / 1024
        else                     printf "%dB/s", bps
    }')

    info "input BW: ${BEST_M[input_bw]} (avg template: ${avg_tpl_size} bytes)"
}

# save_result PROFILE CONNS RPS CPU MEM BREAKDOWN
# One JSON per (profile, connection count), carrying the fields the arena's own
# result files carry, so the two can be read with the same tooling.
save_result() {
    local profile="$1" conns="$2" best_rps="$3" best_cpu="$4" best_mem="$5" best_breakdown="$6"
    local dir="$RESULTS_DIR/$profile/$conns"
    mkdir -p "$dir"

    local cpu_extra=""
    if [ -n "$best_breakdown" ]; then
        cpu_extra=",
  \"cpu_breakdown\": \"$best_breakdown\""
    fi

    local input_extra=""
    if [ -n "${BEST_M[input_bw]:-}" ]; then
        input_extra="
  \"input_bw\": \"${BEST_M[input_bw]}\","
    fi

    # The per-template counts are what a mixed-endpoint score is built from. The
    # api profiles report them directly. The gateway mix is a fixed 20-URI list
    # (6 static, 4 baseline, 7 json, 3 async-db) so its split is proportional.
    local tpl_extra=""
    if [ "$profile" = "api-4" ] || [ "$profile" = "api-16" ]; then
        tpl_extra=",
  \"tpl_baseline\": ${BEST_M[tpl_baseline]:-0},
  \"tpl_json\": ${BEST_M[tpl_json]:-0},
  \"tpl_db\": 0,
  \"tpl_upload\": 0,
  \"tpl_static\": 0,
  \"tpl_async_db\": ${BEST_M[tpl_async_db]:-0}"
    elif [ "$profile" = "gateway-64" ] && [ "${BEST_M[status_2xx]:-0}" -gt 0 ] 2>/dev/null; then
        local total=${BEST_M[status_2xx]}
        tpl_extra=",
  \"tpl_static\": $(( total * 6 / 20 )),
  \"tpl_baseline\": $(( total * 4 / 20 )),
  \"tpl_json\": $(( total * 7 / 20 )),
  \"tpl_async_db\": $(( total * 3 / 20 ))"
    fi

    local pipeline
    IFS='|' read -r pipeline _ _ _ <<< "${PROFILES[$profile]}"

    cat > "$dir/${ENTRY}.json" <<EOF
{
  "framework": "$DISPLAY_NAME",
  "language": "$LANGUAGE",
  "rps": $best_rps,
  "avg_latency": "${BEST_M[avg_lat]:-}",
  "p99_latency": "${BEST_M[p99_lat]:-}",
  "cpu": "$best_cpu",
  "memory": "$best_mem",
  "connections": $conns,
  "threads": $THREADS,
  "duration": "$DURATION",
  "pipeline": $pipeline,
  "bandwidth": "${BEST_M[bandwidth]:-0}",$input_extra
  "reconnects": ${BEST_M[reconnects]:-0},
  "status_2xx": ${BEST_M[status_2xx]:-0},
  "status_3xx": ${BEST_M[status_3xx]:-0},
  "status_4xx": ${BEST_M[status_4xx]:-0},
  "status_5xx": ${BEST_M[status_5xx]:-0}${tpl_extra}${cpu_extra}
}
EOF
    info "saved results/$profile/$conns/${ENTRY}.json"
}

# --------------------------------------------------------- #

# Everything from here lands in the result file as well as on the terminal, the
# way the arena wrapper tees its bench. The redirection starts only after every
# argument has validated, so a usage error still goes to the terminal alone.
exec > >(tee "$RESULT_FILE") 2>&1

START="$(date '+%Y-%m-%d %H:%M:%S')"
echo "Localbench: $ENTRY bench start $START"
echo
echo "# zix localbench run (arena profile matrix, native localbench/ entries)"
echo "# command:      $INVOCATION"
echo "# stamp:        $STAMP"
echo "# entry:        $ENTRY"
echo "# profile:      ${ONLY_PROFILE:-(all)}"
echo "# source:       localbench/$ENTRY"
echo "# fixtures:     $DATA_DIR"
echo "# templates:    $REQUESTS_DIR"
echo "# server_cpus:  $SERVER_CPUS"
echo "# loadgen_cpus: $LOADGEN_CPUS"
echo "# threads:      $THREADS${LOAD_THREADS:+ (--load-threads)}"
echo "# runs:         $RUNS (best wins)"
echo "# duration:     $DURATION"
echo "# quiesce:      $DO_QUIESCE (system_tune equivalent: governor/sysctls/lo-mtu-1500/docker-restart/drop-caches)"
echo "# freq_pin:     ${FREQ_HZ:-(none, arena parity)}"
echo "# probe_gate:   $DO_PROBE"
echo "# sample_mem:   $DO_SAMPLE_MEM$([ "$DO_SAMPLE_MEM" -eq 1 ] && echo "  -> $(basename "$MEM_LOG")")"
echo "# settle_s:     $SETTLE"
echo "# save:         $SAVE_RESULTS"
echo "# summary:      $SUMMARY_MODE"
echo

if [ "$DO_QUIESCE" -eq 1 ]; then
    save_state
    quiesce
elif [ "$IS_ROOT" -eq 1 ]; then
    info "host untuned, pass --quiesce to match the arena"
else
    info "host untuned, re-run as root with --quiesce to match the arena"
fi

# A box that cannot repeat fixed arithmetic within 1% cannot repeat a benchmark
# either, so a failed gate stops before anything is measured.
if [ "$DO_PROBE" -eq 1 ] && ! probe_gate; then
    warn "box is not quiet ($PROBE_RESULT), aborting before the bench"
    exit 1
fi
[ -n "$PROBE_RESULT" ] && info "probe: $PROBE_RESULT"

if any_needs_pg; then
    postgres_start
    any_needs_redis && redis_start
fi

declare -A BEST_M
summary_reset

for profile in "${SUBSCRIBED[@]}"; do
    if [ -z "${PROFILES[$profile]:-}" ]; then
        warn "unknown profile: $profile"
        continue
    fi

    IFS='|' read -r _ _ conns endpoint <<< "${PROFILES[$profile]}"
    tool="$(endpoint_tool "$endpoint")"

    if ! tool_available "$tool"; then
        if [ "$tool" = "h2load-h3" ]; then
            info "skip: $profile needs the $H2LOAD_H3_IMAGE image (build it from the arena: docker build -t $H2LOAD_H3_IMAGE -f docker/h2load-h3.Dockerfile docker)"
        else
            info "skip: $profile needs $tool, which is not installed"
        fi

        continue
    fi

    IFS=',' read -ra conn_list <<< "$conns"
    for conn in "${conn_list[@]}"; do
        run_one "$profile" "$conn" || continue
    done
done

if [ "$DO_SAMPLE_MEM" -eq 1 ]; then
    rm -f "$MEM_LOG.peak"
    [ -s "$MEM_LOG" ] && info "memory samples: $MEM_LOG"
    [ -s "$SMAPS_FILE" ] && info "smaps at peak: $SMAPS_FILE"
fi

info "done"

# The arena stops here. This table is the one addition: an 18-entry sweep is a
# long transcript, and a reader still needs the tiers side by side. One table
# either way: with a profile named on the command line it holds that profile's
# tiers, without one it holds every tier the entry subscribes to.
echo
echo "=============================================="
echo "=== $ENTRY summary ==="
echo "=============================================="
summary_render "$SUMMARY_MODE"
echo
echo "finished:   $(date '+%Y-%m-%d %H:%M:%S')"
echo "result:     $RESULT_FILE"
