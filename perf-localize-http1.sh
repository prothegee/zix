#!/usr/bin/env bash
# Localize where the http1 per-request L1d-cache-load-misses come from, for the
# .EPOLL and .URING dispatch models, by symbol and by source line.
#
# Why a hand-run script: the agent's sandbox kills `perf record` (its sampling
# mmap) and any backgrounded/sleeping helper, so the record pass has to be run by
# a human in a normal terminal. perf stat worked in-sandbox (that is how the
# per-request cache table was measured), perf record does not.
#
# Prereq: build the ReleaseFast examples first.
#   zig-0.16 build example-http1 -Doptimize=ReleaseFast
#
# Usage (from the zix repo root):
#   ./perf-localize-http1.sh
# Then paste rnd/0.5.x/perf-localize-raw.txt (or the stdout) back to the agent.
#
# Needs: wrk on PATH, sudo perf (NOPASSWD is fine). Host is the laptop
# (Ryzen 5 5600H), same box the per-request table was measured on.
set -u

EPOLL=zig-out/bin/example-http1_basic_4_epoll
URING=zig-out/bin/example-http1_basic_5_uring
PORT=9100
SRVCPU=0,2          # 2 distinct physical cores => 2 shared-nothing workers
WRKCPU=6,7,8,9
WRK="wrk -t6 -c128"
OUT=rnd/0.5.x/perf-localize-raw.txt

if [ ! -x "$EPOLL" ] || [ ! -x "$URING" ]; then
    echo "build first: zig-0.16 build example-http1 -Doptimize=ReleaseFast" >&2
    exit 1
fi

: > "$OUT"
log() { echo "$@" | tee -a "$OUT"; }

profile_one() {
    local bin="$1" tag="$2" dso="$3"
    local data="/tmp/perf_localize_${tag}.data"

    log ""
    log "==================== $tag ===================="

    taskset -c "$SRVCPU" "$bin" >/tmp/srv_${tag}.log 2>&1 &
    local srv=$!
    for _ in $(seq 1 50); do
        if exec 3<>/dev/tcp/127.0.0.1/$PORT 2>/dev/null; then exec 3<&- 3>&-; break; fi
        sleep 0.1
    done

    # warm the pool / page-in, then run steady load while perf samples the server.
    taskset -c "$WRKCPU" $WRK -d4s "http://127.0.0.1:$PORT/" >/dev/null 2>&1
    taskset -c "$WRKCPU" $WRK -d25s "http://127.0.0.1:$PORT/" >/tmp/wrk_${tag}.txt 2>&1 &
    local load=$!

    sleep 4
    sudo perf record -e L1-dcache-load-misses -c 2000 -p "$srv" -o "$data" -- sleep 15

    wait "$load" 2>/dev/null
    kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null

    log "--- RPS ---"
    grep "Requests/sec" /tmp/wrk_${tag}.txt | tee -a "$OUT"

    log "--- L1d-miss by symbol, all DSOs (kernel vs user split) ---"
    sudo perf report --stdio -i "$data" --percent-limit 1 2>/dev/null \
        | grep -vE "^#|^$" | head -30 | tee -a "$OUT"

    log "--- L1d-miss in the zix binary only ($dso) ---"
    sudo perf report --stdio -i "$data" --dsos="$dso" --percent-limit 1 2>/dev/null \
        | grep -vE "^#|^$" | head -25 | tee -a "$OUT"

    local top
    top=$(sudo perf report --stdio -i "$data" --dsos="$dso" 2>/dev/null \
        | grep -vE "^#|^$" | head -1 | awk '{print $NF}')
    log "--- annotate hottest zix symbol: $top ---"
    if [ -n "$top" ]; then
        sudo perf annotate --stdio -i "$data" --dsos="$dso" "$top" 2>/dev/null \
            | grep -E "^\s+[0-9]+\.[0-9]+|:" | head -50 | tee -a "$OUT"
    fi
}

pkill -f example-http1_basic 2>/dev/null
profile_one "$EPOLL" epoll example-http1_basic_4_epoll
profile_one "$URING" uring example-http1_basic_5_uring

log ""
log "DONE. Full text saved to $OUT . Paste it back to the agent."
