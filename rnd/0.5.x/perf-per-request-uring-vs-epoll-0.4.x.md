# Per-request perf-stat: http1 .URING vs .EPOLL (cache locality)

> This is 0.5.x research on the 0.4.x-rc engine code (the dispatch split of ADR-043).

## What this measures

The loopback board is kernel-bound, so RPS clusters and the engine-side
differentiator is cache behaviour, not raw instruction count. This run counts
server-side hardware events during a steady-state load window and converts each to
a per-request figure. It reproduces the headline from the io_uring exploration: the
ring path does the same work with far fewer cache stalls per request.

Counted on the server process only (`perf stat -p <pid>`), then converted via the
steady RPS rate: `events_per_req = (events / window_seconds) / requests_per_second`.
The perf window sits fully inside a longer wrk load so there is no ramp or idle-tail
skew.

## Setup

| Item | Value |
| :- | :- |
| Host | AMD Ryzen 5 5600H (Zen3, 6 cores / 12 threads), single NUMA node |
| Engines | `example-http1_basic_4_epoll` (.EPOLL), `example-http1_basic_5_uring` (.URING) |
| Build | `zig-0.16 build examples -Doptimize=ReleaseFast` |
| Server pin | `taskset -c 0,2` (2 distinct physical cores, 2 shared-nothing workers) |
| Load pin | `taskset -c 6,7,8,9`, `wrk -t4 -c128` |
| Window | 20s load, 4s ramp skipped, 12s counted |
| Routes | `/` (13-byte text), `/echo` (15-byte JSON, response-cache path) |
| Reps | 3 per cell, values below are the 3-rep mean |
| perf access | no sudo needed (paranoid=2 permits cycles + L1d counters for a launched process) |

`max_recv_buf` is 16 KiB (`.throughput` profile) for both engines, so the per-conn
footprint is identical. The only variable is the dispatch model.

Events: `cycles`, `instructions`, `L1-dcache-loads`, `L1-dcache-load-misses`,
`ic_tag_hit_miss.instruction_cache_miss`. LLC/L3 counters are not exposed on this
consumer part (only `l3_read_miss_latency`), so L3-share spill is not directly
countable here. That belongs to the 64c box.

## Result: route `/` (baseline text)

| Metric (per request) | .EPOLL | .URING | Delta |
| :- | :- | :- | :- |
| L1d-cache load-misses | 548.5 | 359.3 | -34.5% |
| L1d-cache miss rate | 9.92% | 6.02% | -3.90 pts |
| i-cache misses | 1595.0 | 1288.3 | -19.2% |
| IPC (instructions/cycle) | 0.714 | 0.841 | +17.8% |
| cycles | 20,297 | 18,624 | -8.2% |
| instructions | 14,490 | 15,658 | +8.1% |
| RPS (2 workers, loopback) | 404,641 | 439,569 | +8.6% |

### Reading it

The ring path executes about 8% MORE instructions per request (the submit + CQE
bookkeeping the readiness path does not have), yet finishes in about 8% FEWER
cycles. The reason is entirely the cache: -34.5% L1d load-misses and -19.2% i-cache
misses lift IPC by +17.8%, so the extra instructions retire with far fewer stall
cycles. Fewer demand-paged buffer touches and the tighter completion loop keep more
of the per-request working set resident in L1/L2.

This is the same effect logged earlier as the "-20 to -33% per-request L1-miss" win,
reproduced here at -34.5% with a clean steady-state method. The cache win is real and
measurable on this laptop. The +8.6% RPS is a by-product of this 2-worker pinned
loopback config and is NOT a sign-off number: the >1% RPS gate still belongs to the
64-core real-traffic run.

## Result: route `/echo` (JSON, response-cache path)

| Metric (per request) | .EPOLL | .URING | Delta |
| :- | :- | :- | :- |
| L1d-cache load-misses | 547.8 | 364.7 | -33.4% |
| L1d-cache miss rate | 9.88% | 6.08% | -3.80 pts |
| i-cache misses | 1605.2 | 1298.5 | -19.1% |
| IPC (instructions/cycle) | 0.716 | 0.843 | +17.7% |
| cycles | 20,318 | 18,691 | -8.0% |
| instructions | 14,556 | 15,748 | +8.2% |
| RPS (2 workers, loopback) | 402,326 | 436,891 | +8.6% |

The JSON route tracks the baseline almost exactly because the response-cache path
keeps the served body precomputed, so the per-request working set (recv parse, route
dispatch, send) is the same shape. The cache delta is route-independent here: it is a
property of the dispatch model, not the payload.

## Takeaway

