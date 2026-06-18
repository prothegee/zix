# ADR-037 (accepted record)

Records the foundation decision for the `.URING` dispatch model before any `src/`
ring code is written (Phase 1 of `rnd/0.4.x/Proposal-IO_uring_Dispatch_Model.md`).
To be folded into `docs/adr-en.md` (before the `###### end of adr` footer) and
mirrored into `docs/adr-id.md` once the wording is settled. Kept here as the rnd
record alongside the PoC (`rnd/0.4.x/server_hello_uring.zig`,
`server_hello_epoll.zig`, `client_hello.zig`). No external engine or benchmark
framework is named, per project rule.

---

## ADR-037: `.URING` dispatch model on the raw linux io_uring surface, thread-per-core shared-nothing rings

**Status:** Accepted

**Context:** zix offers four readiness-model dispatch options (`.POOL`, `.ASYNC`,
`.MIXED`, `.EPOLL`), all level-triggered or thread-per-task models built on the
`epoll` readiness interface. The `.EPOLL` path is shared-nothing and competitive on
raw loopback throughput, but under pipelined load it spends a large share of
userspace cycles on syscall transitions (one `recv`, one `send`, and the
`epoll_wait` bookkeeping per ready event). A completion-based io_uring dispatch
batches submissions and reaps completions, removing most of those transitions. A
PoC measured the effect (loopback, ReleaseFast, two zix builds only, the `.EPOLL`
engine versus a hand-rolled io_uring hello server):

| Metric | zix-epoll | zix-uring (PoC) |
| :- | :- | :- |
| p1 cycles/req (userspace) | 1627 | 818 |
| p1 L1-miss/req | 73.5 | 22.9 |
| p16 cycles/req (userspace) | 710 | 240 |
| p16 server CPU (t4 c128, 10s) | ~45.1s | ~37.25s |

io_uring roughly halves userspace cycles per request at pipeline depth 1 and cuts
server CPU about 21 percent at equal throughput under depth 16. Peak loopback
throughput is parity at depth 1 (kernel and client bound), so the gain is
efficiency headroom, not peak req/s. The userspace cyc/req and L1-miss/req drop
reproduces the established exception-less, batched-submission syscall mechanism
(FlexSC, OSDI 2010), so it is a verification of a known effect, not a local
assumption.

The PoC proves the gain. The open question this ADR settles, before any `src/` work
begins, is which io_uring foundation to build `.URING` on, since that choice drives
the whole port. Two independent engine pre-wins that benefit `.EPOLL` regardless
have already landed in `zix.Http1` on `main` (lazy `parseHead` and the `EPOLLOUT`
re-arm), verified by `zig build test-all`. They are still pending for `zix.Http`.

**Decision:** Build the `.URING` dispatch model on the raw linux io_uring surface
(`std.os.linux.IoUring`, the stable low-level ring), not the fiber-based
`std.Io.Uring`. The two foundations were weighed as:

| Aspect | A. std posix io_uring (`std.Io.Uring`) | B. raw linux io_uring (`std.os.linux.IoUring`) |
| :- | :- | :- |
| Source | std-provided fiber-based `Evented` backend, drop-in `std.Io` | hand-rolled per-worker rings on the stable low-level ring API |
| Coupling | rides the existing `io: std.Io` config field, one code path for all backends | new `.URING`-only runtime, separate from the `std.Io` abstraction |
| Control | submission and reaping owned by std, opaque to zix | full control: ring flags, buffer rings, multishot ops, batching policy |
| Features used | whatever std exposes through `std.Io` | multishot accept and recv, provided buffer ring, one coalesced send per readable completion, gen-tagged `user_data`, deferred close while a send is in flight |
| Shared-nothing | depends on std executor topology | native: one ring per worker, no cross-thread handoff, matches the `.EPOLL` design |
| Stability risk | tracks std internals (the io_uring surface moved across 0.16.x) | depends only on the stable kernel io_uring ABI, not on std internals |
| Maintenance | low (std maintains the engine) | higher (zix owns the ring lifecycle and edge cases) |

Reasoning for B:
- The measured win comes from features std does not currently expose through
  `std.Io` (multishot accept and recv, provided buffer rings). Approach A cannot
  reach the PoC numbers without those.
- The shared-nothing per-worker ring model (one ring, one `SO_REUSEPORT` listener,
  no shared accept queue) is already the topology the `.EPOLL` path uses. Approach B
  keeps it intact. Approach A reintroduces a std-owned executor topology zix does not
  control, the same ownership problem that confines the response cache to `.EPOLL`
  (ADR-036).
- Approach B depends only on the stable kernel ABI, not on std internals, so the
  moving std io_uring surface does not gate it and the work starts on current Zig
  (0.16.x).

Scope of the decision:
- Topology preserved from `.EPOLL`: thread-per-core, one ring per worker, one
  `SO_REUSEPORT` listener per worker, no shared accept queue, no cross-thread fd
  handoff. Process-per-core (fork-per-core) is rejected because it would split the
  per-worker route tables and response cache out of one address space.
