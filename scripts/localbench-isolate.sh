#!/usr/bin/env bash
# localbench-isolate.sh - Quiesced, pinned wrapper around localbench-run.sh.
#
# A bare localbench-run.sh measures whatever the machine happens to be doing. This wrapper
# puts the run in the same conditions every time: the server on one half of the cores, the
# load generator on the other, and the host knobs that move a result held still for the
# duration. Two sides never share a core, so a fast server cannot starve its own load.
#
# Everything touched is saved first and restored on exit, including after Ctrl-C. Running
# without root skips the host knobs (they need privilege) and still applies the pinning,
# which is the part that matters most on a shared desktop.
#
# What is held still when running as root:
#   cpu governor performance, socket and UDP sysctls, loopback MTU 1500, page cache drop
#
# Lifecycle (trap-driven):
#   save -> quiesce -> pin -> run -> settle -> restore
#
# Args (flags anywhere, positionals are <entry> [profile] [httparena-dir]):
#   <entry>           Required. An entry directory name under localbench/.
#   [profile]         Optional. Run only this profile.
#   [httparena-dir]   Optional. HttpArena checkout (default: sibling HttpArena next to this one).
#   --out-dir DIR     Optional. Result directory (default: logs/localbench).
#   --settle SECS     Optional. Wait before restore (default: 5).
#   --no-quiesce      Optional. Skip the host knobs, keep the pinning (measure noisy baseline).
#
# The three above are this wrapper's own. Every other flag is forwarded to
# localbench-run.sh verbatim, and none of them turn on by default: --probe, --sample-mem,
# --save, --summarize, --runs N, --duration SPEC, --load-threads N, --freq HZ,
# --keep-sidecars. An unknown flag is reported by the run script, which owns the list.
#
# Usage:
#   ./scripts/localbench-isolate.sh http1-uring
#   sudo -E ./scripts/localbench-isolate.sh http1-uring json --runs 5 --probe
#   ./scripts/localbench-isolate.sh http1-uring --sample-mem --summarize
#   ./scripts/localbench-isolate.sh http1-uring --no-quiesce

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SELF_DIR/.." && pwd)"

IS_ROOT=0
[ "${EUID:-$(id -u)}" -eq 0 ] && IS_ROOT=1

# Recorded before the parse loop shifts it away, so the result header carries a
# copy-paste-safe command line.
INVOCATION="$(printf '%q ' "$0" "$@")"
INVOCATION="${INVOCATION% }"

SAVE_DIR=""
QUIESCED=0

info() { echo "[isol] $*"; }
fail() { echo "[isol] error: $*" >&2; exit 1; }

SETTLE=5
DO_QUIESCE=1
OUT_DIR=""
PASSTHROUGH=()
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --settle)
            [ "$#" -ge 2 ] || fail "--settle needs a value"
            SETTLE="$2"; shift 2 ;;
        --settle=*) SETTLE="${1#*=}"; shift ;;
        --no-quiesce) DO_QUIESCE=0; shift ;;
        --out-dir)
            [ "$#" -ge 2 ] || fail "--out-dir needs a value"
            OUT_DIR="$2"; shift 2 ;;
        --out-dir=*) OUT_DIR="${1#*=}"; shift ;;
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
        # The run script's value-taking flags are named here so the value travels with
        # the flag. Left to the catch-all below, the flag would be forwarded alone and
        # its value read as a positional, which would land as the profile name.
        --runs|--duration|--load-threads|--freq)
            [ "$#" -ge 2 ] || fail "$1 needs a value"
            PASSTHROUGH+=("$1" "$2"); shift 2 ;;
        # Everything else belongs to localbench-run.sh, forwarded exactly as typed and
        # never added on its own. That covers --probe, --sample-mem, --save, --summarize,
        # --keep-sidecars, and any --flag=value form.
        -*) PASSTHROUGH+=("$1"); shift ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

[ "${#POSITIONAL[@]}" -gt 0 ] || {
    echo "usage: $(basename "$0") <entry> [profile] [httparena-dir] [--out-dir DIR]" >&2
    exit 1
}

