# Architecture Decision Records: zix

Each ADR records a significant design decision: the context that made it necessary, the decision taken, and its consequences. Accepted ADRs are binding. Proposed ones are under discussion.

---

## ADR-001: `std.Io` as the I/O abstraction

**Status:** Accepted

**Context:** The server must handle many concurrent connections without blocking on I/O. Zig 0.16 provides `std.Io` as an opaque event loop abstraction over OS facilities (epoll, kqueue, io_uring, etc.). The alternative was raw OS threads with explicit synchronization.

**Decision:** Accept `std.Io` as a parameter in `zix.Http.Server` and `zix.Udp.Server`. The caller owns and provides the backend (`process.io` for runtime-managed or `std.Io.Threaded` for an explicit cap). The server uses `io.concurrent()` in model 1; in model 2 the pool threads call `handleConnection` directly with a `std.Io` derived from `std.Io.Threaded`.

**Consequences:**
- Caller controls the concurrency model. zix does not own or deinit the backend.
- `zix.Http.Server.run()` and `zix.Udp.Server.run()` block until error.
- `io.concurrent()` is used in model 1 (single accept, task-per-connection). Model 2 bypasses `io.concurrent()` entirely: pool threads handle connections with blocking synchronous I/O.
- Code that needs true parallelism (e.g. UDP broadcast) can call `io.concurrent()` from within a task.

---

## ADR-002: Namespace API (zix.Http.*, zix.Udp.*)

**Status:** Accepted

**Context:** The initial API exposed flat exports from the zix root (`zix.HttpServer`, `zix.Request`, etc.). When UDP was added the surface became inconsistent: HTTP types were flat while UDP types were already under `zix.Udp.*`. The flat HTTP names also carried redundant prefixes (`HttpServer`, `HttpHeader`) that became obvious once nested.

**Decision:** Introduce `zix.Http` and `zix.Udp` as namespace aggregators backed by `Http.zig` and `Udp.zig`. Remove all flat HTTP exports. Canonical paths:
- `zix.Http.Server`, `zix.Http.Request`, `zix.Http.WebSocket`, ...
- `zix.Udp.Server(Packet)`, `zix.Udp.Client(Packet)`, `zix.Udp.ServerConfig`, ...

`zix.Tcp.Http.*` remains accessible (Tcp.zig re-exports Http.zig) but is not the canonical path.
`zix.utils` stays flat (it is not protocol-specific).

**Consequences:**
- Breaking change: all code referencing flat exports must update.
- Namespace makes protocol affiliation self-evident at the call site.
- Adding future protocols (UDS, QUIC) follows the same pattern with zero impact on existing namespaces.

---

## ADR-003: Per-connection arena allocator, reset per request

**Status:** Accepted

**Context:** Handler code needs temporary allocations (body parsing, path segments, JSON, etc.) that are only valid for the duration of one request. A general-purpose allocator would require explicit `free` calls in every handler and every error path.

**Decision:** Allocate one `ArenaAllocator` per connection (backed by `smp_allocator`). Reset it between requests with `.retain_capacity`. Expose the arena's allocator as `ctx.allocator`. Deinit the arena when the connection closes.

**Consequences:**
- Handlers never call `free`. All per-request memory is reclaimed automatically at request end.
- `ctx.allocator` allocations must not escape the request (e.g. stored in a global). The name `ctx.allocator` is intentionally brief, the arena lifetime constraint is documented rather than encoded in the name. (A rename to `ctx.request_arena` was considered and declined: the lifetime constraint is enforced by documentation and convention.)
- Retain-capacity reset amortizes arena backing block growth over the connection lifetime.

---

## ADR-004: 3-pass router dispatch (exact > param > prefix)

**Status:** Accepted

**Context:** A router needs a consistent priority rule when multiple patterns could match the same request. Options were: first-match-wins (registration order), longest-match, or explicit priority tiers.

**Decision:** Three passes in fixed priority order: exact routes first, then param routes (first-registered wins within pass 2), then prefix routes (longest wins within pass 3). Registration order is irrelevant for passes 1 and 3.

