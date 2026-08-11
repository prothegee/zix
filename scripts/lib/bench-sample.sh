#!/usr/bin/env bash
# bench-sample.sh - Server-side CPU and memory sampling for one load pass.
#
# The arena samples its containers with `docker stats`. A localbench entry is a
# plain process, so the same two numbers come from /proc instead. The shape is
# deliberately the arena's, down to the variable names, so the run script reads
# the same either side: start the collector, drive the load, stop it, then read
# STATS_AVG_CPU, STATS_PEAK_MEM and STATS_BREAKDOWN.
#
# Two things are worth stating outright, because both are easy to get wrong:
#
#   - CPU is percent of ONE core, so 580% means the server used the equivalent
#     of 5.8 cores over the pass. That is the arena's unit too.
#   - Aggregate memory is the peak of the per-snapshot SUM, never the sum of
#     each process's own peak: two processes that peak at different moments
#     never held that much between them at any single instant.
#
# Usage:
# ```bash
# stats_start server=1234 edge=5678
# output="$(run_load ...)"
# stats_stop
# echo "CPU $STATS_AVG_CPU | Mem $STATS_PEAK_MEM"
# ```
#
# Sourced by:
#   scripts/localbench-run.sh

STATS_PID=""
STATS_LOG=""
STATS_AVG_CPU="0%"
STATS_PEAK_MEM="0MiB"
STATS_BREAKDOWN=""

STATS_CLK_TCK="$(getconf CLK_TCK 2>/dev/null || echo 100)"

# Per-target state captured at stats_start, read back at stats_stop.
STATS_LABELS=()
STATS_PIDS=()
STATS_TICKS_BEFORE=()
STATS_CLOCK_BEFORE=0

# proc_ticks PID
# User plus system ticks for a process, every thread included. The comm field
# is parenthesised and may hold spaces, so the split is on the last close paren
# rather than on whitespace.
#
# Return:
# - a whole number of ticks, or 0 when the process is gone
proc_ticks() {
    local line
    line="$(cat "/proc/$1/stat" 2>/dev/null)" || { echo 0; return 0; }

    echo "${line##*) }" | awk '{print $12 + $13}'
}

# proc_rss_kib PID
# Resident set size right now, in KiB. Empty when the process is gone.
proc_rss_kib() {
    [ -r "/proc/$1/status" ] || return 0

    awk '/^VmRSS:/ { print $2; exit }' "/proc/$1/status" 2>/dev/null || true
}

# stats_start LABEL=PID...
# Record the starting tick count for every live target and spawn the memory
# poller. A target whose process is already gone is dropped rather than
# reported as zero, so a missing edge never reads as an idle one.
stats_start() {
    STATS_LABELS=()
    STATS_PIDS=()
    STATS_TICKS_BEFORE=()

    local target label pid
    for target in "$@"; do
        label="${target%%=*}"
        pid="${target#*=}"

        [ -n "$pid" ] && [ -d "/proc/$pid" ] || continue

        STATS_LABELS+=("$label")
        STATS_PIDS+=("$pid")
        STATS_TICKS_BEFORE+=("$(proc_ticks "$pid")")
    done

    STATS_LOG="$(mktemp)"
    STATS_CLOCK_BEFORE="$(date +%s%N)"

    if [ "${#STATS_PIDS[@]}" -eq 0 ]; then
        STATS_PID=""
        return 0
    fi

    # 10 Hz. Fast enough to catch a connection-storm peak, cheap enough that
    # the poller itself does not show up in the number it is measuring.
    # Log line format: <snapshot> <label> <rss-kib>
    (
        local snap=0 index rss
        while true; do
            snap=$((snap + 1))
            for index in "${!STATS_PIDS[@]}"; do
                rss="$(proc_rss_kib "${STATS_PIDS[$index]}")"
                [ -n "$rss" ] && echo "$snap ${STATS_LABELS[$index]} $rss"
            done

            sleep 0.1
        done
    ) >"$STATS_LOG" 2>/dev/null &
    STATS_PID=$!
}

