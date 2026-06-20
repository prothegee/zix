# ADR-043 (proposal record)

> This is part of 0.5.x

## Objective
Record the decision to split each engine's per-dispatch-model code out of its one
large `server.zig` into a per-engine `dispatch/` folder, one file per model, for
maintainability. This is file organization only: no behavior change, no perf
change, no shared or generic dispatch loop. It refines ADR-042, not contradicts
it. ADR-042 said do not unify dispatch loops ACROSS engines. ADR-043 says split
the models WITHIN an engine into their own files. Both keep the same rule: each
engine owns its dispatch, and no per-event indirection is introduced.

## Background
`src/tcp/http1/server.zig` is about 2,600 lines holding all five dispatch models
(`.ASYNC`, `.POOL`, `.MIXED`, `.EPOLL`, `.URING`) plus their connection tables,
workers, helpers, and tests. The two readiness/completion engines dominate it:
`.EPOLL` is about 900 lines, `.URING` about 900 lines, and they barely reference
each other. A change to one model means scrolling past the other four, and the
A2 idle-pool work showed the value of isolating a model: the four A2 variants
(`pre_A2`, `flat_256`, `adaptive`, `cold_tail`) differ ONLY in the `.URING`
idle-pool code, yet today each is a full 2,600-line copy of the whole file.

The other engines (`zix.Http`, `zix.Http2`, `zix.Grpc`, `zix.Tcp`, `zix.Fix`,
`zix.Udp`) have the same shape: one `server.zig` per engine carrying every model.

## Decision
Per engine, split the dispatch models into a `dispatch/` subfolder, one file per
model named after the `DispatchModel` enum value. Shared dispatch helpers go in
`dispatch/common.zig`. `server.zig` shrinks to the public `Server` type and the
runtime `dispatch_model` switch. Roll out on `zix.Http1` first as the pilot, then
replicate the exact pattern to the other engines.

Layout (http1):

```
http1
|
|___/dispatch
|   |___common.zig      (shared dispatch helpers)
|   |___async.zig
|   |___pool.zig
|   |___mixed.zig
|   |___epoll.zig
|   |___uring.zig
|
|___server.zig          (Server type + dispatch_model switch)
|___core.zig            (unchanged: parse, sink, caches, header build)
|___config.zig
|___router.zig
|___websocket.zig
```

The filename maps one-to-one to the enum value (`.EPOLL` to `epoll.zig`), so no
redundant `server_` prefix. `core.zig` is untouched, it already holds the shared
request processing used by every model.

## Partition map (http1 pilot)

| Destination | Moves in (from server.zig) |
| :- | :- |
| `dispatch/common.zig` | logSystem, ConnArgs + connEntry, ChunkDecode + decodeChunkedInBuf, setNoDelay, setNonBlock, setBusyPoll, pinToCpu, getAvailableCpuCount, parseGetFastPath, effectiveCacheEntries, MAX_FD (each used by 2 or more models) |
| `dispatch/async.zig` | runAsync |
| `dispatch/pool.zig` | ConnQueue, PoolCtx, AcceptCtx, poolEntry, acceptEntry, runPool |
| `dispatch/mixed.zig` | MixedAcceptCtx, mixedAcceptEntry, runMixed |
| `dispatch/epoll.zig` | EPOLL_MAX_EVENTS, EPOLL_OUT_BUF_SIZE, Conn, ConnTable, serveEpollConn + Inner + Write + Ws + Drain, EpollWorkerCtx, epollWorkerFn, runEpoll, and the EPOLL tests |
| `dispatch/uring.zig` | URING_* + WS_RING_* consts, initUringRing, UringConn, UringWorker, UringWorkerCtx, uringWorkerFn, runUring, and the URING tests |
| `server.zig` (kept) | imports, Http1ServerImpl, pub Server, the Server.init tests |

Comptime-baked handlers cross files cleanly: `runEpoll(config, comptime
handler_fn, comptime raw_fn)` called from `server.zig` is a normal import. The
runtime `dispatch_model` switch references all five `run*` entries, so every model
file is imported and compiled, the split adds no dead code and removes none.

## A2 variant preservation
The four A2 snapshots (`server.1.pre_A2.zig` ... `server.4.cold_tail.zig`) are
full copies of the monolithic `server.zig`, so the split would orphan them. They
differ only in the `.URING` idle-pool code, which after the split lives entirely
in `dispatch/uring.zig`. Preserve them as follows:

- Reduce each to its `.URING` form and relocate to `rnd/0.5.x/a2-variants/`
  (`uring.1.pre_A2.zig` ... `uring.4.cold_tail.zig`), out of `src/` since they are
  inert research snapshots, not built code. `dispatch/uring.zig` stays the
  canonical cold_tail.