**Consequences:**
- Exact and prefix routes are deterministic regardless of order. This covers the common case (most routes are exact or prefix).
- Param routes require care: more-literal patterns must be registered before all-param patterns of the same depth. This is documented and demonstrated in examples.
- The 3-pass design was considered for replacement with first-match-wins. Deferred: the change would be breaking and the benefit is marginal for typical route counts.

---

## ADR-005: Comptime-generic UDP packet type

**Status:** Accepted

**Context:** UDP carries application-defined binary structs. A fixed built-in packet type would limit interoperability. A runtime `[]u8` slice would lose type safety and require the user to handle serialization manually.

**Decision:** `UdpServer` and `UdpClient` are generic over a comptime `Packet: type`. The user defines their own `extern struct` and passes it at the instantiation site (`zix.Udp.Server(MyPacket)`). zix handles endianness, size validation, and framing. The application owns the packet definition and identity logic.

**Consequences:**
- The server does not stamp or modify any packet field. The `id` field (if present) is the sender's responsibility.
- Endianness helpers (`toEndian`, `fromEndian`) are fully generic: they work on any `extern struct`.
- `@sizeOf(Packet)` is comptime-known, enabling the RFC 768 size assert and the fixed receive buffer `[@sizeOf(Packet)]u8`.

---

## ADR-006: LITTLE endianness as default for UDP

**Status:** Accepted

**Context:** UDP packets transmitted across machines or languages must agree on byte order. The two common choices are LITTLE (x86/ARM native, most modern hardware) and BIG (network byte order, RFC 791 convention).

**Decision:** `Endianness.LITTLE` is the default in both `UdpServerConfig` and `UdpClientConfig`. BIG is available for interop with legacy or internet protocols.

**Consequences:**
- On x86 and ARM (the majority of deployment targets), LITTLE is a no-op (no swapping performed).
- Cross-language clients (Go, C++, Rust) on the same hardware family also default to little-endian, so no conversion is needed in the common case.
- Users targeting network byte order (BIG) must explicitly set `endianness: .BIG` on both sides.

---

## ADR-007: Timeout-based disconnect detection for UDP

**Status:** Accepted

**Context:** UDP has no connection state. There is no OS-level equivalent of TCP FIN. The only reliable way to detect that a client has stopped sending is the absence of traffic for a configurable period.

**Decision:** Track clients by remote address in a `Managed(ClientRecord)` list. Update `last_seen` on each packet. On `receiveTimeout` expiry (poll interval) and after each burst of packets (rate-limited check), scan for clients whose `last_seen` is older than `disconnect_timeout_ms` and remove them.

**Consequences:**
- Worst-case detection delay is `disconnect_timeout_ms + poll_timeout_ms`. This is documented and configurable.
- A client that crashes and restarts from a new port is treated as a new client.
- A client that restarts from the same port is re-registered on the next packet.
- False positives (briefly silent clients) are bounded by `disconnect_timeout_ms`.

---

## ADR-008: Heap-allocated peer snapshot for UDP broadcast

**Status:** Accepted

**Context:** Broadcast requires sending the received packet to all currently connected clients. The client list is mutable (new clients may join between packets). Passing a pointer to the mutable list into the concurrent task would create a data race.

**Decision:** Before `io.concurrent(processPacket)`, snapshot the current client addresses into a heap-allocated `[]IpAddress` (`smp_allocator.alloc`). The task receives the snapshot by value in its `Task` struct. The task frees the snapshot via `defer` after all sends complete.

**Consequences:**
- No shared mutable state between the receive loop and concurrent tasks.
- Allocation only occurs when `broadcast = true` and the clients list is non-empty.
- A client that disconnects between the snapshot and the broadcast send will receive a send error that is silently ignored (correct behavior).

---

## ADR-009: extra_buf as arena-allocated []HttpHeader

**Status:** Accepted

**Context:** The original design stored custom response headers in a fixed `[32]HttpHeader` buffer. This caused an out-of-bounds write when `max_response_headers = .LARGE` (64 slots) and more than 32 headers were added. A compile-time cap was insufficient because the cap is runtime-configurable per server instance.

