# Architecture Decision Records: zix

Each ADR records a significant design decision: the context that made it necessary, the decision taken, and its consequences. Accepted ADRs are binding. Proposed ones are under discussion.

---

## ADR-001: `std.Io` as the I/O abstraction

**Status:** Accepted

**Context:** The server must handle many concurrent connections without blocking on I/O. Zig 0.16 provides `std.Io` as an opaque event loop abstraction over OS facilities (epoll, kqueue, io_uring, etc.). The alternative was raw OS threads with explicit synchronization.

**Decision:** Accept `std.Io` as a parameter in `zix.Http.Server` and `zix.Udp.Server`. The caller owns and provides the backend (`process.io` for runtime-managed or `std.Io.Threaded` for an explicit cap). The server uses `io.concurrent()` in model 1. In model 2 the pool threads call `handleConnection` directly with a `std.Io` derived from `std.Io.Threaded`.

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

**Decision:** Implemented in `src/uds/`. Namespace aggregator at `src/uds/Uds.zig`, exported as `pub const Uds = @import("uds/Uds.zig")` in `lib.zig`. Stream mode only (datagram requires raw `std.posix`, not exposed via `std.Io.net.UnixAddress`, and is deferred). Frame format: 4-byte `u32` length header (native little-endian) followed by payload bytes. `UdsClient.sendMsg`/`recvMsg` and `echoHandler` all use this frame contract.

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

**Decision:** Comptime wrapper functions that return `HandlerFn`. Each wrapper takes `comptime next: HandlerFn` and returns a new `HandlerFn`. The `next` call is a direct function call (no runtime dispatch, no allocation). Composing left-to-right: outermost wrapper runs first.

```zig
fn withAuth(comptime next: zix.Http.HandlerFn) zix.Http.HandlerFn {
    return struct {
        fn handle(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) anyerror!void {
            // guard ...
            return next(req, res, ctx);
        }
    }.handle;
}

var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/private", .handler = withAuth(withLogging(privateHandler)) },
}, .{ .io = process.io, .ip = "127.0.0.1", .port = 9000 });
```

**Consequences:**
- Zero runtime overhead. Each unique `next` value generates a distinct function at comptime.
- No heap allocation. No middleware chain runner to deinit.
- Composition is explicit at the registration call site: readers see the full chain without looking inside any function.
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

**Context:** `UdpServer` uses the heap for two purposes: the `Managed(ClientRecord)` client list (process lifetime) and the per-packet `[]IpAddress` broadcast snapshot (freed inside `processPacket`). Both previously used `std.heap.smp_allocator` internally, invisible to the caller. The project's "explicit over implicit" principle applies equally to memory ownership: hiding the allocator makes it impossible to substitute a leak-detecting allocator in tests.

**Decision:** Add `allocator: std.mem.Allocator` as a required field (no default) to `UdpServerConfig`. The server uses this allocator for the client list and broadcast peer snapshots. `UdpClientConfig` receives no allocator field because `UdpClient` makes no heap allocations: all buffers are stack-allocated (`[@sizeOf(Packet)]u8`).

**Why `ArenaAllocator` is explicitly rejected for UDP:** Unlike HTTP (where the router allocator is append-only), the UDP server allocates and frees a peer snapshot on every packet when `broadcast = true`. `ArenaAllocator.free()` is a no-op: memory is not reclaimed until `arena.deinit()`. On a busy broadcast server this causes unbounded growth:

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
- `UdpClient` remains simpler by design: no heap allocation, no allocator field required.

---

## ADR-014: `Server.init(comptime stack_threshold, config)`, explicit stack buffer threshold

**Status:** Accepted

**Context:** The original API used a comptime generic function as the entry point: `zix.Http.Server(4096).init(config)`. This forced callers to treat `HttpServer` as a factory function rather than a struct, which was unintuitive and inconsistent with the rest of the API. The stack threshold controls whether per-connection I/O buffers (`read_buf`, `write_buf`) live on the stack or heap: if `max_recv_buf` and `max_client_response` both fit within `stack_threshold`, the buffers are stack-allocated, otherwise they fall back to `smp_allocator`.

**Decision:** Expose a `pub const Server` struct with a single `pub fn init(comptime stack_threshold: usize, comptime routes: []const Route, config: Config) !HttpServerImpl(stack_threshold, routes)`. The `HttpServerImpl` generic remains private. Call sites become `zix.Http.Server.init(4096, &[_]zix.Http.Route{...}, .{...})`: `Server` reads as a type, `init` reads as a constructor.

**Consequences:**
- Call sites are one level simpler: `Server.init(N, routes, config)` instead of `Server(N).init(config)`.
- Both `stack_threshold` and `routes` must remain `comptime`: Zig requires comptime-known sizes for stack arrays, and the route table is zero-size at runtime when comptime.
- `HttpServerImpl(stack_threshold, routes)` is the concrete type returned, callers use `var server = try ...` without naming the generic type.
- Breaking change: all existing call sites updated.

---

## ADR-015: Model 2 work-queue architecture (ConnQueue)

**Status:** Accepted

**Context:** The original Model 2 used `io.concurrent()` to dispatch connections from each worker thread. This added scheduler overhead (condvar wakeup per connection) that caused ~4x higher latency than a comparable blocking-thread HTTP server (334 us vs ~88 us) despite matching throughput (~145K req/s). A blocking-thread architecture (dedicated accept thread + OS thread pool + synchronous I/O) eliminates the fiber scheduler from the hot path entirely.

**Decision:** Replace per-worker `io.concurrent()` dispatch with a shared `ConnQueue` (mutex + condvar + `ArrayListUnmanaged`). Accept threads (`worker_count`, default 2) only call `accept()` and `queue.push()` (they never handle I/O). Pool threads (`pool_size`, default `max(10, cpu_count * 2)`) call `queue.pop()` and then handle each connection synchronously with blocking I/O. `std.Io.Mutex` and `std.Io.Condition` are used (Zig 0.14 sync primitives. `std.Thread.Mutex` does not exist in this version).

**Consequences:**
- Pool threads handle connections with pure blocking I/O: no condvar dispatch overhead per request, no fiber wakeup latency.
- Throughput ~143-144K req/s, latency ~92 us avg. A ~3-5K req/s gap and ~4 us latency gap vs comparable blocking-thread servers remains, attributed to `std.http.Server` parsing overhead and the per-connection arena vs direct POSIX allocators.
- `pool_size` is now a configurable field in `HttpServerConfig` (`0` = auto `max(10, cpu_count * 2)`).
- Accept threads are fast enough that 2 is sufficient to saturate the kernel accept queue, `workers = N` allows explicit override.
- `io.concurrent()` is still used in Model 1 (`workers = 1`) (unaffected).

---

## ADR-017: Channel, In-Process Typed Message Passing

**Status:** Accepted, Implemented (2026-05-13)

**Context:** The server models (Model 1 / Model 2) handle request concurrency. There is no primitive for typed message passing between concurrent tasks within a single process. Go channels and POSIX pipes address this pattern, zix needs its own Zig-native equivalent that works alongside `io.concurrent()` tasks.

**Decision:** Implemented as `zix.Channel(comptime T: type)`. Buffered only (capacity > 0, unbuffered rendezvous deferred). Blocking `send(io, value)` and `recv(io)`. Exported as `pub const Channel = @import("channel/Channel.zig").Channel` in `lib.zig`. Open questions resolved:

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
- No change to `Response.send()`: existing handlers are unaffected.
- `res.streaming` defaults to `false`. Only SSE handlers set it to `true`.
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
- `routes.items.len` becomes `routes.len`. Field access becomes `routes.items(.field)[i]`
- `init()` simplified: `routes` default-initializes to `.{}`, no explicit `.empty` needed
- `append()` and `deinit()` signatures are unchanged
- Unit tests in `router.zig` updated, integration tests and examples unchanged (public API unaffected)
- Practical gain is proportional to PARAM and PREFIX route count, most production deployments favour exact routes (O(1) via `exact_map`) so the improvement is cache-coherence rather than algorithmic

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

**Context:** The original `HttpServerConfig` used `workers: usize` to select between two concurrency modes: `workers = 1` for single-accept `io.async()` dispatch and `workers = 0` / `workers = N` for the work-queue thread pool. A third mode (N accept threads each dispatching via `io.async()` without a ConnQueue) existed as a natural middle ground. The `workers` field was overloaded: a value of `1` changed the dispatch strategy entirely rather than setting an accept thread count. This was non-obvious and not self-documenting at call sites.

**Decision:** Introduce `DispatchModel = enum(u8) { POOL = 0, ASYNC = 1, MIXED = 2 }` as a named field `dispatch_model: DispatchModel = .POOL` in `HttpServerConfig`. The three models are:

- `.POOL` (default): N accept threads push to a shared `ConnQueue`. M pool threads pop and handle connections with synchronous blocking I/O. Best throughput under high connection counts. `workers` controls accept thread count. `pool_size` controls pool thread count.
- `.ASYNC`: Single accept thread dispatches each connection via `io.async()`. Preferred for SSE and WebSocket: long-lived connections do not hold pool threads. `workers` and `pool_size` are ignored.
- `.MIXED`: N accept threads each dispatch via `io.async()` directly, no `ConnQueue`. Balanced throughput and latency. `pool_size` is ignored.

The old `workers = 1` shorthand for single-accept dispatch is removed. Callers wanting that behavior set `dispatch_model = .ASYNC`.

`workers = 0` now means cpu_count accept threads for `.POOL` and `.MIXED`. The former default of 2 was an undercount on machines with many cores.

**Consequences:**
- Breaking change: callers using `workers = 1` must migrate to `dispatch_model = .ASYNC`.
- `dispatch_model` is self-documenting at the call site. The three strategies are explicit enum variants, not magic `usize` values.
- `pool_size` is silently ignored for `.ASYNC` and `.MIXED` (no error, documented in `HttpServerConfig`).
- Enum backing type `u8` follows the project convention for all named enums.

---

## ADR-022: zix.Tcp raw stream server and client

**Status:** Accepted

**Context:** After the HTTP engine was complete, the next protocol layer was a generic raw TCP stream server: no HTTP framing, no router, user-defined handler owns the stream. The HTTP PoC in `rnd/` proved all three dispatch models (POOL, ASYNC, MIXED) work for TCP. The question was how to expose this as a library API without duplicating HTTP internals.

**Decision:**

- `zix.Tcp.Server` and `zix.Tcp.Client` are standalone types in `src/tcp/server.zig` and `src/tcp/client.zig`. No shared base with `zix.Http.Server`, same standalone-per-protocol principle as `zix.Uds.Server`.
- `HandlerFn = *const fn(stream: std.Io.net.Stream, io: std.Io) void`: identical signature to `zix.Uds.HandlerFn`. The handler owns the stream and must close it before returning.
- `TcpServer.run(io)` / `runWith(io, handler)`: io is passed as a parameter (not stored in config). The caller controls the `std.Io` backend lifetime.
- All three dispatch models (POOL, ASYNC, MIXED) apply with the same `ConnQueue` + thread spawn pattern from `zix.Http.Server`. `DispatchModel` is defined once in `src/tcp/config.zig` and imported by `src/tcp/http/config.zig` (single source of truth for all TCP-based protocols).
- Frame format: `[u32 big-endian payload_len][payload bytes]`. Big-endian (network byte order) is chosen for TCP because it is the network convention and matches what other protocol libraries expect. `zix.Uds` uses little-endian by contrast (local only, no interop requirement).
- `initArgs()` on the server and `connectArgs()` on the client parse `--ip` and `--port` from CLI args, following the `zix.Udp.Server.initArgs()` pattern.