- A cross-reference manifest in `rnd/0.5.x/` indexes the four, names the single
  differing function set, and links the existing records: issue comments 6 and 7,
  `a2-uring-4way-results-0.4.x.md`, `smaps-anon-breakdown-0.4.x.md`,
  `bench-cell-scaling-analysis-0.4.x.md`, and the `project_a2_uring_idle_pool`
  memory (which already holds all four code shapes). The manifest is the durable
  record, the files are attachments it points at.

## Alternatives rejected
| Alternative | Why rejected |
| :- | :- |
| Keep the monolithic server.zig | The maintainability cost is real and growing: every model edit scrolls past the other four, and the A2 variants are forced to be full-file copies. |
| Flat files with a server_ prefix in the engine dir | Clutters the engine directory and the prefix is redundant with the path. The subfolder reads cleaner and groups the models. |
| Hoist shared socket/CPU helpers (pinToCpu, setNoDelay, getAvailableCpuCount) up to a shared src/tcp/ module now | A good cross-engine dedup, but a cross-engine change. Deferred until after the http1 pilot proves the per-engine layout. common.zig keeps them local for now. |
| Generic dispatch loop or multiplexer interface | Already rejected by ADR-042: it forces one connection-table shape on every engine and adds per-event indirection on the hottest path. ADR-043 does not revisit that, it only reorganizes files. |

## Consequences
- Each new file needs its own `std.testing.refAllDecls` line in `src/lib.zig`
  (refAllDecls is not recursive), else its tests silently never run.
- Tests move into the file of the model they cover. Shared-helper tests
  (parseGetFastPath, effectiveCacheEntries) go to `dispatch/common.zig`.
- No behavior or API change. `server.zig`'s public `Server.init` / `initRaw` and
  the config are unchanged.
- Once the http1 pilot is verified, the same partition is applied to the other
  engines (Http, Http2, Grpc, Tcp, Fix, Udp). Each is an independent, equivalent
  move.

## Pilot outcome (http1, landed)
The `zix.Http1` pilot is done and green. `server.zig` went from 2,624 lines to 154
(Server type + switch), with the models in `dispatch/common.zig` (316),
`async.zig` (32), `pool.zig` (146), `mixed.zig` (66), `epoll.zig` (749), and
`uring.zig` (1,325, cold-tail). Moved bodies are byte-identical: each model file
aliases the shared helpers (`const setNoDelay = common.setNoDelay;`), and only the
`run()` switch was rewritten. `zig build`, `test-all`, and `test-runner-all` (all
56 protocols) pass, with the 25 http1 tests preserved (4 server, 7 common, 6
epoll, 8 uring). The four A2 variant snapshots were relocated to
`rnd/0.5.x/a2-variants/` with a README cross-reference manifest. The other engines
remain on the monolithic layout, to be split next.

## Final entry (to fold into docs/adr-en.md and docs/adr-id.md)

## ADR-043: split each engine's dispatch models into a per-engine dispatch/ folder

**Status:** Accepted (0.5.x, http1 pilot landed, other engines pending)

**Context:** Each engine keeps all of its dispatch models in one `server.zig`
(ADR-042). For `zix.Http1` that file is about 2,600 lines, with `.EPOLL` and
`.URING` about 900 lines each and barely overlapping. Maintainability suffers, and
the A2 idle-pool variants, which differ only in the `.URING` pool code, are forced
to be full-file copies.

**Decision:** Split the models into a per-engine `dispatch/` folder, one file per
model named for the `DispatchModel` enum value (`async.zig`, `pool.zig`,
`mixed.zig`, `epoll.zig`, `uring.zig`), with shared dispatch helpers in
`dispatch/common.zig`. `server.zig` keeps the public `Server` type and the
runtime model switch. `core.zig` (shared request processing) is untouched. Roll
out on `zix.Http1` first, then replicate.

**Rationale:** This is file organization, not a behavior or perf change, and does
not introduce a shared or generic dispatch loop, so it complies with ADR-042 (no
per-event indirection, each engine still owns its dispatch). Isolating a model
makes per-model work and per-model variant comparison (the A2 record) tractable.

**Config:** none. No code-behavior or API change.

**Consequences:** Each new file needs a `refAllDecls` line in `lib.zig`. Tests
move with their model. The model switch still imports every model file. The http1
pilot landed green (`zig build`, `test-all`, `test-runner-all`, 25 tests
preserved): `server.zig` shrank from 2,624 lines to 154, the models live under
`dispatch/`, and moved bodies are byte-identical (shared helpers reached via
`const X = common.X;` aliases, only the `run()` switch rewritten). The four A2
idle-pool variants are preserved as full-server snapshots in
`rnd/0.5.x/a2-variants/` (they differ only in the `.URING` pool code) with a
cross-reference manifest. The other engines (Http, Http2, Grpc, Tcp, Fix, Udp)
remain on the monolithic layout and get the same split next.