**Decision:** In `Response.init()`, allocate `extra_buf = arena.alloc(HttpHeader, max_headers)` from the per-request arena. `max_headers` comes from `ServerConfig.max_response_headers.value()`. The `max_headers` field on `Response` was removed, `extra_buf.len` is the cap.

**Consequences:**
- The cap is exact: no `@min(..., 128)` clamp, no wasted slots.
- `Response.init()` is now fallible (`!Response`) because `arena.alloc` can fail.
- The arena lifetime guarantees the buffer is valid for the request and reclaimed automatically.

---

## ADR-010: UDS (Unix Domain Socket)

**Status:** Accepted, Implemented (2026-05-13)

**Context:** Unix Domain Sockets are the standard IPC mechanism on Linux and macOS for same-host communication. A `zix.Uds` namespace following the same pattern as `zix.Udp` would complete the trilogy of transport protocols.

**Decision:** Implemented in `src/uds/`. Namespace aggregator at `src/uds/Uds.zig`, exported as `pub const Uds = @import("uds/Uds.zig")` in `zix.zig`. Stream mode only (datagram requires raw `std.posix`, not exposed via `std.Io.net.UnixAddress`, and is deferred). Frame format: 4-byte `u32` length header (native little-endian) followed by payload bytes. `UdsClient.sendMsg`/`recvMsg` and `echoHandler` all use this frame contract.

**`std.Io.net` API used:** `std.Io.net.UnixAddress.init(path)`, `.listen(io, opts) !Server`, `.connect(io) !Stream`. `has_unix_sockets = false` on WASI: both `Server.init()` and `Client.connect()` emit `@compileError` on unsupported platforms.

**Consequences:**
- `zix.Uds.Server`, `zix.Uds.Client`, `zix.Uds.ServerConfig`, `zix.Uds.ClientConfig`, `zix.Uds.HandlerFn`, and `zix.Uds.echoHandler` are all public.
- Server uses Model 1 (`io.concurrent()`): one accept thread, task per connection.
- Socket path is unlinked before bind (clean restart) and again on `runWith()` return.
- `error.PathEmpty` is returned by `Server.init()` when `config.path` is empty.
- `allocator` field in `UdsServerConfig` is reserved for future extensions. Current implementation is allocation-free (stack buffers only).

---

## ADR-011: Comptime middleware wrapper pattern

**Status:** Accepted

**Context:** HTTP handlers need cross-cutting concerns (auth, rate limiting, CORS, logging) that apply to subsets of routes. Options were: runtime chain runner (heap-allocated list of middleware functions called in order), decorator pattern (wrapper functions), or manual handler composition.

**Decision:** Comptime wrapper functions that return `HandlerFn`. Each wrapper takes `comptime next: HandlerFn` and returns a new `HandlerFn`. The `next` call is a direct function call — no runtime dispatch, no allocation. Composing left-to-right: outermost wrapper runs first.

```zig
fn withAuth(comptime next: zix.Http.HandlerFn) zix.Http.HandlerFn {
    return struct {
        fn handle(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) anyerror!void {
            // guard ...
            return next(req, res, ctx);
        }
    }.handle;
}

server.registerHandler("/private", withAuth(withLogging(privateHandler)));
```

**Consequences:**
- Zero runtime overhead. Each unique `next` value generates a distinct function at comptime.
- No heap allocation. No middleware chain runner to deinit.
- Composition is explicit at the registration call site — readers see the full chain without looking inside any function.
- Each unique composition generates a new comptime function, excessive combinations increase binary size.

---

## ADR-012: Explicit HTTP server behavior config fields

**Status:** Proposed

**Context:** Several HTTP server behaviors are embedded in `server.zig` internals and not visible in `HttpServerConfig`: the 404 auto-response when no route matches, the keep-alive loop, and the static file fallback behavior. Users cannot override these without modifying source.

**Decision:** Add named fields to `HttpServerConfig` for every configurable behavior. `null` disables a behavior, a function value enables the user's override. Proposed additions:

```zig
pub const HttpServerConfig = struct {
    // existing fields ...
    not_found:  ?HandlerFn = null,    // null = built-in 404 plain text
    keep_alive: bool       = true,    // false = close after each response
};
```

The `public_dir` field already exists but its role as an opt-in feature (not a magic fallback) should be made explicit in documentation.

