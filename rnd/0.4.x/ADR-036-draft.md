# ADR-036 (accepted record)

Folded into `docs/adr-en.md` (before the `###### end of adr` footer) and mirrored into `docs/adr-id.md` as the accepted ADR-036, the multi-engine as-shipped version. Kept here as the rnd record alongside the PoC (`rnd/0.4.x/server_response_cache.zig`). No external benchmark framework is named, per project rule.

---

## ADR-036: Opt-in per-worker ResponseCache (shared `utils`) across `zix.Http1`, `zix.Http`, and `zix.Grpc`, plus WebSocket build-once broadcast

**Status:** Accepted

**Context:** A handler re-runs and re-serializes its response on every request. For repeated idempotent calls whose response is expensive to build, that work dominates the userspace cost, while the kernel path is shared by every approach. The engine already proves a precompute-then-write pattern elsewhere (comptime gRPC reply blocks, the cached SETTINGS frame, the thread-local cached Date). A PoC (`rnd/0.4.x/server_response_cache.zig`) measured whether extending that to user handlers, as a per-key precomputed response cache, pays off. Loopback, AMD Ryzen 5 5600H (12 logical cores), zig 0.16.0, wrk 4.2.0, threads 6, duration 5s, c512 and c4096, twice each, avg Requests/sec:

| Response | c512 nocache -> cache | c4096 nocache -> cache |
| :- | :- | :- |
| trivial (13 B) | 614,551 -> 611,758 (-0.5%) | 453,328 -> 449,565 (-0.8%) |
| built (~32 KiB JSON) | 171,821 -> 230,844 (+34.4%) | 137,516 -> 163,116 (+18.6%) |
| file-backed (~32 KiB) | 209,590 -> 225,058 (+7.4%) | 158,803 -> 163,997 (+3.3%) |

A body-size sweep (c512) puts the crossover near 4 KiB: the delta stays inside run-to-run noise below ~2 KiB (256 B +0.2%, 1 KiB +1.9%, 2 KiB +3.7%), then jumps at 4 KiB (+12.6%) and climbs to +37% at 64 KiB. The file-backed case wins only modestly because the OS page cache already serves the file cheaply.

**Decision:** Add an opt-in, per-worker ResponseCache as a shared module, off by default and scoped to compute-heavy responses, and wire it into `zix.Http1`, `zix.Http`, and `zix.Grpc`. Adopt the same build-once principle for WebSocket broadcast.

- Shared structure in `src/utils/response_cache.zig`: a structure-of-arrays slab (`keys: []u64` open addressing with 0 as the empty sentinel, `meta: []Meta` of `insert_tick_ms` / `len` / `ttl_ms`, and one flat payload slab). Slot count is a power of two indexed by mask. An arena allocates the slab once at init and frees it whole at deinit. A churning cache reuses fixed slots in place, so the arena never grows. Lazy on-access TTL: an entry expires exactly at `insert_tick_ms + ttl_ms`, so `ttl_ms = 0` is never fresh. Expired slots are reused in place by the next store, never zeroed, since zeroing would truncate an open-addressing probe chain. No timer thread is introduced.
- One cache per worker, never shared, never locked (lock-free by ownership). The invariant holds only when one zix-owned thread installs the cache (allocate, set, free on exit) and is the sole thread that touches it. Under `.EPOLL` shared-nothing each worker is exactly that, so the cache is installed there. `.POOL` is also zix-owned and could be wired safely, but each pool thread would hold an independent cache (lower hit rate, N times the memory), so it is deferred. `.ASYNC` and `.MIXED` run handlers on the `std.Io` executor pool that zix does not own, where a task is not pinned to one thread, so a shared cache would need locks and break the lock-free design. In this release the cache is installed under `.EPOLL` only, the other models leave it uninstalled and the API degrades to a plain send.
- HTTP (`zix.Http1`, `zix.Http`): the key is method, path, and query, and the cached value is the full serialized HTTP response, written verbatim on a hit. `zix.Http1` exposes the explicit pair `cacheLookup` / `cacheStore` plus the fused `writeWithCache`. `zix.Http` exposes `res.serveCached` (lookup then write verbatim) and `res.sendCached` (serialize, write, store), producing bytes identical to a plain `send`.
- gRPC (`zix.Grpc`, unary): the key is the path plus the request body, and the cached value is the response message, not the framed reply, because HEADERS are HPACK and stream-id stateful. On a hit the message is re-framed for the current stream so HPACK and stream id stay correct. `ctx.serveCached` replays the stored message and finishes with OK, `ctx.sendCached` sends and stores.
- WebSocket broadcast adopts the same build-once principle rather than a TTL cache: `zix.Http1.WebSocket.broadcast(conns, opcode, payload)` serializes the frame once and fans the same bytes out to every fd in a caller-maintained room, skipping a failed write to a dead peer. This is the WS-shaped form of the follow-up, not a keyed cache.
- Config is flat and the field names are identical across `Http1ServerConfig`, `HttpServerConfig`, and `GrpcServerConfig`: `response_cache: bool = false`, `cache_max_entries: u32` (rounded down to a power of two), `cache_max_value_bytes: u32` (responses past it bypass, lean default around 16 KiB), `cache_ttl_ms: u32`, and `cache_max_total_bytes: usize = 0` (optional ceiling validated against `entries * value_bytes`).

**Consequences:**
- Clear win for expensive serialization past the ~4 KiB crossover (+12.6% at 4 KiB, rising to +37% at 64 KiB, c512) and zero regression below it, which is why opt-in is mandatory rather than a default.
- Per-worker memory is `cache_max_entries * cache_max_value_bytes`, multiplied by the worker count. Bounded and predictable, the deliberate trade for lock-free per-worker ownership.
- Deliberately not aimed at file-backed or static responses: the OS page cache already serves those cheaply, so `sendfile` / `splice` is the better lever there.
- Correctness rests on opt-in: the engine never auto-caches a handler's output. The handler decides cacheability and TTL. A dynamic or database-backed response sets a short `cache_ttl_ms` (accepting that much staleness) or does not cache and writes directly. The HTTP key covers method, path, and query only, so a response that varies on a header or cookie must not be cached.
- The cache structure is engine-agnostic in `src/utils`, so the per-engine glue (a thread-local cache plus key derivation) is the only protocol-specific part.
