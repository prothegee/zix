# Architecture Decision Records -- zix

Each ADR records a significant design decision: the context that made it necessary, the decision taken, and its consequences. Accepted ADRs are binding; Proposed ones are under discussion.

---

## ADR-001: `std.Io` event-driven concurrency model

**Status:** Accepted

**Context:** The server must handle many concurrent connections without blocking on I/O. Zig 0.16 provides `std.Io` as an opaque event loop abstraction over OS facilities (epoll, kqueue, io_uring, etc.). The alternative was raw OS threads with explicit synchronization.

**Decision:** Accept `std.Io` as a parameter in `zix.Http.Server` and `zix.Udp.Server`. The caller owns and provides the backend (`process.io` for runtime-managed or `std.Io.Threaded` for an explicit cap). Use `io.concurrent()` to dispatch each connection or packet as a task.

**Consequences:**
- Tasks suspend at OS boundaries -- no busy-waiting, no per-connection thread.
- Caller controls the concurrency model. zix does not own or deinit the backend.
- `zix.Http.Server.run()` and `zix.Udp.Server.run()` block until error; the caller decides what to do after they return.
- Code that needs true parallelism (e.g. UDP broadcast) can call `io.concurrent()` from within a task.

---

## ADR-002: Namespace API (zix.Http.*, zix.Udp.*)

**Status:** Accepted

**Context:** The initial API exposed flat exports from the zix root (`zix.HttpServer`, `zix.Request`, etc.). When UDP was added the surface became inconsistent: HTTP types were flat while UDP types were already under `zix.Udp.*`. The flat HTTP names also carried redundant prefixes (`HttpServer`, `HttpHeader`) that became obvious once nested.

**Decision:** Introduce `zix.Http` and `zix.Udp` as namespace aggregators backed by `Http.zig` and `Udp.zig`. Remove all flat HTTP exports. Canonical paths:
- `zix.Http.Server`, `zix.Http.Request`, `zix.Http.WebSocket`, ...
- `zix.Udp.Server(Packet)`, `zix.Udp.Client(Packet)`, `zix.Udp.ServerConfig`, ...

`zix.Tcp.Http.*` remains accessible (Tcp.zig re-exports Http.zig) but is not the canonical path.
`zix.utils` stays flat -- it is not protocol-specific.

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
- `ctx.allocator` allocations must not escape the request (e.g. stored in a global). The name `ctx.allocator` is intentionally brief; the arena lifetime constraint is documented rather than encoded in the name. (A rename to `ctx.request_arena` was considered and declined -- see `rnd/http_specification.md`.)
- Retain-capacity reset amortizes arena backing block growth over the connection lifetime.

---

## ADR-004: 3-pass router dispatch (exact > param > prefix)

**Status:** Accepted

**Context:** A router needs a consistent priority rule when multiple patterns could match the same request. Options were: first-match-wins (registration order), longest-match, or explicit priority tiers.

**Decision:** Three passes in fixed priority order: exact routes first, then param routes (first-registered wins within pass 2), then prefix routes (longest wins within pass 3). Registration order is irrelevant for passes 1 and 3.

**Consequences:**
- Exact and prefix routes are deterministic regardless of order. This covers the common case (most routes are exact or prefix).
- Param routes require care: more-literal patterns must be registered before all-param patterns of the same depth. This is documented and demonstrated in examples.
- The 3-pass design was considered for replacement with first-match-wins (see `rnd/http_specification.md`). Deferred: the change would be breaking and the benefit is marginal for typical route counts.

---

## ADR-005: Comptime-generic UDP packet type

**Status:** Accepted

**Context:** UDP carries application-defined binary structs. A fixed built-in packet type would limit interoperability. A runtime `[]u8` slice would lose type safety and require the user to handle serialization manually.

**Decision:** `UdpServer` and `UdpClient` are generic over a comptime `Packet: type`. The user defines their own `extern struct` and passes it at the instantiation site (`zix.Udp.Server(MyPacket)`). zix handles endianness, size validation, and framing; the application owns the packet definition and identity logic.

