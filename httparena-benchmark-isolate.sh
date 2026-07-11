#!/usr/bin/env bash
# benchmark-httparena-isolate - Full-suite isolate wrapper for HttpArena scripts/benchmark.sh.
#
# Runs the FULL benchmark suite (stock profiles, connection sweeps, and durations,
# exactly what the arena box runs) in a quiesced, pinned environment, scaled to
# THIS machine's CPU count instead of the arena's hard-coded 64-core topology.
# The test matrix is identical everywhere: only the CPU sizing differs, so a
# result scales with the cores available rather than measuring a different test
# (the lite profile subset reads wrong in absolute terms). Tracked HttpArena
# scripts are unmodified: patched disposable copies run and are removed on exit.
#
# What is scaled to the machine (everything else is stock benchmark.sh):
#   - Server cpuset: profiles' hard-coded 0-31,64-95 becomes the local SMT-aware
#     half split (whole cores per side, siblings kept together).
#   - Load generator: GCANNON_CPUS = the other half, THREADS/H2THREADS/H3THREADS =
#     one per load-gen hardware thread (the arena ratio), unless --load-threads.
#   - Load generators run in Docker (LOADGEN_DOCKER=true default: a laptop rarely
#     has an ngtcp2-enabled h2load native). Pre-set LOADGEN_DOCKER=false to override.
#
# Quiesce is an EXACT system_tune equivalent, nothing more, so the local run
# matches the arena run knob for knob (including the cold first run after the
# page-cache drop: the arena has it too, so it stays):
#   governor performance, socket/UDP sysctls, lo MTU 1500 (realistic Ethernet,
#   matters for h3), docker daemon restart, page cache drop
# Everything touched is saved first and restored on exit (the arena leaves some
# knobs set, this does not). --freq additionally pins a fixed frequency: that is
# a DEVIATION from the arena (which runs governor performance with boost), off
# by default, for noise hunting only. system_tune/system_restore are neutralized
# in the patched copy so tuning happens exactly once, out here, with restore.
#
# Lifecycle (trap-driven, runs on EXIT/Ctrl-C):
#   save -> quiesce -> pin -> bench (scripts/benchmark.sh) -> settle -> restore
#
# Isolate flags:
#   --settle SECS   Wait before restore (default: 5).
#   --freq HZ       Pin a fixed frequency (arena DEVIATION, off by default).
#   --probe         Run spin.c noise-floor gate; abort if stddev > 1%.
#   --sample-mem    Poll container cgroup (total, anon/sock/slab, smaps) during bench.
#   --no-quiesce    Skip quiesce/pin (measure noisy baseline).
#   --out-dir DIR   Result directory (default: logs/benchmark).
#
# Source flags (mirroring benchmark-httparena-lite.sh):
#   --source MODE     "remote" (default, Dockerfile fetches the branch) or "local".
#   --zix-dir DIR     Local zix checkout for --source local (default: this dir).
#   --load-threads N  Override the derived load-gen thread count.
#
# Positionals (order does not matter for the last two):
#   <framework>       Required (e.g. zix_uring_http1-1).
#   [profile]         Bench only this profile. Validated before any build.
#   [httparena-dir]   HttpArena folder (default: this script's directory).
#
# Usage (re-execs under sudo when ISOLATE_SUDO=true; rootless skips host quiesce):
#   ./benchmark-httparena-isolate.sh zix_uring_http3-1 ../HttpArena --source local
#   ./benchmark-httparena-isolate.sh zix_uring_http3-1 baseline-h3 ../HttpArena --sample-mem
#   ./benchmark-httparena-isolate.sh zix_uring_http1-1 ../HttpArena --probe --sample-mem --source local

set -euo pipefail

IS_ROOT=0
[ "${EUID:-$(id -u)}" -eq 0 ] && IS_ROOT=1
if [ "$IS_ROOT" -ne 1 ] && [ "${ISOLATE_SUDO:-false}" = "true" ]; then
    exec sudo -E -- "$0" "$@"
fi

# Record full invocation for self-documenting result files (copy-paste safe).
INVOCATION="$(printf '%q ' "$0" "$@")"
INVOCATION="${INVOCATION% }"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_RESULT_DIR="$SELF_DIR/logs/benchmark"

