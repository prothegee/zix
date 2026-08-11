#!/usr/bin/env bash
# bench-memlog.sh - Whole-tier memory profile to a side file, for --sample-mem.
#
# Distinct from bench-sample.sh, which answers "what did this one pass cost" for
# the result line. This one answers "where did the memory go", at a slower rate
# and into a file, for the case where a peak number alone is not enough.
#
# What it records, and what it cannot:
#   total   resident set size, summed across the sampled processes
#   anon    anonymous pages: heap, stacks, and every allocator arena
#   file    total minus anonymous: mapped binaries, shared libraries, mapped files
#   pss     the proportional set size, which charges a shared page to its sharers
#
# The arena samples a container cgroup, so it also reports `sock` (kernel socket
# buffers) and `slab`. Neither has a per-process equivalent in /proc: they are
# kernel-side allocations a cgroup owns and a process does not. They are absent
# here rather than filled with a number that would not mean the same thing.
#
# Usage:
# ```bash
# memlog_start "$mem_log" "$smaps_file" "$tier_tag" server=1234 edge=5678
# ...drive the load...
# memlog_stop
# memlog_summary "$mem_log" "$smaps_file" "$tier_tag"
# ```
#
# Sourced by:
#   scripts/localbench-run.sh

MEMLOG_PID=""

