## Design Considerations

Layout and structure notes: the choices already made, plus directions to revisit. Not active tasks.

**CT (Compile Time):**<br>
Zix pushes work to `comptime` whenever the input is fixed at build time. Route tables are partitioned and dispatch is specialized per route set (`Router(comptime routes)`, `HttpServerImpl(comptime stack_threshold, comptime routes)`), and version differences are gated out with `ZIG_SEMVER` (`comptime ZIG_SEMVER.MINOR == 16`) so only the active branch is compiled. The trade is build-time work and binary size for zero runtime branching on the hot path.

> Use it when an input is known at build time: prefer a comptime parameter or branch over a runtime field or check.

<br>

**AoS (Array of Structures):**<br>
Remaining sites (`extra_buf`, `fields`, `conns`, ...). When any becomes a throughput bottleneck, a SoA layout is a candidate. Route tables are already partitioned at comptime into exact / prefix / param groups (`router.zig`), so dispatch scans only the relevant kind instead of one mixed list.

> Move a site to SoA when a profile shows one field scanned across many records dominates.

<br>

**OoP (Object-oriented Patterns):**<br>
Most structs (`Request`, `Response`, `Router`, `Context`, `ConnQueue`, `MultipartParser`, ...) follow this shape. Idiomatic in Zig and fine as the baseline.

> Keep it as the default. Reach past it only when encapsulation shows up as a throughput cost.

<br>

**DoD (Data-Oriented Design):**<br>
The direction to move when data layout matters more than encapsulation. For the HTTP layer this began as `zix.Http1`: a lean, data-oriented engine whose EPOLL / URING dispatch carves connection buffers from one contiguous demand-paged slab (`http1/dispatch/`, `multiplexers/slab.zig`). The full `zix.Http` still uses the OoP baseline.

> Revisit a DoD core for `zix.Http` when the OoP baseline hits a real ceiling.

<br>

**Arena (Per-Request Arena Allocation):**<br>
Each `zix.Http` connection gets an arena (configurable initial capacity, grows on demand). Per-request scratch and the body buffer are carved from it and released in one bulk reset instead of per-object frees.

> Use it when allocations live exactly as long as the request or connection.

<br>

**Slab (Contiguous Demand-Paged Slab):**<br>
The `zix.Http1` EPOLL / URING connection table pre-allocates one `MAX_FD * buf_size` virtual slab per worker (Linux demand-paged) and assigns each connection's buffer from it with no per-accept heap call. Untouched slots cost no physical memory, and an empty slot is just `buf.len == 0` (`multiplexers/slab.zig`).

> Use it when per-accept heap allocation shows up on the hot path and the entry count is bounded.

<br>

---

## Design Patterns

**Type-Per-Domain Methods (Namespace Struct):**<br>
Each protocol is its own Zig file-as-struct namespace exported from `lib.zig` (`zix.Http`, `zix.Http1`, `zix.Grpc`, `zix.Tcp`, `zix.Fix`, `zix.Udp`, `zix.Uds`, `zix.Channel`, `zix.Logger`), exposing only that domain's methods (`Server.init`, `run`, ...).

> Use it when a subsystem has a self-contained surface: give it one namespace type instead of scattered free functions.

<br>

**Flat Config (No Builder):**<br>
Every config struct keeps all fields at the top level, no nested sub-configs and no fluent builder (`*/config.zig`).

> Keep it flat: add a top-level field rather than a builder method or a nested config object.

<br>

**Shared-Nothing / Thread-Per-Core:**<br>
Each EPOLL / URING worker owns one `SO_REUSEPORT` listener and a private event loop, no shared queue and no cross-thread fd handoff (`http1/dispatch/epoll.zig`, `tcp/server.zig`).

> Use it for high connection counts where queue contention, not CPU, is the ceiling.

<br>

**Reactor (Readiness-Based Loop):**<br>
The `epoll_wait` loop reports ready fds and the worker handles each inline (`http1/dispatch/epoll.zig`, `grpc/server.zig`).

> Use it when readiness notification plus inline I/O is enough.

<br>

**Proactor (Completion-Based Loop):**<br>
SQEs are submitted and CQEs reaped on the io_uring ring, batching most syscall transitions (`http1/dispatch/uring.zig`, ADR-037).

> Use it when syscall-entry cost or per-request cache locality is the lever.

<br>

**Strategy (Pluggable Dispatch):**<br>
A `DispatchModel` enum selects `runAsync` / `runPool` / `runMixed` / `runEpoll` / `runUring` at startup, per engine (`*/server.zig`).

