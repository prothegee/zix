# rediz Driver Dispatch Transport PoC: Summary Record

## Intention and Request

Same question as the postgrez PoC, on the redis side: with fiber-async blocked by
the std.Io.Uring network gap, can a driver-owned multiplexed pipelined transport
(EPOLL / URING) beat the current thread-pool blocking model (ASYNC) on raw
driver-to-Redis throughput. Measured at the driver, no HTTP in the loop, std only,
no driver import.

The redis role in the HttpArena entry is a write-behind mirror: on crud writes and
cache fills or invalidations the entry mirrors to redis, and the reply is never
awaited. So the win from a better transport is mostly CPU efficiency: push the same
mirror work with less CPU, leaving more cores for the HTTP hot path.

Same rules as postgrez: three models (ASYNC, EPOLL, URING) only, driver init gains
a dispatch_model knob (default ASYNC, zix_uring_http1_3b pins URING), K connections
fixed and equal, duration-based measurement, record CPU and memory.

## Methodology

- Models:
  - ASYNC: K blocking connections, one round trip in flight each, run on K threads.
  - EPOLL: one thread, K non-blocking connections, up to WINDOW commands pipelined
    per connection (hand-rolled epoll).
  - URING: one thread, the same pipelined multiplexing on a hand-rolled io_uring.
- Fairness: K connections fixed and equal across all three (K = 12), WINDOW = 64.
- Measurement: duration-based, 5 seconds per (model, operation), counting completed
  replies. One RESP reply is one completed request.
- Timing is workload only: connection setup is excluded.
- Two CPU numbers: drvCPU% is the driver process only (top-style, 100 percent is
  one core). machCPU% is the whole 12-core box (matches top), which here includes
  redis.
- Operations, each isolated:
  - SET: write the item JSON under item:id (the write-behind mirror fill).
  - GET: read item:id back.
  - DEL: delete item:id (the mirror invalidation).

## Environment

- redis:7-alpine, protected-mode off, no auth, port 6379, maxmemory 512mb,
  allkeys-lru, one io thread (redis is single-threaded for command execution).
- Box exposes 12 usable CPUs to the PoC, so K = 12.

## Legend

Picture one CPU core as one worker.

**reqs**: how many requests finished in the 5 second window (each cell runs 5 seconds). A faster transport finishes more.

**req/s**: requests per second, the throughput. This is the "how fast" number. Higher is better.

**drvCPU%**: CPU the driver itself used, as a percent of one core. 100 percent is one core fully busy. Below 100 percent means the driver was waiting on redis, not computing. Lower is better at the same req/s.

**machCPU%**: how busy the whole 12-core machine was, driver plus redis plus system. Here it stays low, because redis is single-threaded and cannot use more than about one core.

**rssMB**: memory (RAM) the driver held while running, in megabytes. Lower is leaner.

## Result per dispatch (mean across the three operations)

| dispatch | mean req/s | mean drvCPU% | mean machCPU% | peak rssMB |
| :- | -: | -: | -: | -: |
| ASYNC | 172,349 | 103 | 22 | 10.5 |
| EPOLL | 2,119,555 | 63 | 16 | 9.2 |
| URING | 1,998,075 | 55 | 15 | 8.5 |

EPOLL and URING push about 12 times the requests per second of ASYNC, while
burning less CPU and less memory. This is a far larger gap than postgres, and the
reason is the server speed (see What We Learned).

## Result per operation (5 seconds per cell)

Each operation is its own table so the gap between the three transports is easy to
see. reqs is the count completed in the 5 second window, req/s the throughput,
drvCPU% the driver process (100 percent is one core), machCPU% the whole box,
rssMB the driver memory.

### SET (write-behind mirror fill of the item JSON)

| model | reqs | req/s | drvCPU% | machCPU% | rssMB |
| :- | -: | -: | -: | -: | -: |
| ASYNC | 827,737 | 165,545 | 99 | 22 | 8.8 |
| EPOLL | 8,170,368 | 1,634,061 | 45 | 15 | 6.9 |
| URING | 8,272,704 | 1,654,537 | 44 | 14 | 6.9 |

Gap: EPOLL and URING finish about 10 times more than ASYNC, at less than half the
driver CPU.

### GET (read item back)

| model | reqs | req/s | drvCPU% | machCPU% | rssMB |
| :- | -: | -: | -: | -: | -: |
| ASYNC | 875,326 | 175,063 | 105 | 22 | 10.0 |
| EPOLL | 10,912,192 | 2,182,401 | 84 | 18 | 8.6 |
| URING | 8,968,576 | 1,793,704 | 66 | 15 | 7.8 |

Gap: about 10 to 12 times ASYNC. GET carries a larger reply (the item JSON), so it
costs more driver CPU than SET or DEL, and EPOLL edges URING here.

### DEL (mirror invalidation)

| model | reqs | req/s | drvCPU% | machCPU% | rssMB |
| :- | -: | -: | -: | -: | -: |
| ASYNC | 882,209 | 176,440 | 105 | 22 | 10.5 |
| EPOLL | 12,711,104 | 2,542,203 | 60 | 15 | 9.2 |
| URING | 12,730,240 | 2,545,985 | 56 | 15 | 8.5 |

Gap: about 14 times ASYNC, the biggest of the three, because the reply is a tiny
integer so the transport is almost the entire cost.

## Caveats

- Redis is single-threaded, so machCPU% stays low (15 to 22 percent) and the box is
  never saturated. Unlike postgres, there is no core-competition confound here, so
  this is a clean transport comparison and the multiplex win is pure pipelining.
- The throughput ceiling is redis itself (about 1.6 to 2.5 million req/s on one
  thread). EPOLL and URING reach it, ASYNC does not get close.
- Localhost, so round trip latency is near zero. On a real network the pipelining
  win would be larger still, since ASYNC pays a full network round trip per request.
- Connection setup is excluded from timing on purpose.

## What We Learned and Found

1. On redis the transport decides almost everything: EPOLL and URING beat ASYNC by
   about 10 to 14 times on req/s, while using less CPU and less memory. The gap is
   far bigger than postgres.
2. The reason is server speed. Redis answers in microseconds, so the per-request
   round trip and syscall overhead dominates. ASYNC sends one request per
   connection and waits, which starves the fast server (its 12 blocking
   connections leave redis mostly idle). EPOLL and URING pipeline up to 64 deep per
   connection, keeping redis continuously fed, so they saturate its single thread.
3. This brackets the postgrez result nicely. When the server is the bottleneck
   (heavy postgres queries) the transport gap is small. When the server is fast
   (redis) the transport gap is enormous. The multiplex transport is never worse
   and is dramatically better exactly where the server can keep up.
4. URING and EPOLL are close. EPOLL is slightly ahead on GET (the larger reply),
   URING is leanest on CPU and memory. Either is a huge win over ASYNC.
5. For the entry's use, redis is a write-behind mirror (fire-and-forget), so the
   practical win is CPU: the same mirror traffic at less than half the driver CPU,
   or far more mirror headroom for the same CPU. Both free cores for the HTTP hot
   path.
6. Confirms the plan: carry the URING transport into src/driver/rediz behind the
   dispatch_model knob (default ASYNC, zix_uring_http1_3b pins URING). RESP has no
   auth, so the port is even simpler than postgrez.
