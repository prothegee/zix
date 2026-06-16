# io_uring Dispatch Model (.URING)

Local design note. Proposed issue for the 0.4.x-rc2 cycle. Maps to the `enhancement`
issue template (new `.URING` dispatch model). The core question this proposal settles is
which io_uring foundation to build on: the default posix io_uring (`std.Io.Uring`) or the
raw linux io_uring syscall surface.

## Status

Ready to start on current Zig (0.16.x). PoC complete and measured under `rnd/0.4.x/`
(`server_hello_uring.zig`, `server_hello_epoll.zig`, `client_hello.zig`). Decision pending
an ADR. See the core decision and benchmark data below.

---

## Issue: io_uring dispatch model (.URING)

**Component:** server (http1, http, grpc), engine-wide.

**Files:**
- `src/tcp/http1/server.zig`, `src/tcp/http/server.zig`, `src/tcp/http2/grpc/server.zig` (per-engine dispatch branch)
- `src/*/config.zig` (`DispatchModel` enum, add `.URING`)
- new `src/tcp/io_uring/` (shared ring runtime, if approach B is chosen)

**Status:** Ready to start on current Zig (0.16.x). Implementation note, not a blocker:
`std.posix.socket`/`bind`/`listen`/`close` were removed in 0.16.x, so the listener setup
uses raw `linux.*` (or `std.Io.net`) directly. Approach B depends only on the kernel
`io_uring` ABI, so the moving std io_uring surface does not gate it. PoC and benchmark
baseline already captured under `rnd/0.4.x/` (`server_hello_uring.zig`,
`server_hello_epoll.zig`, `client_hello.zig`).

**Problem Statement:**
zix currently offers four readiness-model dispatch options (`.POOL`, `.ASYNC`, `.MIXED`,
`.EPOLL`). All of them are level-triggered or thread-per-task models built on the
`epoll` readiness interface. Under high connection counts the `.EPOLL` path is
shared-nothing and competitive on raw loopback throughput, but profiling shows it spends
a large share of userspace cycles on syscall transitions (one `recv`, one `send`, and
the surrounding `epoll_wait` bookkeeping per ready event). A completion-based io_uring
dispatch removes most of those transitions by batching submissions and reaping
completions, which frees CPU headroom for the actual request work.

The open question for this issue is not whether to add io_uring (the PoC already proves
the gain). It is which foundation to build the `.URING` dispatch model on. This decision
drives the whole port, so it must be settled before any `src/` work begins.

**Core decision: which io_uring foundation**

Two approaches, mutually exclusive at the dispatch layer.

| Aspect | A. std posix io_uring (`std.Io.Uring`) | B. raw linux io_uring (`linux.io_uring_*`) |
| :- | :- | :- |
| Source | std-provided fiber-based `Evented` backend (drop-in `std.Io`) | hand-rolled per-worker rings on raw syscalls |
| Coupling | rides the existing `io: std.Io` config field, one code path for all backends | new `.URING`-only runtime, separate from the `std.Io` abstraction |
| Control | submission/reaping owned by std, opaque to zix | full control: ring flags, buffer rings, multishot ops, batching policy |
| Features used | whatever std exposes through `std.Io` | `SINGLE_ISSUER` + `COOP_TASKRUN`, multishot accept, multishot recv + provided buffer ring (`BufferGroup`), one coalesced send per readable completion, gen-tagged `user_data` against fd reuse, deferred close while a send is in flight |
| Shared-nothing | depends on std executor topology | native: one ring per worker, no cross-thread handoff, matches the `.EPOLL` shared-nothing design |
| Stability risk | tracks std internals (the io_uring surface moved across 0.16.x) | depends only on the stable kernel `io_uring` ABI, not on std internals |
| Maintenance | low (std maintains the engine) | higher (zix owns the ring lifecycle and edge cases) |

**Recommendation: B (raw linux io_uring), startable on current Zig (0.16.x).**