**Consequences:**
- Config struct is the complete contract: if it is not in the struct, it does not happen.
- Breaking change for any code that relies on the current implicit 404 behavior (minimal impact in practice).
- `not_found = null` preserves the current default behavior, no migration required unless the user wants a custom 404.
- Static fallback magic is removed: `public_dir = ""` (already the default) disables it, as it does now.

---

## ADR-013: Explicit allocator in UdpServerConfig

**Status:** Accepted

**Context:** `UdpServer` uses the heap for two purposes: the `Managed(ClientRecord)` client list (process lifetime) and the per-packet `[]IpAddress` broadcast snapshot (freed inside `processPacket`). Both previously used `std.heap.smp_allocator` internally — invisible to the caller. `HttpServerConfig` already exposes `allocator: std.mem.Allocator` for router storage. The project's "explicit over implicit" principle applies equally to memory ownership: hiding the allocator makes it impossible to substitute a leak-detecting allocator in tests.

**Decision:** Add `allocator: std.mem.Allocator` as a required field (no default) to `UdpServerConfig`. The server uses this allocator for the client list and broadcast peer snapshots. `UdpClientConfig` receives no allocator field because `UdpClient` makes no heap allocations — all buffers are stack-allocated (`[@sizeOf(Packet)]u8`).

**Why `ArenaAllocator` is explicitly rejected for UDP:** Unlike HTTP (where the router allocator is append-only), the UDP server allocates and frees a peer snapshot on every packet when `broadcast = true`. `ArenaAllocator.free()` is a no-op — memory is not reclaimed until `arena.deinit()`. On a busy broadcast server this causes unbounded growth:

```
// PoC: what goes wrong with ArenaAllocator
var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
var server = try MyServer.init(.{
    .allocator = arena.allocator(), // WRONG for UDP
    .broadcast = true,
    ...
});
// Each received packet when broadcast = true:
//   alloc(IpAddress, N)  ->  real allocation, grows arena
//   free(peers)          ->  NO-OP, memory not reclaimed
// After M packets with N clients: M * N * @sizeOf(IpAddress) bytes permanently held
// arena.deinit() is never called while the server runs -> unbounded memory growth
```

`ArenaAllocator` is correct for `HttpServerConfig.allocator` because the router is append-only: routes are registered once at startup and freed together via `arena.deinit()` when the server shuts down.

**Consequences:**
- Breaking change: all existing `UdpServerConfig` initialisers must add `.allocator = ...`
- Test code can now pass `std.testing.allocator` for leak detection, prod code passes `std.heap.smp_allocator`.
- `UdpServerConfig` and `HttpServerConfig` are now consistent: both expose an explicit, required allocator field.
- `UdpClient` remains simpler by design — no heap allocation, no allocator field required.

---

## ADR-014: `Server.init(comptime stack_threshold, config)`, explicit stack buffer threshold

**Status:** Accepted

**Context:** The original API used a comptime generic function as the entry point: `zix.Http.Server(4096).init(config)`. This forced callers to treat `HttpServer` as a factory function rather than a struct, which was unintuitive and inconsistent with the rest of the API. The stack threshold controls whether per-connection I/O buffers (`read_buf`, `write_buf`) live on the stack or heap: if `max_client_request` and `max_client_response` both fit within `stack_threshold`, the buffers are stack-allocated, otherwise they fall back to `smp_allocator`.

**Decision:** Expose a `pub const Server` struct with a single `pub fn init(comptime stack_threshold: usize, config: Config) !HttpServerImpl(stack_threshold)`. The `HttpServerImpl` generic remains private. Call sites become `zix.Http.Server.init(4096, .{...})`: `Server` reads as a type, `init` reads as a constructor.

**Consequences:**
- Call sites are one level simpler: `Server.init(N, config)` instead of `Server(N).init(config)`.
- `stack_threshold` must remain `comptime`: Zig requires comptime-known sizes for stack arrays.
- `HttpServerImpl(stack_threshold)` is the concrete type returned, callers use `var server = try ...` without naming the generic type.
- Breaking change: all existing call sites updated via `sed`.

---

