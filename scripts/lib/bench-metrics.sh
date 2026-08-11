#!/usr/bin/env bash
# bench-metrics.sh - Load-generator output to the arena's metric set.
#
# One parser per driver, each echoing KEY=VALUE lines the caller reads into an
# associative array. The keys, the extraction expressions, and the arithmetic
# are the ones HttpArena's scripts/lib/tools/*.sh use, so a localbench number
# and an arena number mean the same thing.
#
# The one thing to know before reading further: rps is COMPUTED as successful
# responses divided by the measured duration, never taken from the driver's own
# throughput line. Every driver counts 4xx and 5xx as completed requests, so a
# server that has started answering 404 reads as faster than one that still
# works. Counting only successful responses makes that impossible.
#
# Emitted keys:
#   rps          successful responses per second (whole number)
#   avg_lat      mean request latency, as the driver worded it
#   p99_lat      tail latency: a real p99 where the driver has one, else max
#   reconnects   connections the driver had to re-establish
#   bandwidth    response bytes per second, as the driver worded it
#   status_2xx   .. status_5xx   response counts by class
#   tpl_*        per-template response counts (api-4 and api-16 only)
#
# Sourced by:
#   scripts/localbench-run.sh

# --------------------------------------------------------- #
# gcannon

# gcannon_parse ENDPOINT OUTPUT
# The summary line is the source of truth for the measured duration. Its shape
# is one of:
#   <req> requests    in <dur>s, <resp> responses
#   <req> frames sent in <dur>s, <resp> frames received   (--ws)
gcannon_parse() {
    local endpoint="$1" output="$2"
    local duration_secs ok

    duration_secs=$(echo "$output" | grep -oP '(?:requests|frames sent) in \K[\d.]+' | head -1 || true)
    duration_secs=${duration_secs:-1}

    case "$endpoint" in
        ws-echo)
            # The received-frame count is what a websocket echo answers with.
            # Older gcannon builds word it differently, hence the cascade.
            ok=$(echo "$output" | grep -oP '\d+\s+(?:responses|frames received)' | head -1 | grep -oP '\d+' || true)

            if [ -z "$ok" ]; then
                ok=$(echo "$output" | grep -oP 'WS frames:\s*\K\d+' | head -1 || true)
            fi
            if [ -z "$ok" ]; then
                ok=$(echo "$output" | grep -oP '2xx=\K\d+' | head -1 || true)
            fi
            ;;
        *)
            ok=$(echo "$output" | grep -oP '2xx=\K\d+' | head -1 || true)
            ;;
    esac
    ok=${ok:-0}

    echo "rps=$(awk -v ok="$ok" -v dur="$duration_secs" \
        'BEGIN { if (dur + 0 > 0) printf "%d", ok / dur; else print 0 }' 2>/dev/null || echo 0)"
    echo "avg_lat=$(echo "$output" | grep "Latency" | head -1 | awk '{print $2}')"
    echo "p99_lat=$(echo "$output" | grep "Latency" | head -1 | awk '{print $5}')"
    echo "reconnects=$(echo "$output" | grep -oP 'Reconnects: \K\d+' | head -1 || echo 0)"
    echo "bandwidth=$(echo "$output" | grep -oP 'Bandwidth:\s+\K\S+' | head -1 || echo 0)"

    if [ "$endpoint" = "ws-echo" ]; then
        echo "status_2xx=${ok}"
        echo "status_3xx=0"
        echo "status_4xx=0"
        echo "status_5xx=0"
    else
        echo "status_2xx=$(echo "$output" | grep -oP '2xx=\K\d+' | head -1 || echo 0)"
        echo "status_3xx=$(echo "$output" | grep -oP '3xx=\K\d+' | head -1 || echo 0)"
        echo "status_4xx=$(echo "$output" | grep -oP '4xx=\K\d+' | head -1 || echo 0)"
        echo "status_5xx=$(echo "$output" | grep -oP '5xx=\K\d+' | head -1 || echo 0)"
    fi

    # Per-template counts, only meaningful where the profile rotates templates.
    # The grouping below must stay in line with the api-4 and api-16 template
    # order in localbench-run.sh: get, get, get, json, json, json, db, db.
    if [ "$endpoint" = "api-4" ] || [ "$endpoint" = "api-16" ]; then
        local tpl_line
        tpl_line=$(echo "$output" | grep -oP 'Per-template-ok: \K.*' | head -1 || true)

        if [ -n "$tpl_line" ]; then
            local -a tpl
            IFS=',' read -ra tpl <<< "$tpl_line"

            echo "tpl_baseline=$(( ${tpl[0]:-0} + ${tpl[1]:-0} + ${tpl[2]:-0} ))"
            echo "tpl_json=$(( ${tpl[3]:-0} + ${tpl[4]:-0} + ${tpl[5]:-0} ))"
            echo "tpl_async_db=$(( ${tpl[6]:-0} + ${tpl[7]:-0} ))"
        fi
    fi
}