# memlog_start MEM_LOG SMAPS_FILE TIER LABEL=PID...
# Append one line per second to MEM_LOG, tagged with TIER so a file spanning a
# whole sweep can still be read one connection count at a time. A full smaps
# dump lands in SMAPS_FILE whenever the run reaches a new overall peak, and a
# smaps_rollup snapshot goes into MEM_LOG every 15 samples.
memlog_start() {
    local mem_log="$1" smaps_file="$2" tier="$3"
    shift 3

    local -a pids=()
    local target pid
    for target in "$@"; do
        pid="${target#*=}"

        [ -n "$pid" ] && [ -d "/proc/$pid" ] && pids+=("$pid")
    done

    if [ "${#pids[@]}" -eq 0 ]; then
        MEMLOG_PID=""

        return 0
    fi

    # The peak carries across tiers in its own file, so the single smaps dump is
    # the run's real high-water mark rather than the last tier's.
    local peak_file="$mem_log.peak"
    [ -s "$peak_file" ] || echo 0 >"$peak_file"

    (
        local tick=0 timestamp
        while true; do
            local total=0 anon=0 pss=0
            local sample_pid rss anonymous proportional

            for sample_pid in "${pids[@]}"; do
                # All three numbers come from one read of one file, so they
                # always describe the same instant and anon can never exceed
                # total. Taking VmRSS from /proc/<pid>/status and Anonymous from
                # smaps_rollup does not hold: those are two reads, and reading
                # smaps_rollup is slow enough that during an allocation ramp the
                # pair straddled it and reported more anonymous than resident.
                if [ -r "/proc/$sample_pid/smaps_rollup" ]; then
                    read -r rss anonymous proportional < <(awk '
                        /^Rss:/       { resident = $2 }
                        /^Anonymous:/ { anonymous = $2 }
                        /^Pss:/       { proportional = $2 }
                        END           { printf "%d %d %d\n", resident + 0, anonymous + 0, proportional + 0 }
                    ' "/proc/$sample_pid/smaps_rollup" 2>/dev/null || echo "0 0 0")

                    total=$((total + ${rss:-0}))
                    anon=$((anon + ${anonymous:-0}))
                    pss=$((pss + ${proportional:-0}))
                else
                    # No smaps_rollup before kernel 4.14. The resident total is
                    # still readable, the breakdown is not, so it stays zero
                    # rather than being guessed at.
                    rss="$(awk '/^VmRSS:/ { print $2; exit }' "/proc/$sample_pid/status" 2>/dev/null || true)"
                    total=$((total + ${rss:-0}))
                fi
            done

            if [ "$total" -gt 0 ]; then
                timestamp=$(date +%s)
                echo "$timestamp tier=$tier current=$total anon=$anon file=$((total - anon)) pss=$pss" >>"$mem_log"
            fi

            if [ $(( tick % 15 )) -eq 0 ]; then
                for sample_pid in "${pids[@]}"; do
                    [ -r "/proc/$sample_pid/smaps_rollup" ] || continue

                    {
                        echo "# smaps_rollup pid=$sample_pid tier=$tier @$(date +%s)"
                        cat "/proc/$sample_pid/smaps_rollup"
                        echo
                    } >>"$mem_log"
                done
            fi

            # A new overall peak is the only moment a full smaps is worth the
            # cost: it is thousands of lines per process.
            if [ "$total" -gt "$(cat "$peak_file" 2>/dev/null || echo 0)" ]; then
                echo "$total" >"$peak_file"

                {
                    echo "# full smaps tier=$tier @$(date +%s) current=${total}kB"
                    for sample_pid in "${pids[@]}"; do
                        [ -r "/proc/$sample_pid/smaps" ] || continue

                        echo "# pid=$sample_pid"
                        cat "/proc/$sample_pid/smaps"
                    done
                } >"$smaps_file" 2>/dev/null || true
            fi

            tick=$(( tick + 1 ))
            sleep 1
        done
    ) >/dev/null 2>&1 &
    MEMLOG_PID=$!
}

# memlog_stop
memlog_stop() {
    [ -n "$MEMLOG_PID" ] || return 0

    kill "$MEMLOG_PID" 2>/dev/null || true
    wait "$MEMLOG_PID" 2>/dev/null || true
    MEMLOG_PID=""
}

# memlog_summary MEM_LOG SMAPS_FILE TIER
# Print what this tier's samples say. The peak and the steady figure answer
# different questions: the peak is what the machine had to have available, the
# steady figure is what the server actually sits at.
#
# Note:
# - The rows are sorted by total and the middle ROW is picked, so every field
#   printed comes from the same second. Sorting each field on its own would
#   pair a total from one moment with an anon from another, which is how a
#   summary ends up claiming more anonymous memory than resident memory.
# - An even sample count has no single middle, so the lower of the two is used.
#   Averaging the pair would put a number in the output that was never measured.
memlog_summary() {
    local mem_log="$1" smaps_file="$2" tier="$3"

    [ -s "$mem_log" ] || return 0

    echo "# memory (from $(basename "$mem_log")):"

    grep -F "tier=$tier " "$mem_log" 2>/dev/null | awk '
        /current=/ {
            total = anon = file = pss = 0
            for (field = 1; field <= NF; field++) {
                split($field, pair, "=")
                if      (pair[1] == "current") total = pair[2] + 0
                else if (pair[1] == "anon")    anon  = pair[2] + 0
                else if (pair[1] == "file")    file  = pair[2] + 0
                else if (pair[1] == "pss")     pss   = pair[2] + 0
            }

            printf "%d %d %d %d\n", total, anon, file, pss
        }' | sort -n -k1,1 | awk '
        { row[count++] = $0 }
        END {
            if (count == 0) { print "#   no samples"; exit }

            split(row[count - 1], peak)
            split(row[int((count - 1) / 2)], mid)

            printf "#   total: peak=%.1fMiB  steady=%.1fMiB  samples=%d\n", peak[1] / 1024, mid[1] / 1024, count
            printf "#   anon  at_steady=%.1fMiB\n", mid[2] / 1024
            printf "#   file  at_steady=%.1fMiB\n", mid[3] / 1024
            printf "#   pss   at_steady=%.1fMiB\n", mid[4] / 1024
        }' || true

    # The smaps dump belongs to whichever tier peaked, so it is only worth
    # printing under the tier that produced it.
    if [ -s "$smaps_file" ] && head -1 "$smaps_file" | grep -qF "tier=$tier "; then
        echo "#   top regions at peak (from $(basename "$smaps_file")):"

        awk '
            /^[0-9a-f]+-[0-9a-f]+ / {
                label = $6 == "" ? "[anon]" : $6
                for (field = 7; field <= NF; field++) label = label " " $field
            }
            /^Rss:/ { rss[label] += $2 }
            END { for (name in rss) printf "%d\t%s\n", rss[name], name }
        ' "$smaps_file" | sort -rn | head -8 | awk -F'\t' '
            { printf "#   %8.1fMiB  %s\n", $1 / 1024, $2 }' || true
    fi
}