> Use it when one engine must offer several runtime execution shapes behind one config field.

<br>

**Comptime Route Table:**<br>
`Router(comptime routes)` partitions routes into exact / prefix / param groups at compile time, so dispatch scans only the relevant kind (`http/router.zig`).

> Use it when the route set is known at build time and per-request matching is hot.

<br>

**Callback Handler (Function Pointer):**<br>
Request, frame, and session handlers are plain function pointers (`HandlerFn`, `FrameFn`, FIX session callbacks) (`fix/core.zig`).

> Use it when the engine owns the loop and the user supplies only the per-event body.

<br>

**Shared-Primitive Multiplexer:**<br>
Only byte-identical primitives are hoisted to `src/multiplexers/` (the ring `user_data` codec, the slab), while each engine keeps its own dispatch loop (ADR-042).

> Share a primitive only when it must match across engines, otherwise keep it per-engine.

<br>

**Slab (Inline Demand-Paged Slots):**<br>
The EPOLL / URING connection table carves each connection's buffer from one contiguous demand-paged slab, no per-accept heap call (`multiplexers/slab.zig`).

> Use it when per-accept allocation is hot and the entry count is bounded.

<br>

**Arena (Bulk-Reset Allocation):**<br>
Per-connection and per-request scratch is taken from an arena and released in one reset (`http/request.zig`).

> Use it when allocations share a single lifetime.

<br>

**Object Pool (Idle-Conn Reclaim):**<br>
The URING ring keeps an idle-connection pool with LRU-tail reclaim instead of freeing on every close (`http1/dispatch/uring.zig`, ADR-041).

> Use it when connection churn dominates and re-acquire cost matters.

<br>

**Generation-Tagged Slot (Handle Map):**<br>
The io_uring `user_data` codec packs an fd-keyed slot guarded by a generation, so a stale completion is detected and dropped (`multiplexers/ring.zig`).

> Use it when async completions can outlive the slot they referenced.

<br>

**Resumable State Machine:**<br>
Multiplexed h2 (gRPC) and FIX sessions hold resumable per-connection state, so one worker drives many connections (`grpc/server.zig`, `fix/core.zig`).

> Use it when a protocol spans many round-trips on one non-blocking connection.

<br>

**Memoization (Response Cache):**<br>
A per-key precomputed response is replayed without re-encoding (`utils/response_cache.zig`).

> Use it when the same response body is served repeatedly and encoding is measurable.

<br>

**Write Coalescing (Batched Sink):**<br>
Several writes in one pass are staged and flushed as a single `send` (`http1/core.zig`, `websocket.zig`).

> Use it when a response or pump pass emits several small writes.

<br>

**Backpressure (EPOLLOUT Arming):**<br>
When a send would block, the fd is armed for writable and the remainder flushed on the next event (`http/response.zig`, `http1/dispatch/epoll.zig`).

> Use it when slow clients must not park a worker on a blocking write.

<br>

**Baked Response Prefix:**<br>
A precomputed header prefix is emitted with one memcpy instead of formatting per request (`http1/core.zig`).

> Use it when a response prefix is constant across requests.

<br>

## Naming Conventions

**Enum member casing:**<br>
Enum members are UPPER_CASE by default. The exceptions are not a free choice, they match the source the enum models:

| Enum kind | Casing | Examples |
| :- | :- | :- |
| Domain, public, or config | UPPER_CASE | `DispatchModel` (.ASYNC / .EPOLL / .URING), `Content.Type`, `RouteKind` (EXACT / PREFIX / PARAM), `Version` (HTTP_1 / HTTP_2 / HTTP_3), logger `Level` (DEBUG / INFO / WARN / ERROR), `GrpcStatus`, compression `Encoding` (IDENTITY / GZIP / DEFLATE / BR) |
| Protocol-mirroring | match the source spec | WebSocket `Opcode` mirrors RFC 6455 (continuation, text, binary, ping, pong), FIX `Tag` mirrors the FIX field names (ClOrdID, MsgSeqNum, BeginString) |
| Internal control-flow | lower_case snake | `ConnOutcome` / `ReqOutcome` / `FrameOutcome` (keep_alive, close), `MuxPhase`, ring `OpKind` (accept, recv, send) |

> FIX `Tag` is PascalCase on purpose: the members are the FIX spec field names verbatim, so they must not be renamed until the FIX community updates the spec (see the note on `Tag` in `tcp/fix/core.zig`).