# --------------------------------------------------------- #
# wrk

# wrk_parse ENDPOINT OUTPUT
# wrk reports only a total request count, so every answer counts as 2xx. Its
# latency line is "Latency 3.70ms 8.37ms 279.91ms 96.41%": avg, stdev, max,
# and the share within one stdev. There are no percentiles without --latency,
# so max stands in for the tail.
wrk_parse() {
    local output="$2"
    local lat total_reqs

    echo "rps=$(echo "$output" | grep -oP 'Requests/sec:\s+\K[\d.]+' | cut -d. -f1 || echo 0)"

    lat=$(echo "$output" | grep "Latency" | head -1 || true)
    echo "avg_lat=$(echo "$lat" | awk '{print $2}')"
    echo "p99_lat=$(echo "$lat" | awk '{print $4}')"

    echo "reconnects=0"
    echo "bandwidth=$(echo "$output" | grep -oP 'Transfer/sec:\s+\K\S+' | head -1 || echo 0)"

    total_reqs=$(echo "$output" | grep -oP '(\d+) requests in' | grep -oP '\d+' | head -1 || echo 0)
    echo "status_2xx=${total_reqs:-0}"
    echo "status_3xx=0"
    echo "status_4xx=0"
    echo "status_5xx=0"
}

# --------------------------------------------------------- #
# h2load

# h2load_parse ENDPOINT OUTPUT
# The latency one-liner is "time for request: min max mean sd +/- sd", so mean
# is field 6 and max is field 5. h2load carries no percentile, so max is the
# tail figure.
h2load_parse() {
    local output="$2"
    local duration_secs ok

    duration_secs=$(echo "$output" | grep -oP 'finished in \K[\d.]+' | head -1 || true)
    duration_secs=${duration_secs:-1}
    ok=$(echo "$output" | grep -oP '\d+(?= 2xx)' | head -1 || true)
    ok=${ok:-0}

    echo "rps=$(awk -v ok="$ok" -v dur="$duration_secs" \
        'BEGIN { if (dur + 0 > 0) printf "%d", ok / dur; else print 0 }' 2>/dev/null || echo 0)"

    echo "avg_lat=$(echo "$output" | awk '/time for request:/ {print $6}' | head -1)"
    echo "p99_lat=$(echo "$output" | awk '/time for request:/ {print $5}' | head -1)"

    echo "reconnects=0"
    echo "bandwidth=$(echo "$output" | grep -oP 'finished in [\d.]+s, [\d.]+ req/s, \K[\d.]+[KMGT]?B/s' | head -1 || echo 0)"

    echo "status_2xx=$(echo "$output" | grep -oP '\d+(?= 2xx)' | head -1 || echo 0)"
    echo "status_3xx=$(echo "$output" | grep -oP '\d+(?= 3xx)' | head -1 || echo 0)"
    echo "status_4xx=$(echo "$output" | grep -oP '\d+(?= 4xx)' | head -1 || echo 0)"
    echo "status_5xx=$(echo "$output" | grep -oP '\d+(?= 5xx)' | head -1 || echo 0)"
}

