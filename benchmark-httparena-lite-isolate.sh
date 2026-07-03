#!/usr/bin/env bash
# benchmark-httparena-lite-isolate - Low-noise wrapper for benchmark-httparena-lite.sh.
#
# Runs the lite bench in a quiesced, pinned environment to reduce jitter, then
# restores all global knobs. The tracked script is unmodified.
# See rnd/isolate_benchmark.md for methodology.
#
# Lifecycle (trap-driven, runs on EXIT/Ctrl-C):
#   save    -> snapshot global knobs
#   quiesce -> perf governor, boost off, fixed freq, shallow C-states, THP never,
#              stop irqbalance, lo mtu 65536, perf_event_paranoid -1
#   pin     -> SMT-aware split: GCANNON_CPUS=LOADGEN half, docker update for SERVER half
#   bench   -> call benchmark-httparena-lite.sh with passthrough args
#   settle  -> wait --settle seconds (default 5)
#   restore -> revert all saved values. Box ends exactly as started.
#
# Isolate-specific flags (others pass through to benchmark-httparena-lite.sh):
#   --settle SECS   Wait before restore (default: 5).
#   --freq HZ       Fixed freq to pin (default: cpu0 base or max).
#   --probe         Run spin.c noise-floor gate; abort if stddev > 1%.
#   --sample-mem    Poll container cgroup (total, anon/sock/slab, smaps) during bench.
#   --no-quiesce    Skip quiesce/pin (measure noisy baseline).
#   --out-dir DIR   Result directory (default: logs/benchmark).
#
# Passthrough args: <framework> (required), [httparena-dir], --load-threads N,
# --source MODE, --zix-dir DIR. If --load-threads is omitted, defaults to half
# the logical CPUs (matching loadgen half).
#
# Usage (re-execs under sudo if needed):
#   ./benchmark-httparena-lite-isolate zix ../HttpArena
#   ./benchmark-httparena-lite-isolate zix ../HttpArena --probe --sample-mem
#   ./benchmark-httparena-lite-isolate zix ../HttpArena --source local --load-threads 12
#   ./benchmark-httparena-lite-isolate zix ../HttpArena --no-quiesce
#
# Notes:
# - Requires root for sysfs/sysctl/systemd (re-execs via sudo). Rootless skips
#   host quiesce but still applies pinning and memory sampling.
# - isolcpus/nohz_full/rcu_nocbs are boot-time preconditions (not set here).

set -euo pipefail

# Root check: re-exec under sudo if ISOLATE_SUDO=true. Otherwise, rootless mode
# skips host-wide quiesce but keeps pinning and memory sampling.
IS_ROOT=0
[ "${EUID:-$(id -u)}" -eq 0 ] && IS_ROOT=1
if [ "$IS_ROOT" -ne 1 ] && [ "${ISOLATE_SUDO:-false}" = "true" ]; then
    exec sudo -E -- "$0" "$@"
fi

# Record full invocation for self-documenting result files (copy-paste safe).
INVOCATION="$(printf '%q ' "$0" "$@")"
INVOCATION="${INVOCATION% }"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LITE="$SELF_DIR/benchmark-httparena-lite.sh"
if [ ! -x "$LITE" ]; then
    echo "error: $LITE not found or not executable (this script wraps it)" >&2
    exit 1
fi

# Default result directory (overridable via --out-dir).
DEFAULT_RESULT_DIR="$SELF_DIR/logs/benchmark"

# Parse isolate flags; collect rest as passthrough for benchmark-httparena-lite.sh.
SETTLE=5
FREQ_HZ=
DO_PROBE=0
DO_SAMPLE_MEM=0
DO_QUIESCE=1
OUT_DIR=
PASSTHROUGH=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --settle)     [ "$#" -ge 2 ] || { echo "error: --settle needs a value" >&2; exit 1; }; SETTLE="$2"; shift 2 ;;
        --settle=*)   SETTLE="${1#*=}"; shift ;;
        --freq)       [ "$#" -ge 2 ] || { echo "error: --freq needs a value (Hz)" >&2; exit 1; }; FREQ_HZ="$2"; shift 2 ;;
        --freq=*)     FREQ_HZ="${1#*=}"; shift ;;
        --probe)      DO_PROBE=1; shift ;;
        --sample-mem) DO_SAMPLE_MEM=1; shift ;;
        --no-quiesce) DO_QUIESCE=0; shift ;;
        --out-dir)    [ "$#" -ge 2 ] || { echo "error: --out-dir needs a value" >&2; exit 1; }; OUT_DIR="$2"; shift 2 ;;
        --out-dir=*)  OUT_DIR="${1#*=}"; shift ;;
        *)            PASSTHROUGH+=("$1"); shift ;;
    esac