OUT_DIR="${OUT_DIR:-$ROOT_DIR/logs/localbench}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# restore
# Puts every saved knob back. Runs on all exit paths, so an interrupted run does not leave
# the machine pinned to performance with a 1500 byte loopback.
restore() {
    local status=$?

    if [ "$QUIESCED" -eq 1 ] && [ "$IS_ROOT" -eq 1 ]; then
        info "settling ${SETTLE}s before restore"
        sleep "$SETTLE"

        if [ -s "$SAVE_DIR/governor" ]; then
            local governor
            governor="$(cat "$SAVE_DIR/governor")"
            local policy
            for policy in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                [ -w "$policy" ] && echo "$governor" >"$policy" 2>/dev/null || true
            done
        fi

        if [ -s "$SAVE_DIR/sysctl" ]; then
            while IFS='=' read -r key value; do
                [ -n "$key" ] && sysctl -q -w "$key=$value" 2>/dev/null || true
            done <"$SAVE_DIR/sysctl"
        fi

        if [ -s "$SAVE_DIR/lo_mtu" ]; then
            ip link set dev lo mtu "$(cat "$SAVE_DIR/lo_mtu")" 2>/dev/null || true
        fi

        info "host knobs restored"
    fi

    [ -n "$SAVE_DIR" ] && [ -d "$SAVE_DIR" ] && rm -rf "$SAVE_DIR"

    return "$status"
}
trap restore EXIT INT TERM

SAVE_DIR="$(mktemp -d)"

# The knobs held still, and the values they are held at.
SYSCTL_KEYS=(
    net.core.somaxconn
    net.core.netdev_max_backlog
    net.core.rmem_max
    net.core.wmem_max
    net.ipv4.tcp_max_syn_backlog
    net.ipv4.udp_rmem_min
    net.ipv4.udp_wmem_min
)
SYSCTL_VALUES=(
    65535
    250000
    16777216
    16777216
    65535
    16384
    16384
)

# quiesce
# Saves each knob, then sets it. Nothing here is set that restore does not put back.
quiesce() {
    if [ "$IS_ROOT" -ne 1 ]; then
        info "not root, skipping host quiesce (governor, sysctl, mtu), pinning still applies"

        return 0
    fi

    QUIESCED=1

    local policy
    for policy in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -r "$policy" ] || continue

        cat "$policy" >"$SAVE_DIR/governor"
        break
    done
    for policy in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -w "$policy" ] && echo performance >"$policy" 2>/dev/null || true
    done

    : >"$SAVE_DIR/sysctl"
    local index=0
    while [ "$index" -lt "${#SYSCTL_KEYS[@]}" ]; do
        local key="${SYSCTL_KEYS[$index]}"
        local current
        current="$(sysctl -n "$key" 2>/dev/null || true)"
        [ -n "$current" ] && echo "$key=$current" >>"$SAVE_DIR/sysctl"
        sysctl -q -w "$key=${SYSCTL_VALUES[$index]}" 2>/dev/null || true
        index=$((index + 1))
    done

    ip link show dev lo 2>/dev/null | grep -oP 'mtu \K\d+' >"$SAVE_DIR/lo_mtu" || true
    ip link set dev lo mtu 1500 2>/dev/null || true

    sync
    echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true

    info "host quiesced (governor performance, socket sysctls, lo mtu 1500, page cache dropped)"
}

CORES="$(nproc 2>/dev/null || echo 4)"
if [ "$CORES" -le 2 ]; then
    SERVER_CPUS="0-$((CORES - 1))"
    LOADGEN_CPUS="0-$((CORES - 1))"
else
    SERVER_CPUS="0-$((CORES / 2 - 1))"
    LOADGEN_CPUS="$((CORES / 2))-$((CORES - 1))"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
HEADER="$OUT_DIR/isolate-${POSITIONAL[0]}-$STAMP.txt"

# What reached the run script, so a result carries proof of which optional gates were
# armed rather than leaving a reader to infer it from the command line.
FORWARDED="${PASSTHROUGH[*]+${PASSTHROUGH[*]}}"

{
    echo "localbench isolate"
    echo "command:   $INVOCATION"
    echo "forward:   ${FORWARDED:-(none)}"
    echo "server:    cpus=$SERVER_CPUS"
    echo "loadgen:   cpus=$LOADGEN_CPUS"
    echo "root:      $([ "$IS_ROOT" -eq 1 ] && echo yes || echo "no (host knobs skipped)")"
    echo "started:   $(date '+%Y-%m-%d %H:%M:%S')"
} | tee "$HEADER"

[ "$DO_QUIESCE" -eq 1 ] && quiesce

# The run script pins the load generator itself, so it is told which half to use. The
# server inherits this process's own mask through taskset below.
export LOCALBENCH_LOADGEN_CPUS="$LOADGEN_CPUS"

info "running localbench-run.sh"
taskset -c "$SERVER_CPUS" "$SELF_DIR/localbench-run.sh" \
    "${POSITIONAL[@]}" --out-dir "$OUT_DIR" "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}" 2>&1 | tee -a "$HEADER"

info "result: $HEADER"
