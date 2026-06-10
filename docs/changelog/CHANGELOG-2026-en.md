# CHANGELOG

<!--
IMPORTANT:
- Do not remove this
- Naming file is always based on year
- The latest is always on top, bottom next is previous change
- Format:
```
## MAJOR.MINOR.PATCH (YYYY-MM-DD)

__*Update:*__
- Foo
- Bar:
    - Baz
    ---

<br>

__*Fix:*__

- ISSUE_FIX_SHORT_NAME:
    - ISSUE_LINK
    - SHORT_SUMMARY
    - PROFILE_CONTRIBUTOR:
        - NAME_OR_USERNAME / PROFILE_LINK

<br>

## PREVIOUS_CHANGELOG
...
```
-->

<br>

## 0.3.0 (2026-06-10)

__*Update:*__
- Http1 router prefix param:
    - `zix.Http1.Router` gains `.PREFIX` and `.PARAM` route kinds (added `RouteKind` and a `kind` field on `zix.Http1.Route`, default `.EXACT`), reaching parity with the `zix.Http` router and its `exact > param > prefix` priority (ADR-004). Captured path params are read with the new free function `zix.Http1.pathParam(name)` (a per-handler thread-local, since the Http1 handler has no `Request`, see ADR-029), capped at 8 params per match.
    - The prefix pass now guards the boundary byte behind `startsWith`. The same fix was applied to the `zix.Http` router, which read one byte past a request path shorter than a registered prefix (a panic in Debug/ReleaseSafe, a masked out-of-bounds read in ReleaseFast).
    - Backward compatible: `.kind` defaults to `.EXACT`, so existing exact-only Http1 route tables are unchanged. `examples/http1_static.zig` now routes `/secret` via a `.PREFIX` route. See ADR-033.
    ---
- Epoll max events 512:
    - The epoll batch (max events drained per `epoll_wait`) is raised from 256 to 512 across all native epoll servers (`zix.Tcp`, `zix.Http`, `zix.Fix`, `zix.Grpc`, `zix.Http1`) and unified into one named, documented file-level constant `EPOLL_MAX_EVENTS: usize = 512` per server. The previous mix of a lowercase `epoll_max_events` const and inline `256` literals is removed.
    - 512 lets a worker clear its ready-fd set in a single syscall at high connection counts: a worker holding more than 256 readable fds no longer needs a second `epoll_wait`. No public API change, the constant is an internal tuned default. See ADR-032.
    ---
- Httpconfig naming consistency:
    - `HttpServerConfig` field renames for API-wide consistency (defaults unchanged): `max_kernel_backlog` becomes `kernel_backlog` (now matching `Tcp`, `Fix`, `Http1`, `http2`, and `Grpc`, which already used the bare name), and `max_client_request` becomes `max_recv_buf` (matching `zix.Http1`).
    - Migration: rename the fields at the call site. `.max_kernel_backlog = N` becomes `.kernel_backlog = N`, and `.max_client_request = N` becomes `.max_recv_buf = N`. `max_allocator_size` and `max_client_response` are unchanged (no equivalent exists outside `zix.Http`).
    ---
- Http1 handler at init:
    - `zix.Http1.Server.init` now takes the comptime handler as its first argument and bakes it into the server type, so `run()` takes no argument. This matches `zix.Http` and `zix.Grpc`, which register routes at init. The server core stays routing-agnostic: the handler may be a `Router(routes).dispatch`, a bare `HandlerFn`, or a middleware chain.
    - Migration: `Server.init(.{ ... })` then `server.run(Routes.dispatch)` becomes `Server.init(Routes.dispatch, .{ ... })` then `server.run()`.
    ---
- Grpc epoll multiplexed:
    - `zix.Grpc` `.EPOLL` was rewritten from a blocking thread-per-connection pool into a shared-nothing multiplexed event loop. Each worker owns a private `SO_REUSEPORT` listener, its own epoll instance, and a private fd-indexed connection table, the kernel balances connections across workers. One worker drives many non-blocking connections through a resumable HTTP/2 state machine (`GrpcMuxConn` / `grpcMuxOnReadable`), so concurrency is bounded by connection count, not thread count.
    - Every route, including server-streaming, is dispatched inline on the worker under `.EPOLL` (no per-stream thread, no connection write mutex). A streaming handler runs on the event loop and must stay bounded, use `.ASYNC` for unbounded streams. The blocking `serveGrpcConn` path is unchanged for `.ASYNC` / `.POOL` / `.MIXED`.
    - `pool_size` is now the multiplexing worker count for `.EPOLL` (0 = cpu count), not a blocking pool size. See ADR-031.
    ---
