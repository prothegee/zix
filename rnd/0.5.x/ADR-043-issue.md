> This is part of 0.5.x-rc1 (ADR-042: no generic dispatch loop)

**Status:** Done. http1 pilot plus the connection-oriented engines (Http2, Fix, Grpc, Tcp, Http) split and green on Zig 0.16.x + 0.17.x. `zix.Udp` was excluded at the time (connectionless, no dispatch models), but the revisit condition below was later met: zix.Udp raw mode (ADR-049) added the second datagram serve strategy (SO_REUSEPORT + recvmmsg / sendmmsg per-core), so `src/udp/dispatch/` now follows the same per-model partition, and `zix.Http3` (`src/udp/http3/dispatch/`) does too.

## Problem
`src/tcp/http1/server.zig` was ~2,600 lines, containing all 5 dispatch models (`.ASYNC`, `.POOL`, `.MIXED`, `.EPOLL`, `.URING`).
- **Maintainability:** Editing one model required scrolling past the others. `.EPOLL` and `.URING` are ~900 lines each and barely overlap.
- **A2 Variants:** The 4 A2 idle-pool variants differ *only* in `.URING` pool code, but required full 2,600-line file copies.

## Decision
Split dispatch models into a per-engine `dispatch/` subfolder. One file per model (named after the `DispatchModel` enum). Shared helpers go in `common.zig`. `server.zig` shrinks to just the public `Server` type and the runtime `dispatch_model` switch.

**This is file organization only.** No behavior change, no perf change, no shared/generic dispatch loop.

### Layout (`http1` pilot, landed)
```text
http1
|
|___/dispatch
|   |___common.zig           (shared dispatch helpers)
|   |___async.zig
|   |___pool.zig
|   |___mixed.zig
|   |___epoll.zig
|   |___uring.zig
|
|___server.zig               (Server type + dispatch_model switch)
|___core.zig                 (unchanged: parse, sink, caches)
|___config.zig
|___router.zig
|___websocket.zig
```

### Partition Map (HTTP1)
| Destination | Contents |
| :- | :- |
| `dispatch/common.zig` | Shared helpers used by >= 2 models (logSystem, ConnArgs, ChunkDecode, socket opts like `setNoDelay`/`setNonBlock`, CPU pinning, parseGetFastPath, MAX_FD) |
| `dispatch/{model}.zig` | Specific model implementation + its dedicated tests (e.g., `epoll.zig` gets `runEpoll`, `ConnTable`, EPOLL tests) |
| `server.zig` | Imports, `Http1ServerImpl`, `pub Server`, `Server.init` tests |

### A2 Variant Preservation
The 4 A2 snapshots are full copies of the monolith, differing only in `.URING` pool code.
1. Moved as full-server snapshots to a variants folder. Kept full rather than reduced to `.URING`-only, so each stays a complete, self-consistent snapshot that diffs cleanly to the idle-pool delta.
2. Added a README cross-reference manifest in the variants folder linking the existing research records. `dispatch/uring.zig` remains the canonical `cold_tail`.

## Acceptance Criteria / Checklist

**Pilot (`zix.Http1`)**
- [x] Create `dispatch/` folder and split `server.zig` according to the partition map. (`server.zig` 2,624 to 154 lines)
- [x] Add `std.testing.refAllDecls` (one per new file) in `src/lib.zig` so tests actually run.
- [x] Move model-specific tests into their respective `dispatch/*.zig` files. Move shared helper tests to `common.zig`. (25 tests: 4 server, 7 common, 6 epoll, 8 uring)
- [x] Relocate A2 variants to a variants folder and create the cross-reference manifest. (moved as full-server snapshots, not reduced to `.URING`-only)
- [x] Verify **zero behavior/API change**: `zig build`, `test-all`, and the live `test-runner-*` pass with identical numbers. (all 56 protocols green, 25 http1 tests preserved)

**Rollout**
- [x] Replicate the exact same partition pattern to the remaining connection-oriented engines: `Http2`, `Fix`, `Grpc`, `Tcp`, `Http` (order). Each gated on Zig 0.16.x and 0.17.x (`test-all` + `examples`), all green.
  - Comptime-route engines (`Http2`, `Grpc`, `Http`) thread routes through a `common.Dispatch(...)` generic so moved bodies stay byte-identical, runtime-route engines (`Tcp`, `Fix`) pass the handler at runtime.
  - `Http` gotcha: `io.async` rejects a function with an `anytype` parameter (`std.meta.ArgsTuple`), so `handleConnection` is wrapped in a concrete local closure where the server pointer type is fixed.
- [x] `zix.Udp` excluded at the time. The dispatch models abstract connection lifecycle (accept, per-fd multiplex, close). The typed `Server(Packet)` is connectionless: one bound datagram socket, no per-connection fds, clients tracked as application-level address records, concurrency per-datagram (`io.concurrent`) not per-connection. The note here said a `dispatch/` split is revisited only if a second datagram serve strategy is added (reuseport plus `recvmmsg` / `sendmmsg` / io_uring multishot). That happened: zix.Udp raw mode (ADR-049) added exactly that, so `src/udp/dispatch/` now has the per-model split, and `zix.Http3` (`src/udp/http3/dispatch/`) follows it for the QUIC engine.
