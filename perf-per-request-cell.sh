#!/usr/bin/env bash
# Per-request perf-stat harness: counts server-side hardware events during a
# steady-state window, then converts to per-request via the reported RPS rate
# (events/sec / requests/sec = events/req). The perf window sits fully inside a
# longer wrk load so there is no ramp or idle tail skew. Compares http1 .EPOLL
# vs .URING dispatch on cache behaviour (L1d misses/req, i-cache, IPC).
set -u

BIN="$1"; PORT="$2"; ROUTE="$3"; LABEL="$4"; REP="${5:-1}"
SERVER_CPUS="0,2"     # 2 distinct physical cores => 2 shared-nothing workers
WRK_CPUS="6,7,8,9"
WRK_THREADS=6
WRK_CONNS=128
WRK_DUR=20           # total load duration
RAMP=4               # let RPS reach steady state before counting
PERF_WIN=12          # counting window, fully inside [RAMP, WRK_DUR]
EVENTS="cycles,instructions,L1-dcache-loads,L1-dcache-load-misses,ic_tag_hit_miss.instruction_cache_miss"

taskset -c "$SERVER_CPUS" "$BIN" >/tmp/perf_srv_${LABEL}.log 2>&1 &
SRV=$!

for _ in $(seq 1 50); do
    if exec 3<>/dev/tcp/127.0.0.1/$PORT 2>/dev/null; then exec 3<&- 3>&-; break; fi
    sleep 0.1
done

# Warm pool / page-in.
taskset -c "$WRK_CPUS" wrk -t"$WRK_THREADS" -c"$WRK_CONNS" -d3s "http://127.0.0.1:$PORT$ROUTE" >/dev/null 2>&1

# Steady load for the whole window.
taskset -c "$WRK_CPUS" wrk -t"$WRK_THREADS" -c"$WRK_CONNS" -d"${WRK_DUR}s" "http://127.0.0.1:$PORT$ROUTE" >/tmp/perf_wrk_${LABEL}.txt 2>&1 &
WRK=$!

sleep "$RAMP"
perf stat -x, -e "$EVENTS" -p "$SRV" -o /tmp/perf_stat_${LABEL}.csv -- sleep "$PERF_WIN" 2>/dev/null

wait "$WRK"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null

RPS=$(grep "Requests/sec" /tmp/perf_wrk_${LABEL}.txt | awk '{print $2}')
get() { grep ",$1," /tmp/perf_stat_${LABEL}.csv | awk -F, '{print $1}'; }
CYC=$(get cycles); INS=$(get instructions)
L1L=$(get L1-dcache-loads); L1M=$(get L1-dcache-load-misses)
ICM=$(get ic_tag_hit_miss.instruction_cache_miss)

# events/req = (events / PERF_WIN) / RPS
awk -v lbl="$LABEL" -v rt="$ROUTE" -v rep="$REP" -v win="$PERF_WIN" -v rps="$RPS" \
    -v cyc="$CYC" -v ins="$INS" -v l1l="$L1L" -v l1m="$L1M" -v icm="$ICM" 'BEGIN{
  rq = rps*win;
  printf "%s,%s,%d,%.0f,%.0f,%.0f,%.3f,%.0f,%.1f,%.2f,%.1f\n",
    lbl, rt, rep, rps, cyc/rq, ins/rq, ins/cyc, l1l/rq, l1m/rq, (l1m/l1l)*100.0, icm/rq;
}'