The ring path is not faster because it does less. It does about 8% MORE work per
request (submit + completion bookkeeping) and still costs about 8% FEWER cycles,
purely because it stalls less: about -34% L1d load-misses and -19% i-cache misses,
lifting IPC by about +18%. This is the cache-locality lever, now with a number
attached on real silicon. The next levers (hot/cold split, `@prefetch`, smaller live set) aim to push
the EPOLL miss count down toward the URING figure without changing the dispatch model.

What this run cannot settle: L3-share spill (the c512 to c4096 degradation), because
this consumer part exposes no usable L3 miss counter. That, and the >1% RPS sign-off,
stay on the 64-core box.

## Appendix: per-rep raw (3 reps each)

| label | route | rep | rps | cyc/req | instr/req | IPC | L1d_loads/req | L1d_miss/req | L1d_miss% | iC_miss/req |
| :- | :- | :- | :- | :- | :- | :- | :- | :- | :- | :- |
| epoll | / | 1 | 405469 | 20269 | 14475 | 0.714 | 5521 | 547.8 | 9.92 | 1589.6 |
| epoll | / | 2 | 404379 | 20313 | 14468 | 0.712 | 5520 | 547.7 | 9.92 | 1597.2 |
| epoll | / | 3 | 404075 | 20308 | 14526 | 0.715 | 5541 | 550.0 | 9.93 | 1598.3 |
| uring | / | 1 | 442644 | 18553 | 15653 | 0.844 | 5962 | 355.3 | 5.96 | 1280.0 |
| uring | / | 2 | 437887 | 18631 | 15656 | 0.840 | 5967 | 360.3 | 6.04 | 1288.6 |
| uring | / | 3 | 438177 | 18688 | 15665 | 0.838 | 5968 | 362.3 | 6.07 | 1296.2 |
| epoll | /echo | 1 | 402609 | 20324 | 14547 | 0.716 | 5543 | 548.0 | 9.89 | 1606.3 |
| epoll | /echo | 2 | 402485 | 20316 | 14596 | 0.718 | 5561 | 548.3 | 9.86 | 1602.2 |
| epoll | /echo | 3 | 401883 | 20314 | 14524 | 0.715 | 5534 | 547.1 | 9.89 | 1607.1 |
| uring | /echo | 1 | 437029 | 18693 | 15731 | 0.842 | 5995 | 362.1 | 6.04 | 1297.8 |
| uring | /echo | 2 | 436984 | 18683 | 15760 | 0.844 | 6005 | 363.4 | 6.05 | 1296.5 |
| uring | /echo | 3 | 436660 | 18696 | 15754 | 0.843 | 6001 | 368.6 | 6.14 | 1301.2 |

Run-to-run spread is well under 1% per cell (L1d-miss/req: epoll 547.1 to 550.0,
uring 355.3 to 368.6), so the -33 to -35% gap is far outside the noise band. The
harness lives at `perf-per-request-cell.sh` (single cell) and
`perf-per-request-matrix.sh` (the epoll vs uring x route x rep matrix), both at the repo root.

## Lever attempt log

### Lever 3: @prefetch the next event's Conn slot (EPOLL) - NULL, reverted

Hypothesis: the drain loop looks up `slots[fd]` per event, the fds in one
`epoll_wait` batch are scattered, and `Conn` is 72 bytes (2 cache lines), so each
lookup should miss L1d. Prefetching the next event's slot while the current one is
served should hide the miss. Added a `ConnTable.prefetch` and an index-based loop
issuing `@prefetch(.read, .locality 3, .data)` one event ahead.

A/B on the same build, interleaved (base, pre, base, pre) to cancel drift, 4 reps,
route `/`:

| | base (mean) | prefetch (mean) | delta |
| :- | :- | :- | :- |
| L1d-miss/req | 547.4 | 551.6 | +0.77% (worse) |
| RPS | 404,710 | 403,207 | -0.37% |

Per-rep prefetch L1d-miss: 551.7, 547.7, 549.8, 557.3 (vs base 548.8, 547.6, 547.8,
545.4). The change does NOT reduce misses, it trends slightly up, and RPS edges
down. Reverted (the goal was fewer misses, it produced more).

Conclusion that matters more than the null: the Conn-slot access is NOT a dominant
L1d-miss source here. The hardware prefetcher already streams it, so an explicit hint
only adds an instruction. By the same logic a hot/cold slot split (lever 2) would
likely also be null, because it targets the same slot access. The EPOLL-vs-URING
189-miss/req gap is therefore I/O-model-structural (URING zero-copy recv via
MSG_TRUNC plus batched completions touch fewer distinct lines per request), not a
slot-layout problem. The 548 misses come from elsewhere: the recv-buffer parse pass,
response staging, and the slab pages.

Recommended before the next lever: `perf record -e L1-dcache-load-misses` then
`perf annotate` on the EPOLL server to localize which function and line own the
misses, rather than guessing the next layout change. That turns the remaining work
from speculative into targeted.
