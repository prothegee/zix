# ADR-036 draft (scratch, do not commit)

Draft to fold into `docs/adr-en.md` (before the `###### end of adr` footer) and mirror into `docs/adr-id.md` once the cache lands in `src/tcp/http1/`. Status stays Proposed until then. No external benchmark framework is named, per project rule.

---

## ADR-036: `zix.Http1` opt-in ResponseCache, per-worker precomputed-response slab

**Status:** Proposed (PoC measured 2026-06-15, not yet landed in `src/`)

**Context:** A `zix.Http1` handler re-runs and re-serializes its response on every request. For repeated idempotent GETs whose response is expensive to build, that serialization dominates the userspace cost, while the kernel path is shared by every approach. The engine already proves a precompute-then-write pattern elsewhere (comptime gRPC reply blocks, the cached SETTINGS frame, the thread-local cached Date). A PoC (`rnd/0.4.x/server_response_cache.zig`) measured whether extending that to user handlers, as a per-key precomputed response cache, pays off. Loopback, AMD Ryzen 5 5600H (12 logical cores), zig 0.16.0, wrk 4.2.0, threads 6, duration 5s, c512 and c4096, twice each, avg Requests/sec:

| Response | c512 nocache -> cache | c4096 nocache -> cache |
| :- | :- | :- |
| trivial (13 B) | 614,551 -> 611,758 (-0.5%) | 453,328 -> 449,565 (-0.8%) |
| built (~32 KiB JSON) | 171,821 -> 230,844 (+34.4%) | 137,516 -> 163,116 (+18.6%) |
| file-backed (~32 KiB) | 209,590 -> 225,058 (+7.4%) | 158,803 -> 163,997 (+3.3%) |

A body-size sweep (c512) puts the crossover near 4 KiB: the delta stays inside run-to-run noise below ~2 KiB (256 B +0.2%, 1 KiB +1.9%, 2 KiB +3.7%), then jumps at 4 KiB (+12.6%) and climbs to +37% at 64 KiB. The file-backed case wins only modestly because the OS page cache already serves the file cheaply (`/static-nocache` at 210k already beats the built `/heavy-nocache` at 172k).

**Decision:** Add an opt-in, per-worker ResponseCache to `zix.Http1`, scoped to compute-heavy serialization and off by default.

- Structure-of-arrays slab: `keys: []u64` (open addressing, 0 is the empty sentinel), `meta: []Meta` (`insert_tick_ms`, `len`, `ttl_ms`), and one flat payload slab. Slot count is a power of two, indexed by mask.
- One cache per worker, never shared, and never locked (lock-free by ownership). The invariant holds only when one zix-owned thread installs the cache and is the sole thread that touches it. Under `.EPOLL` shared-nothing each worker is exactly that: a zix-owned thread with a clean spawn-to-exit lifecycle, so the cache is installed there. `.POOL` is also zix-owned and could be wired safely, but each pool thread would hold an independent cache (lower hit rate, N times the memory), so it is deferred. `.ASYNC` / `.MIXED` run handlers on the `std.Io` executor pool that zix does not own, where a task is not pinned to one thread, so a shared cache would need locks: out of scope for this lock-free design. In this release the cache is installed under `.EPOLL` only, the other models leave it uninstalled and the API degrades to a plain send.
- An arena allocates the slab once at init and frees it whole at deinit. A churning cache reuses fixed slots in place, so the arena never grows.
- Key is `hash(method, path, vary)` (the PoC keys on the query for its parametrized routes). Only `GET` and `HEAD` are cacheable.
- Lazy on-access TTL: an entry expires exactly at `insert_tick_ms + ttl_ms`, so `ttl_ms = 0` is never fresh (a per-store skip). Expired slots are reused in place by the next `store`, never zeroed, since zeroing would truncate an open-addressing probe chain. No timer thread is introduced (`zix.Http1` has none by design).
- API: an explicit pair (`cacheLookup`, `cacheStore`) plus a fused `writeWithCache` (lookup, on-miss produce, store, write). The handler decides cacheability and TTL. With the master switch off the lookup is a no-op and output is byte-identical to today.
- Config (flat, names consistent with `max_recv_buf` / `kernel_backlog`): `response_cache: bool = false`, `cache_max_entries: u32` (power of two), `cache_max_value_bytes: u32` (responses past it bypass, lean default around 16 KiB so only past-crossover responses cache), `cache_ttl_ms: u32`, `cache_max_total_bytes: usize = 0` (optional ceiling validated against `entries * value_bytes`). Request-in size stays validated by `max_recv_buf`, response-out by `cache_max_value_bytes`.
- On a hit the cached slice is sent under `TCP_CORK` in a single `writev`.

**Consequences:**
- Clear win for expensive serialization past the ~4 KiB crossover (+12.6% at 4 KiB, rising to +37% at 64 KiB, c512) and zero regression below it, which is why opt-in is mandatory rather than a default.
- Per-worker memory is `cache_max_entries * cache_max_value_bytes`, multiplied by the worker count. This is bounded and predictable, the deliberate trade for lock-free per-worker ownership.
- Deliberately not aimed at file-backed or static responses: the OS page cache already serves those cheaply (+7% only), so `sendfile` / `splice` is the better lever there. That stays out of scope for this ADR.
- Correctness rests on opt-in: the framework never auto-caches a handler's output. A dynamic or database-backed response either sets a short `ttl_ms` (accepting that much staleness) or does not cache and writes directly.
- Follow-ups tracked separately: `zix.Http`, WebSocket broadcast (build one frame, fan out to N clients), and gRPC unary identical replies.

---
