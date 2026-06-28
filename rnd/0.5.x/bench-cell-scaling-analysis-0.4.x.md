# Bench cell analysis: c512 to c4096 scaling, and json lever-sensitivity (0.4.x)

Analysis of two patterns seen across the A2 URING idle-pool runs on the
12-load-thread isolate bench (zix_http_uring, 6 server workers on a 12-core box):
why throughput degrades from c512 to c4096 across the cell types, and why json is
the cell that moves with every idle-pool adjustment. Per-cell numbers in
`a2-uring-4way-results-0.4.x.md`.

Note: the box has no kernel cycle counters here (paranoid=2) and ~2 to 3% whole-run
variance, so the mechanisms below are inferred from cell parameters, topology, and
the four-way deltas, not measured with perf counters.

## 1. c512 to c4096 degradation (baseline, pipelined, limited-conn)

Magnitudes (cold-tail run, same shape in all four approaches):

| Cell | c512 | c4096 | Δ |
| :- | -: | -: | -: |
| baseline | 557,005 | 436,914 | -21.6% |
| pipelined | 6,837,161 | 4,924,009 | -28.0% |
| limited-conn | 353,250 | 326,997 | -7.4% |

This is connection-count scaling on a fixed 6 server cores, not a per-cell defect.
The server holds ~240 to 265% CPU at both conn counts, so it never saturates its 6
cores: the box is loadgen and loopback bound, and the drop is per-connection
overhead rising, not the server running out of CPU. Shared root causes:

1. **Working set outgrows cache.** 512 conns / 6 workers is about 85 per worker,
   4096 is about 683 per worker. Each live connection touches a slot plus a 16KiB
   recv buf plus a 16KiB send buf per request. At ~85/worker that hot set fits in
   L2/LLC, at ~683/worker (about 44MiB of buffers per worker) it spills, so every
   request pays more memory latency. On loopback (about 85% kernel-bound) this
   per-connection cache footprint is the dominant server-side cost.
2. **Kernel per-fd overhead grows.** More fds in the epoll ready list and more CQEs
   per drain, larger socket-table and TCP bookkeeping, more loopback segments.
3. **Loadgen is more contended.** 12 gcannon threads on 6 loadgen CPUs, and at
   c4096 that is 341 conns/thread versus 43/thread at c512, so the client drives
   less efficiently. Part of the degradation is the harness, not zix.

Why the per-cell magnitudes differ, by how cache/bandwidth-bound each cell is
versus syscall-bound:

| Cell | Δ | why |
| :- | -: | :- |
| pipelined | -28% | 16 requests in flight per conn, biggest in-flight volume and coalescing-sink working set, maximal cache and bandwidth pressure |
| baseline | -22% | pure keep-alive, pays the cache-footprint cost without the pipeline multiplier |
| limited-conn | -7% | already reconnect and syscall bound (accept + close dominate), so the cache-footprint term is a smaller fraction of an already-expensive request |

Answer: rising concurrency past what 6 cores keep hot, plus a more-contended
loadgen, so per-request cost climbs, and each cell shows it in proportion to how
cache/bandwidth-bound (rather than syscall-bound) it already is.

## 2. Why json moves with every idle-pool adjustment

json across the four approaches (it is the memory-heaviest cell of all):

| | pre-A2 | flat-256 | adaptive | cold-tail |
| :- | -: | -: | -: | -: |
| json RPS | 305,192 | 292,429 | 295,357 | 300,008 |
| json Mem | 180MiB | 135MiB | 149MiB | 128MiB |

json is c4096, 25 req/conn, 7 templates, reconnects about 58k, and about 1GB/s
bandwidth (roughly 3.4KB per response, about 30x the baseline payload). That makes
it both:

- **The heaviest cell** (180MiB): 4096 live conns times 32KiB of buffers is about
  128MiB of working set alone, plus the idle pool fed by its 58k reconnects, plus
  the most response data in flight. So it has by far the most idle-pool buffer to
  reclaim, which is why its memory swings the most of any cell (180 to 128MiB, the
  biggest absolute drop) and tracks each lever directly.
- **The most bandwidth-bound cell**, so it is the most sensitive to anything that
  perturbs memory locality. This is where the RPS differences come from: flat-256
  and adaptive madvise the released (most-recently-used) connection on the churn
  path, so each of json's 58k reconnects risks reusing a just-evicted buffer and
  faulting its pages back in, and json (already bandwidth-stressed) pays that
  re-fault harder than a low-bandwidth cell. cold-tail evicts the LRU tail instead,
  never the buffer the reconnect grabs next, so json recovers to 300k while still
  reclaiming the most memory.

Where it comes from: the per-connection send buffer grows to multi-MiB only when a
single staged response exceeds the 16KiB base, and json's ~3.4KB responses fit
inside it, so the send_buf shrink half of A2 is largely inert for json. The json
effect is the idle-pool reclaim interacting with json's reconnect churn and
bandwidth sensitivity, not the shrink. json is also the noisiest cell on this box,
so a slice of the swing is variance, which is why it is the cell to watch on the
64-core gate.

Net: c512 to c4096 degradation is generic concurrency scaling weighted by how
cache/bandwidth-bound each cell is. json is the lever-sensitive cell because it is
at once the heaviest (most to reclaim) and the most bandwidth-bound (most hurt by a
mis-placed reclaim), the exact pair of properties cold-tail was built to satisfy
together.