Reasoning:
1. The measured win comes from features std does not currently expose through `std.Io`:
   multishot accept/recv and provided buffer rings (incremental consumption). Approach A
   cannot reach the PoC numbers without those.
2. The shared-nothing per-worker ring model (one ring, one listener via `SO_REUSEPORT`,
   no shared accept queue) is already the design the `.EPOLL` path uses. Approach B keeps
   that topology intact. Approach A reintroduces a std-owned executor topology that zix
   does not control, the same ownership problem that blocks the response cache on
   `.ASYNC`/`.MIXED` (see the cache awareness note in `README`).
3. Approach B depends only on the stable kernel ABI, not on std internals, so the moving
   std io_uring surface does not gate it and the work can start on current Zig (0.16.x).
   Approach A would couple the schedule to std io_uring stabilizing.

Approach A stays the fallback if the raw-syscall surface proves too costly to maintain,
or if a future `std.Io` exposes multishot and provided buffers as first-class operations.

**Benchmark / Profiling Data (PoC, loopback, ReleaseFast):**

Two zix builds only (epoll engine vs the hand-rolled uring PoC), no external references.

| Metric | zix-epoll | zix-uring (PoC) |
| :- | :- | :- |
| p1 cycles/req (userspace) | 1627 | 818 |
| p1 L1-miss/req | 73.5 | 22.9 |
| p16 cycles/req (userspace) | 710 | 240 |
| p16 server CPU (t4 c128, 10s) | ~45.1s | ~37.25s |

Reads:
- At pipeline depth 1 io_uring roughly halves userspace cycles per request: the epoll path
  pays syscall transitions that pollute caches, the ring path keeps userspace hot.
- At pipeline depth 16 the epoll engine burns about 21 percent more CPU at equal
  throughput. Peak loopback throughput is parity at depth 1 (kernel and client bound), so
  the io_uring gain is efficiency headroom, not peak req/s.
- Independent of io_uring, two engine wins surfaced in the PoC and have already landed in
  `zix.Http1` on `main` because they cut the epoll cost too: lazy `parseHead` (drop the
  fixed header array, scan headers on demand) cut engine userspace cost about 33 percent at
  depth 16, and an `EPOLLOUT` re-arm removed a head-of-line write stall on the `.EPOLL` path
  in `src/tcp/http1/server.zig` (a flush hitting `EAGAIN` is now staged in
  `conn.write_pending` and `EPOLLOUT` is armed, instead of blocking the worker on
  `poll(POLLOUT, -1)`). The same two wins are still pending for `zix.Http`, which keeps the
  fixed header array in `src/tcp/http/parser.zig`.

**Implementation order:** `zix.Http1` first, then WebSocket, then `zix.Grpc`, then `zix.Http`.

1. `zix.Http1`: the simplest request/response shape and the smallest engine, so it
   proves the ring core (per-worker ring, multishot accept, the per-connection slot model,
   batched completion drain) before any protocol complexity is layered on.
2. WebSocket: builds on the Http1 upgrade path and long-lived connections. The engine
   already coalesces a readable burst into one write through the `SendSink`, which maps
   directly onto one batched ring submission per readable completion, so it is the natural
   second step once the Http1 ring core exists.
3. `zix.Grpc`: hardest, because HTTP/2 framing, HPACK, and stream multiplexing are
   stateful, so it lands only after the ring core and the send-batching are proven.
4. `zix.Http`: shares the Http1 engine internals, so it reuses the proven Http1 ring core
   and is the cheapest to finish last.

**Design constraints to honor (settled before coding):**
- Thread-per-core, not process-per-core: keep zix's existing `.EPOLL` worker model
  (one thread, one `SO_REUSEPORT` listener, one ring) so the per-worker route tables and
  response cache stay in-process. A fork-per-core model would lose that sharing.
- Buffer strategy is a staged decision: start with a fixed per-connection recv buffer plus
  a plain `recv` SQE (simplest, already enough to be competitive), and only move to a
  registered provided-buffer ring or multishot recv if the measured syscall savings justify
  the harder buffer lifecycle.