**Consequences:**
- `zix.Tcp.Http.*` and `zix.Tcp.Server`/`Client` coexist under the same `zix.Tcp` namespace: HTTP is the high-level protocol, raw TCP is the low-level stream layer.
- `zix.Tcp.Server` does not allocate from a user-provided allocator. The `ConnQueue` uses `smp_allocator` directly, same approach as the HTTP server.
- The built-in `echoHandler` uses `takeVarInt(u32, .big, 4)` and `readSliceAll` (vs. the `readSliceShort` loop in `zix.Uds.echoHandler`), consistent with the PoC pattern confirmed during the TCP RnD phase.
- Future Fix protocol (`zix.Tcp.Fix.*`) follows the same standalone-per-protocol pattern and will not be built on top of `zix.Tcp.Server`.

---

## ADR-023: zix.Logger, structured thread-safe event logger

**Status:** Accepted, Implemented (2026-05-23)

**Context:** Every server implementation (HTTP, TCP, UDP, UDS, FIX, gRPC) needs a logging layer. `std.debug.print` is unsafe on background OS threads because it routes through `std.Options.debug_io`, a global `Io.Threaded` singleton: calling it from any spawned thread races with the test runner's IPC channel and causes a panic. A logging primitive that is safe on background OS threads without a `std.Io` dependency is required.

**Decision:** Implement `zix.Logger` as a struct with a per-instance spinlock (atomic CAS) protecting a 64 KB write buffer and file descriptor. All I/O uses raw `std.posix.write` (no `std.Io`, no `std.debug.print`). Protocol-specific log methods provide machine-parseable lines without post-processing: `system()`, `access()` (HTTP), `conn()` (TCP), `packet()` (UDP), `frame()` (UDS), `session()` (FIX), `rpc()` (gRPC). Each server config accepts `logger: ?*Logger = null`. The logger is optional and the server is silent when null.

**Consequences:**
- All log methods are safe to call simultaneously from any OS thread including thread-pool workers, accept threads, and connection handlers.
- No `std.Io` allocation per log call. The write buffer is flushed on date rollover, sequence rotation, explicit `logger.flush()`, or `logger.deinit()`.
- File rotation is daily (`YYYY-MM-DD/` subdirectory) with per-file sequence numbering. `save_path` must exist before `Logger.init`: the logger does not create it.
- Console output is controlled by `ConsoleMode` (`.OFF`, `.DEBUG_ONLY`, `.ALWAYS`). Both file and console paths are guarded by `save_min_level` / `console_min_level`.
- `access()` derives log level from HTTP status: 2xx/3xx=INFO, 4xx=WARN, 5xx=ERROR. `rpc()` derives from grpc-status code.

---

## ADR-024: zix.Fix, FIX 4.x session layer as standalone server

**Status:** Accepted, Implemented (2026-05-23)

**Context:** FIX (Financial Information eXchange) protocol is the dominant messaging standard for financial trading systems. It uses SOH (0x01) as a field delimiter (not a length prefix), which makes it incompatible with the `readSliceShort` recv pattern used by HTTP. A standalone server following the same config and dispatch-model pattern as `zix.Tcp` is required, with the session layer (Logon/Logout/Heartbeat handling) built in so callers do not implement it themselves.

**Decision:** Implement `zix.Fix` in `src/tcp/fix/`. `serveConn` is the core loop: it accumulates bytes via `takeByte` until `findMessageEnd` detects a complete message, then dispatches internally by MsgType (tag 35). Logon/Logout/Heartbeat/TestRequest are handled automatically, all other messages are echoed. No handler callback needed. Session state (comp_id, seq_num) is stack-local to `serveConn`, no heap allocation in the message loop. All 4 dispatch models apply. `.ASYNC` is the default because FIX sessions are long-lived. `.EPOLL` runs natively on Linux (single epoll accept loop, `FdQueue` ring buffer, pool workers hold each connection for its full lifetime, same pattern as `zix.Grpc`). Non-Linux falls back to `.POOL`.

**Consequences:**
- `takeByte` in a loop avoids the `readSliceShort` deadlock: the reader's internal buffer absorbs the full TCP segment, subsequent `takeByte` calls drain it with no extra syscalls.
- `serveConn` uses only stack buffers (`recv_buf[MAX_MSG_SIZE * 2]`, `fields[MAX_FIELDS]`). No per-request allocation.
- `buildMessage` computes and embeds the checksum. `verifyChecksum` validates incoming messages. Bad checksum closes the connection without a reply.
- `std.debug.print` is absent from all thread entry functions, learned from the `std.Options.debug_io` test runner IPC panic.
- `FixClient` provides a typed client (`logon`, `logout`, `sendMessage`, `recvMessage`) for tests and examples.

---

## ADR-025: `reuse_address = true` on all dispatch models (SO_REUSEADDR + SO_REUSEPORT)

**Status:** Accepted

**Context:** Every server in zix (Http, Http2, Grpc, Tcp, Fix) calls `addr.listen(io, .{ .reuse_address = true })`. In Zig's `std.Io.Threaded`, `reuse_address = true` sets both `SO_REUSEADDR` and `SO_REUSEPORT` on POSIX. `SO_REUSEPORT` is strictly required by the POOL dispatch model: each accept thread calls `addr.listen()` on the same port independently, without it the second bind fails with `EADDRINUSE`. The choice was whether to set it conditionally (POOL only) or unconditionally (all models).

**Decision:** Apply `reuse_address = true` unconditionally on every `addr.listen()` call regardless of dispatch model. All models share the same socket setup path: no branching on `dispatch_model` at the socket level. This is socket-level behavior, it is documented here and inline in source, not exposed as a config field.

**Consequences:**
- POOL works correctly: all accept threads bind to the same port and the kernel load-balances incoming connections across them.
- ASYNC, MIXED, and EPOLL also receive `SO_REUSEPORT` as a side effect. Multiple server instances on the same port do not crash: the kernel silently distributes connections between them.
- This is intentional. Port-sharing between processes is a valid deployment pattern (rolling restart, staged rollout). Examples that share a port number coexist without error when run simultaneously for the same reason.
- No `ServerConfig` field is added to expose or toggle this behavior.

---

## ADR-026: zix.Http1 writeSimple, combined buffer beats writev for small bodies

**Status:** Accepted

**Context:** `zix.Http1.writeSimple` (the EPOLL hot path) sends a status line, headers, and a body. Two strategies were profiled in ReleaseFast. Strategy A (`writev` with two `iovec` entries) is zero-copy: the header buffer and the body slice are passed as separate segments, no concatenation. Strategy B copies the header and body into one contiguous stack buffer, then issues a single `write()`. The theory favored A (no copy), the measurement did not.

**Decision:** Use a contiguous buffer plus a single `write()` for bodies up to 3840 bytes (header buffer is a 256-byte stack array, total fits a 4096-byte stack buffer). For bodies above 3840 bytes, fall back to inline `writev` to avoid copying a large payload. The Date header is filled by `cachedDate()`, which calls `clock_gettime` only every 256 requests via a thread-local tick counter. The response header itself is built by `buildSimpleHeader`, a direct byte encoder (`appendStatusCode` / `appendDec` / `appendBytes`) replacing `std.fmt.bufPrint`.

**Consequences:**
- Small-body throughput rose from ~450k to ~612k req/s at c128 on the reference machine. A single contiguous `write()` outperforms `writev` with two small segments because the per-syscall `iovec` setup and kernel gather cost exceeds the cost of copying ~100 bytes on the stack.
- Large bodies (over 3840 bytes) keep zero-copy semantics through the `writev` fallback, so big responses pay no 4KB stack-copy penalty.
- Benchmark caveat: loopback `wrk` at high concurrency is roughly 85 percent kernel-bound and highly variance-prone. Comparisons must be run back-to-back in one script under identical conditions, never from separate captures. See docs commentary and the project memory note.

---

## ADR-027: Response header default lowered to `.MINIMAL` (16)

**Status:** Accepted

**Context:** `HttpServerConfig.max_response_headers` controls the per-request arena slot count for custom response headers (ADR-009). The default was `.COMMON` (32). Most handlers in practice emit far fewer than 16 custom headers (a bare service adds 2 to 6), so the 32-slot default over-provisioned the per-request arena for the common case. The `zix.Http1` engine made the same move at the compile-time level (`MAX_HEADERS` 32 to 16, plus a runtime `Http1ServerConfig.max_headers: u8 = 16`).

**Decision:** Lower the default to `.MINIMAL` (16) for both `zix.Http` (`max_response_headers`) and `zix.Http1` (`max_headers` and the `MAX_HEADERS` cap). Callers who need more raise the tier explicitly (`.COMMON`, `.LARGE`, `.EXTRA_LARGE`, or `.{ .CUSTOM = N }`).

**Consequences:**
- Worst-case per-response header arena footprint drops from ~1 KB (32 slots) to ~512 bytes (16 slots), tightening the DoS bound for a handler that loops on `addHeader()`.
- Behavioral change for any deployment that relied on the implicit 32-slot cap and added 17 to 32 custom headers. Such handlers now hit `error.TooManyHeaders` until the tier is raised. Documented in `docs/headers-en.md` and `docs/headers-id.md`.
- The dynamic-growth allocation strategy (ADR-009) is unchanged. Only the default cap value moved.

---

## ADR-028: Version selector on the shared `zix.Http.Client`

**Status:** Accepted

**Context:** The `zix.Http1` engine needed a client example (`examples/http1_client.zig`). A separate raw `zix.Http1.Client` would have duplicated URL parsing, TLS, redirect handling, and connection pooling that `zix.Http.Client` already provides by wrapping `std.http.Client`. The Zig std roadmap adds HTTP/2 to that same `std.http.Client`, so a single client is the natural path to multi-version support. The open question was how to express the protocol version without a separate client per version.

**Decision:** Add a `version` field to `HttpClientConfig`, typed `Version` (`HTTP_1`, `HTTP_2`, `HTTP_3`, CAPITAL variants, no `auto`, default `.HTTP_1`), exported as `zix.Http.ClientVersion`. `request()` guards on it: `HTTP_1` proceeds (HTTP/1.1 over `std.http.Client`), `HTTP_2` and `HTTP_3` return `error.UnsupportedVersion`. Do not build a separate `zix.Http1.Client`.

**Consequences:**
- One client surface speaks HTTP/1.1 today and works against any HTTP/1.1 server, including the raw `zix.Http1` server. The `http1_client` example uses it with `.version = .HTTP_1`.
- The API is forward-shaped: when an h2 (or h3) backend lands, it slots in behind the existing enum value with no caller-facing signature change.
- A caller selecting `HTTP_2` or `HTTP_3` fails fast and explicitly rather than silently downgrading.

---

## ADR-029: `zix.Http1` per-handler deadline via thread-local, not a ctx object

**Status:** Accepted

**Context:** `zix.Http` enforces a per-handler budget through `ctx.isExpired()`, where the server sets `ctx.deadline` before dispatch (ADR-018). The `zix.Http1` handler signature is `fn(head, body, fd) void` with no context parameter, kept deliberately lean for the zero-alloc hot path. Adding a `ctx` parameter would have rippled through `Router`, every example, and the dispatch loop, and would have widened the hot-path call.