## ADR-015: Model 2 work-queue architecture (ConnQueue)

**Status:** Accepted

**Context:** The original Model 2 used `io.concurrent()` to dispatch connections from each worker thread. This added scheduler overhead (condvar wakeup per connection) that caused ~4× higher latency than a comparable blocking-thread HTTP server (334 µs vs ~88 µs) despite matching throughput (~145K req/s). A blocking-thread architecture — dedicated accept thread + OS thread pool + synchronous I/O — eliminates the fiber scheduler from the hot path entirely.

**Decision:** Replace per-worker `io.concurrent()` dispatch with a shared `ConnQueue` (mutex + condvar + `ArrayListUnmanaged`). Accept threads (`worker_count`, default 2) only call `accept()` and `queue.push()` (they never handle I/O). Pool threads (`pool_size`, default `max(10, cpu_count * 2)`) call `queue.pop()` and then handle each connection synchronously with blocking I/O. `std.Io.Mutex` and `std.Io.Condition` are used (Zig 0.14 sync primitives. `std.Thread.Mutex` does not exist in this version).

**Consequences:**
- Pool threads handle connections with pure blocking I/O: no condvar dispatch overhead per request, no fiber wakeup latency.
- Throughput ~143–144K req/s, latency ~92 µs avg. A ~3–5K req/s gap and ~4 µs latency gap vs comparable blocking-thread servers remains, attributed to `std.http.Server` parsing overhead and the per-connection arena vs direct POSIX allocators.
- `pool_size` is now a configurable field in `HttpServerConfig` (`0` = auto `max(10, cpu_count * 2)`).
- Accept threads are fast enough that 2 is sufficient to saturate the kernel accept queue, `workers = N` allows explicit override.
- `io.concurrent()` is still used in Model 1 (`workers = 1`) (unaffected).

---

## ADR-017: Channel, In-Process Typed Message Passing

**Status:** Accepted, Implemented (2026-05-13)

**Context:** The server models (Model 1 / Model 2) handle request concurrency. There is no primitive for typed message passing between concurrent tasks within a single process. Go channels and POSIX pipes address this pattern, zix needs its own Zig-native equivalent that works alongside `io.concurrent()` tasks.

**Decision:** Implemented as `zix.Channel(comptime T: type)`. Buffered only (capacity > 0, unbuffered rendezvous deferred). Blocking `send(io, value)` and `recv(io)`. Exported as `pub const Channel = @import("channel/Channel.zig").Channel` in `zix.zig`. Open questions resolved:

- **Locking:** `std.Io.Mutex` + `std.Io.Condition` (fiber-aware, works in both `io.concurrent()` handler tasks and OS threads). `std.Thread.Mutex` was rejected because it blocks the OS thread.
- **Storage:** heap-allocated ring buffer (`allocator.alloc(T, capacity)`), runtime capacity, allocator required in `init()`.
- **Naming:** `Channel` (not `Chan`), locked at first example.
- **Unbuffered:** not yet implemented. `init()` asserts `capacity > 0`.
- **`select`/multiplex:** deferred. Ring design does not preclude it.

**Consequences:**
- `zix.Channel(T)` is a generic returning a struct. Usage: `const MyChan = zix.Channel(u32)`.
- `init(allocator, capacity)` allocates the ring buffer. `deinit()` frees it.
- `close(io)` unblocks all waiting `recv()` calls: receivers drain remaining items then get `error.Closed`.
- `send()` and `recv()` require an `io` valid on the calling thread: each OS thread needs its own `std.Io` (e.g. from `std.Io.Threaded`).
- Non-blocking `trySend`/`tryRecv` are deferred. All current examples use blocking variants.

---

## ADR-016: SSE via `res.stream()` + `SseWriter`, `.ASYNC` preferred

**Status:** Accepted (dispatch model updated by ADR-021)

**Context:** SSE (Server-Sent Events) requires a streaming HTTP response: headers are sent once with no `Content-Length`, and the connection stays open while the handler pushes events. The existing `Response.send()` assumes a complete body and always emits `Content-Length`. A new code path is needed without breaking the existing response API.