done

# Resolve result directory.
RESULT_DIR="${OUT_DIR:-$DEFAULT_RESULT_DIR}"
mkdir -p "$RESULT_DIR"
if [ "${#PASSTHROUGH[@]}" -eq 0 ]; then
    echo "usage: $(basename "$0") <framework> [httparena-dir] [isolate + passthrough flags]" >&2
    echo "       see the header comment for the full flag list" >&2
    exit 1
fi

# Extract <framework> from passthrough args (skip known flag values).
FRAMEWORK=""
skip_next=0
for arg in "${PASSTHROUGH[@]}"; do
    if [ "$skip_next" -eq 1 ]; then
        skip_next=0
        continue
    fi
    case "$arg" in
        --load-threads|--source|--zix-dir) skip_next=1; continue ;;
        --*) continue ;;
        *) FRAMEWORK="$arg"; break ;;
    esac
done

# Default --load-threads to half logical CPUs if not provided.
has_load_threads=0
for arg in "${PASSTHROUGH[@]}"; do
    case "$arg" in
        --load-threads|--load-threads=*) has_load_threads=1; break ;;
    esac
done
if [ "$has_load_threads" -eq 0 ]; then
    avail_cpus=$(nproc)
    default_load_threads=$(( avail_cpus / 2 ))
    [ "$default_load_threads" -ge 1 ] || default_load_threads=1

    PASSTHROUGH+=(--load-threads "$default_load_threads")
    echo "[isolate] --load-threads not set, defaulting to $default_load_threads (half of $avail_cpus logical CPUs)" >&2
fi

# SMT-aware half-split: keeps SMT pairs together on server or loadgen side.
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
}

# Saved pre-run state (empty = unreadable, skip restore).
SAVED_GOVERNOR=""
SAVED_BOOST=""
SAVED_MIN_FREQ=""
SAVED_MAX_FREQ=""
SAVED_THP=""
SAVED_IRQBALANCE=""
SAVED_LO_MTU=""
SAVED_PARANOID=""
RESTORED=0

save_state() {
    [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ] &&
        SAVED_GOVERNOR="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"

    [ -r /sys/devices/system/cpu/cpufreq/boost ] &&
        SAVED_BOOST="$(cat /sys/devices/system/cpu/cpufreq/boost)"

    [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq ] &&
        SAVED_MIN_FREQ="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq)"
    [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq ] &&
        SAVED_MAX_FREQ="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"

    if [ -r /sys/kernel/mm/transparent_hugepage/enabled ]; then
        SAVED_THP="$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled)"
    fi

    if systemctl is-active --quiet irqbalance 2>/dev/null; then
        SAVED_IRQBALANCE=active
    else
        SAVED_IRQBALANCE=inactive
    fi

    [ -r /sys/class/net/lo/mtu ] && SAVED_LO_MTU="$(cat /sys/class/net/lo/mtu)"

    SAVED_PARANOID="$(sysctl -n kernel.perf_event_paranoid 2>/dev/null || true)"
}