- Minimal correct core first: multishot accept re-armed on `!IORING_CQE_F_MORE`, an
  fd-indexed slot table (direct index, no hashmap) guarded against the close-versus-recv
  completion race with a generation tag in `user_data` against fd reuse, a fixed
  per-connection recv buffer with a plain `recv` SQE, and a batched CQE drain into a
  stack array. The listener setup uses raw `linux.*` (or `std.Io.net`) because
  `std.posix.socket` / `bind` / `listen` / `close` were removed in 0.16.x.
- Ring flags are optimizations, not prerequisites: a ring initialized with no flags
  is correct. `SINGLE_ISSUER`, `COOP_TASKRUN`, and `DEFER_TASKRUN` (the last needs
  kernel 6.1 or newer) are added and measured one at a time.
- Buffer strategy is staged: start with the fixed per-connection recv buffer plus a
  plain `recv` SQE (already enough to compete), and move to a registered provided
  buffer ring with multishot recv only if the measured syscall savings justify the
  harder buffer lifecycle.
- Other staged levers (each behind its own A/B, settled by perf counters):
  registered or direct files (`IOSQE_FIXED_FILE`, `accept_direct`), a registered
  send buffer holding a response-cache payload (`send_fixed` on a hit), reading the
  clock once per CQE batch for the cache TTL, and `SEND_ZC` for responses past a
  size gate.
- Implementation order: `zix.Http1` first (proves the ring core), then WebSocket
  (reuses the upgrade path, the readable-burst coalescing maps to one batched send),
  then `zix.Grpc` (h2 framing, HPACK, and stream multiplexing are stateful), then
  `zix.Http` (reuses the Http1 ring core, cheapest last).
- `DispatchModel.URING` is added to every server `config.zig`, with a non-Linux
  compile-time or run-time fallback to `.EPOLL` (mirrors the existing non-Linux
  `.EPOLL` to `.POOL` fallback).

**Consequences:**
- The deliverable is CPU per request and connections per core, not a bigger loopback
  req/s number. Peak loopback throughput stays parity at depth 1 because that
  workload is kernel and client bound. Acceptance is measured with `cycles:u` and
  `L1-miss/req` under pipelined load, back to back against `.EPOLL` on the same
  machine, fresh server per run (the ring pins memlock pages, so reusing a server
  instance across runs exhausts the per-user memlock budget).
- zix owns the ring lifecycle and its edge cases: the close-versus-recv completion
  race, fd reuse (handled by the generation tag), and the per-user memlock budget
  the rings consume. This is the maintenance cost traded for the control that the
  measured win requires.
- Approach A stays the fallback if the raw-syscall surface proves too costly to
  maintain, or if a future `std.Io` exposes multishot and provided buffers as
  first-class operations.
- The two engine pre-wins (lazy `parseHead`, `EPOLLOUT` re-arm) are in `zix.Http1`
  and benefit `.EPOLL` independently of this decision. Both are now ported to
  `zix.Http` as well: its `ParsedHead` drops the per-request 64-entry header array
  and records the raw header block as offsets for `getHeader` to rescan on demand,
  and its `.EPOLL` worker stages the unwritten response tail on a partial write and
  arms `EPOLLOUT` to drain it on the next writable event instead of dropping the
  connection. The coalescing sink is bypassed for SSE, whose draining stays
  handler-side (a blocking write parks the handler, not a library event loop).
- The io_uring-specific levers above rest on documented kernel mechanisms but have
  no workload-specific proof yet, so each is settled locally by an A/B with a named
  perf-counter signal rather than assumed. Peer-reviewed io_uring evidence is mostly
  storage, so for networking the backing is the FlexSC mechanism plus the kernel
  maintainer design notes.

**Extension to `zix.Tcp` and `zix.Fix` (callback rings):**
- These two engines could not take a direct ring port: their handler is a blocking
  `fn(stream, io)` that owns the connection and loops on synchronous reads and
  writes, which a single-threaded completion loop cannot run. So each gains a new
  engine-driven callback API alongside the existing blocking one. `zix.Tcp` adds
  `runFramed` with a per-frame `FrameFn` over a 4-byte length prefix, and `zix.Fix`
  adds a `.URING` path that runs a resumable session processor
  (`core.processFixRing`) per readable batch. The blocking `runWith` and `serveConn`
  paths are unchanged, and their `.URING` still folds to `.EPOLL`.
- FIX heartbeats on the ring use a per-worker periodic timer, not a per-connection
  one. A single `prep_timeout` SQE per worker (re-armed on each fire, tagged with a
  new `.timeout` `OpKind` that the other engines treat as a no-op) ticks every
  `heartbeat_timeout_ms`. On each fire the worker scans its slot table and, for every
  logged-in session idle past the interval, sends a TestRequest on the first tick
  then a Logout on the next, written straight to the fd. One SQE per worker plus an
  O(n) scan per tick beats a per-connection timeout that would cancel and re-arm on
  every inbound message. Reaping an idle session is close-safe: its only in-flight op
  is an idle recv with no buffered data, so closing it leaves the stale recv
  completion to be dropped by the generation tag. This completes the session:
  `processFixRing` answers peer Heartbeat/TestRequest reactively, and the timer adds
  the server-initiated half.