- Per-connection state via an fd-indexed slot table (direct index, no hashmap), guarded
  against the close-versus-recv completion race, with a generation tag in `user_data` to
  harden against fd reuse.
- Ring init needs no special flags to be correct: `SINGLE_ISSUER` and `COOP_TASKRUN` are
  optimizations to add and measure, not prerequisites.
- Build on the stable low-level ring API (`std.os.linux.IoUring`), which is present on the
  current stable Zig, not the fiber-based `std.Io.Uring`.

**Optimization levers (the techniques the evidence and bets below draw from):**
Grouped by class. zix already proves several of these on the `.EPOLL` path, and the ring port carries them over and adds the io_uring-specific ones. No external engine is named here, per project rule.

- Comptime:
  - Route dispatch via a perfect-hash table (already in `zix.Http1`), and an op-to-handler jump from a small comptime enum on the completion path.
  - Response templates: build the invariant header prefix at comptime and write only the variable bytes (the Content-Length digits and the body), so the constant bytes never hit the ALU again.
  - `user_data` codec: pack op, fd, and generation with comptime shift and mask constants for a branchless encode and decode.
  - Framing masks: the masked 8-byte header compares (content-length, connection, transfer-encoding, expect) with precomputed needles, already used by `parseHeadAt`.
- Zero-copy:
  - Parse in place: recv straight into the per-connection slot buffer and keep header slices pointing into it, never copy into a parsed-head array (the lazy `parseHead` win, already measured -33% at p16).
  - Zero-copy send (`SEND_ZC`) for large responses, size-gated.
  - Registered (fixed) send buffers so a response-cache hit sends by buffer index and skips per-op page pinning, strongest when paired with the precomputed cache payload.
  - Scatter-gather send (iovec) for header plus body, with no concatenation.
- L1 and data layout:
  - Hot and cold split the per-connection slot to one cache line (hot: state, buffer pointer and length, parse cursor; cold: timestamps and rare config in a separate array).
  - Structure-of-arrays for anything the batch loop streams (the response-cache slab is already SoA: a dense `keys: []u64`, 8 per cache line, so a linear probe stays in-line).
  - Batch the completion drain into a stack array and iterate linearly, branchless per entry where possible.
  - Per-worker structs aligned and padded to a cache line so two workers never share a line (shared-nothing already avoids cross-core bouncing).
- Kernel-side caching (registrations plus precomputed bytes):
  - Registered or direct files so accepted fds live in a fixed table and each op skips the fd refcount lookup.
  - Registered recv and send buffers pinned once and referenced by index.
  - Provided buffer ring plus multishot recv (deferred behind measurement) so idle connections do not each hold a recv buffer.
  - Registered ring fd plus `DEFER_TASKRUN` / `SINGLE_ISSUER` to cut enter-time overhead.
  - Precomputed "certain bytes": the cached Date header (already thread-local, refreshed per second), the comptime SETTINGS and HPACK static blocks, and the response-cache full-response payloads. Read the clock once per completion batch rather than per request for the cache TTL.

**Evidence basis (mechanism proven in literature, magnitude still measured locally):**
The core gain rests on an established, peer-reviewed mechanism, not on a local assumption. Each citation justifies the direction of a win and removes the "is this a real effect" bias. The size of the win on this workload is still measured with the standard counters (`cycles:u`, `L1-miss/req`) under pipelined load.

- Exception-less, batched-submission syscalls cut userspace cycles and cache pollution: FlexSC (Soares and Stumm, OSDI 2010). The PoC signature (`L1-miss/req` ~73 -> ~23, `cyc/req` 1627 -> 818) reproduces this effect, so it is verification, not bias.
- Cache-conscious record layout (hot and cold split, field reordering): Chilimbi, Davidson, Larus and Chilimbi, Hill, Larus (both PLDI 1999).
- Structure-of-arrays and columnar layout for cache and SIMD locality: MonetDB/X100 (CIDR 2005), C-Store (VLDB 2005).
- False-sharing avoidance via per-worker cache-line padding: Bolosky and Scott (USENIX 1993).
- Zero-copy send pays only above a byte threshold (page-pinning overhead): IO-Lite (OSDI 1999) and the Linux `MSG_ZEROCOPY` documentation.
- O(1) worst-case comptime route dispatch via perfect hashing: Fredman, Komlos, Szemeredi (JACM 1984).
- Caveat: peer-reviewed io_uring evidence is mostly storage (Didona et al., SYSTOR 2022). For networking the backing is the FlexSC mechanism plus the maintainer design notes, so every io_uring-specific lever below is settled by local A/B.

