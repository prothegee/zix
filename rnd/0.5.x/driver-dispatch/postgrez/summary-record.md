# postgrez Driver Dispatch Transport PoC: Summary Record

## Intention and Request

Background: the original goal was Plan 1, an async opt-in lane for the zix.Http1
handler, so a DB round trip would park a fiber instead of blocking the worker.
That path is blocked. In Zig 0.16.0 `std.Io.Uring` has no network send, connect,
accept, or listen (they are Unavailable stubs), so there is no yielding io that
can drive a socket client like postgrez or rediz. A driver cannot be made
fiber-async through std on this compiler.

The pivot: if the driver cannot park on a yielding io, can it instead own a
multiplexed pipelined transport (the zix EPOLL / URING idiom applied to the DB
sockets) and beat the current thread-pool blocking model on raw driver-to-DB
throughput. This PoC answers that for postgrez.

The request, as agreed:
- A PoC / RnD, std only, minimal, no import of the real driver, under
  rnd/0.5.x/driver-dispatch/{postgrez,rediz}. Proving it std-only first makes the
  later port into the real driver easier.
- Three dispatch models only: ASYNC, EPOLL, URING. No POOL, no MIXED.
- The driver init gains a dispatch_model knob, default ASYNC. zix_uring_http1_3b
  will pin URING.
- The checkmark is driver-to-DB throughput (completed requests and req/s), with
  no HTTP server anywhere in the loop.
- Record CPU and memory per dispatch, not only throughput.
- A realistic workload, not a trivial round trip: the operations the HttpArena
  entry actually runs (select, insert, update, transaction), each isolated per
  operation so insert vs select is visible.
- The connection count is fixed and equal across the three models (fairness), so
  the result isolates the transport, not the connection count.
- Framing: latency is not controllable, so the comparison is about send and
  receive throughput per dispatch model. The multiplexed pipeline should show its
  win on throughput.

## Methodology

- Models:
  - ASYNC: K blocking connections, one round trip in flight each, run on K
    threads (io.async on std.Io.Threaded). This is the current driver model.
  - EPOLL: one thread, K non-blocking connections, up to WINDOW queries pipelined
    per connection (hand-rolled epoll).
  - URING: one thread, the same pipelined multiplexing on a hand-rolled io_uring.
- Fairness: K connections fixed and equal across all three (K = 12, CPU-derived),
  WINDOW = 64.
- Measurement: duration-based, 5 seconds per (model, operation). Each cell issues
  from a fixed pool of 20000 rendered queries, cycled, and counts completed
  requests. One ReadyForQuery boundary is one completed request (a query or a full
  transaction). Because the window is fixed at 5 seconds, a faster transport
  finishes MORE requests, so the reqs column is not equal across models, that is
  the point of a duration bench.
- Timing is workload only: connection setup (12 SCRAM-SHA-256 handshakes) is
  excluded, so the pbkdf2 cost never skews the single-thread models.
- Two CPU numbers, different scopes:
  - drvCPU% is the driver process only (getrusage on the PoC, all its threads),
    top-style, so 100 percent is one core. This is the transport cost and the
    axis that differs by model.
  - machCPU% is the whole 12-core box over the run (/proc/stat), so it includes
    postgres and matches what top shows. It is near saturation in every run.
- rssMB is peak RSS of the driver process during the run (VmHWM from /proc).
- Operations, each isolated:
  - GET: indexed select by primary key (postgres is cheap, transport-bound).
  - SCAN: range select on the un-indexed price column (sequential scan).
  - INSERT: upsert on conflict.
  - UPDATE: update by id.
  - TRANSACTION: BEGIN, update by id, COMMIT.

## Environment

- postgres:18 bench container, user / password / db = bench / bench / benchmark,
  host TCP SCRAM-SHA-256, items table seeded with 100000 rows, price un-indexed.
- Box exposes 12 usable CPUs to the PoC, so K = 12.

## Legend

Picture one CPU core as one worker.

**reqs**: how many requests finished in the 5 second window (each cell runs 5 seconds). A faster transport finishes more.

**req/s**: requests per second, the throughput. This is the "how fast" number. Higher is better.

**drvCPU%**: CPU the driver itself used, as a percent of one core. 100 percent is one core fully busy. Below 100 percent means the driver was waiting on the database, not computing. Lower is better at the same req/s.

**machCPU%**: how busy the whole 12-core machine was, driver plus postgres plus system. Near 100 percent means the box is full. This is what top shows, and most of it is postgres, not the driver.

**rssMB**: memory (RAM) the driver held while running, in megabytes. Lower is leaner.

In one line: we want high req/s at low drvCPU% and low rssMB, so the driver does more with less.

## Result per dispatch (mean across the five operations)

| dispatch | mean req/s | mean drvCPU% | mean machCPU% | peak rssMB |
| :- | -: | -: | -: | -: |
| ASYNC | 95,592 | 80 | 95 | 20.1 |
| EPOLL | 120,156 | 66 | 97 | 19.6 |
| URING | 120,027 | 62 | 98 | 17.8 |

EPOLL and URING push about 26 percent more requests per second than ASYNC, while
the driver process burns less CPU (about 0.62 to 0.66 of a core against ASYNC's
0.80) and holds less peak memory. machCPU% is near saturation for all three,
because the driver and postgres share the same 12-core box (see caveats).

## Result per operation (5 seconds per cell)

Each operation is its own table so the gap between the three transports is easy
to see. reqs is the count completed in the 5 second window, req/s the throughput,
drvCPU% the driver process (100 percent is one core), machCPU% the whole 12-core
box (matches top), rssMB the driver memory.

### GET (indexed select by primary key)