**Consequences:**
- The server does not stamp or modify any packet field. The `id` field (if present) is the sender's responsibility.
- Endianness helpers (`toEndian`, `fromEndian`) are fully generic -- they work on any `extern struct`.
- `@sizeOf(Packet)` is comptime-known, enabling the RFC 768 size assert and the fixed receive buffer `[@sizeOf(Packet)]u8`.

---

## ADR-006: LITTLE endianness as default for UDP

**Status:** Accepted

**Context:** UDP packets transmitted across machines or languages must agree on byte order. The two common choices are LITTLE (x86/ARM native, most modern hardware) and BIG (network byte order, RFC 791 convention).

**Decision:** `Endianness.LITTLE` is the default in both `UdpServerConfig` and `UdpClientConfig`. BIG is available for interop with legacy or internet protocols.

**Consequences:**
- On x86 and ARM (the majority of deployment targets), LITTLE is a no-op -- no swapping performed.
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
- A client that disconnects between the snapshot and the broadcast send will receive a send error that is silently ignored -- correct behavior.

---

## ADR-009: extra_buf as arena-allocated []HttpHeader

**Status:** Accepted

**Context:** The original design stored custom response headers in a fixed `[32]HttpHeader` buffer. This caused an out-of-bounds write when `max_response_headers = .LARGE` (64 slots) and more than 32 headers were added. A compile-time cap was insufficient because the cap is runtime-configurable per server instance.

**Decision:** In `Response.init()`, allocate `extra_buf = arena.alloc(HttpHeader, max_headers)` from the per-request arena. `max_headers` comes from `ServerConfig.max_response_headers.value()`. The `max_headers` field on `Response` was removed; `extra_buf.len` is the cap.

**Consequences:**
- The cap is exact: no `@min(..., 128)` clamp, no wasted slots.
- `Response.init()` is now fallible (`!Response`) because `arena.alloc` can fail.
- The arena lifetime guarantees the buffer is valid for the request and reclaimed automatically.

---

## ADR-010: UDS (Unix Domain Socket) -- Planned

**Status:** Proposed

**Context:** Unix Domain Sockets are the standard IPC mechanism on Linux and macOS for same-host communication. A `zix.Uds` namespace following the same pattern as `zix.Udp` would complete the trilogy of transport protocols.

**Decision:** Not yet implemented. Will follow the same pattern: `src/uds/`, namespace aggregator at `src/uds/Uds.zig`, exported as `pub const Uds = @import("uds/Uds.zig")` in `zix.zig`.

**Consequences:** None until implemented. Tracking here to reserve the namespace and establish the design intent. For open design questions see `rnd/uds_specification.md`.

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
- Each unique composition generates a new comptime function; excessive combinations increase binary size.

---

## ADR-012: Explicit HTTP server behavior config fields

**Status:** Proposed

**Context:** Several HTTP server behaviors are embedded in `server.zig` internals and not visible in `HttpServerConfig`: the 404 auto-response when no route matches, the keep-alive loop, and the static file fallback behavior. Users cannot override these without modifying source.

**Decision:** Add named fields to `HttpServerConfig` for every configurable behavior. `null` disables a behavior; a function value enables the user's override. Proposed additions:

```zig
pub const HttpServerConfig = struct {
    // existing fields ...
    not_found:  ?HandlerFn = null,    // null = built-in 404 plain text
    keep_alive: bool       = true,    // false = close after each response
};
```

The `public_dir` field already exists but its role as an opt-in feature (not a magic fallback) should be made explicit in documentation.

**Consequences:**
- Config struct is the complete contract -- if it is not in the struct, it does not happen.
- Breaking change for any code that relies on the current implicit 404 behavior (minimal impact in practice).
- `not_found = null` preserves the current default behavior; no migration required unless the user wants a custom 404.
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
- Test code can now pass `std.testing.allocator` for leak detection; prod code passes `std.heap.smp_allocator`.
- `UdpServerConfig` and `HttpServerConfig` are now consistent: both expose an explicit, required allocator field.
- `UdpClient` remains simpler by design — no heap allocation, no allocator field required.

---

###### end of adr
