# ADR-042 (proposal record)

> This is part of 0.4.x-rc3

## Objective
Record, as a deliberate architecture decision, why each engine keeps its own
dispatch loop (`.ASYNC` / `.POOL` / `.MIXED` / `.EPOLL` / `.URING`) in its own
`server.zig` instead of behind one generic multiplexer abstraction, and why the
only thing hoisted into `src/multiplexers/` is a byte-identical primitive (the
`.URING` `user_data` codec). The split is intentional and is itself an
optimization, not duplication waiting to be removed.

## Background
ADR-037 introduced the `.URING` model and, when it landed across engines, the
only piece extracted into a shared module was `src/multiplexers/ring.zig`: the
`OpKind` routing tag plus `packUserData` / `unpackUserData` (about 40 lines of
logic). Every io_uring engine reuses that codec because the bits must match
exactly: a connection slot is keyed by fd and guarded against fd reuse by a
generation in the same `user_data` layout everywhere.

Notably the rest of the `.URING` path was not centralized. Each engine still
declares its own ring connection slot table (`UringConn` in `zix.Http1`,
`UringGrpcConn` in `zix.Grpc`, `UringFixConn` in `zix.Fix`) and its own
completion loop. The same is true of `.EPOLL`: each engine has its own
connection table, its own `acceptAll`, and its own per-event dispatch.

A reader can reasonably ask whether the dispatch loops should be unified the way
`ring.zig` was, so this record states the answer once.

## The seam this codebase actually has
The natural unit of sharing here is a narrow primitive that is byte-for-byte
identical across engines, not a loop. The evidence is the connection table,
which looks like the most duplicated piece but is in fact specialized per
engine for that engine's hot path:

| Engine | `.EPOLL` connection table | Allocation strategy | Why |
| :- | :- | :- | :- |
| `zix.Http1` | `ConnTable` | contiguous demand-paged slab (`slab: []u8`, `MAX_FD * buf_size`, empty slot is `buf.len == 0`) | no per-accept heap call on the hottest accept path |
| `zix.Grpc` | `GrpcConnTable` | per-connection heap pointer (`slots: []?*GrpcMuxConn`) | the connection object carries resumable h2 + HPACK state, too large and variable for a uniform slab cell |
| `zix.Fix` | `UringFixConn` table | per-connection heap pointer | the connection object carries FIX session state (sequence numbers, heartbeat timing) |

The `acceptAll` signatures already diverge for the same reason (`zix.Grpc` takes
a `GrpcServeOpts`, `zix.Http1` takes none). And the per-event dispatch bodies are
the bulk of each `server.zig` and are irreducibly engine-specific:

| Engine | per-event dispatch shape |
| :- | :- |
| `zix.Http1` | `write_pending` to `drain` to `ws` to `serveEpollConn` branch ladder, plus pipelining and WebSocket handoff |
| `zix.Grpc` | resumable HTTP/2 state machine across frames |
| `zix.Fix` | length-and-checksum session framing |

## Decision
Keep each engine's dispatch loop in its own `server.zig`. Do not build a generic
multiplexer interface or a shared dispatch loop.

Share only byte-identical primitives in `src/multiplexers/`. Today that is the
`.URING` `user_data` codec (`ring.zig`). A future primitive qualifies only if it
is identical across engines by requirement, not merely similar in shape.

The rule, stated once: share primitives that must match, keep dispatch loops
per-engine.

## Rationale
- Per-engine ownership lets each engine tune its hot path for its own connection
  shape. The table above is that tuning made concrete: `zix.Http1` pays zero heap
  on accept via a slab, while `zix.Grpc` and `zix.Fix` accept a heap pointer
  because their connection objects cannot share one fixed slab cell.
- A single generic loop would force one connection-table shape on every engine
  (erasing the `zix.Http1` slab win) and would add a callback-per-event
  indirection on the accept / recv / send path, which is the hottest path in the
  library. `ring.zig` deliberately stayed a codec for exactly this reason: it
  adds no indirection to the loop.