- Grpc unary hotpath:
    - Unary and streaming replies (initial HEADERS, every DATA, the trailer, and control frames) are coalesced into one `write()` per readable event via a per-connection `ReplyStage` cork.
    - `SETTINGS_INITIAL_WINDOW_SIZE` raised to 16 MB with a one-time connection-window bump, so small request bodies no longer trigger a per-DATA `WINDOW_UPDATE`, the connection window is replenished in bulk only past a threshold.
    - Buffered frame reads (a HEADERS plus DATA pair costs one `read()`), and per-stream `body` / `header_scratch` moved to per-connection backing slices sized to `max_body` / `max_header_scratch` instead of fixed inline arrays.
    - The constant reply header blocks (`:status 200` + `content-type: application/grpc+proto`, and the `grpc-status: 0` trailer) are HPACK-encoded once at comptime and memcpy'd on the hot path. `HpackEncoder.writeString` now types the Huffman result as `?usize` so the encoder runs at comptime. Other content-types / statuses use the dynamic encoder.
    - Combined effect: unary ~110k to ~420k req/s at 256 connections, streaming ~2.6k to ~28k calls/s. See ADR-031.
    ---
- Gttp1 logger field:
    - `Http1ServerConfig.logger: ?*Logger` added. The server routes lifecycle lines (listening, EPOLL fallback) through it.
    - Per-request access logging is handler-side: the Http1 handler writes to the fd and returns void, so the server cannot observe response status or bytes. Handlers call `logger.access()` themselves (examples use a module global).
    ---
- Gttp1 examples parity and completion:
    - The 9 existing `http1_*` examples were brought to `http_*` presentation parity (full tunable constant block, commented logger scaffolding in the basic family).
    - 6 new examples complete the set (15 total): `http1_manual_concurrent`, `http1_sse`, `http1_xtra_headers`, `http1_client`, `http1_timeout_resp`, `http1_websocket`.
    ---
- Gttp1 handler timeout:
    - `Http1ServerConfig.handler_timeout_ms` plus `zix.Http1.setTimeout()` and `zix.Http1.isExpired()`. The server arms a thread-local deadline before each dispatch across all four models.
    - `statusPhrase` gained `408 Request Timeout`. See ADR-029.
    ---
- Http1 websocket:
    - New `zix.Http1.WebSocket` module: RFC 6455 frame codec (`parseFrame` / `buildFrame` / `buildHeader` / `acceptKey`) and `upgrade()` over raw fd I/O.
    - Engine-owned frame loop under `.EPOLL`: a handler calls `WebSocket.serve(fd, key, on_frame)` to hand the connection to the epoll loop. The engine echoes via `on_frame` per readable event (`fn(fd, opcode, payload) void`), auto-ponging ping and auto-echoing close. No worker is parked per connection.
    - `WebSocket.send` coalesces every frame produced during one readable event into a single `write()`, so a pipelined burst costs one syscall instead of one per frame.
    - `zix.Http1.WsFrameFn` exported. Engine-owned WebSocket is `.EPOLL` only: under `.ASYNC` / `.POOL` the handoff is cleared and the connection ends. See ADR-030.
    ---
- Http1 large body drain:
    - Under `.EPOLL`, a request body larger than `max_recv_buf` no longer returns `431`. The engine dispatches the handler with an empty body (large-body endpoints use the Content-Length value), then reads and discards the remaining body bytes across events so the connection stays usable for keep-alive. Bodies that fit the buffer are unchanged.
    ---
- Http client version selector:
    - `zix.Http.Client` gained a `version` config field (`zix.Http.ClientVersion`: `HTTP_1`, `HTTP_2`, `HTTP_3`, default `HTTP_1`).
    - `HTTP_2` and `HTTP_3` return `error.UnsupportedVersion` until backends are wired. See ADR-028.
    ---