# Parse flags; positionals are <framework> [profile] [httparena-dir].
SETTLE=5
FREQ_HZ=
DO_PROBE=0
DO_SAMPLE_MEM=0
DO_QUIESCE=1
OUT_DIR=
SOURCE=remote
ZIX_DIR=
LOAD_THREADS=
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --settle)         [ "$#" -ge 2 ] || { echo "error: --settle needs a value" >&2; exit 1; }; SETTLE="$2"; shift 2 ;;
        --settle=*)       SETTLE="${1#*=}"; shift ;;
        --freq)           [ "$#" -ge 2 ] || { echo "error: --freq needs a value (Hz)" >&2; exit 1; }; FREQ_HZ="$2"; shift 2 ;;
        --freq=*)         FREQ_HZ="${1#*=}"; shift ;;
        --probe)          DO_PROBE=1; shift ;;
        --sample-mem)     DO_SAMPLE_MEM=1; shift ;;
        --no-quiesce)     DO_QUIESCE=0; shift ;;
        --out-dir)        [ "$#" -ge 2 ] || { echo "error: --out-dir needs a value" >&2; exit 1; }; OUT_DIR="$2"; shift 2 ;;
        --out-dir=*)      OUT_DIR="${1#*=}"; shift ;;
        --source)         [ "$#" -ge 2 ] || { echo "error: --source needs a value (local|remote)" >&2; exit 1; }; SOURCE="$2"; shift 2 ;;
        --source=*)       SOURCE="${1#*=}"; shift ;;
        --zix-dir)        [ "$#" -ge 2 ] || { echo "error: --zix-dir needs a value" >&2; exit 1; }; ZIX_DIR="$2"; shift 2 ;;
        --zix-dir=*)      ZIX_DIR="${1#*=}"; shift ;;
        --load-threads)   [ "$#" -ge 2 ] || { echo "error: --load-threads needs a value" >&2; exit 1; }; LOAD_THREADS="$2"; shift 2 ;;
        --load-threads=*) LOAD_THREADS="${1#*=}"; shift ;;
        --*)              echo "error: unknown flag '$1'" >&2; exit 1 ;;
        *)                POSITIONAL+=("$1"); shift ;;
    esac
done
case "$SOURCE" in
    local|remote) ;;
    *) echo "error: --source must be 'local' or 'remote', got '$SOURCE'" >&2; exit 1 ;;
esac

FRAMEWORK="${POSITIONAL[0]:-}"
if [ -z "$FRAMEWORK" ]; then
    echo "usage: $(basename "$0") <framework> [profile] [httparena-dir] [flags]" >&2
    echo "       see the header comment for the full flag list" >&2
    exit 1
fi

# Classify the remaining positionals: an HttpArena folder (has scripts/benchmark.sh)
# is [httparena-dir], anything else is [profile].
REPO_DIR=
PROFILE=
for extra in "${POSITIONAL[@]:1}"; do
    if [ -f "$extra/scripts/benchmark.sh" ]; then
        if [ -n "$REPO_DIR" ]; then
            echo "error: httparena-dir given twice ('$REPO_DIR', '$extra')" >&2
            exit 1
        fi
        REPO_DIR="$extra"
    else
        if [ -n "$PROFILE" ]; then
            echo "error: profile given twice ('$PROFILE', '$extra')" >&2
            exit 1
        fi
        PROFILE="$extra"
    fi
done
REPO_DIR="${REPO_DIR:-$SELF_DIR}"
if [ ! -f "$REPO_DIR/scripts/benchmark.sh" ]; then
    echo "error: '$REPO_DIR' is not an HttpArena folder (no scripts/benchmark.sh)" >&2
    exit 1
fi
REPO_DIR="$(cd "$REPO_DIR" && pwd)"

# Validate [profile] against the stock full-suite profile set before any build.
KNOWN_PROFILES="baseline pipelined limited-conn json json-comp json-tls upload api-4 api-16 static async-db crud fortunes baseline-h2 static-h2 baseline-h2c json-h2c baseline-h3 static-h3 unary-grpc unary-grpc-tls stream-grpc stream-grpc-tls gateway-64 gateway-h3 production-stack echo-ws echo-ws-pipeline"
if [ -n "$PROFILE" ]; then
    case " $KNOWN_PROFILES " in
        *" $PROFILE "*) ;;
        *)
            echo "error: unknown profile '$PROFILE'" >&2
            echo "known profiles: $KNOWN_PROFILES" >&2
            exit 1 ;;
    esac