- The split is what makes per-engine benchmarking and tuning tractable. ADR-040
  (hot-path optimizations) and ADR-041 (`.URING` churn scaling) were both
  engine-local changes that did not have to reason about a shared abstraction.

## Alternatives rejected
| Alternative | Why rejected |
| :- | :- |
| Move nothing and say nothing | The duplication looks accidental to a new reader, so the intent must be recorded even though no code moves. |
| Extract a generic fd slot table for all engines | `zix.Http1`'s slab table cannot join without losing its no-alloc-on-accept property, so the highest-traffic engine would either regress or stay out, leaving a half-measure. The shapes are similar, not identical, so it fails the `ring.zig` bar. |
| Generic multiplexer interface, rewrite every engine against it | The dispatch bodies are engine-specific (h2 state machine, FIX framing, HTTP/1 pipelining and WebSocket), so a generic interface either leaks per-engine hooks until it is not generic, or forces a per-event indirection on the hottest path. It also means rewriting the `.URING` and drain paths just stabilized for rc3, risking regression in green code, for negative perf. |

## Consequences
- A small amount of boilerplate stays duplicated across engines: the epoll
  bootstrap (`epoll_create1`, register listener, `setNonBlock`, the
  `epoll_wait` and errno-switch skeleton) and the fd-indexed slot table shape.
  This is accepted in exchange for per-engine tunability, and each copy is small.
- A bounds or generation fix in the slot table pattern must be applied per
  engine. This is the known cost and is judged acceptable given the tables are
  intentionally not identical.
- `src/multiplexers/` remains the home for shared primitives only, not for
  dispatch loops. The bar for adding to it is byte-identical-by-requirement.
- No code change. This ADR records existing intent. It is paired with a short
  subsection in `docs/concurrency-en.md` (and `docs/concurrency-id.md`) so the
  rationale is discoverable from the concurrency documentation as well.

## Final entry (to fold into docs/adr-en.md and docs/adr-id.md)

## ADR-042: dispatch loops stay per-engine, only byte-identical primitives are shared

**Status:** Accepted

**Context:** When `.URING` (ADR-037) landed across engines, the only piece
hoisted into a shared module was `src/multiplexers/ring.zig`: the `OpKind` tag
and the `user_data` codec (about 40 lines). Every io_uring engine reuses it
because the bits must match exactly (an fd-keyed slot guarded by a generation in
one `user_data` layout). The rest stayed per-engine: each engine keeps its own
`.EPOLL` and `.URING` connection table, `acceptAll`, and per-event dispatch. A
reader can ask whether those loops should be unified the way the codec was.

**Decision:** Keep each engine's dispatch loop (`.ASYNC` / `.POOL` / `.MIXED` /
`.EPOLL` / `.URING`) in its own `server.zig`. Do not build a generic multiplexer
interface. Share only byte-identical primitives in `src/multiplexers/` (today,
the `.URING` `user_data` codec). The rule: share primitives that must match,
keep dispatch loops per-engine.

**Rationale:** The split is the optimization. Per-engine ownership lets each
engine tune its hot path for its own connection shape: `zix.Http1` carves
connection buffers from a contiguous demand-paged slab (no per-accept heap call),
while `zix.Grpc` and `zix.Fix` hold per-connection heap pointers because their
connection objects carry h2 or FIX session state too large or variable for one
fixed slab cell. A single generic loop would force one table shape on every
engine (erasing the slab win) and add a callback-per-event indirection on the
accept / recv / send path, the hottest path in the library. `ring.zig`
deliberately stayed a codec to avoid exactly that indirection.

**Config:** none. No code or API change. This records existing intent.

**Consequences:**
- A small amount of boilerplate stays duplicated per engine (the epoll bootstrap
  and the fd-indexed slot table shape), accepted in exchange for per-engine
  tunability. A bounds or generation fix in that pattern is applied per engine.
- `src/multiplexers/` stays the home for shared primitives only. The bar for
  adding to it is byte-identical-by-requirement, not merely similar shape.
- The connection tables are intentionally not identical: `zix.Http1` slab versus
  `zix.Grpc` / `zix.Fix` per-connection heap pointers, each chosen for that
  engine's connection shape.