- Http1 writesimple hotpath:
    - `zix.Http1.writeSimple` now builds the response header with a direct byte encoder (`buildSimpleHeader` via `appendStatusCode` / `appendDec` / `appendBytes`), replacing `std.fmt.bufPrint`.
    - Small bodies (up to 3840 bytes) are copied with the header into one contiguous stack buffer and sent with a single `write()`. Bodies above 3840 bytes fall back to inline `writev` to avoid copying a large payload.
    - `cachedDate()` calls `clock_gettime` only every 256 requests via a thread-local tick counter, not per-request.
    - Measured ~450k to ~612k req/s at c128 vs the prior `writev`-only path. See ADR-026.
    ---
- Response header default minimal:
    - `HttpServerConfig.max_response_headers` default lowered from `.COMMON` (32) to `.MINIMAL` (16).
    - `zix.Http1`: `MAX_HEADERS` cap 32 to 16, new `Http1ServerConfig.max_headers: u8 = 16`.
    - Behavioral change: handlers adding 17 to 32 custom headers now hit `error.TooManyHeaders` until the tier is raised. See ADR-027.
    ---

<br>

__*Fix:*__
- Http1 websocket epoll echo:
    - `zix.Http1` WebSocket echo did not work under `.EPOLL`: the handshake succeeded but no frame was ever echoed. The handler's blocking `read()` loop returned `EAGAIN` at once on the engine's non-blocking sockets. The engine-owned frame loop (`WebSocket.serve`, see ADR-030) replaces that pattern. The `http1_websocket` example now uses `.EPOLL`.

<br>

## 0.2.2 (2026-06-06)

__*Update:*__
- Grpc unary inline dispatch:
    - Unary routes (`Route.is_server_streaming = false`, the default) now dispatch synchronously on the connection thread. No per-call Task alloc, no 4 KB `header_scratch` copy, no `io.async` enqueue, no ConnMutex acquire/release.
    - Server-streaming routes require `is_server_streaming = true` on the `Route` entry to use thread-per-stream dispatch.
    - New field on `zix.Grpc.Route`: `is_server_streaming: bool = false`.
    ---
- Grpc bench fixtures:
    - Added `examples/grpc_hello_req.bin` and `examples/grpc_location_req.bin`: properly gRPC-framed binary fixtures for h2load and ghz benchmarking.
    - h2load and ghz benchmark commands added to all 8 gRPC server examples.
    ---

<br>

__*Fix:*__
- n/a

<br>

## 0.2.1 (2026-06-05)

__*Update:*__
- n/a

<br>

__*Fix:*__
- Grpc content type:
    - https://codeberg.org/prothegee/zix/issues/67
    - `sendGrpcError` omitted `content-type` in the trailers-only HEADERS frame. gRPC clients rejected the response with a content-type error. All HEADERS frames sent by the server now include `content-type: application/grpc+proto` per the gRPC spec.

<br>

- Grpc concurrent stream:
    - https://codeberg.org/prothegee/zix/issues/68
    - Concurrent server-streaming RPCs on the same h2 connection could deadlock when the TCP send buffer filled under backpressure. Each stream is now dispatched on a dedicated thread sharing a connection-level write mutex, preventing frame interleaving.

<br>

## 0.2.0 (2026-06-02)

__*Update:*__
- Adding TCP raw
- Adding gRPC h2c
- Adding FIX (over TCP)
- Adding EPOLL dispatch model
- ASYNC is default dispatch model
- Handler/router (Http & gRPC) now use comptime
- Documentation split into English (en) and Bahasa (id)

<br>

__*Fix:*__
- n/a

<br>

## 0.1.0 (2026-05-16)

__*Update:*__
- Initial release, Zig 0.16.x network library (minimum_zig_version: 0.16.0-dev.2974+83c7aba12):
    - HTTP:
        - Server with three dispatch models: POOL, ASYNC, MIXED
        - Router with exact, param, and prefix matching
        - Middleware (comptime, zero-allocation)
        - WebSocket upgrade
        - Server-Sent Events (SSE)
        - Multipart upload
        - Static file serving
        - HTTP client
        ---
    - UDP:
        - Generic server and client over user-defined packet type
        - Broadcast peer snapshot per packet
        ---
    - Unix Domain Sockets (UDS):
        - Framed server and client
        ---
    - Channel:
        - In-process ring-buffer message passing, generic over element type
        ---
    - Utils:
        - File save helper, MIME type resolution
        ---

<br>

__*Fix:*__
- n/a

<br>

---

###### end of changelog