fi

ZIX_DIR="${ZIX_DIR:-$SELF_DIR}"

# Canonicalize the result dir: the bench itself runs after a cd into the
# HttpArena folder, so a relative --out-dir must be pinned to the invocation
# directory here or every later write would resolve against the wrong root.
RESULT_DIR="${OUT_DIR:-$DEFAULT_RESULT_DIR}"
mkdir -p "$RESULT_DIR"
RESULT_DIR="$(cd "$RESULT_DIR" && pwd)"

# Disposable patched copies (removed on exit). They live next to the originals
# so BASH_SOURCE-relative lib sourcing keeps resolving.
BENCH_SRC="$REPO_DIR/scripts/benchmark.sh"
BENCH_PATCHED="$REPO_DIR/scripts/.benchmark-scaled.$$.sh"
FW_SRC="$REPO_DIR/scripts/lib/framework.sh"
FW_PATCHED="$REPO_DIR/scripts/lib/.framework-grpcfix.$$.sh"
PROFILES_SRC="$REPO_DIR/scripts/lib/profiles.sh"
PROFILES_PATCHED="$REPO_DIR/scripts/lib/.profiles-scaled.$$.sh"
ORIG_DIR="$PWD"

# Local-source staging targets (all removed on exit).
FW_DIR="$REPO_DIR/frameworks/$FRAMEWORK"
VENDOR_DIR="$FW_DIR/vendor/zix"
LOCAL_DOCKERFILE="$FW_DIR/.Dockerfile.local.$$"
LOCAL_BUILDSH="$FW_DIR/build.sh"

# Validate --source local before the trap so a pre-existing tracked build.sh is never deleted.
if [ "$SOURCE" = "local" ]; then
    if [ ! -f "$ZIX_DIR/build.zig" ] || [ ! -f "$ZIX_DIR/build.zig.zon" ] || [ ! -f "$ZIX_DIR/src/lib.zig" ]; then
        echo "error: --zix-dir '$ZIX_DIR' is not a zix checkout (no build.zig, build.zig.zon or src/lib.zig)" >&2
        exit 1
    fi
    if [ ! -f "$FW_DIR/Dockerfile" ] || ! grep -q 'vendor/zix' "$FW_DIR/Dockerfile"; then
        echo "error: framework '$FRAMEWORK' does not vendor zix; --source local does not apply" >&2
        exit 1
    fi
    if [ -e "$LOCAL_BUILDSH" ]; then
        echo "error: '$LOCAL_BUILDSH' already exists; refusing to overwrite a tracked build.sh" >&2
        exit 1
    fi

    ZIX_DIR="$(cd "$ZIX_DIR" && pwd)"
fi