**Unproven levers (calibrated bets, settle by A/B):**
These rest on a documented mechanism but no workload-specific proof, so each is a bet with a condition and a falsification signal, not a settled fact. The percentages are calibrated estimates to prioritize the measurement order, not measurements.

~70% and above (land first):

| Lever | Win prob | Pays off when | Confirm or deny signal |
| :- | :- | :- | :- |
| Registered or direct files (`IOSQE_FIXED_FILE`, `accept_direct`) | ~75% | many small ops per connection, pipelined | fewer `fget` / `fput`, lower `cyc/req` at p16 |
| `DEFER_TASKRUN` + `SINGLE_ISSUER` (one issuer per ring) | ~75% | kernel >= 6.1, completion-heavy loop | lower task-run / IPI cost, `cyc/req` drop at p16 |
| Response cache still wins past a (shifted) crossover on the ring | ~80% effect, ~50% same number | heavy-serialization endpoints | cache vs nocache A/B at 4 / 16 / 64 KiB; the crossover likely moves, re-measure it |
| Clock read once per CQE batch (coarse TTL) | ~70% | high request rate where every cycle counts | `clock_gettime` cycles disappear from the p16 profile |
| Registered send buffer holding the cache payload (`send_fixed` on a hit) | ~70% | large cached responses past the crossover | fewer `get_user_pages` on the hit path |

Below 70% (opportunistic, only after the above land and the profile still shows the targeted cost):

| Lever | Win prob | Why uncertain | Confirm or deny signal |
| :- | :- | :- | :- |
| `SEND_ZC` for big responses | ~60% | extra notification CQE, nets out only above ~16 KiB while traffic is small-response dominant | net throughput up only above the size gate, down below it |
| Provided-buffer ring + multishot recv vs fixed per-connection buffer | ~60% | wins mainly at c4096, the fixed per-connection buffer already competes | recv-buffer memory and re-arm syscalls drop at c4096, neutral at low conn |
| The exact ~4 KiB crossover transferring to the ring | ~50% | ring send is cheaper, so the number moves | re-measured crossover from the cache vs nocache sweep |
| Comptime response template with a patched length field | ~50% | the compiler may already fold the piecewise append | disasm shows the constant prefix is no longer rebuilt, marginal in perf |

**Acceptance criteria:**
1. Decision recorded as an ADR (approach A or B) with the trade-off table above.
2. `DispatchModel.URING` added to every server `config.zig`, with a non-Linux compile-time
   or run-time fallback to `.EPOLL` (mirrors the existing non-Linux `.EPOLL` to `.POOL`
   fallback).
3. Shared-nothing topology preserved: one ring per worker, `SO_REUSEPORT` listener per
   worker, no shared accept queue, no cross-thread fd handoff.
4. The two independent engine wins (lazy `parseHead`, `EPOLLOUT` re-arm) land first, since
   they benefit `.EPOLL` regardless of the io_uring outcome. Already satisfied in `main` for
   `zix.Http1` (verified by `zig build test-all`), still pending for `zix.Http`.
5. Benchmark protocol on completion: `wrk -c512 -t6 -d5s` twice, then
   `wrk -c4096 -t6 -d5s` twice, each run saved to `rnd/0.4.x/` as a `.txt` file. Compare
   `.URING` against `.EPOLL` on the same machine, back to back, fresh server per run
   (the ring pins memlock pages, so reusing a server instance across runs exhausts the
   per-user memlock budget).
6. All four test tiers pass.
