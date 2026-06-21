# A2 URING idle-pool variants (cross-reference record)

Full-server snapshots of the four idle-pool approaches tried for the A2 lever
(URING http1 idle-pool memory reclaim). Each file is a complete, self-consistent
`zix.Http1` server in the MONOLITHIC layout, captured before the ADR-043 dispatch
split. They are inert reference snapshots, not built code (nothing imports them).

The four differ ONLY in the `.URING` idle-pool code (`releaseConn` / `acquireConn`
/ `evictColdTail` plus the pool struct fields and the floor constant). Everything
else is byte-identical across the four.

| File | Approach | Idle-pool behaviour on close |
| :- | :- | :- |
| server.1.pre_A2.zig | pre-A2 | unbounded pool, no reclaim (`releaseConn` parks the conn, buffers stay resident) |
| server.2.flat_256.zig | flat-256 | flat cap `free_cap = 256`, madvise the RELEASED conn past the cap + shrink grown send_buf |
| server.3.adaptive.zig | adaptive | cap `idleCap = max(live_count, 64)`, still madvise the released conn |
| server.4.cold_tail.zig | cold-tail (LANDED) | warm MRU-head / LRU-tail pool + cold stack, evict and madvise the LRU TAIL, not the released conn |

## How to compare

The full files diff cleanly to the idle-pool delta, for example:

```
diff a2-variants/server.1.pre_A2.zig a2-variants/server.4.cold_tail.zig
```

shows only the URING pool change (and the matching tests). The canonical
post-split form of the winner (cold-tail) now lives at
`src/tcp/http1/dispatch/uring.zig`.

## Outcome (why cold-tail won)

The lesson was which connection to reclaim, not the cap value: the pool is LIFO,
so the head is hot and the tail is cold. flat-256 and adaptive regressed the churn
cell (limited-conn) by reclaiming the just-released, most-recently-used conn
(4096c -6.4%, 512c -12.4%). cold-tail reclaims the least-recently-used tail
instead, bringing churn back into the noise (512c -1.1%, 4096c -0.7%) AND shedding
the most memory (steady anon 22.2 to 13.5MiB).

## Cross-references

- `rnd/0.5.x/a2-uring-4way-results-0.4.x.md`: per-cell RPS + memory for all four.
- `rnd/0.5.x/smaps-anon-breakdown-0.4.x.md`: the smaps anon split that motivated A2.
- `rnd/0.5.x/bench-cell-scaling-analysis-0.4.x.md`: c512 to c4096 + json sensitivity.
- `rnd/0.5.x/ADR-043-draft.md`: the dispatch split that relocated these snapshots.