# Idempotent, best-effort restore (tolerates failures to ensure all knobs run).
restore_state() {
    [ "$RESTORED" -eq 1 ] && return 0
    RESTORED=1

    [ "${IS_ROOT:-0}" -ne 1 ] && return 0

    echo "[isolate] restoring host state" >&2

    if [ -n "$SAVED_GOVERNOR" ]; then
        cpupower frequency-set -g "$SAVED_GOVERNOR" >/dev/null 2>&1 || true
    fi

    if [ -n "$SAVED_MIN_FREQ" ] && [ -n "$SAVED_MAX_FREQ" ]; then
        cpupower frequency-set -d "${SAVED_MIN_FREQ}" -u "${SAVED_MAX_FREQ}" >/dev/null 2>&1 || true
    fi

    if [ -n "$SAVED_BOOST" ] && [ -w /sys/devices/system/cpu/cpufreq/boost ]; then
        echo "$SAVED_BOOST" > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    fi

    cpupower idle-set -E >/dev/null 2>&1 || true

    if [ -n "$SAVED_THP" ] && [ -w /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo "$SAVED_THP" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    fi

    if [ "$SAVED_IRQBALANCE" = active ]; then
        systemctl start irqbalance >/dev/null 2>&1 || true
    fi

    if [ -n "$SAVED_LO_MTU" ]; then
        ip link set lo mtu "$SAVED_LO_MTU" 2>/dev/null || true
    fi

    if [ -n "$SAVED_PARANOID" ]; then
        sysctl -w "kernel.perf_event_paranoid=$SAVED_PARANOID" >/dev/null 2>&1 || true
    fi
}

# Cleanup: stop background helpers, then restore state.
PINNER_PID=""
SAMPLER_PID=""

PROBE_RESULT=""
MEM_LOG=""
SMAPS_FILE=""
cleanup() {
    [ -n "$PINNER_PID" ] && kill "$PINNER_PID" 2>/dev/null || true
    [ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" 2>/dev/null || true

    restore_state
}

# Trap cleanup on EXIT; route INT/TERM through exit to ensure restore on Ctrl-C.
trap cleanup EXIT
trap 'exit 130' INT TERM

quiesce() {
    # Skip host-wide writes if not root (pinning still applies).
    if [ "${IS_ROOT:-0}" -ne 1 ]; then
        echo "[isolate] not root, skipping host quiesce (governor/sysctl/mtu/etc.), pinning still applied" >&2
        return 0
    fi

    echo "[isolate] quiescing host" >&2

    cpupower frequency-set -g performance >/dev/null 2>&1 || true

    if [ -w /sys/devices/system/cpu/cpufreq/boost ]; then
        echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    fi

    # Pin fixed frequency (prefer base clock, fallback to max, allow override).
    local pin="$FREQ_HZ"
    if [ -z "$pin" ]; then
        if [ -r /sys/devices/system/cpu/cpu0/cpufreq/base_frequency ]; then
            pin="$(cat /sys/devices/system/cpu/cpu0/cpufreq/base_frequency)"
        elif [ -n "$SAVED_MAX_FREQ" ]; then
            pin="$SAVED_MAX_FREQ"
        fi
    fi
    if [ -n "$pin" ]; then
        cpupower frequency-set -d "$pin" -u "$pin" >/dev/null 2>&1 || true
    fi

    cpupower idle-set -D 0 >/dev/null 2>&1 || true

    if [ -w /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    fi

    systemctl stop irqbalance >/dev/null 2>&1 || true

    ip link set lo mtu 65536 2>/dev/null || true

    sysctl -w kernel.perf_event_paranoid=-1 >/dev/null 2>&1 || true
}

# Noise-floor gate: times a pinned compute kernel. Aborts if relative stddev > 1%.
# Skips gracefully if tools (cc, taskset) are missing.
probe_gate() {
    local probe_core=${SERVER_CPUS%%,*}

    if ! command -v cc >/dev/null 2>&1; then
        echo "[isolate] cc not found, skipping --probe noise-floor gate" >&2
        PROBE_RESULT="skipped (no cc)"
        return 0
    fi

    # Private temp dir for probe build (avoids predictable /tmp paths).
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
        echo "[isolate] probe build failed, skipping --probe noise-floor gate" >&2
        PROBE_RESULT="skipped (build failed)"
        rm -rf "$probe_tmp"
        return 0
    fi

    # Prefer taskset to pin probe core; fallback to bare run.
    local runner=("$bin")
    command -v taskset >/dev/null 2>&1 && runner=(taskset -c "$probe_core" "$bin")

    local samples=() i start end
    for i in $(seq 20); do
        start=$(date +%s.%N)
        "${runner[@]}" >/dev/null 2>&1 || true
        end=$(date +%s.%N)

        samples+=("$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.6f", b - a }')")
    done

    # Cleanup probe binary.
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
            echo "[isolate] probe produced no usable timing ($rel), skipping gate" >&2
            PROBE_RESULT="skipped (no usable timing)"
            return 0 ;;
    esac

    echo "[isolate] noise-floor relative stddev: ${rel}%" >&2

    # Abort if stddev > 1.0%. (awk exits 0 when > 1.0 to trigger the if-branch).
    if awk -v r="$rel" 'BEGIN { exit !(r > 1.0) }'; then
        PROBE_RESULT="${rel}% (ABORT, box not quiet >1%)"
        echo "[isolate] box is not quiet (>1%), aborting before bench" >&2

        # Record aborted probe run.
        {
            echo "$START_BANNER"
            echo
            echo "# zix isolate bench (ABORTED at probe)"
            echo "# probe_rel:   $PROBE_RESULT"
        } > "$RESULT_TXT" 2>/dev/null || true
        echo "[isolate] aborted-probe record -> $RESULT_TXT" >&2

        exit 1
    fi

    PROBE_RESULT="${rel}% (PASS, <=1%)"
}

# Pin framework container to server CPUs. Watches for container creation and
# applies cpuset, as lite profiles leave cpu_limit empty.
start_server_pinner() {
    [ -z "$SERVER_CPUS" ] && return 0
    command -v docker >/dev/null 2>&1 || { echo "[isolate] docker absent, server not pinned" >&2; return 0; }

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
# Dumps smaps_rollup every 15s and full smaps at peak memory. Uses cgroup stats
# over `ss` for accurate per-container socket totals.
start_mem_sampler() {
    command -v docker >/dev/null 2>&1 || return 0

    local name="httparena-bench-$FRAMEWORK"
    MEM_LOG="$RESULT_DIR/isolate-mem-${FRAMEWORK}-${RUN_STAMP}.txt"
    SMAPS_FILE="$RESULT_DIR/isolate-smaps-${FRAMEWORK}-${RUN_STAMP}.txt"
    echo "[isolate] memory samples -> $MEM_LOG" >&2
    (
        local tick=0 peak_cur=0
        while true; do
            local id ts both scope host_pid
            local cur=0 anon=0 file=0 sock=0 slab=0 kstack=0
            # Full ID for systemd cgroup scope path (docker-<full64>.scope).
            id=$(docker ps -q --no-trunc --filter "name=$name" 2>/dev/null | head -1 || true)
            if [ -n "$id" ]; then
                ts=$(date +%s)
                scope="/sys/fs/cgroup/system.slice/docker-$id.scope"

                # Read memory.current and memory.stat atomically to prevent skew.
                both=$(docker exec "$id" sh -c 'cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.stat' 2>/dev/null ||
                       cat "$scope/memory.current" "$scope/memory.stat" 2>/dev/null || true)

                # `|| true` prevents set -e from killing sampler on missing trailing newline.
                read -r cur anon file sock slab kstack < <(printf '%s\n' "$both" | awk '
                    NR == 1              { cur = $1 }
                    $1 == "anon"         { a = $2 }
                    $1 == "file"         { f = $2 }
                    $1 == "sock"         { s = $2 }
                    $1 == "slab"         { sl = $2 }
                    $1 == "kernel_stack" { k = $2 }
                    END { printf "%d %d %d %d %d %d\n", cur + 0, a + 0, f + 0, s + 0, sl + 0, k + 0 }') || true

                [ "$cur" != 0 ] && echo "$ts current=$cur anon=$anon file=$file sock=$sock slab=$slab kstack=$kstack" >> "$MEM_LOG"

                # Server host PID for smaps access.
                host_pid=$(docker inspect -f '{{.State.Pid}}' "$id" 2>/dev/null || true)

                # Periodic smaps_rollup.
                if [ $(( tick % 15 )) -eq 0 ] && [ -n "$host_pid" ] && [ -r "/proc/$host_pid/smaps_rollup" ]; then
                    {
                        echo "# smaps_rollup pid=$host_pid @${ts}"
                        cat "/proc/$host_pid/smaps_rollup"
                        echo
                    } >> "$MEM_LOG"
                fi

                # Full smaps at peak memory (overwritten on new peaks).
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
RESULT_TXT="$RESULT_DIR/isolate-${FRAMEWORK}-${RUN_STAMP}.txt"

# Start banner for terminal and result file.
START_BANNER="Isolate: $FRAMEWORK bench start $START"
echo "[isolate] $START_BANNER" >&2
echo "[isolate] command: $INVOCATION" >&2

save_state
derive_split
echo "[isolate] server=$SERVER_CPUS loadgen=$LOADGEN_CPUS" >&2

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

# Pin load generator to its half via GCANNON_CPUS (honored by benchmark-lite.sh).
export GCANNON_CPUS="$LOADGEN_CPUS"

# Write self-describing header to result file.
{
    echo "$START_BANNER"
    echo
    echo "# zix isolate bench"
    echo "# command:     $INVOCATION"
    echo "# stamp:        $RUN_STAMP"
    echo "# framework:    $FRAMEWORK"
    echo "# args:         ${PASSTHROUGH[*]} (effective, --load-threads injected if absent)"
    echo "# server_cpus:  $SERVER_CPUS"
    echo "# loadgen_cpus: $LOADGEN_CPUS"
    echo "# quiesce:      $DO_QUIESCE (governor/boost/freq/cstate/thp/irqbalance/lo-mtu/paranoid)"
    echo "# probe_gate:   $DO_PROBE${PROBE_RESULT:+  ($PROBE_RESULT)}"
    echo "# sample_mem:   $DO_SAMPLE_MEM${MEM_LOG:+  -> $(basename "$MEM_LOG")}"
    echo "# settle_s:     $SETTLE"
    echo
} > "$RESULT_TXT"

echo "[isolate] running bench, result -> $RESULT_TXT" >&2
# Tolerate non-zero bench exit (e.g., skipped tests) to ensure settle and summary run.
bench_rc=0
"$LITE" "${PASSTHROUGH[@]}" 2>&1 | tee -a "$RESULT_TXT" || bench_rc=$?
[ "$bench_rc" -eq 0 ] || echo "[isolate] note: bench exited $bench_rc, continuing to summary and restore" >&2

echo "[isolate] settling ${SETTLE}s before restore" >&2
sleep "$SETTLE"

# Summarize memory samples (peak + steady-state median) into main log.
if [ "$DO_SAMPLE_MEM" -eq 1 ] && [ -n "$MEM_LOG" ] && [ -s "$MEM_LOG" ]; then
    {
        echo
        echo "# memory (from $(basename "$MEM_LOG")):"

        # Total cgroup memory stats.
        awk -F'current=' 'NF > 1 { print $2 + 0 }' "$MEM_LOG" | sort -n | awk '
            { a[n++] = $1 }
            END {
                if (n == 0) { print "#   no samples"; exit }
                peak = a[n - 1]
                median = (n % 2) ? a[int(n / 2)] : (a[n / 2 - 1] + a[n / 2]) / 2
                printf "#   total: peak=%.1fMiB  steady_median=%.1fMiB  samples=%d\n", peak / 1048576, median / 1048576, n
            }'

        # Split medians (anon, sock, slab).
        for field in anon sock slab; do
            grep -ho "$field=[0-9]*" "$MEM_LOG" 2>/dev/null | cut -d= -f2 | sort -n | awk -v f="$field" '
                { a[n++] = $1 }
                END {
                    if (n == 0) exit
                    median = (n % 2) ? a[int(n / 2)] : (a[n / 2 - 1] + a[n / 2]) / 2
                    printf "#   %-5s median=%.1fMiB\n", f, median / 1048576
                }' || true
        done

        # Top process-memory regions at peak.
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

echo "[isolate] result saved: $RESULT_TXT" >&2

# Restore runs via EXIT trap.
