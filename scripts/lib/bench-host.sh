#!/usr/bin/env bash
# bench-host.sh - Host preparation shared by every local benchmark runner.
#
# What lives here is the part that has nothing to do with WHAT is being measured:
# splitting the machine between server and load generator, tuning the host the
# way the arena's system_tune does, and putting every knob back afterwards.
#
# Sourced by:
#   scripts/httparena-benchmark-isolate.sh   (arena containers)
#   scripts/localbench-run.sh                (native localbench/ entries)
#
# Both runners measure on the same box, so a number from one is only readable
# against the other when the host was prepared identically. That is the whole
# reason this is one file rather than two copies.
#
# Expects from the caller:
#   IS_ROOT   0 or 1, whether the host knobs can be written at all
#   FREQ_HZ   empty, or a fixed frequency to pin (a deviation from the arena)
#   LOG_TAG   short prefix for progress lines, e.g. "isol" or "run"

IS_ROOT="${IS_ROOT:-0}"
FREQ_HZ="${FREQ_HZ:-}"
LOG_TAG="${LOG_TAG:-bench}"

# --------------------------------------------------------- #
# CPU split

# One entry per physical core (the core's full sibling set) on the server half,
# so a layout that carves N physical cores out of that half can be derived on
# any topology.
LOADGEN_THREAD_COUNT=0
SERVER_PAIRS=()

# derive_split
# SMT-aware half split: SMT siblings stay together on whichever side they land,
# and the loadgen hardware threads are counted for the derived thread count.
#
# Sets: SERVER_PAIRS, SERVER_CPUS, LOADGEN_CPUS, LOADGEN_THREAD_COUNT
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

    SERVER_PAIRS=("${server[@]}")
    SERVER_CPUS=$(IFS=,; echo "${server[*]}")
    LOADGEN_CPUS=$(IFS=,; echo "${loadgen[*]}")

    # One load-gen thread per loadgen hardware thread (the arena runs 64 threads
    # on a 64-HT half). Expand ranges to count entries.
    local expanded
    expanded=$(echo "$LOADGEN_CPUS" | tr ',' '\n' | awk -F- '{ if (NF == 2) n += $2 - $1 + 1; else n += 1 } END { print n + 0 }')
    LOADGEN_THREAD_COUNT="$expanded"
}

# --------------------------------------------------------- #
# Host state

# Saved pre-run state (empty = unreadable, skip restore). Only what quiesce
# touches is saved: governor, sysctls, lo MTU, and (under FREQ_HZ) min/max freq.
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

    echo "[$LOG_TAG] restoring host state" >&2

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

# Exact system_tune equivalent (same knobs, same values, nothing extra), saved
# first and restored on exit. FREQ_HZ adds an explicit fixed-frequency pin on
# top (a deviation from the arena, off by default). Rootless skips all of it.
quiesce() {
    if [ "${IS_ROOT:-0}" -ne 1 ]; then
        echo "[$LOG_TAG] not root, skipping host quiesce (governor/sysctl/mtu/etc.), pinning still applied" >&2
        return 0
    fi

    echo "[$LOG_TAG] quiescing host (system_tune equivalent)" >&2

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

# --------------------------------------------------------- #
# Noise floor

# Set by probe_gate: the measured relative stddev, or why the gate was skipped.
PROBE_RESULT=""

# probe_gate
# Times a pinned compute kernel 20 times on the server half and reports how much
# the timings varied. A box that cannot repeat a fixed amount of arithmetic
# within 1% cannot be trusted to repeat a benchmark either, so the caller is
# expected to refuse to measure when this fails.
#
# Note:
# - Skipped, not failed, when no C compiler is available: an absent toolchain
#   says nothing about whether the machine is quiet.
#
# Return:
# - 0 when the box is quiet (or the gate could not run)
# - 1 when the relative stddev is above 1%
probe_gate() {
    local probe_core=${SERVER_CPUS%%,*}
    probe_core=${probe_core%%-*}

    if ! command -v cc >/dev/null 2>&1; then
        echo "[$LOG_TAG] cc not found, skipping the noise-floor gate" >&2
        PROBE_RESULT="skipped (no cc)"

        return 0
    fi

    local probe_tmp source_file binary
    probe_tmp="$(mktemp -d)"
    source_file="$probe_tmp/spin.c"
    binary="$probe_tmp/spin"

    cat > "$source_file" <<'EOF'
#include <stdint.h>
int main(void) {
    volatile uint64_t acc = 0;
    for (uint64_t i = 0; i < 3000000000ULL; i++) acc += i * 2654435761ULL;
    return (int)acc;
}
EOF

    if ! cc -O2 -o "$binary" "$source_file" 2>/dev/null; then
        echo "[$LOG_TAG] probe build failed, skipping the noise-floor gate" >&2
        PROBE_RESULT="skipped (build failed)"
        rm -rf "$probe_tmp"

        return 0
    fi

    local runner=("$binary")
    command -v taskset >/dev/null 2>&1 && runner=(taskset -c "$probe_core" "$binary")

    local samples=() index start end
    for index in $(seq 20); do
        start=$(date +%s.%N)
        "${runner[@]}" >/dev/null 2>&1 || true
        end=$(date +%s.%N)

        samples+=("$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.6f", b - a }')")
    done

    rm -rf "$probe_tmp"

    local relative
    relative=$(printf '%s\n' "${samples[@]}" | awk '
        { sum += $1; sumsq += $1 * $1; n++ }
        END {
            if (n == 0) { print "ERR_NODATA"; exit }

            mean = sum / n
            if (mean <= 0) { print "ERR_ZEROMEAN"; exit }

            sd = sqrt(sumsq / n - mean * mean)
            printf "%.2f", 100 * sd / mean
        }')

    case "$relative" in
        ERR_*)
            echo "[$LOG_TAG] probe produced no usable timing ($relative), skipping the gate" >&2
            PROBE_RESULT="skipped (no usable timing)"

            return 0 ;;
    esac

    echo "[$LOG_TAG] noise-floor relative stddev: ${relative}%" >&2

    if awk -v r="$relative" 'BEGIN { exit !(r > 1.0) }'; then
        PROBE_RESULT="${relative}% (ABORT, box not quiet >1%)"

        return 1
    fi

    PROBE_RESULT="${relative}% (PASS, <=1%)"

    return 0
}