**Decision:** Add `Http1ServerConfig.handler_timeout_ms`. Store the deadline in a `threadlocal` in `core.zig`, armed by the server (`setTimeout(config.handler_timeout_ms)`) before every dispatch across all four models (`serveConn` via `ServeOpts`, `serveEpollConn` via a parameter). Expose `zix.Http1.isExpired()` and `zix.Http1.setTimeout()` as free functions so handlers query and override their budget without a ctx object. Add `408 Request Timeout` to `statusPhrase`.

**Consequences:**
- The handler signature stays `fn(head, body, fd) void`. No breaking change to `Router` or existing examples.
- The deadline is per-worker-thread, which matches the shared-nothing dispatch model (each connection is served by one thread for the call's duration).
- `handler_timeout_ms == 0` leaves the thread-local at 0, so `isExpired()` is a cheap always-false check with no clock syscall on the disabled path.
- `serveConnOne` (a niche public helper) is left unarmed. Callers using it directly arm their own deadline via `setTimeout()`.

---

## ADR-030: `zix.Http1` engine-owned WebSocket frame loop with per-event write coalescing

**Status:** Accepted

**Context:** The first `zix.Http1` WebSocket example did the handshake in the handler and then ran its own `while (true)` blocking `std.posix.read` loop to echo frames. Under `.EPOLL` the engine accepts with `accept4(SOCK.NONBLOCK)`, so that read returned `EAGAIN` on the first empty poll and the handler returned at once: the handshake succeeded but no frame was ever echoed (0 frames). Even where the loop did work (the blocking `.ASYNC` sockets), it parked one worker thread on a single connection for that connection's whole lifetime, which caps concurrency at the worker count. A reference io_uring echo server keeps every connection in a completion loop instead, so all connections progress at once.

**Decision:** Make the WebSocket frame loop engine-owned under `.EPOLL`. A handler calls `WebSocket.serve(fd, key, on_frame)`, which performs the handshake and records a thread-local handoff (`core.requestWebSocket`). Right after the handler returns, the epoll loop reads the handoff (`core.takeWebSocket`), flips the connection to WebSocket mode (`Conn.ws`), and from then on routes that fd to `serveEpollWs`. Each readable event reads once (the loop is level-triggered, so more bytes re-fire) and `WebSocket.pump` parses every complete frame, invoking `on_frame` for text and binary, auto-ponging ping, and auto-echoing close. The callback is `fn(fd, opcode: u8, payload) void`: `opcode` is the raw RFC 6455 value to keep the type in `core.zig` and avoid a `core` to `websocket` import cycle. All frames produced during one readable event are staged in a per-event `SendSink` and flushed in a single `write()`, so a pipelined burst costs one syscall instead of one per frame. `buildHeader` was split out of `buildFrame` for the staged path. On `.ASYNC` and `.POOL` the handoff is cleared and the connection ends after the handler returns: engine-owned WebSocket is `.EPOLL` only.

**Consequences:**
- The handler signature stays `fn(head, body, fd) void`. WebSocket support adds no ctx and no router change, the handler just calls `WebSocket.serve` instead of looping.
- No worker is parked per connection. One epoll worker drives many WebSocket connections, echoing each on readiness.
- Write coalescing is the dominant pipelined win. Without it a 16-deep pipelined burst issued 16 writes per event.
- A frame larger than the connection read buffer can never complete: `serveEpollWs` closes such a connection rather than spin. For the echo workload (small frames) this never triggers.
- A manual blocking-loop WebSocket is still possible under `.ASYNC` or `.POOL` (those sockets are blocking), but it carries the old one-worker-per-connection cap and does not use the handoff.

---

## ADR-031: `zix.Grpc` `.EPOLL` multiplexed event loop, inline dispatch, and hot-path coalescing

**Status:** Accepted

**Context:** The first `zix.Grpc` `.EPOLL` model was not event-multiplexed. A single accept loop fed a `FdQueue`, and a pool of `max(10, cpu*2)` worker threads each popped one connection and ran the full h2c connection lifetime with blocking reads. Concurrency was therefore capped at the worker count: under a load of 256 or 1024 connections only ~24 were ever served at once. The per-request cost was also high: a unary reply issued seven `write()` calls (HEADERS, DATA, trailer, each a separate frame-header write plus a payload write), plus two `WINDOW_UPDATE` writes per inbound DATA frame, plus a 9-byte frame-header read then a payload read per frame, with `TCP_NODELAY` on. Each connection also allocated a 16-slot stream table with a 64 KB inline body per slot (~1.1 MB per connection). Server-streaming routes spawned one thread per stream. Under benchmark load, unary throughput plateaued at ~110k req/s regardless of connection count and streaming sat at ~2.6k calls/s.

**Decision:** Re-architect the `.EPOLL` model into a shared-nothing multiplexed event loop and cut the per-request work to a near-minimum syscall count.

- Multiplexing: each worker owns a private `SO_REUSEPORT` listener, its own epoll instance, and a private fd-indexed `GrpcConnTable`. The kernel load-balances new connections across the per-worker listeners. `worker_count = pool_size` (0 selects cpu count). The h2 connection loop became a resumable state machine (`GrpcMuxConn`): a per-connection read accumulator persists across readable events and holds any partial frame, a handshake phase machine (`await_preface` / `await_upgrade` / `await_preface2` / `h2`) replaces the blocking preface read, and `muxFrameLoop` processes every complete buffered frame and returns to epoll on `EAGAIN`.
- Inline dispatch: in the `.EPOLL` model every route, including server-streaming, is dispatched inline on the worker (no per-stream thread, no connection write mutex), because the worker owns the connection. A streaming handler runs on the event loop and must stay bounded.
- Per-event write coalescing: all response frames produced while handling one readable event (initial HEADERS, every DATA, the trailer, and any control frame) are staged in a per-connection `ReplyStage` cork and flushed in a single `write()`. A unary reply is one write instead of seven.
- Flow control: `SETTINGS_INITIAL_WINDOW_SIZE` is raised to 16 MB and the connection receive window is bumped once after the handshake, so small request bodies never trigger a per-DATA `WINDOW_UPDATE`. The connection window is replenished in bulk only past a threshold.
- Buffered reads: frame headers and payloads are served from the connection read buffer, so a HEADERS plus DATA pair costs one `read()` rather than four.
- Right-sized buffers: per-stream `body` and `header_scratch` are slices into per-connection backing buffers sized to `max_body` / `max_header_scratch`, not fixed inline arrays.
- Cached reply blocks: the constant reply headers for the common case are HPACK-encoded once at comptime - `:status 200` plus `content-type: application/grpc+proto` for the initial HEADERS, and `grpc-status: 0` for the OK trailer. `buildGrpcHeaders` and `buildGrpcTrailer` memcpy the cached block and stamp the 9-byte frame header instead of re-running the HPACK encoder (two 61-entry linear scans plus Huffman per header). The dynamic encoder is the fallback for other content-types or statuses.

The blocking `serveGrpcConn` and `serveGrpcLoop` are retained unchanged for `.ASYNC`, `.POOL`, and `.MIXED`.

**Consequences:**
- Unary throughput rose from ~110k to ~420k req/s at 256 connections. Streaming rose from ~2.6k to ~28k calls/s. On isolated (separate-cpuset) cores the server is CPU-saturated and scales near-linearly at ~38-39k req/s per core. The earlier lower result at 1024 connections was a shared-core measurement artifact where the load generator and the server contended for the same cores.
- `pool_size` changed meaning for `.EPOLL`: it is now the multiplexing worker count (0 = cpu), not a blocking pool size. A large value no longer helps and oversubscribes the scheduler.
- The advertised `max_streams` must be at least the client's concurrent-stream count, or the client's optimistically opened streams get `REFUSED_STREAM` at connection start. The HttpArena entry sets `max_streams = 128` (h2load uses `-m 100`).
- `.EPOLL` streaming handlers must be bounded: a long-running stream blocks the other connections on that worker. Unbounded streaming should use `.ASYNC`.
- Non-blocking writes use the staged flush. `EAGAIN` is treated as a broken pipe and drops the connection. This never triggers for the small replies of the benchmark, but a slow client with a large reply could be dropped: a future `EPOLLOUT` backpressure queue would remove that edge.
- The h2c upgrade path in the multiplexed loop is minimal: it returns `400` without an `Upgrade: h2c` header (the validate probe path) and `101` then the connection preface with one, but it does not serve an initial request carried on stream 1 of the upgrade. Prior-knowledge clients are unaffected.
- A one-line change in `HpackEncoder.writeString` (annotating the Huffman result as `?usize`) lets the encoder run at comptime so the cached blocks can be built there.

---

## ADR-032: `EPOLL_MAX_EVENTS = 512`, one named epoll batch constant across all servers

**Status:** Accepted

**Context:** Every native epoll worker (`zix.Tcp`, `zix.Http`, `zix.Fix`, `zix.Grpc`, `zix.Http1`) calls `epoll_wait` with a fixed-size `epoll_event` array. That size is the maximum number of ready events the worker drains in one syscall. The value was `256` everywhere, expressed three different ways: a named file-level `epoll_max_events` in `tcp` and `http`, and an inline `const max_events` literal in `fix`, `grpc`, and `http1`. With one `SO_REUSEPORT` listener and one epoll instance per worker, a worker on a 12-core box at 4096 connections holds roughly 341 fds, so more than 256 can be readable in a single tick. A 256 cap then forces a second `epoll_wait` to drain the remainder, an extra syscall per loop that appears only once the ready set exceeds the cap.

**Decision:** Raise the batch to `512` and express it as one named, documented file-level constant `EPOLL_MAX_EVENTS: usize = 512` in each of the five server files, used for both the `[N]epoll_event` array size and the `epoll_wait` count argument. The inline `256` literals and the lowercase `epoll_max_events` consts are removed, and the type is unified to `usize`. 512 covers a worker's ready-fd set in one syscall at the high connection counts where the old cap was binding.

**Consequences:**
- A/B perf (`EPOLL_MAX_EVENTS` 256 vs 512 on the same release build, fixed-response handler, profiled with `perf stat` on userspace counters) showed the change is neutral at c128 and c1024, where the ready set per worker is well under 256 so the cap never bound, and a small gain at c4096, where throughput rose ~8% and userspace cycles per request fell. That matches the predicted mechanism: fewer `epoll_wait` syscalls only where the ready set exceeded 256.
- Cost is one `epoll_event` array per worker growing from ~6 KB to ~12 KB of stack. Negligible against the 512 KB worker stacks.
- No public API change. The constant is private and not configurable. The value is a tuned default, not a knob.
- The c2048+ throughput collapse seen on a shared-core loopback box is environmental (load generator and server contend for the same cores). It is neither caused nor addressed by this constant.

---

## ADR-033: `zix.Http1` router gains `.PREFIX` and `.PARAM`, params via thread-local

**Status:** Accepted

**Context:** The `zix.Http1` comptime router was exact-match only (`std.mem.eql` over the route table), while the higher-level `zix.Http` router has supported `.EXACT` / `.PREFIX` / `.PARAM` since ADR-004. Any prefix or path-param routing in an Http1 server had to be hand-written in the dispatch function with `startsWith` and `splitScalar` (as `examples/http1_paths.zig` did). The capture problem is the reason the gap persisted: the `zix.Http` matcher writes captured params to `req.path_params`, but the Http1 handler is `fn(head: *const ParsedHead, body, fd) void` with no `Request` and no per-call mutable state to write into (the same lean zero-alloc signature defended in ADR-029).

**Decision:** Bring the Http1 router to parity with the Http router. Add `RouteKind { EXACT, PREFIX, PARAM }` and a `kind` field (default `.EXACT`) to `zix.Http1.Route`, and partition the route table at comptime into a `StaticStringMap` (exact), a PARAM array, and a PREFIX array. Dispatch keeps the ADR-004 priority: exact (O(1) hash) > param (first-registered wins) > prefix (longest wins). Param capture reuses the ADR-029 model: matched `:name` segments are written to a per-handler `threadlocal` store in `router.zig`, read back through a new free function `zix.Http1.pathParam(name)` instead of a ctx or `Request`. The store is a fixed array capped at `MAX_PATH_PARAMS = 8`, so capture is zero-alloc. The prefix pass guards the boundary index behind `startsWith` (`p[route.path.len]` is only read once `p.len >= route.path.len`), and the same guard was applied back to the `zix.Http` router, which had the index ordered before the `startsWith` check.

**Consequences:**
- The handler signature is unchanged and `.kind` defaults to `.EXACT`, so every existing exact-only Http1 route table compiles and behaves identically. No breaking change.
- Param values are thread-local and valid only for the dispatch call (they borrow the request path), which matches the shared-nothing model where one worker serves one connection at a time. A handler that needs a param past its own return must copy it.
- Capture is capped at 8 params per match. A pattern with more `:segments` than that fails to match rather than overflowing.
- The `zix.Http` prefix pass no longer reads one byte past a short request path. In ReleaseFast this was a harmless out-of-bounds read masked by the `and`, in Debug or ReleaseSafe it was a panic on any request path shorter than a registered prefix.
- `examples/http1_paths.zig` still demonstrates manual `startsWith` / `splitScalar` routing on purpose (custom matching beyond the three kinds). Its prior comment claiming the router is exact-only was corrected.

---

## ADR-034: `zix.Http` `.EPOLL` shared-nothing architecture

**Status:** Accepted

**Context:** The original `zix.Http` `.EPOLL` model used a centralized design: one accept thread pushed accepted connection streams to a shared `ConnQueue` (mutex + condvar + ring buffer), and a pool of `max(10, cpu_count * 2)` worker threads popped from the queue and called `handleOneRequest`. Under benchmark load at c1000, the `ConnQueue` mutex became the bottleneck. Throughput was 428k req/s vs 480k for `zix.Http1` (same shared-nothing architecture, 11% gap). `pool_size` was the relevant config field.

**Decision:** Replace the centralized model with a shared-nothing architecture matching `zix.Http1`. Each worker binds its own `SO_REUSEPORT` listener, creates its own `epoll` instance, and runs its own level-triggered event loop. The kernel distributes new connections across per-worker listeners. No `ConnQueue`, no mutex, no condvar, no fd handoff between threads.

- `workers` (not `pool_size`) is now the EPOLL worker count for `zix.Http`. `0` selects cpu_count.
- `pool_size` is ignored for `zix.Http` `.EPOLL` (it still applies to `.POOL`).
- Level-triggered `EPOLLIN` replaces `EPOLLONESHOT`: connections stay registered after each request and re-fire when new data arrives. No explicit re-arm.
- Accepted fds are blocking: `handleOneRequest` does a synchronous recv/parse/dispatch/send, then the worker returns to `epoll_wait`.
- `handleOneRequest` is unchanged: no new non-blocking logic, no per-connection state table.

**Consequences:**
- Throughput: 428k to 451k req/s at c1000 (`wrk -c1000 -t4 -d10s`), closing the gap vs `zix.Http1` from 11% to 6.8%.
- Remaining 6.8% gap is structural: `zix.Http` allocates an `ArenaAllocator` per connection and builds a `Request` / `Response` / `ParsedHead` (64-entry header array) per request. `zix.Http1` uses zero-alloc stack-local parsing. This gap is not closeable by architecture alone.
- The `pool_size` field is silently ignored for `.EPOLL` (same behavior as `.ASYNC` and `.MIXED` already ignored it). Existing callers that set `.pool_size = N` with `.EPOLL` must migrate to `.workers = N`.
- SSE and WebSocket are still not suitable for `.EPOLL`: blocking reads park the worker for the connection's lifetime. Use `.ASYNC`.

---

## ADR-035: gRPC mux per-connection staging, cached SETTINGS, and TCP_CORK

**Status:** Accepted

**Context:** The multiplexed gRPC EPOLL event loop (ADR-031) stages a reply (HEADERS + DATA + trailer) into a `ReplyStage` buffer and flushes it in one `write()`. The buffer was an inline `[4096]u8` on `GrpcMuxConn`. A streaming handler that emits thousands of messages overflowed 4096 bytes repeatedly, forcing one `write()` per overflow (~85 KB streamed in ~21 flushes). The server SETTINGS frame was re-encoded from a parameter loop on every new connection. Streaming handlers produced many small intermediate flushes, each becoming its own TCP segment.

**Decision:** Make the reply stage backing caller-owned and give the mux connection a larger buffer plus a precomputed handshake, and cork streaming output.

- `ReplyStage.buf` is now a `[]u8` slice supplied by the caller. The blocking inline path (`dispatchGrpcInline`) passes a 4096-byte stack array (unary replies are small). The mux path passes the connection's own buffer.
- `GrpcMuxConn` owns a 64 KB `stage_buf`. A ~5000-message streaming call (~85 KB peak) flushes in two writes, and ~100 concurrent unary replies (~6 KB) coalesce into a single write.
- `GrpcMuxConn.init` calls `buildSettingsFrame` once to fill a 33-byte `settings_frame` (9-byte header + 4 params). The handshake appends that blob as-is instead of re-running the encode loop per connection.
- `muxDispatch` detects a streaming route (`routeIsStreaming`) and wraps the handler in `setTcpCork(fd, true)` / `setTcpCork(fd, false)`: the kernel holds output until the MSS is full or cork clears, coalescing the intermediate stage flushes into fewer segments. Unary routes are not corked (already single-write). No-op on non-Linux.

**Consequences:**
- Fewer syscalls per streaming call (writes drop from ~21 to ~2 for a 5000-message reply) and fewer TCP segments on the wire under cork.
- `GrpcMuxConn` grows by ~64 KB per connection. This is a deliberate per-connection memory cost traded for syscall and segment reduction. The mux model holds one `GrpcMuxConn` per live h2 connection, not per stream.
- Related stream-write fix: `fdWriteAll` now polls and retries on `EAGAIN` rather than reporting `BrokenPipe`, so a full send buffer on a non-blocking EPOLL socket no longer truncates a staged reply. See the 0.4.0 changelog.

---

## ADR-036: Opt-in per-worker ResponseCache (shared `utils`) across `zix.Http1`, `zix.Http`, and `zix.Grpc`, plus WebSocket build-once broadcast

**Status:** Accepted

**Context:** A handler re-runs and re-serializes its response on every request. For repeated idempotent calls whose response is expensive to build, that work dominates the userspace cost, while the kernel path is shared by every approach. The engine already proves a precompute-then-write pattern elsewhere (comptime gRPC reply blocks, the cached SETTINGS frame, the thread-local cached Date). A PoC measured whether extending that to user handlers, as a per-key precomputed response cache, pays off. Loopback, AMD Ryzen 5 5600H (12 logical cores), zig 0.16.0, wrk 4.2.0, threads 6, duration 5s, c512 and c4096, twice each, avg Requests/sec:

| Response | c512 nocache -> cache | c4096 nocache -> cache |
| :- | :- | :- |
| trivial (13 B) | 614,551 -> 611,758 (-0.5%) | 453,328 -> 449,565 (-0.8%) |
| built (~32 KiB JSON) | 171,821 -> 230,844 (+34.4%) | 137,516 -> 163,116 (+18.6%) |
| file-backed (~32 KiB) | 209,590 -> 225,058 (+7.4%) | 158,803 -> 163,997 (+3.3%) |

A body-size sweep (c512) puts the crossover near 4 KiB: the delta stays inside run-to-run noise below ~2 KiB (256 B +0.2%, 1 KiB +1.9%, 2 KiB +3.7%), then jumps at 4 KiB (+12.6%) and climbs to +37% at 64 KiB. The file-backed case wins only modestly because the OS page cache already serves the file cheaply.

**Decision:** Add an opt-in, per-worker ResponseCache as a shared module, off by default and scoped to compute-heavy responses, and wire it into `zix.Http1`, `zix.Http`, and `zix.Grpc`. Adopt the same build-once principle for WebSocket broadcast.

- Shared structure in `src/utils/response_cache.zig`: a structure-of-arrays slab (`keys: []u64` open addressing with 0 as the empty sentinel, `meta: []Meta` of `insert_tick_ms` / `len` / `ttl_ms`, and one flat payload slab). Slot count is a power of two indexed by mask. An arena allocates the slab once at init and frees it whole at deinit. A churning cache reuses fixed slots in place, so the arena never grows. Lazy on-access TTL: an entry expires exactly at `insert_tick_ms + ttl_ms`, so `ttl_ms = 0` is never fresh. Expired slots are reused in place by the next store, never zeroed, since zeroing would truncate an open-addressing probe chain. No timer thread is introduced.
- One cache per worker, never shared, never locked (lock-free by ownership). The invariant holds only when one zix-owned thread installs the cache (allocate, set, free on exit) and is the sole thread that touches it. Under `.EPOLL` shared-nothing each worker is exactly that, so the cache is installed there. The `.URING` rings are the same (one thread per ring), so the cache is installed there too. `.POOL` is also zix-owned and could be wired safely, but each pool thread would hold an independent cache (lower hit rate, N times the memory), so it is deferred. `.ASYNC` and `.MIXED` run handlers on the `std.Io` executor pool that zix does not own, where a task is not pinned to one thread, so a shared cache would need locks and break the lock-free design. In this release the cache is installed under `.EPOLL` and `.URING`, the other models leave it uninstalled and the API degrades to a plain send.
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

---

## ADR-037: `.URING` dispatch model on the raw linux io_uring surface, thread-per-core shared-nothing rings

**Status:** Accepted

**Context:** zix offers four readiness-model dispatch options (`.POOL`, `.ASYNC`, `.MIXED`, `.EPOLL`), all level-triggered or thread-per-task models built on the `epoll` readiness interface. The `.EPOLL` path is shared-nothing and competitive on raw loopback throughput, but under pipelined load it spends a large share of userspace cycles on syscall transitions (one `recv`, one `send`, and the `epoll_wait` bookkeeping per ready event). A completion-based io_uring dispatch batches submissions and reaps completions, removing most of those transitions. A PoC measured the effect (loopback, ReleaseFast, two zix builds only, the `.EPOLL` engine versus a hand-rolled io_uring hello server):

| Metric | zix-epoll | zix-uring (PoC) |
| :- | :- | :- |
| p1 cycles/req (userspace) | 1627 | 818 |
| p1 L1-miss/req | 73.5 | 22.9 |
| p16 cycles/req (userspace) | 710 | 240 |
| p16 server CPU (t4 c128, 10s) | ~45.1s | ~37.25s |

io_uring roughly halves userspace cycles per request at pipeline depth 1 and cuts server CPU about 21 percent at equal throughput under depth 16. Peak loopback throughput is parity at depth 1 (kernel and client bound), so the gain is efficiency headroom, not peak req/s. The userspace cyc/req and L1-miss/req drop reproduces the established exception-less, batched-submission syscall mechanism (FlexSC, OSDI 2010), so it is a verification of a known effect, not a local assumption. The PoC proves the gain. The open question this ADR settles, before any `src/` work begins, is which io_uring foundation to build `.URING` on, since that choice drives the whole port. Two independent engine pre-wins that benefit `.EPOLL` regardless have already landed in `zix.Http1` (lazy `parseHead` and the `EPOLLOUT` re-arm), verified by `zig build test-all`. They are still pending for `zix.Http`.

**Decision:** Build the `.URING` dispatch model on the raw linux io_uring surface (`std.os.linux.IoUring`, the stable low-level ring), not the fiber-based `std.Io.Uring`. The two foundations were weighed as:

| Aspect | A. std posix io_uring (`std.Io.Uring`) | B. raw linux io_uring (`std.os.linux.IoUring`) |
| :- | :- | :- |
| Source | std-provided fiber-based `Evented` backend, drop-in `std.Io` | hand-rolled per-worker rings on the stable low-level ring API |
| Coupling | rides the existing `io: std.Io` config field, one code path for all backends | new `.URING`-only runtime, separate from the `std.Io` abstraction |
| Control | submission and reaping owned by std, opaque to zix | full control: ring flags, buffer rings, multishot ops, batching policy |
| Features used | whatever std exposes through `std.Io` | multishot accept and recv, provided buffer ring, one coalesced send per readable completion, gen-tagged `user_data`, deferred close while a send is in flight |
| Shared-nothing | depends on std executor topology | native: one ring per worker, no cross-thread handoff, matches the `.EPOLL` design |
| Stability risk | tracks std internals (the io_uring surface moved across 0.16.x) | depends only on the stable kernel io_uring ABI, not on std internals |
| Maintenance | low (std maintains the engine) | higher (zix owns the ring lifecycle and edge cases) |

Reasoning for B: the measured win comes from features std does not currently expose through `std.Io` (multishot accept and recv, provided buffer rings), so approach A cannot reach the PoC numbers. The shared-nothing per-worker ring model (one ring, one `SO_REUSEPORT` listener, no shared accept queue) is already the topology the `.EPOLL` path uses, so approach B keeps it intact, while approach A reintroduces a std-owned executor topology zix does not control (the same ownership problem that confines the response cache to the shared-nothing per-worker models, ADR-036). Approach B depends only on the stable kernel ABI, so the moving std io_uring surface does not gate it and the work starts on current Zig (0.16.x).

Scope of the decision:
- Topology preserved from `.EPOLL`: thread-per-core, one ring per worker, one `SO_REUSEPORT` listener per worker, no shared accept queue, no cross-thread fd handoff. Process-per-core (fork-per-core) is rejected because it would split the per-worker route tables and response cache out of one address space.
- Minimal correct core first: multishot accept re-armed on `!IORING_CQE_F_MORE`, an fd-indexed slot table (direct index, no hashmap) guarded against the close-versus-recv completion race with a generation tag in `user_data` against fd reuse, a fixed per-connection recv buffer with a plain `recv` SQE, and a batched CQE drain into a stack array. The listener setup uses raw `linux.*` (or `std.Io.net`) because `std.posix.socket` / `bind` / `listen` / `close` were removed in 0.16.x.
- Ring flags are optimizations, not prerequisites: a ring initialized with no flags is correct. `SINGLE_ISSUER`, `COOP_TASKRUN`, and `DEFER_TASKRUN` (the last needs kernel 6.1 or newer) are added and measured one at a time.
- Buffer strategy is staged: start with the fixed per-connection recv buffer plus a plain `recv` SQE (already enough to compete), and move to a registered provided buffer ring with multishot recv only if the measured syscall savings justify the harder buffer lifecycle.
- Other staged levers (each behind its own A/B, settled by perf counters): registered or direct files (`IOSQE_FIXED_FILE`, `accept_direct`), a registered send buffer holding a response-cache payload (`send_fixed` on a hit), reading the clock once per CQE batch for the cache TTL, and `SEND_ZC` for responses past a size gate.
- Implementation order: `zix.Http1` first (proves the ring core), then WebSocket (reuses the upgrade path, the readable-burst coalescing maps to one batched send), then `zix.Grpc` (h2 framing, HPACK, and stream multiplexing are stateful), then `zix.Http` (reuses the Http1 ring core, cheapest last).
- `DispatchModel.URING` is added to every server `config.zig`, with a non-Linux compile-time or run-time fallback to `.EPOLL` (mirrors the existing non-Linux `.EPOLL` to `.POOL` fallback).

**Consequences:**
- The deliverable is CPU per request and connections per core, not a bigger loopback req/s number. Peak loopback throughput stays parity at depth 1 because that workload is kernel and client bound. Acceptance is measured with `cycles:u` and `L1-miss/req` under pipelined load, back to back against `.EPOLL` on the same machine, fresh server per run (the ring pins memlock pages, so reusing a server instance across runs exhausts the per-user memlock budget).
- zix owns the ring lifecycle and its edge cases: the close-versus-recv completion race, fd reuse (handled by the generation tag), and the per-user memlock budget the rings consume. This is the maintenance cost traded for the control that the measured win requires.
- Approach A stays the fallback if the raw-syscall surface proves too costly to maintain, or if a future `std.Io` exposes multishot and provided buffers as first-class operations.
- The two engine pre-wins (lazy `parseHead`, `EPOLLOUT` re-arm) are in `zix.Http1` and benefit `.EPOLL` independently of this decision. Both are now ported to `zix.Http` as well: its `ParsedHead` drops the per-request 64-entry header array and records the raw header block as offsets for `getHeader` to rescan on demand, and its `.EPOLL` worker stages the unwritten response tail on a partial write and arms `EPOLLOUT` to drain it on the next writable event instead of dropping the connection. The coalescing sink is bypassed for SSE, whose draining stays handler-side (a blocking write parks the handler, not a library event loop).
- The io_uring-specific levers above rest on documented kernel mechanisms but have no workload-specific proof yet, so each is settled locally by an A/B with a named perf-counter signal rather than assumed. Peer-reviewed io_uring evidence is mostly storage, so for networking the backing is the FlexSC mechanism plus the kernel maintainer design notes.

**Extension to `zix.Tcp` and `zix.Fix` (callback rings):**
- These two engines could not take a direct ring port: their handler is a blocking `fn(stream, io)` that owns the connection and loops on synchronous reads and writes, which a single-threaded completion loop cannot run. So each gains a new engine-driven callback API alongside the existing blocking one. `zix.Tcp` adds `runFramed` with a per-frame `FrameFn` over a 4-byte length prefix, and `zix.Fix` adds a `.URING` path that runs a resumable session processor (`core.processFixRing`) per readable batch. The blocking `runWith` and `serveConn` paths are unchanged, and their `.URING` still folds to `.EPOLL`.
- FIX heartbeats on the ring use a per-worker periodic timer, not a per-connection one. A single `prep_timeout` SQE per worker (re-armed on each fire, tagged with a new `.timeout` `OpKind` that the other engines treat as a no-op) ticks every `heartbeat_timeout_ms`. On each fire the worker scans its slot table and, for every logged-in session idle past the interval, sends a TestRequest on the first tick then a Logout on the next, written straight to the fd. One SQE per worker plus an O(n) scan per tick beats a per-connection timeout that would cancel and re-arm on every inbound message. Reaping an idle session is close-safe: its only in-flight op is an idle recv with no buffered data, so closing it leaves the stale recv completion to be dropped by the generation tag. This completes the session: `processFixRing` answers peer Heartbeat/TestRequest reactively, and the timer adds the server-initiated half.

## ADR-038: `zix.Tcp` server bakes the handler at comptime, single `run`, mirroring the engine server shape

**Status:** Accepted

**Context:** Every zix server engine except `zix.Tcp` bakes its handler (or route table) into the server type at `init`, so the handler is comptime-known and `run` takes no handler argument (`zix.Http1`, `zix.Http2`, `zix.Grpc`). `zix.Tcp` was the exception: it took the handler as a runtime function pointer through `runWith(io, handler)`, with `run(io)` as a separate entry that used the built-in echo handler, plus `runFramed(io, frame_fn)` for the per-frame callback. The `run` versus `runWith` split and the runtime pointer were inconsistent with the other engines and with the project's explicit-over-implicit and comptime-where-structural principles. Note the asymmetry was already half-resolved: the per-frame `FrameFn` (`runFramed`) was comptime, only the per-connection `HandlerFn` was runtime. This change is justified on consistency and clarity, not measurement. The per-connection blocking handler runs once per accepted connection (a cold dispatch point), so devirtualizing it is negligible, unlike `zix.Http1`'s per-request handler or the per-frame `FrameFn`, which is why those are already comptime.

**Decision:** Mirror the `zix.Http1` / `zix.Grpc` server shape. Bake the handler (or per-frame callback) into the server type at `init` so `run` takes only `io`. `zix.Tcp.Server` becomes a fieldless namespace with comptime constructors over two private factory types:

| Constructor | Returns | Contract |
| :- | :- | :- |
| `Server.init(comptime handler, config)` / `initArgs(..., args)` | `TcpServerImpl(handler)` | per-connection `HandlerFn` (owns the stream) |
| `Server.initFramed(comptime frame_fn, config)` / `initFramedArgs(..., args)` | `TcpFramedServerImpl(frame_fn)` | per-frame `FrameFn` (engine owns the connection) |

Both factory types hold only `config` and expose `init`, `deinit`, and `run(io)`. The built-in echo handler stops being a hidden default behind `run`: it is the public `zix.Tcp.echoHandler`, passed explicitly (`Server.init(zix.Tcp.echoHandler, config)`), per explicit-over-implicit. The `runWith` and `runFramed` methods are removed.

The two factory types (rather than one type with an optional second comptime parameter, as `zix.Http1` uses for `(handler, raw_fn)`) follow a compose-versus-alternative rule. In `zix.Http1` the raw interceptor composes with the handler (same connection, a pre-parse hook), so one impl carries both. In `zix.Tcp`, `HandlerFn` (owns the connection, blocks) and `FrameFn` (engine-owned, never blocks, runs on the `.URING` ring) are mutually exclusive contracts: a connection cannot be both hand-owned and engine-deframed. Two factory types keep that impossible state unrepresentable. The `FrameFn` contract from ADR-037 is unchanged, only its entry point moves.

`io` stays a `run(io)` argument rather than a config field (unlike `zix.Http1` / `zix.Grpc`, whose `io` lives in config). Moving `io` into `TcpServerConfig` for full shape parity (which would also resolve the io-placement inconsistency across the server configs) is a separate, larger change spanning the config struct and every call site, deferred to its own decision.

**Consequences:**
- Breaking API change: `runWith` and `runFramed` are gone, `run(io)` is the only run path, and the constructor carries the handler. The internal worker functions (`serveDispatch`, `runEpoll`, and the pool / async / epoll entries) keep the handler as a runtime value, exactly as `zix.Http1`'s `runAsync` / `runPool` / `runMixed` do. The comptime binding is at the type boundary (no runtime registration), not a hot-loop devirtualization.
- The handler must be comptime-known. A runtime-selected handler (`const h = pick(cfg)`) now branches at the call site (`if (...) Server.init(handlerA, ...) else ...`). This is the one expressiveness cost, accepted on principle for the raw-TCP engine.
- Supersedes the extension API names in ADR-037: the blocking path is `Server.init(handler, config)` then `run(io)` (was `runWith`), the framed ring path is `Server.initFramed(frame_fn, config)` then `run(io)` (was `runFramed`). `.URING` still folds to `.EPOLL` for the per-connection handler and runs natively for the framed callback.
- Verified: the library compiles, all five `tcp_server_*` examples compile, the unit / integration / edge / behaviour suites pass, and all five end-to-end runners (async, pool, mixed, epoll, uring) pass.

---

## ADR-039: `zix.Tcp` / `zix.Udp` / `zix.Uds` move `io` into the server config and `zix.Uds` bakes the handler at comptime, unifying the server shape on `run()`

**Status:** Accepted

**Context:** Five server engines (`zix.Http`, `zix.Http1`, `zix.Http2`, `zix.Grpc`, `zix.Fix`) carry `io: std.Io` in their config, so `run()` takes no argument. The three remaining servers diverged: `zix.Tcp` and `zix.Udp` took `io` as a `run(io)` parameter, and `zix.Uds` took both `io` and the handler at run (`run(io, handler)`). This was the last server-shape inconsistency in the library: moving a server between protocols meant remembering which ones thread `io` through `run`. ADR-038 already baked the `zix.Tcp` handler into the type at `init`, but deliberately deferred the `io` placement as a separate, larger change. Nothing prevents the move: the engine servers prove the pattern, and the internal worker functions already take `io` as a plain value.

**Decision:** Move `io` into the config and bake the `zix.Uds` handler at `init`, so every server is constructed the same way and `run()` takes no argument.

- Add `io: std.Io` as the first, required field of `TcpServerConfig`, `UdpServerConfig`, and `UdsServerConfig`.
- `run()` takes no argument on all three. It reads `self.config.io` and passes that value to the existing internal workers (`serveDispatch`, `runEpoll`, the Udp receive loop, the Uds accept loop), so there is no hot-path or ownership change.
- `zix.Uds` adopts the ADR-038 factory shape: `Server.init(comptime handler, config)` returns a specialized type whose `run()` takes nothing. The built-in echo default is the public `zix.Uds.echoHandler`, passed explicitly. The old `run(io, handler)` / `runWith` path is removed.

The server constructor map is now uniform:

| Server | Construct | Run |
| :- | :- | :- |
| `zix.Http` / `zix.Http1` / `zix.Http2` / `zix.Grpc` / `zix.Fix` | `Server.init(routes_or_handler, config)` | `run()` |
| `zix.Tcp` | `Server.init(handler, config)` / `initFramed(frame_fn, config)` | `run()` |
| `zix.Udp` | `Server(Packet).init(config)` | `run()` |
| `zix.Uds` | `Server.init(handler, config)` | `run()` |

Clients (`zix.Tcp.Client`, `zix.Udp.Client`, `zix.Uds.Client`) keep `io` as a `connect()` / `init()` parameter. Client `io` placement is a separate axis (`zix.Grpc.Client` also takes `io` as a parameter while `zix.Http.Client` carries it in config), deferred to its own decision.

**Consequences:**
- Breaking API change: every `zix.Tcp` / `zix.Udp` / `zix.Uds` server call site adds `.io = process.io` to the config literal and drops the `run` argument. `zix.Uds` callers also pass the handler to `init` (the `runWith` path is gone).
- `io` must outlive the server, the same contract the engine configs already document.
- Supersedes the `io` placement recorded in ADR-038: the `zix.Tcp` run path is now `run()` (was `run(io)`). The handler-at-`init` decision from ADR-038 is unchanged and is extended to `zix.Uds`.
- Full server-shape parity: all eight servers are constructed with a config that carries `io` and served with a no-argument `run()`. Moving a server between protocols is mechanical.
- Verified: the library compiles, every `tcp_server_*` / `udp_server` / `uds_server` example compiles, the unit / integration / edge / behaviour suites pass, and the `tcp` (all five models), `udp`, and `uds` end-to-end runners pass.

---

## ADR-040: user-space hot-path optimizations across the engine family (integer-compare, baked response prefix, lazy parse, writer bypass, copy reduction)

**Status:** Accepted

**Context:** The 0.4.x kernel-cycle pass showed loopback is ~94% kernel TCP, identical for `.EPOLL` and `.URING`. The io_uring syscall levers (direct descriptors, fixed buffers, send_zc, SQPOLL) are sub-noise on this box, and a probe of the top io_uring HTTP engines (ringzero, zeemo) found they use none of them, so those are deprioritized. The remaining wins that clear the 1% bar are in the shared user-space hot path: they are measurable on loopback and help every dispatch model (`.EPOLL`, `.URING`, `.POOL`, `.ASYNC`, `.MIXED`) at once, because the code lives in the shared parse and response paths, not a dispatch loop. The server-process perf profiles name the hot user-space leaves:

| Symbol | http1 EPOLL | http1 URING | http EPOLL | http URING | Pattern |
| :- | :- | :- | :- | :- | :- |
| `mem.eql` (fixed-string compares) | present | 14.99% | present | present | P1 |
| `buildSimpleHeaderInto` / response build | 4.63% | 9.92% | 5.39% | 7.02% | P2 |
| `mem.findScalarPos` (eager header scan) | low | low | present | 10.98% | P3 |
| `Io.Writer.alignBufferOptions` (std writer) | n/a | n/a | 1.91% | 1.97% | P4 |
| `memcpy.memcpyFast` (build-then-copy) | 1.40% | 1.99% | 4.95% | 9.03% | P5 |

**Decision:** Apply five optimization patterns, each as one increment, applied to every engine whose hot path contains it, gated by `zig build test-all`, `zig build examples`, and `zig build test-runner-all` before the next.

| Id | Pattern | What | Targets |
| :- | :- | :- | :- |
| P1 | integer-compare | Replace a hot `mem.eql` against a fixed-length string literal with one integer (u32/u64) load-and-compare. | HTTP/1 version + method, HTTP/2 `:method` / `:path`, gRPC `:path` |
| P2 | baked response prefix | Replace per-request response-header assembly (many small appends or `bufPrint`) with one `@memcpy` of a comptime-baked prefix, plus the variable Content-Length digits and optional cached Date. | Http1, Http |
| P3 | lazy header parse | Parse only the framing headers up front, defer the rest to on-demand lookup. | Http (already lazy) |
| P4 | writer bypass | Write the response straight into the engine sink/fd instead of through `std.Io.Writer`. | Http |
| P5 | copy reduction | Build the response header directly into the send/sink buffer (write-in-place), removing one copy generation. | any build-then-copy path |

Per-engine application (a pattern applies only where the hot path has it):

| Engine | Change |
| :- | :- |
| zix.Http1 | P1 `parseGetFastPath` version/method `readInt` compares. P2 comptime-baked `statusLine` (one `memcpy`) |
| zix.Http | P1 parser framing-header length-switch. P2 + P4 `buildResponse` + `send` Content-Type / Date `@memcpy` (drops `std.Io.Writer`) |
| zix.Http2 / zix.Grpc | P1 `:method` / `:path` length-gated compares |
| WebSocket (Http1 + Http) | already a 16-wide `@Vector(16, u8)` unmask, no change |
| zix.Fix / zix.Tcp / zix.Udp | byte-level or length-prefixed framing, no hot fixed-string compare, no change |

**Config:** internal optimizations, no new server-config field. Should a toggle ever prove necessary it is added to every server config (`Http`, `Http1`, `Http2`, `Grpc`, `Tcp`, `Udp`, `Uds`, `Fix`) with the same name, type, and default, per the flat-config consistency rule.

**Consequences:**
- Faster on every dispatch model, and measurable on loopback (unlike the io_uring levers). Each pattern targets a symbol that is at least ~1% of a server profile.
- No API or behaviour change. Each increment carries an equivalence test (byte-exact output or behaviour), so the wire bytes are unchanged. The unit / integration / behaviour / edge suites plus the end-to-end runners are the regression gate, run green after every increment (56/56 runner protocols each).
- Verified already-optimal (no change): zix.Http `parse` is already lazy and vectorized (P3 pre-done), zix.Http `buildResponse` already bakes the status line and uses `@memcpy` + `writeDecimal` for Content-Length, WebSocket unmask is already SIMD, and zix.Grpc replies already use comptime-cached HPACK blocks.
- Result (httparena-lite, attempt 3, post-sweep, AMD Ryzen 5 5600H, 6/12 threads, loopback, recorded in the README Benchmark tables): representative EPOLL HTTP/1.1 throughput rose versus the prior recorded attempt, baseline 512c 585,239 -> 614,416 req/s (+5.0%) and pipelined 512c 7,156,160 -> 7,682,896 req/s (+7.4%), with the remaining scenarios within loopback variance and `.URING` at parity with `.EPOLL` (expected on a 94%-kernel loopback path). These are full-suite numbers (a fresh server per scenario), so they confirm the direction rather than isolate a per-increment delta.

---

## ADR-041: `.URING` connection-churn scaling (ring `prep_close` teardown + on-ring `RespSink` growth) after the write-path pivot

**Status:** Accepted

**Context:** On the 64-core HttpArena box, `.URING` split from `.EPOLL` by reqs-per-connection. It won the long-lived cells (baseline +14 to +20%, pipelined +9 to +13%) and tied static, but collapsed on the connection-churn cells (json -73%, limited-conn -87%). Per-core throughput was equal or better for `.URING`, so the problem was core occupancy, not work done per request. Under churn the worker engaged only about 7 of 64 cores because each teardown blocked it in a synchronous `linux.close` between connections, making the accept-recv-send-close cycle close-bound. The earlier read had blamed the write path (a response over the 16 KiB send buffer falling back to a blocking off-ring `fdWriteAllDirect`), but the write-path cell (static) already tied, so the real lever was connection setup and teardown.

**Decision:** Two changes, both `.URING` only, with `.EPOLL` byte-for-byte unchanged:

| Change | What |
| :- | :- |
| ring close | `finishClose` submits a `prep_close` SQE (tagged with a new shared `OpKind.close`) and recycles the connection slot first, instead of a synchronous `linux.close`, so the worker keeps reaping completions across teardowns. It falls back to a synchronous close only when the SQ is momentarily full. The half-duplex per-connection state guarantees no in-flight op targets the closing fd. |
| on-ring growth | `RespSink` grows the per-connection `send_buf` (power-of-two `realloc` up to `URING_SEND_BUF_MAX` = 1 MiB, never shrinks, reused through the idle-conn free list) to stage an oversized response on the ring, removing the blocking `fdWriteAllDirect` fallback. |

The shared `OpKind` lives in `src/multiplexers/ring.zig` (relocated from `src/tcp/io_uring`) and gained `close`, so every io_uring engine carries a `.close => {}` arm. Only `zix.Http1` arms it for now.

Rejected on the way, kept for the record. Ring `sendFile` for static was deprioritized because static already ties, so it is quality, not a composite mover. A comptime `Route.profile` write-strategy API is scaffolding rather than a perf lever, because parsing happens before routing and writes live in the handler, so a route-level write profile has nothing real to select until other behaviors exist. A buffer-select parse-in-place recv was implemented and reverted, because the plain recv-into-`conn.buf` path already parses in place with no copy, so the buffer ring only added per-recv bookkeeping and regressed pipelined 13 to 16%. A per-machine `lean` / `throughput` recv-buffer profile (comptime, app-level, no engine change) is kept as a deployment knob.

**Config:** no new server-config field. The per-machine recv buffer is selected by the deployment through the existing `max_recv_buf`. The send-buffer grow cap is an internal constant.

**Consequences:**
- The churn cells recovered to parity on the 64-core box: json -73% to -2.4%, limited-conn 512 -87% to +5.5%, limited-conn 4096 -87% to -1.5%, an absolute jump of roughly 8x on limited-conn and 3.7x on json. Mechanism confirmed: limited-conn 512 server CPU rose from about 722% (around 7 of 64 cores) to about 5443% (around 54 cores), so the cores now fill across teardowns.
- `.URING` now reaches parity or better on every subscribed cell at 50 to 85% less memory than `.EPOLL` (json 289 MiB versus 1.3 GiB, limited-conn 4096 231 MiB versus 1.5 GiB), so the HttpArena entry ships on `.URING`. `.EPOLL` is unchanged this release.
- No API or behaviour change. The `prep_close` teardown is exercised end-to-end by the io_uring integration runners (HTTP, WebSocket upgrade, large-body drain). The grow path is capped and pooled, a correctness and tail-latency guard rather than a hot path, because no benchmark cell emits a response over 16 KiB inline.

---

## ADR-042: dispatch loops stay per-engine, only byte-identical primitives are shared

**Status:** Accepted

**Context:** When `.URING` (ADR-037) landed across engines, the first piece hoisted into a shared module was `src/multiplexers/ring.zig`: the `OpKind` tag and the `user_data` codec (about 40 lines). Every io_uring engine reuses it because the bits must match exactly (an fd-keyed slot guarded by a generation in one `user_data` layout). A second primitive later joined it, `src/multiplexers/slab.zig`: the Linux demand-paging helpers (`mapZeroedSlots`, `unmapSlots`, `releaseSlabPages`) that every per-worker EPOLL / URING connection table uses to mmap zero-filled slots and hand a closed connection's pages back to the OS. Everything else stayed per-engine: each engine keeps its own `.EPOLL` and `.URING` connection table, `acceptAll`, and per-event dispatch. A reader can ask whether those loops should be unified the way the codec and the slab helpers were.

**Decision:** Keep each engine's dispatch loop (`.ASYNC` / `.POOL` / `.MIXED` / `.EPOLL` / `.URING`) and its connection table in its own `server.zig` (or `dispatch/` folder, ADR-043). Do not build a generic multiplexer interface. Share only byte-identical primitives in `src/multiplexers/`: today the `.URING` `user_data` codec (`ring.zig`) and the demand-paging helpers (`slab.zig`). The rule: share primitives that must match, keep dispatch loops and tables per-engine.

**Rationale:** The split is the optimization. Per-engine ownership lets each engine tune its hot path for its own connection shape: `zix.Http1` carves connection buffers from a contiguous demand-paged slab (no per-accept heap call), while `zix.Grpc` and `zix.Fix` hold per-connection heap pointers because their connection objects carry h2 or FIX session state too large or variable for one fixed slab cell. A single generic loop would force one table shape on every engine (erasing the slab win) and add a callback-per-event indirection on the accept / recv / send path, the hottest path in the library. The two shared primitives pass the bar precisely because they are mechanics, not policy: `ring.zig` is a pure bit codec, and `slab.zig` is pure mmap / madvise that works for an inline-struct slot (zero means empty) or a pointer slot (zero means null) without knowing the table shape. Each engine still owns the table that calls them.

**Config:** none. No API change. This records existing intent.

**Consequences:**
- `src/multiplexers/` holds shared primitives only, today `ring.zig` (the `user_data` codec) and `slab.zig` (the demand-paging helpers). The bar for adding to it is byte-identical-by-requirement, not merely similar shape.
- A small amount of boilerplate stays duplicated per engine (the epoll bootstrap and the fd-indexed slot table shape), accepted in exchange for per-engine tunability. A bounds or generation fix in that pattern is applied per engine.
- The connection tables are intentionally not identical: `zix.Http1` inline-struct slab versus `zix.Grpc` / `zix.Fix` per-connection heap pointers, each chosen for that engine's connection shape, but both reach the shared `slab.zig` helpers for the mmap and page-release mechanics.

---

## ADR-043: split each engine's dispatch models into a per-engine dispatch/ folder

**Status:** Accepted

**Context:** Each engine keeps all of its dispatch models in one `server.zig` (ADR-042). For `zix.Http1` that file was about 2,600 lines, with `.EPOLL` and `.URING` about 900 lines each and barely overlapping, so a change to one model meant scrolling past the other four. The A2 idle-pool variants, which differ only in the `.URING` pool code, were forced to be full-file copies.

**Decision:** Split the models into a per-engine `dispatch/` folder, one file per model named for the `DispatchModel` enum value (`async.zig`, `pool.zig`, `mixed.zig`, `epoll.zig`, `uring.zig`), with shared dispatch helpers in `dispatch/common.zig`. `server.zig` keeps the public `Server` type and the runtime model switch. `core.zig` (shared request processing) is untouched. Rolled out on `zix.Http1` first, then replicated to the other connection-oriented engines (`zix.Http`, `zix.Http2`, `zix.Grpc`, `zix.Tcp`, `zix.Fix`). `zix.Udp` is excluded by design (see Consequences): it is connectionless, has a single serve strategy, and has no `dispatch_model` to switch on.

**Rationale:** This is file organization, not a behavior or perf change, and it does not introduce a shared or generic dispatch loop, so it complies with ADR-042: no per-event indirection, and each engine still owns its dispatch. Isolating a model makes per-model work and per-model variant comparison (the A2 record) tractable. Moved bodies stay byte-identical because each model file reaches the shared helpers through `const X = common.X;` aliases, so only the `run()` switch is rewritten.

**Config:** none. No code-behavior or API change. `Server.init` / `initRaw` and the config are unchanged.

**Consequences:**
- Each new file needs its own `std.testing.refAllDecls` line in `src/lib.zig` (refAllDecls is not recursive), else its tests silently never run. Tests move into the file of the model they cover.
- The `zix.Http1` pilot landed green: `server.zig` shrank from 2,624 lines to 154, the five models live under `dispatch/` (with `common.zig` for the shared helpers), and `zig build`, `test-all`, and `test-runner-all` (all 56 protocols) pass with the 25 http1 tests preserved.
- The four A2 idle-pool variants are preserved as full-server snapshots in `rnd/0.5.x/a2-variants/` (they differ only in the `.URING` pool code) with a cross-reference manifest.
- The connection-oriented engines (`zix.Http`, `zix.Http2`, `zix.Grpc`, `zix.Tcp`, `zix.Fix`) landed the same split, each an independent equivalent move, all green on Zig 0.16.x and 0.17.x (`test-all`, `examples`, `test-runner-all`). The comptime-route engines (`zix.Http2`, `zix.Grpc`, `zix.Http`) thread routes through a `common.Dispatch(...)` generic so the moved bodies stay byte-identical, the runtime-route engines (`zix.Tcp`, `zix.Fix`) pass the handler at runtime.
- `zix.Udp` is excluded by design. The dispatch models abstract connection lifecycle (accept, then per-fd multiplex, then close). UDP is connectionless: one bound datagram socket, no per-connection fds, clients tracked as application-level address records, and concurrency is per-datagram (`io.concurrent`) not per-connection. There are no models to partition. A `dispatch/` split would be revisited only if a second datagram serve strategy is added (reuseport plus `recvmmsg` / `sendmmsg` / io_uring multishot).

---

## ADR-044: support Zig 0.16.x and 0.17.x from one tree via comptime ZIG_SEMVER gating

**Status:** Accepted

**Context:** zix is developed on Zig 0.16.0 while the rolling `zig` toolchain has moved to 0.17.0-dev, and the two differ in std and build APIs in ways that break compilation outright. The roadmap framed a version bump as blocking the 0.5.x campaign because it was assumed to force a re-baseline and an io_uring rewrite. Two findings removed that: the feared io_uring rewrite is a non-issue (the raw `std.os.linux.IoUring` is unchanged in 0.17, so the ring engines compile as-is), and every other difference is either a single parse-level operator change or a semantic API change that a comptime branch can carry on both versions at once. The full difference inventory is in `regression-zig-0.16-to-zig-0.17-diff.md`.

**Decision:** Build on BOTH 0.16.x and 0.17.x from one source tree, gated by `ZIG_SEMVER`, a named comptime constant (`MAJOR` / `MINOR` / `PATCH`) over `builtin.zig_version`. It exists in exactly two places, because `build.zig` and the zix module are separate compilation contexts and `build.zig` cannot import the module: a build-only copy in `build.zig` (for the `ensureSupportedZig` guard and the `dirExists` build-root branch) and the public `zix.ZIG_SEMVER` in `src/lib.zig` (for source-code gates and external consumers). Semantic differences are gated `if (comptime ZIG_SEMVER.MINOR == 16) { 0.16 code } else { 0.17 form }`, where the comptime-dead branch is never analyzed so neither version sees the other's API. `ensureSupportedZig` fails fast with a readable message outside the 0.16.x / 0.17.x range.

**Rationale:** Pinning one version would either strand 0.16 users or block adoption of the current toolchain for no benefit, since dual support is mechanical once the io_uring fear is gone. The gate preserves the validated 0.16 code verbatim on its branch and adds the 0.17 form in the `else`, rather than rewriting working code. `ZIG_SEMVER` centralizes the check, so the next port (0.18) is a search for `ZIG_SEMVER.MINOR` plus the parse-level sweep. The one exception is the `**` repeat operator: its 0.17 rejection is a parse (AstGen) error that fires over the whole file before any comptime branch is eliminated, so it cannot be gated and is replaced unconditionally with `@splat`, which is byte-identical on 0.16.

**Config:** none. `ZIG_SEMVER` is a comptime constant, not a runtime field. No engine config or API change.

**Consequences:**
- One tree serves both the stable 0.16 line and the current 0.17 toolchain, with no fork or per-version branch, and the roadmap's Phase-1-blocking version decision is removed.
- The seven differences resolved: `b.build_root` -> `b.root.root_dir` (build.zig), `X ** N` -> `@splat` (6 sites, unconditional), `bufPrintZ` -> `bufPrintSentinel(buf, fmt, args, 0)`, `indexOfIgnoreCase` -> `findIgnoreCase` (a rename), `@typeInfo` `.fields` -> `field_names` + `field_types`, `std.meta.Int` -> `@Int`, and io_uring unchanged.
- Verified green on both 0.16.0 and 0.17.0-dev.902 across `test-all`, `examples`, and the live `test-runner-all` (56 protocols).
- Two `ZIG_SEMVER` copies (build-only and public) must stay in sync, three trivial lines each over the same `builtin.zig_version`, and the doc comment in each forbids a third copy. A future compiler can add differences not covered here, bounded by `ensureSupportedZig`.

---

## ADR-045: pure-Zig TLS, TLS 1.2 the minimum version

**Status:** Accepted

**Context:** zix needs TLS for https and h2, and as the hard prerequisite for Http3. std ships a TLS client only, so a server needs its own certificate-based handshake. Two decisions had to be fixed: build the handshake in Zig or bind a C library, and which protocol versions to put on the wire.

**Decision:** Build the TLS 1.3 server handshake in pure Zig on `std.crypto` primitives, no OpenSSL or BoringSSL. Version policy: offer TLS 1.2 and TLS 1.3, prefer 1.3, never negotiate below 1.2. 1.2 is the floor and required scope, 1.0 / 1.1 / SSL are never offered (RFC 8996). Mandatory-to-implement crypto: `TLS_AES_128_GCM_SHA256`, secp256r1 plus X25519 ECDHE, an ECDSA P-256 or Ed25519 certificate. https is opt-in, cleartext stays the default and is left untouched, and https lives on its own perf band.

**Rationale:** std already provides every primitive (AES-GCM, HKDF, X25519, P-256, ECDSA, Ed25519), so a C dependency would add build complexity and an FFI boundary for no functional gain and would break the pure-Zig posture. TLS 1.2 is the minimum because RFC 5246 is not deprecated and is still widely deployed (older Android, legacy OpenSSL, embedded and enterprise stacks), whereas 1.0 / 1.1 are deprecated (RFC 8996) and so are never offered. The 1.2 suites are restricted to ECDHE-AEAD for forward secrecy and authenticated encryption on both versions, and an ECDSA or Ed25519 certificate covers authentication on the std signing path. RSA signing was initially left optional here, then implemented later for RSA-certificate interop (ADR-048).

**Config:** flat `tls_*` fields on the server configs (`tls_cert_path`, `tls_key_path`, `tls_alpn`, plus `hsts_max_age_s` on Http1) and `tls_ca_path` on the client config. No nested sub-config, per the existing flat-config rule. The server-side flat fields are superseded by the `Tls.Context` object (ADR-047).

**Consequences:**
- The TLS 1.3 server is implemented and verified byte-exact against the RFC 8448 trace, green on Zig 0.16 and 0.17.
- TLS 1.2 is an OPEN required milestone (the shipped code is 1.3-only). It is a separate track: a SHA-256 / SHA-384 PRF key schedule, the 1.2 record layer, the 1.2 handshake, and cross-version suite negotiation restricted to ECDHE-AEAD.
- The downgrade-protection sentinel (RFC 8446 4.1.3) becomes required once both versions are offered. It is not yet implemented.
- The cleartext EPOLL / URING path is untouched, and https is held to its own perf band, not the 1 percent gate.
- A native verifying TLS client (ALPN offer plus X.509 / RFC 6125) is a separate milestone.

---

## ADR-046: wire TLS as a layer, gated serve paths over the unchanged engines

**Status:** Accepted

**Context:** TLS sits under Http1 and Http2 (https, h2). https had to be added without disturbing the tuned cleartext dispatch models (`.ASYNC` / `.POOL` / `.MIXED` / `.EPOLL` / `.URING`) or their hot path.

**Decision:** Add TLS as a gated blocking serve path per engine, selected when `config.tls` is set (the `Tls.Context`, ADR-047), leaving every cleartext model untouched. Http1: `serveConnTls` runs the handshake through `zix.Tls`, then per request decrypts the record, reuses `core.parseHead`, runs the existing fd-handler over a pipe, and encrypts the response. Http2: a terminator runs the UNCHANGED h2c engine (`core.serveConn`) behind a socketpair, with a `poll` loop that decrypts inbound client records to plaintext and encrypts the engine's frames back, and ALPN selects h2. `zix.Tls` is sans-I/O: `serverHandshake` returns the bytes to send plus a `Connection`, so the engine owns the socket loop.

**Rationale:** Terminating TLS in front of the unchanged engines reuses the whole cleartext frame and request machinery, so https cannot regress the cleartext hot path (it is additive) and the h2c state machine is not forked. The blocking path with a per-connection pipe or socketpair is acceptable because https is opt-in on its own perf band, not the 1 percent gate. Sans-I/O keeps `zix.Tls` usable from blocking and non-blocking dispatch alike. Teardown uses `shutdown(SHUT_WR)` so the engine sees EOF without a write racing a closed peer, avoiding SIGPIPE.

**Config:** `config.tls` (a `*Tls.Context`, ADR-047) gates the path. No new dispatch model and no change to the cleartext API.

**Consequences:**
- Http1 https/1.1 and Http2 h2 both serve over TLS 1.3, examples on ports 9060 and 9061, green on Zig 0.16 and 0.17.
- The h2 path reuses `core.serveConn` unchanged. Only ALPN selection and the terminator are new code.
- One request per Http1 https connection for now (keep-alive is a later refinement), and the terminator is one thread plus a socketpair per connection, accepted on the https band.
- No native h2 runner yet: it needs an ALPN-offering client, which is the `zix.Tls` client milestone.

---

## ADR-047: TLS bind options as a Tls.Context object

**Status:** Accepted

**Context:** TLS shipped with flat `tls_*` fields (cert, key, alpn, HSTS) on each HTTP server config (ADR-045 / 046), the minimal subset. Exposing the full bind surface (version floor / ceiling, ECDHE curves, cipher suites, server-cipher preference) as more flat fields would bloat every HTTP config, and a runtime config-file parser (the planned `zixer` executable) cannot produce compile-time enum literals: it needs a value it builds at runtime.

**Decision:** Expose server TLS as a user-owned object, `zix.Tls.Context`, modeled on the logger (`logger: ?*Logger`). `Tls.Context.Config` is the plain settings struct (`cert_path`, `key_path`, `alpn`, `min_version`, `max_version`, `curves`, `ciphers`, `prefer_server_ciphers`, `hsts_max_age_s`). `Tls.Context.init(allocator, io, config)` loads the PEM, detects the key type, and validates the policy once on the cold path. The HTTP configs carry `tls: ?*Tls.Context = null`, and a non-null pointer is the https opt-in gate (replacing the `tls_cert_path != null` gate). Curves and ciphers are typed enum slices validated to the implemented set: an unsupported value is a startup error, never a silent no-op. zix is ECDHE-only, so there is no dhparam knob. Session resumption is deferred: it touches the data path and is gated on the perf bench.

**Rationale:** The logger already established that a user-constructed object passed by pointer is the right shape for cross-cutting state, and it keeps `HttpServerConfig` flat (the many TLS knobs live inside `Tls.Context.Config`, not on the HTTP config). `Context` is the honest name: `zix.Tls` is sans-I/O with no listener (the accept loop is the HTTP engine's), so the object is the loaded-state context (the `SSL_CTX` analog), not a server. One config type serves two front-ends: the typed library path and the future `zixer` text-config parser both produce a `Tls.Context.Config`. Validate-or-reject keeps every exposed field honored or refused, never silently ignored, and loading / validating once keeps the per-connection serve path free of PEM work. Forward secrecy (ECDHE) and AEAD hold on both 1.2 and 1.3 by construction.

**Config:** `tls: ?*Tls.Context` on the Http1 and Http2 server configs. `Tls.Context.Config` holds the bind options. The flat `tls_*` server fields of ADR-045 / 046 are removed.

**Consequences:**
- The four flat fields (`tls_cert_path`, `tls_key_path`, `tls_alpn`, Http1 `hsts_max_age_s`) collapse to one `tls` pointer. HSTS becomes available to Http2 too, since it lives in the shared context.
- Configured curves are threaded into TLS 1.3 negotiation (reorder / subset is honored), and the version floor / ceiling gates the serve path: a ceiling of TLS 1.2 forces the 1.2 path, a floor of TLS 1.3 refuses 1.2 clients with a protocol_version alert.
- The implemented set (X25519, secp256r1, AES-128-GCM for 1.3, ECDHE-ECDSA-AES128-GCM for 1.2) widens with no API change as crypto lands. Unsupported values are rejected at init.
- The `Tls.Context` is the foundation the planned `zixer` executable parses its text config into.
- Green on Zig 0.16 and 0.17 (unit-test plus the 59-protocol test-runner-all).

---

## ADR-048: RSA server certificate signing

**Status:** Accepted

**Context:** ADR-045 left RSA signing optional: an ECDSA P-256 or Ed25519 certificate covers authentication on the std signing path, and std verifies RSA but cannot sign with an RSA private key. A deployment that must serve a pre-issued RSA-2048 certificate (a common shape, for example a shared certificate mounted by an external harness) could not be served, since zix had no RSA signing.

**Decision:** Implement RSA signing in pure Zig on `std.crypto`, server-side only, for RSA server certificates. The primitive is `std.crypto.ff.Modulus` modular exponentiation (the same constant-time routine std's RSA verify uses, here with the private exponent), and zix authors the padding: EMSA-PKCS1-v1_5 (RFC 8017 9.2) and EMSA-PSS plus MGF1 (RFC 8017 9.1), plus the PKCS#1 / PKCS#8 private-key DER parse. `Tls.Context.init` detects an `rsaEncryption` certificate, parses the key, and rejects below RSA-2048. RSA authenticates the TLS 1.3 CertificateVerify with `rsa_pss_rsae_sha256`, so an RSA certificate requires TLS 1.3: the 1.2 ServerKeyExchange path stays ECDSA-only, and an RSA context that meets a 1.2-only client returns an error. The default certificate type is unchanged (ECDSA P-256), RSA engages only when an RSA certificate is loaded.

**Rationale:** The bignum was never the gap (`std.crypto.ff` already provides constant-time modexp), only the PKCS#1 padding and the key DER parse were missing, so the work is pure-Zig with no new dependency, holding the ADR-045 posture. PSS (not v1.5) on the 1.3 path because RFC 8446 permits only `rsa_pss_rsae_sha256` for an RSA CertificateVerify. The 2048-bit floor is the modern minimum. Server-side only, with no RSA on the client (`zix.Tls.Client` still offers and verifies ECDSA plus Ed25519), because the driver is serving an RSA certificate, not consuming one. ECDSA stays the default for its smaller, faster signatures.

**Config:** none new. An RSA certificate is selected by pointing `Tls.Context.Config.cert_path` / `key_path` at an RSA certificate and key, `Tls.Context.init` detects the type. Floor the context at TLS 1.3 for an RSA certificate (`min_version = .TLS_1_3`).

**Consequences:**
- `src/tls/rsa.zig` is the signer (key parse, EMSA-PKCS1-v1_5, EMSA-PSS, salt injected by the caller). `certificate.SigningKey` gains an `rsa` variant with `scheme()` returning `rsa_pss_rsae_sha256`. `handshake.SignatureScheme` gains `rsa_pkcs1_sha256` (0x0401) and `rsa_pss_rsae_sha256` (0x0804).
- The PSS salt is threaded per connection like the other randoms: serve-path getrandom into `Tls.Context.handshakeOptions`, then `HandshakeOptions.pss_salt`, then `buildCertificateVerify`.
- Verified: byte-exact against `openssl dgst -sign` for v1.5, std RSA verify for PSS, and an integration test loads an RSA certificate, signs a std-verified PSS signature, and rejects a 1024-bit key. Green on Zig 0.16 and 0.17.
- RSA over TLS 1.2 is out of scope: the 1.2 path is ECDSA-only, so an RSA context serves 1.3 only.

---

###### end of adr