# SMT-aware half-split: keeps SMT pairs together on server or loadgen side, and
# counts the loadgen hardware threads for the derived THREADS value.
LOADGEN_THREAD_COUNT=0
derive_split() {
    local -A core_to_siblings
    local order=()

    for d in /sys/devices/system/cpu/cpu[0-9]*; do
        local siblings
        siblings=$(<"$d/topology/thread_siblings_list")
        local key=${siblings%%,*}

        if [ -z "${core_to_siblings[$key]+set}" ]; then
            order+=("$key")
        fi
        core_to_siblings[$key]="$siblings"
    done

    local total=${#order[@]}
    local half=$((total / 2))

    local server=() loadgen=() index=0
    for key in $(printf '%s\n' "${order[@]}" | sort -n); do
        if [ "$index" -lt "$half" ]; then
            server+=("${core_to_siblings[$key]}")
        else
            loadgen+=("${core_to_siblings[$key]}")
        fi
        index=$((index + 1))
    done

    SERVER_CPUS=$(IFS=,; echo "${server[*]}")
    LOADGEN_CPUS=$(IFS=,; echo "${loadgen[*]}")

    # One load-gen thread per loadgen hardware thread (the arena runs 64 threads
    # on a 64-HT half). Expand ranges to count entries.
    local expanded
    expanded=$(echo "$LOADGEN_CPUS" | tr ',' '\n' | awk -F- '{ if (NF == 2) n += $2 - $1 + 1; else n += 1 } END { print n + 0 }')
    LOADGEN_THREAD_COUNT="$expanded"
}

# Saved pre-run state (empty = unreadable, skip restore). Only what quiesce
# touches is saved: governor, sysctls, lo MTU, and (under --freq) min/max freq.
SAVED_GOVERNOR=""
SAVED_MIN_FREQ=""
SAVED_MAX_FREQ=""
SAVED_LO_MTU=""
declare -A SAVED_SYSCTL=()
SYSCTL_KEYS="net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog net.ipv4.ip_local_port_range net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_tw_reuse net.core.rmem_max net.core.wmem_max"
RESTORED=0

save_state() {
    [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ] &&
        SAVED_GOVERNOR="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"

    [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq ] &&
        SAVED_MIN_FREQ="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq)"
    [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq ] &&
        SAVED_MAX_FREQ="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"

    [ -r /sys/class/net/lo/mtu ] && SAVED_LO_MTU="$(cat /sys/class/net/lo/mtu)"

    local key
    for key in $SYSCTL_KEYS; do
        SAVED_SYSCTL["$key"]="$(sysctl -n "$key" 2>/dev/null || true)"
    done
}

# Idempotent, best-effort restore (tolerates failures to ensure all knobs run).
restore_state() {
    [ "$RESTORED" -eq 1 ] && return 0
    RESTORED=1

    [ "${IS_ROOT:-0}" -ne 1 ] && return 0

    echo "[isol] restoring host state" >&2

    if [ -n "$SAVED_GOVERNOR" ]; then
        cpupower frequency-set -g "$SAVED_GOVERNOR" >/dev/null 2>&1 || true
    fi

    if [ -n "$FREQ_HZ" ] && [ -n "$SAVED_MIN_FREQ" ] && [ -n "$SAVED_MAX_FREQ" ]; then
        cpupower frequency-set -d "${SAVED_MIN_FREQ}" -u "${SAVED_MAX_FREQ}" >/dev/null 2>&1 || true
    fi

    if [ -n "$SAVED_LO_MTU" ]; then
        ip link set lo mtu "$SAVED_LO_MTU" 2>/dev/null || true
    fi

    local key
    for key in $SYSCTL_KEYS; do
        if [ -n "${SAVED_SYSCTL[$key]:-}" ]; then
            sysctl -w "$key=${SAVED_SYSCTL[$key]}" >/dev/null 2>&1 || true
        fi
    done
}

PINNER_PID=""
SAMPLER_PID=""
PROBE_RESULT=""
MEM_LOG=""
SMAPS_FILE=""
cleanup() {
    [ -n "$PINNER_PID" ] && kill "$PINNER_PID" 2>/dev/null || true
    [ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" 2>/dev/null || true

    rm -f "$BENCH_PATCHED" "$FW_PATCHED" "$PROFILES_PATCHED"

    if [ "$SOURCE" = "local" ]; then
        rm -f "$LOCAL_DOCKERFILE" "$LOCAL_BUILDSH"
        rm -rf "$VENDOR_DIR"
    fi

    cd "$ORIG_DIR" 2>/dev/null || true

    restore_state
}

trap cleanup EXIT
trap 'exit 130' INT TERM

# Exact system_tune equivalent (same knobs, same values, nothing extra), saved
# first and restored on exit. --freq adds an explicit fixed-frequency pin on
# top (a deviation from the arena, off by default). Rootless mode skips all of it.
quiesce() {
    if [ "${IS_ROOT:-0}" -ne 1 ]; then
        echo "[isol] not root, skipping host quiesce (governor/sysctl/mtu/etc.), pinning still applied" >&2
        return 0
    fi

    echo "[isol] quiescing host (system_tune equivalent)" >&2

    cpupower frequency-set -g performance >/dev/null 2>&1 || true

    # Optional fixed-frequency pin, only when the user asked for it.
    if [ -n "$FREQ_HZ" ]; then
        cpupower frequency-set -d "$FREQ_HZ" -u "$FREQ_HZ" >/dev/null 2>&1 || true
    fi

    # system_tune's socket limits, port churn headroom, QUIC UDP buffers, and
    # realistic Ethernet MTU on loopback, verbatim values.
    sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_max_syn_backlog=65535 >/dev/null 2>&1 || true
    sysctl -w net.core.netdev_max_backlog=65535 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.ip_local_port_range='1024 65535' >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_max_tw_buckets=131072 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1 || true
    sysctl -w net.core.rmem_max=7500000 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=7500000 >/dev/null 2>&1 || true
    ip link set lo mtu 1500 2>/dev/null || true

    # system_tune restarts the docker daemon for clean networking state, then
    # waits for it to come back. A podman shim has no daemon: the restart
    # no-ops and the wait passes on the first docker info.
    if systemctl restart docker 2>/dev/null; then
        local i
        for i in $(seq 1 15); do
            if docker info >/dev/null 2>&1; then
                sleep 2
                break
            fi
            sleep 1
        done
    fi

    sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
    sync
}

# Noise-floor gate: times a pinned compute kernel. Aborts if relative stddev > 1%.
probe_gate() {
    local probe_core=${SERVER_CPUS%%,*}
    probe_core=${probe_core%%-*}

    if ! command -v cc >/dev/null 2>&1; then
        echo "[isol] cc not found, skipping --probe noise-floor gate" >&2
        PROBE_RESULT="skipped (no cc)"
        return 0
    fi

    local probe_tmp src bin
    probe_tmp="$(mktemp -d)"
    src="$probe_tmp/spin.c"
    bin="$probe_tmp/spin"

    cat > "$src" <<'EOF'
#include <stdint.h>
int main(void) {
    volatile uint64_t acc = 0;
    for (uint64_t i = 0; i < 3000000000ULL; i++) acc += i * 2654435761ULL;
    return (int)acc;
}
EOF
    if ! cc -O2 -o "$bin" "$src" 2>/dev/null; then
        echo "[isol] probe build failed, skipping --probe noise-floor gate" >&2
        PROBE_RESULT="skipped (build failed)"
        rm -rf "$probe_tmp"
        return 0
    fi

    local runner=("$bin")
    command -v taskset >/dev/null 2>&1 && runner=(taskset -c "$probe_core" "$bin")

    local samples=() i start end
    for i in $(seq 20); do
        start=$(date +%s.%N)
        "${runner[@]}" >/dev/null 2>&1 || true
        end=$(date +%s.%N)

        samples+=("$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.6f", b - a }')")
    done

    rm -rf "$probe_tmp"

    local rel
    rel=$(printf '%s\n' "${samples[@]}" | awk '
        { sum += $1; sumsq += $1 * $1; n++ }
        END {
            if (n == 0) { print "ERR_NODATA"; exit }
            mean = sum / n
            if (mean <= 0) { print "ERR_ZEROMEAN"; exit }

            sd = sqrt(sumsq / n - mean * mean)
            printf "%.2f", 100 * sd / mean
        }')

    case "$rel" in
        ERR_*)
            echo "[isol] probe produced no usable timing ($rel), skipping gate" >&2
            PROBE_RESULT="skipped (no usable timing)"
            return 0 ;;
    esac

    echo "[isol] noise-floor relative stddev: ${rel}%" >&2

    if awk -v r="$rel" 'BEGIN { exit !(r > 1.0) }'; then
        PROBE_RESULT="${rel}% (ABORT, box not quiet >1%)"
        echo "[isol] box is not quiet (>1%), aborting before bench" >&2

        {
            echo "$START_BANNER"
            echo
            echo "# zix isolate full bench (ABORTED at probe)"
            echo "# probe_rel:   $PROBE_RESULT"
        } > "$RESULT_TXT" 2>/dev/null || true
        echo "[isol] aborted-probe record -> $RESULT_TXT" >&2

        exit 1
    fi

    PROBE_RESULT="${rel}% (PASS, <=1%)"
}

# Safety net behind the patched profile cpusets: watch for container creation
# and apply the server cpuset (idempotent when the profile already carries it).
start_server_pinner() {
    [ -z "$SERVER_CPUS" ] && return 0
    command -v docker >/dev/null 2>&1 || { echo "[isol] docker absent, server not pinned" >&2; return 0; }

    local name="httparena-bench-$FRAMEWORK"
    (
        local last=""
        while true; do
            local id
            id=$(docker ps -q --filter "name=$name" 2>/dev/null | head -1 || true)
            if [ -n "$id" ] && [ "$id" != "$last" ]; then
                docker update --cpuset-cpus="$SERVER_CPUS" "$id" >/dev/null 2>&1 || true
                last="$id"
            fi
            sleep 0.5
        done
    ) &
    PINNER_PID=$!
}

# Memory sampler: polls container cgroup (total, anon/sock/slab split) every 1s.
# Dumps smaps_rollup every 15s and full smaps at peak memory.
start_mem_sampler() {
    command -v docker >/dev/null 2>&1 || return 0

    local name="httparena-bench-$FRAMEWORK"
    MEM_LOG="$RESULT_DIR/isolate-full-mem-${RUN_TAG}-${RUN_STAMP}.txt"
    SMAPS_FILE="$RESULT_DIR/isolate-full-smaps-${RUN_TAG}-${RUN_STAMP}.txt"
    echo "[isol] memory samples -> $MEM_LOG" >&2
    (
        local tick=0 peak_cur=0
        while true; do
            local id ts both scope host_pid
            local cur=0 anon=0 file=0 sock=0 slab=0 kstack=0
            id=$(docker ps -q --no-trunc --filter "name=$name" 2>/dev/null | head -1 || true)
            if [ -n "$id" ]; then
                ts=$(date +%s)
                scope="/sys/fs/cgroup/system.slice/docker-$id.scope"

                both=$(docker exec "$id" sh -c 'cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.stat' 2>/dev/null ||
                       cat "$scope/memory.current" "$scope/memory.stat" 2>/dev/null || true)

                read -r cur anon file sock slab kstack < <(printf '%s\n' "$both" | awk '
                    NR == 1              { cur = $1 }
                    $1 == "anon"         { a = $2 }
                    $1 == "file"         { f = $2 }
                    $1 == "sock"         { s = $2 }
                    $1 == "slab"         { sl = $2 }
                    $1 == "kernel_stack" { k = $2 }
                    END { printf "%d %d %d %d %d %d\n", cur + 0, a + 0, f + 0, s + 0, sl + 0, k + 0 }') || true

                [ "$cur" != 0 ] && echo "$ts current=$cur anon=$anon file=$file sock=$sock slab=$slab kstack=$kstack" >> "$MEM_LOG"

                host_pid=$(docker inspect -f '{{.State.Pid}}' "$id" 2>/dev/null || true)

                if [ $(( tick % 15 )) -eq 0 ] && [ -n "$host_pid" ] && [ -r "/proc/$host_pid/smaps_rollup" ]; then
                    {
                        echo "# smaps_rollup pid=$host_pid @${ts}"
                        cat "/proc/$host_pid/smaps_rollup"
                        echo
                    } >> "$MEM_LOG"
                fi

                if [ -n "$cur" ] && [ "${cur:-0}" -gt "$peak_cur" ] && [ -n "$host_pid" ] && [ -r "/proc/$host_pid/smaps" ]; then
                    peak_cur=$cur
                    {
                        echo "# full smaps pid=$host_pid @${ts} current=$cur"
                        cat "/proc/$host_pid/smaps"
                    } > "$SMAPS_FILE" 2>/dev/null || true
                fi
            fi

            tick=$(( tick + 1 ))
            sleep 1
        done
    ) &
    SAMPLER_PID=$!
}

# Lifecycle.
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
START="$(date '+%Y-%m-%d %H:%M:%S:%3N')"
RUN_TAG="${FRAMEWORK}${PROFILE:+-$PROFILE}"
RESULT_TXT="$RESULT_DIR/isolate-full-results-${RUN_TAG}-${RUN_STAMP}.txt"

START_BANNER="Isolate-full: $FRAMEWORK bench start $START"
echo "[isol] $START_BANNER" >&2
echo "[isol] command: $INVOCATION" >&2

save_state
derive_split
echo "[isol] server=$SERVER_CPUS loadgen=$LOADGEN_CPUS threads=${LOAD_THREADS:-$LOADGEN_THREAD_COUNT}" >&2

if [ "$DO_QUIESCE" -eq 1 ]; then
    quiesce
fi

if [ "$DO_PROBE" -eq 1 ]; then
    probe_gate
fi

if [ "$DO_QUIESCE" -eq 1 ]; then
    start_server_pinner
fi

if [ "$DO_SAMPLE_MEM" -eq 1 ]; then
    start_mem_sampler
fi

cd "$REPO_DIR"

# Stage local zix source, mirroring benchmark-httparena-lite.sh --source local:
# rsync the checkout into gitignored vendor/zix, rewrite the Dockerfile vendor
# fetch to COPY, and drop a build.sh for the harness build hook.
if [ "$SOURCE" = "local" ]; then
    echo "[isol] staging local zix from $ZIX_DIR into $VENDOR_DIR" >&2

    rm -rf "$VENDOR_DIR"
    mkdir -p "$VENDOR_DIR"
    rsync -a --delete \
        --exclude '.git' \
        --exclude '.zig-cache' \
        --exclude 'zig-out' \
        --exclude 'rnd' \
        "$ZIX_DIR"/ "$VENDOR_DIR"/

    awk '
        function flush() {
            if (in_run) {
                if (buf ~ /vendor\/zix/) print "COPY vendor/zix /src/vendor/zix";
                else printf "%s", buf;
                buf = ""; in_run = 0;
            }
        }
        {
            if (!in_run && $0 ~ /^RUN /) { in_run = 1; buf = $0 "\n"; if ($0 !~ /\\$/) flush(); next }
            if (in_run) { buf = buf $0 "\n"; if ($0 !~ /\\$/) flush(); next }
            print
        }
        END { flush() }
    ' "$FW_DIR/Dockerfile" > "$LOCAL_DOCKERFILE"

    cat > "$LOCAL_BUILDSH" <<EOF
#!/usr/bin/env bash
# Generated by benchmark-httparena-isolate --source local. Removed on exit.
set -euo pipefail

DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"

docker build -t "httparena-$FRAMEWORK" -f "$LOCAL_DOCKERFILE" "\$DIR"
EOF
    chmod +x "$LOCAL_BUILDSH"
fi

# Patch gRPC readiness probe: use the docker ghz command if present, return
# cleanly to avoid falling through to an unset probe_url under set -u.
sed -E \
    -e 's/(            )_wait_grpc "\$endpoint" \&\& return 0/\1_wait_grpc "$endpoint"\n\1return/' \
    -e 's/if "\$GHZ" "\$flag"/if ${GHZ_CMD:-$GHZ} "$flag"/' \
    "$FW_SRC" > "$FW_PATCHED"

# Scale the profiles to this machine: the stock server cpuset (the arena's
# 0-31,64-95 whole-core half) becomes the local SMT-aware half. Connection
# counts, iteration counts, and endpoints stay stock: the test is identical,
# only the CPU sizing differs.
sed -e "s/0-31,64-95/$SERVER_CPUS/g" "$PROFILES_SRC" > "$PROFILES_PATCHED"

# Patch benchmark.sh: source the patched framework/profiles copies, and
# neutralize system_tune/system_restore (quiesce above replicates them with
# save/restore, and no docker daemon restart happens mid-run).
sed -E \
    -e "s|^source \"\\\$SOURCE_DIR/framework\.sh\"|source \"$FW_PATCHED\"|" \
    -e "s|^source \"\\\$SOURCE_DIR/profiles\.sh\"|source \"$PROFILES_PATCHED\"|" \
    -e 's/^([[:space:]]*)system_tune[[:space:]]*$/\1true  # system_tune replaced by isolate quiesce/' \
    -e "s/trap 'cleanup_all; system_restore' EXIT/trap 'cleanup_all' EXIT/" \
    "$BENCH_SRC" > "$BENCH_PATCHED"
chmod +x "$BENCH_PATCHED"

# Machine-scaled sizing (common.sh honors pre-set env): load generators on
# their half, one thread per loadgen hardware thread, dockerized load gens by
# default (pre-set LOADGEN_DOCKER=false for native tools).
export GCANNON_CPUS="$LOADGEN_CPUS"
export THREADS="${LOAD_THREADS:-$LOADGEN_THREAD_COUNT}"
export H2THREADS="$THREADS"
export H3THREADS="$THREADS"
export LOADGEN_DOCKER="${LOADGEN_DOCKER:-true}"
export GCANNON_MODE="${GCANNON_MODE:-docker}"

# Write self-describing header to result file.
{
    echo "$START_BANNER"
    echo
    echo "# zix isolate full bench (stock benchmark.sh matrix, machine-scaled CPUs)"
    echo "# command:      $INVOCATION"
    echo "# stamp:        $RUN_STAMP"
    echo "# framework:    $FRAMEWORK"
    echo "# profile:      ${PROFILE:-(all)}"
    echo "# source:       $SOURCE"
    echo "# server_cpus:  $SERVER_CPUS"
    echo "# loadgen_cpus: $LOADGEN_CPUS"
    echo "# threads:      $THREADS"
    echo "# quiesce:      $DO_QUIESCE (system_tune equivalent: governor/sysctls/lo-mtu-1500/docker-restart/drop-caches)"
    echo "# freq_pin:     ${FREQ_HZ:-(none, arena parity)}"
    echo "# probe_gate:   $DO_PROBE${PROBE_RESULT:+  ($PROBE_RESULT)}"
    echo "# sample_mem:   $DO_SAMPLE_MEM${MEM_LOG:+  -> $(basename "$MEM_LOG")}"
    echo "# settle_s:     $SETTLE"
    echo
} > "$RESULT_TXT"

RUN_ARGS=("$FRAMEWORK")
[ -n "$PROFILE" ] && RUN_ARGS+=("$PROFILE")

echo "[isol] running full bench, result -> $RESULT_TXT" >&2
bench_rc=0
"$BENCH_PATCHED" "${RUN_ARGS[@]}" 2>&1 | tee -a "$RESULT_TXT" || bench_rc=$?
[ "$bench_rc" -eq 0 ] || echo "[isol] note: bench exited $bench_rc, continuing to summary and restore" >&2

echo "[isol] settling ${SETTLE}s before restore" >&2
sleep "$SETTLE"

# Summarize memory samples (peak + steady-state median) into the main log.
if [ "$DO_SAMPLE_MEM" -eq 1 ] && [ -n "$MEM_LOG" ] && [ -s "$MEM_LOG" ]; then
    {
        echo
        echo "# memory (from $(basename "$MEM_LOG")):"

        awk -F'current=' 'NF > 1 { print $2 + 0 }' "$MEM_LOG" | sort -n | awk '
            { a[n++] = $1 }
            END {
                if (n == 0) { print "#   no samples"; exit }
                peak = a[n - 1]
                median = (n % 2) ? a[int(n / 2)] : (a[n / 2 - 1] + a[n / 2]) / 2
                printf "#   total: peak=%.1fMiB  steady_median=%.1fMiB  samples=%d\n", peak / 1048576, median / 1048576, n
            }'

        for field in anon sock slab; do
            grep -ho "$field=[0-9]*" "$MEM_LOG" 2>/dev/null | cut -d= -f2 | sort -n | awk -v f="$field" '
                { a[n++] = $1 }
                END {
                    if (n == 0) exit
                    median = (n % 2) ? a[int(n / 2)] : (a[n / 2 - 1] + a[n / 2]) / 2
                    printf "#   %-5s median=%.1fMiB\n", f, median / 1048576
                }' || true
        done

        if [ -n "$SMAPS_FILE" ] && [ -s "$SMAPS_FILE" ]; then
            echo "#   --- top regions at peak (from $(basename "$SMAPS_FILE")) ---"
            awk '
                /^[0-9a-f]+-[0-9a-f]+ / {
                    label = $6 == "" ? "[anon]" : $6
                    for (i = 7; i <= NF; i++) label = label " " $i
                }
                /^Rss:/ { rss[label] += $2 }
                END { for (l in rss) printf "%d\t%s\n", rss[l], l }
            ' "$SMAPS_FILE" | sort -rn | head -8 | awk -F'\t' '
                { printf "#   %8.1fMiB  %s\n", $1 / 1024, $2 }' || true
        fi
    } >> "$RESULT_TXT"
fi

echo "[isol] result saved: $RESULT_TXT" >&2

# Restore runs via EXIT trap.