# stats_stop
# Stop the poller and fill STATS_AVG_CPU, STATS_PEAK_MEM, and (for more than
# one target) STATS_BREAKDOWN.
stats_stop() {
    if [ -n "$STATS_PID" ]; then
        kill "$STATS_PID" 2>/dev/null || true
        wait "$STATS_PID" 2>/dev/null || true
    fi
    STATS_PID=""

    local elapsed_ns=$(( $(date +%s%N) - STATS_CLOCK_BEFORE ))

    STATS_AVG_CPU="0%"
    STATS_PEAK_MEM="0MiB"
    STATS_BREAKDOWN=""

    if [ "${#STATS_PIDS[@]}" -eq 0 ]; then
        [ -n "$STATS_LOG" ] && rm -f "$STATS_LOG"
        STATS_LOG=""

        return 0
    fi

    # CPU per label: ticks burned over the pass, as percent of one core. Two
    # processes sharing a label (a daemon that forked) add together.
    local -A cpu_by_label=()
    local index label ticks_after

    for index in "${!STATS_PIDS[@]}"; do
        label="${STATS_LABELS[$index]}"
        ticks_after="$(proc_ticks "${STATS_PIDS[$index]}")"

        cpu_by_label["$label"]=$(awk \
            -v carried="${cpu_by_label[$label]:-0}" \
            -v before="${STATS_TICKS_BEFORE[$index]}" \
            -v after="$ticks_after" \
            -v tck="$STATS_CLK_TCK" \
            -v elapsed_ns="$elapsed_ns" 'BEGIN {
                if (elapsed_ns <= 0 || tck <= 0) { printf "%.1f", carried; exit }

                printf "%.1f", carried + ((after - before) / tck) / (elapsed_ns / 1000000000) * 100
            }')
    done

    local total_cpu=0
    for label in "${!cpu_by_label[@]}"; do
        total_cpu="$(awk -v a="$total_cpu" -v b="${cpu_by_label[$label]}" 'BEGIN { printf "%.1f", a + b }')"
    done
    STATS_AVG_CPU="${total_cpu}%"

    if [ ! -s "$STATS_LOG" ]; then
        rm -f "$STATS_LOG"
        STATS_LOG=""

        return 0
    fi

    # Peak of the per-snapshot sum across every target.
    STATS_PEAK_MEM=$(awk '
        { mem[$1] += $3 }
        END {
            max = 0
            for (snap in mem) if (mem[snap] > max) max = mem[snap]

            mib = max / 1024
            if (mib >= 1024) printf "%.1fGiB", mib / 1024
            else             printf "%.0fMiB", mib
        }' "$STATS_LOG")

    # Per-target breakdown, skipped for a single target because it would just
    # restate the aggregate. Peak memory per label is the peak of that label's
    # own per-snapshot sum, for the same reason the aggregate is.
    if [ "${#cpu_by_label[@]}" -gt 1 ]; then
        local -A mem_by_label=()
        local mem_label mem_peak

        while read -r mem_label mem_peak; do
            [ -n "$mem_label" ] && mem_by_label["$mem_label"]="$mem_peak"
        done < <(awk '
            { mem[$2 SUBSEP $1] += $3; labels[$2] = 1 }
            END {
                for (label in labels) {
                    max = 0
                    for (key in mem) {
                        split(key, parts, SUBSEP)
                        if (parts[1] == label && mem[key] > max) max = mem[key]
                    }
                    printf "%s %d\n", label, max
                }
            }' "$STATS_LOG")

        local rendered=""
        for label in "${!cpu_by_label[@]}"; do
            rendered+="${rendered:+ | }$(awk \
                -v label="$label" \
                -v cpu="${cpu_by_label[$label]}" \
                -v kib="${mem_by_label[$label]:-0}" 'BEGIN {
                    mib = kib / 1024
                    if (mib >= 1024) printf "%s: %.0f%% %.1fGiB", label, cpu, mib / 1024
                    else             printf "%s: %.0f%% %.0fMiB", label, cpu, mib
                }')"
        done

        STATS_BREAKDOWN="$rendered"
    fi

    rm -f "$STATS_LOG"
    STATS_LOG=""
}