SSE connections are long-lived (seconds to minutes per stream). `.POOL`'s blocking thread pool assigns one OS thread per open connection for the full stream duration. With the default `max(10, cpu_count * 2)` pool, a handful of SSE clients would exhaust all pool threads and starve regular HTTP requests. `.ASYNC` (`dispatch_model = .ASYNC`) dispatches each connection as a concurrent fiber via `io.async()`, allowing thousands of open SSE streams without thread exhaustion.

**Decision:**

1. Add `res.stream() !SseWriter` to `Response`. It sends `Content-Type: text/event-stream`, `Cache-Control: no-cache`, `Connection: keep-alive`, and `Date` (no `Content-Length`), then sets `res.streaming = true` and returns an `SseWriter`.

2. `SseWriter` holds `*std.Io.Writer` (the connection's buffered writer). Each method writes the SSE wire format and flushes immediately:
   - `writeEvent(data)` -> `data: <data>\n\n`
   - `writeNamedEvent(event, data)` -> `event: <event>\ndata: <data>\n\n`
   - `comment(text)` -> `: <text>\n`

3. `handleConnection` checks `if (res.streaming) break` after each dispatch. When the handler returns the keep-alive loop exits and the TCP connection closes. The browser's `EventSource` auto-reconnects after the default 3-second retry.

4. SSE examples must use `dispatch_model = .ASYNC` (see ADR-021). This is documented in the example, the README, and HLD.

**Consequences:**
- No change to `Response.send()` — existing handlers are unaffected.
- `res.streaming` defaults to `false`; only SSE handlers set it to `true`.
- The `.ASYNC` preference is a usage constraint, not enforced at compile time. Handlers that call `res.stream()` in a `.POOL` server will work but will block pool threads for the stream duration.
- `SseWriter` is exported from `zix.Http.SseWriter` for handler authors who want to type-annotate the writer.

---

## ADR-018: Timeout strategy, B+D (ctx.timedOut + ConnRegistry eviction)

**Status:** Accepted

**Context:** The original `HttpServerConfig.response_timeout_ms` field was never wired into `server.zig`. It existed as a placeholder. Two classes of timeout are needed: a network-level guard for clients that stall before or during header send (holding a pool thread indefinitely), and a handler-level budget for slow application logic.

`SO_RCVTIMEO` was investigated and rejected: on Linux, `SO_RCVTIMEO` fires `EAGAIN`, which `std.Io.Threaded.netReadPosix` maps to `errnoBug` (a panic in debug mode and `error.Unexpected` in release). It cannot be used on blocking sockets in this stack. `stream.shutdown(.both)` is the correct interruption mechanism: on Linux it causes a blocked `readv()` to return 0 (EOF), which propagates as `error.HttpConnectionClosing` or `error.ReadFailed` through `std.http.Server.receiveHead()`.

Four options were prototyped and tested.

**Option A: Connection max-age (rejected):**
A deadline is set once at accept time and checked at the top of each keep-alive loop iteration. This is a connection lifetime cap, not a per-idle-gap timeout. The check fires only when `receiveHead()` returns, so it cannot interrupt a client that goes permanently idle. A thread is held indefinitely inside `receiveHead()` once the client stops sending. Option A is not wired into the server.

**Option C: Watchdog thread per connection (rejected):**
Spawning one OS thread per accepted connection eliminates the permanent-idle problem. Each watchdog sleeps for `timeout_ms` and calls `stream.shutdown(.both)` if the connection has not finished. Tested and working: fires at exactly 5.006s. Rejected because it adds one OS thread per active connection (with a 64KB virtual stack each), which multiplies memory pressure under load. Option D achieves the same coverage at zero extra threads.

**Decision:** Adopt B + D as two independent, orthogonal layers. Remove `response_timeout_ms` and replace it with two config fields:

- `conn_timeout_ms: u32 = 0` (**Layer D**): `ConnRegistry` embedded in `HttpServerImpl`. On each 500ms timer tick, `registry.evict()` scans active connections and calls `stream.shutdown(.both)` on any whose deadline has passed. `handleConnection` registers a `ConnEntry` on accept and deregisters (via `defer`) on close. Effective in model 2 only (the timer thread already exists). Eviction precision: `[deadline, deadline + 500ms]`.

- `handler_timeout_ms: u32 = 0` (**Layer B**): `ctx.deadline` is set from config before each handler dispatch. Handlers opt in by calling `ctx.timedOut()` between expensive steps and responding with 408 early. Zero overhead when disabled (null check on deadline). Works in both model 1 and model 2.

The two layers are orthogonal: D fires if the client stalls before the handler ever starts, B fires if the handler takes too long after it starts. Both default to 0 (disabled) so existing code is unaffected.

**Consequences:**
- `response_timeout_ms` removed: callers that set it must migrate to `conn_timeout_ms` and/or `handler_timeout_ms`.
- Layer D fires `shutdown(.both)` which causes `receiveHead()` to return `error.ReadFailed`. This error case is now handled in `handleConnection`.
- Layer B is cooperative: a handler that does not call `ctx.timedOut()` is never interrupted. This is intentional (forced cancellation across arbitrary Zig code is not safe).
- `conn_timeout_ms` should be >= `handler_timeout_ms`. If D fires while the handler is mid-response, the connection closes abruptly instead of sending a clean 408.
- Option C is the correct choice for deployments where per-connection jitter must be bounded to exact milliseconds rather than `[deadline, deadline + 500ms]`.

---

## ADR-019: Router routes, MultiArrayList (SoA) layout

**Status:** Accepted

**Context:** `Router.routes` was `ArrayList(Route)` where `Route = {path, handler, kind}`. Dispatch Pass 2 (PARAM) and Pass 3 (PREFIX) iterate the list filtering by `kind` before accessing `path` or `handler`. AoS interleaves all three fields in memory, so iterating `kind` pulls `path` and `handler` into cache even when they are not yet needed.

**Decision:** Replace `ArrayList(Route)` with `MultiArrayList(Route)`. Each field (`kind`, `path`, `handler`) is stored in its own contiguous array. Pass 2 iterates only `items(.kind)` with an index, touching `items(.path)[i]` and `items(.handler)[i]` only on a PARAM match. Pass 3 zips `items(.kind)` and `items(.path)` without loading `items(.handler)` until a prefix candidate is confirmed.

**Consequences:**
- `routes.items.len` becomes `routes.len`; field access becomes `routes.items(.field)[i]`
- `init()` simplified: `routes` default-initializes to `.{}`, no explicit `.empty` needed
- `append()` and `deinit()` signatures are unchanged
- Unit tests in `router.zig` updated; integration tests and examples unchanged (public API unaffected)
- Practical gain is proportional to PARAM and PREFIX route count; most production deployments favour exact routes (O(1) via `exact_map`) so the improvement is cache-coherence rather than algorithmic

---

## ADR-020: Http.Client, wrapping std.http.Client with typed response and named errors

**Status:** Accepted

**Context:** zix had a server but no client. Callers writing integration test harnesses, service-to-service calls, or webhook senders needed to reach out to HTTP endpoints. The stdlib provides `std.http.Client` but its API is low-level: callers manage redirect buffers, body readers, head invalidation, and connection pooling themselves. There was no concept of a size-capped response, a typed response object the caller owns, or a named error set.

**Decision:** Implement `zix.Http.Client` as a thin wrapper over `std.http.Client` that adds:

1. **Typed config (`HttpClientConfig`)**: allocator, io, connect/response/read timeouts, body cap, redirect policy, user-agent. All required fields are named. All optional fields have defaults.

2. **Connect timeout**: passed to `std.http.Client.connectTcpOptions(.{ .timeout = Io.Timeout })`. This is the only timeout enforced in v1 because `connectTcpOptions` exposes a timeout parameter. Response and read timeouts require IO-level wiring and are deferred.

3. **Body size cap**: `body_reader.allocRemaining(gpa, .limited(max_response_body))` returns `error.StreamTooLong`, which is remapped to `error.BodyTooLarge`. This prevents silent OOM on large or malicious responses.

4. **Head bytes copy**: `std.http.Client.Response.head.bytes` points into the connection's read buffer. It is invalidated by `response.reader()` and becomes dangling after `req.deinit()`. The client copies `head.bytes` via `gpa.dupe` before calling `response.reader()`. This makes `ClientResponse.header()` and `iterateHeaders()` safe after the request completes.

5. **Caller-owned `ClientResponse`**: holds `status_code: u16`, `head_bytes: []u8`, `body_data: []u8`, all owned by `config.allocator`. Caller calls `deinit()` to free. No hidden lifetime coupling to the `HttpClient` instance.

6. **Named errors**: `error.InvalidUrl` (parse failure, unsupported scheme, missing host) and `error.BodyTooLarge` surface before the caller needs to inspect stdlib error sets. `error.Timeout` from `std.Io` propagates unchanged for connect timeouts.

**Alternatives considered:**

- *Build on raw TCP streams (like UDS client)*: would require reimplementing HTTP/1.1 framing, chunked transfer, header parsing, redirect following, and connection pooling. Too much scope for v1. `std.http.Client` provides all of this correctly.

- *Return `std.http.Client.Response` directly*: the caller would inherit all the head invalidation and buffer lifetime constraints, plus would need to manage the connection pool state. Defeats the "explicit over implicit" goal.

- *Single `fetch()` call path*: `std.http.Client.fetch()` hides connection-level details. It does not expose a way to inject a per-call connect timeout, making `connect_timeout_ms` unimplementable. The lower-level `connectTcpOptions` + `request()` + `receiveHead()` path was chosen instead.

**Consequences:**
- One extra heap allocation per request (head bytes copy via `gpa.dupe`). Size is the raw head (status line + headers), typically a few hundred bytes.
- `ClientResponse` is not safe to use after `deinit()`.
- TLS (HTTPS) is out of scope for zix. The library is a network backend: TLS termination is delegated to an upstream proxy (nginx, HAProxy, Envoy). `std.http.Client` supports TLS internally, but zix does not expose, configure, or test it. Plain HTTP on the internal network is the intended usage.
- `response_timeout_ms` and `read_timeout_ms` are stored in config and documented as "v1: not yet enforced" so callers can set them now and get enforcement in a future release without an API change.

---

## ADR-021: DispatchModel enum (POOL / ASYNC / MIXED)

**Status:** Accepted

**Context:** The original `HttpServerConfig` used `workers: usize` to select between two concurrency modes: `workers = 1` for single-accept `io.async()` dispatch and `workers = 0` / `workers = N` for the work-queue thread pool. A third mode — N accept threads each dispatching via `io.async()` without a ConnQueue — existed as a natural middle ground. The `workers` field was overloaded: a value of `1` changed the dispatch strategy entirely rather than setting an accept thread count. This was non-obvious and not self-documenting at call sites.

**Decision:** Introduce `DispatchModel = enum(u8) { POOL = 0, ASYNC = 1, MIXED = 2 }` as a named field `dispatch_model: DispatchModel = .POOL` in `HttpServerConfig`. The three models are:

- `.POOL` (default): N accept threads push to a shared `ConnQueue`. M pool threads pop and handle connections with synchronous blocking I/O. Best throughput under high connection counts. `workers` controls accept thread count; `pool_size` controls pool thread count.
- `.ASYNC`: Single accept thread dispatches each connection via `io.async()`. Preferred for SSE and WebSocket — long-lived connections do not hold pool threads. `workers` and `pool_size` are ignored.
- `.MIXED`: N accept threads each dispatch via `io.async()` directly — no `ConnQueue`. Balanced throughput and latency. `pool_size` is ignored.

The old `workers = 1` shorthand for single-accept dispatch is removed. Callers wanting that behavior set `dispatch_model = .ASYNC`.

`workers = 0` now means cpu_count accept threads for `.POOL` and `.MIXED`. The former default of 2 was an undercount on machines with many cores.

**Consequences:**
- Breaking change: callers using `workers = 1` must migrate to `dispatch_model = .ASYNC`.
- `dispatch_model` is self-documenting at the call site. The three strategies are explicit enum variants, not magic `usize` values.
- `pool_size` is silently ignored for `.ASYNC` and `.MIXED` — no error, documented in `HttpServerConfig`.
- Enum backing type `u8` follows the project convention for all named enums.

---

###### end of adr