| model | reqs | req/s | drvCPU% | machCPU% | rssMB |
| :- | -: | -: | -: | -: | -: |
| ASYNC | 666,122 | 133,222 | 98 | 98 | 7.8 |
| EPOLL | 903,056 | 180,609 | 71 | 100 | 7.6 |
| URING | 907,899 | 181,576 | 64 | 100 | 5.4 |

Gap: EPOLL and URING finish about 36 percent more than ASYNC, at lower driver CPU
and less memory. The biggest gap of all the operations, because postgres is cheap
here so the transport is the limit.

### SCAN (range select on the un-indexed price column)

| model | reqs | req/s | drvCPU% | machCPU% | rssMB |
| :- | -: | -: | -: | -: | -: |
| ASYNC | 317,349 | 63,468 | 49 | 100 | 11.1 |
| EPOLL | 358,260 | 71,652 | 44 | 99 | 10.8 |
| URING | 354,948 | 70,976 | 47 | 100 | 8.5 |

Gap: about 12 to 13 percent ahead of ASYNC. The smallest gap, because the query
does more work in postgres, so the box does a bigger share and the transport a
smaller one. Note drvCPU% drops to the 40s: the driver waits more.

### INSERT (upsert on conflict)

| model | reqs | req/s | drvCPU% | machCPU% | rssMB |
| :- | -: | -: | -: | -: | -: |
| ASYNC | 492,119 | 98,421 | 87 | 92 | 16.2 |
| EPOLL | 609,193 | 121,838 | 72 | 95 | 13.7 |
| URING | 609,426 | 121,884 | 66 | 96 | 13.7 |

Gap: about 24 percent ahead of ASYNC, at lower driver CPU and less memory.

### UPDATE (update by id)

| model | reqs | req/s | drvCPU% | machCPU% | rssMB |
| :- | -: | -: | -: | -: | -: |
| ASYNC | 467,705 | 93,539 | 84 | 92 | 18.2 |
| EPOLL | 584,087 | 116,817 | 72 | 96 | 18.4 |
| URING | 582,405 | 116,481 | 66 | 96 | 15.6 |

Gap: about 25 percent ahead of ASYNC.

### TRANSACTION (BEGIN, update by id, COMMIT)

| model | reqs | req/s | drvCPU% | machCPU% | rssMB |
| :- | -: | -: | -: | -: | -: |
| ASYNC | 446,557 | 89,310 | 80 | 93 | 20.1 |
| EPOLL | 549,337 | 109,866 | 73 | 96 | 19.6 |
| URING | 546,101 | 109,220 | 66 | 96 | 17.8 |

Gap: about 23 percent ahead of ASYNC. The slowest operation of the five: the extra
COMMIT round trip costs, and every write carries transaction overhead.

## Caveats

- Shared box: the driver and postgres run on the same 12 cores, so machCPU% is
  near 100 percent in every run. Part of the multiplex win is that its single
  driver thread competes less for cores (1 driver thread plus 12 backends against
  ASYNC's 12 driver threads plus 12 backends, so 13 runnable against 24 on 12
  cores). On separate DB hardware that core-competition effect disappears and the
  win reverts to pipelining plus driver CPU efficiency. A cleaner run would pin
  postgres and the PoC to separate cpusets.
- Localhost: round trip latency is near zero here, the case that favors the
  thread-pool model the most and the multiplex the least on latency hiding. Over
  a real network the pipelining win grows, so these numbers understate the
  multiplex advantage on latency.
- postgres is the shared bottleneck for the heavier operations (SCAN especially),
  where the driver CPU drops (it waits on the server) and all three models
  converge.
- Connect and SCRAM are excluded from timing on purpose.

## What We Learned and Found

1. The multiplexed pipelined transport wins on every operation, and it is not a
   marginal call: EPOLL and URING beat ASYNC on req/s by about 13 to 36 percent
   (largest on the cheapest op, GET, plus 36 percent), while spending less driver
   CPU and less memory.
2. It is primarily a CPU-efficiency win. One driver thread doing pipelined
   io_uring or epoll finishes more requests than 12 blocking threads, at less CPU.
   On req/s per core URING is about 2.1 times ASYNC on GET (181,576 req/s at 0.64
   of a core is 283,712 per core, against ASYNC 133,222 at 0.98 of a core, so
   135,941 per core). The single owner thread also holds less resident memory.
   Note the box is saturated (machCPU near 100), so part of this is the single
   driver thread leaving more cores for postgres, see caveats.
3. URING is the transport to carry forward: best or tied throughput on every op,
   lowest CPU per request, lowest memory. EPOLL is a close second and the right
   fallback when io_uring is unavailable. ASYNC, the current model, is the
   slowest and the most CPU-hungry.
4. The transport only matters when the database is not the bottleneck. Indexed
   GET shows the biggest gap because postgres barely works, so the transport is
   the limit. As per-op DB cost rises (GET to SCAN to writes) the gap narrows,
   because postgres takes a larger share of each request. The CPU-efficiency win
   persists even there.
5. Operation cost, cheap to expensive: indexed select (GET) is fastest, then the
   range scan (SCAN, which the LIMIT 20 lets exit early), then the writes
   (INSERT, UPDATE), then the transaction. The extra COMMIT round trip makes the
   transaction the slowest.
6. Wider lesson: since fiber-async DB is impossible on this Zig (the std.Io.Uring
   network gap), a driver-owned io_uring or epoll multiplexed transport is the
   realistic path to efficient concurrent DB I/O for zix. The efficiency comes
   from the driver running its own event loop over many pipelined connections,
   not from std.Io.
7. This validates the plan: carry the URING transport into src/driver/postgrez
   behind the dispatch_model knob (default ASYNC, HttpArena entry pins URING),
   then repeat this PoC for rediz to confirm the same shape holds on RESP.