# --------------------------------------------------------- #
# h2load over HTTP/3

# h2load_h3_parse ENDPOINT OUTPUT
# The h3 build prints a tabular "request :" line instead of h2load's one-liner:
# mean sits at field 8 and the tail at field 7.
h2load_h3_parse() {
    local output="$2"
    local duration_secs ok

    duration_secs=$(echo "$output" | grep -oP 'finished in \K[\d.]+' | head -1 || true)
    duration_secs=${duration_secs:-1}
    ok=$(echo "$output" | grep -oP '\d+(?= 2xx)' | head -1 || true)
    ok=${ok:-0}

    echo "rps=$(awk -v ok="$ok" -v dur="$duration_secs" \
        'BEGIN { if (dur + 0 > 0) printf "%d", ok / dur; else print 0 }' 2>/dev/null || echo 0)"

    echo "avg_lat=$(echo "$output" | awk '/^\s*request\s*:/ { print $8; exit }')"
    echo "p99_lat=$(echo "$output" | awk '/^\s*request\s*:/ { print $7; exit }')"

    echo "reconnects=0"
    echo "bandwidth=$(echo "$output" | grep -oP 'finished in [\d.]+s, [\d.]+ req/s, \K[\d.]+[KMGT]?B/s' | head -1 || echo 0)"

    echo "status_2xx=$(echo "$output" | grep -oP '\d+(?= 2xx)' | head -1 || echo 0)"
    echo "status_3xx=$(echo "$output" | grep -oP '\d+(?= 3xx)' | head -1 || echo 0)"
    echo "status_4xx=$(echo "$output" | grep -oP '\d+(?= 4xx)' | head -1 || echo 0)"
    echo "status_5xx=$(echo "$output" | grep -oP '\d+(?= 5xx)' | head -1 || echo 0)"
}

# --------------------------------------------------------- #
# ghz

# Messages per streaming call. The reported rps is messages per second rather
# than calls per second, which is what makes a streaming figure readable next
# to a unary one.
GHZ_MSGS_PER_CALL=5000

# ghz_parse ENDPOINT OUTPUT
# Only [OK] calls count. ghz's own Requests/sec includes [Unavailable] and
# [Canceled] calls, which inflates exactly when the server is falling over.
ghz_parse() {
    local output="$2"
    local dur_s=${DURATION%s}
    local ok_count p99

    ok_count=$(echo "$output" | grep -oP '\[OK\]\s+\K\d+' | head -1 || echo 0)
    ok_count=${ok_count:-0}

    if [ "$dur_s" -gt 0 ] 2>/dev/null; then
        echo "rps=$(awk -v ok="$ok_count" -v dur="$dur_s" -v msgs="$GHZ_MSGS_PER_CALL" \
            'BEGIN { printf "%d", (ok / dur) * msgs }')"
    else
        echo "rps=0"
    fi

    echo "avg_lat=$(echo "$output" | awk '/^\s*Average:/ { print $2 $3; exit }')"

    p99=$(echo "$output" | awk '/^[[:space:]]*99(\.[0-9]+)? % in /{print $4 $5; exit}')
    [ -z "$p99" ] && p99=$(echo "$output" | awk '/^[[:space:]]*Slowest:/{print $2 $3; exit}')
    echo "p99_lat=$p99"

    echo "reconnects=0"
    echo "bandwidth=0"

    echo "status_2xx=$ok_count"
    echo "status_3xx=0"
    echo "status_4xx=0"
    echo "status_5xx=$(echo "$output" | grep -oP '\[Unavailable\]\s+\K\d+' | head -1 || echo 0)"
}
