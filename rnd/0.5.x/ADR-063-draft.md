# ADR-063 Draft: engine handler trio parity (Request, Response, Context) and explicit Router across engines

Working draft, not yet implemented. All work happens on the `rework_handlers` branch (off `0.5.x-rc2`), one combined pass in the order Fix -> Http -> Http2 -> Grpc -> Http3. This file is the living tracker: checkpoints below are ticked in place as each engine lands. Promotes to `docs/adr-*.md` only after all five land and the re-bench gate passes.

## ADR-063: engine handler trio parity and explicit Router across engines

**Status:** Draft

**Context:** Not every engine gives its handler the same three roles today. `zix.Http` and `zix.Http1` have the full trio since ADR-062. The others do not:

| Engine | Request-like view | Response-like builder | Context-like env |
| :- | :- | :- | :- |
| Http / Http1 | yes, typed `Request` | yes, typed `Response` | yes, `Context` |
| Http3 | yes, `Request` | yes, `Response` | missing, no ctx param, no error return |
| Http2 | missing, raw `method`/`path`/`headers`/`body` args | missing, writes via free `sendResponseFD` on a raw `fd`/`sid` | missing |
| Grpc | missing, raw `headers` slice | missing, writes via free `sendHeadersFD`/`sendDataFD` on `ctx`'s fd | yes, `GrpcContext` |
| Fix | missing, raw `fields` slice | missing, writes via `buildMessage` on `ctx`'s fd | yes, `FixContext` |

Router has a matching split. `Http`, `Http2`, `Grpc`, `Fix` pass a route array straight into `Server.init(routes, config)`, the router is built internally and the user never calls `Router(...)`. `Http1` and `Http3` require the user to call `zix.ENGINE.Router(&[_]zix.ENGINE.Route{...})` and hand `.dispatch` to `Server.init(handler, config)`. That split is why examples read differently per engine.

**Decision:** Every engine gets the trio, protocol-shaped, and the Http1 router idiom everywhere.

- Trio on all engines: `Request`, `Response`, `Context`, with `HandlerFn = *const fn(*Request, *Response, *Context) anyerror!void`. Not forced identical structs: each engine keeps its own shapes for what its protocol actually carries, but the three roles exist everywhere and the idiom matches Http1's (`try res.foo(...)`, `Response.sent` guard, `Context` holds io, per-request arena, deadline, fd/session bits).
- Router: `Server.init(handler, config)` everywhere, the user builds the handler via `zix.ENGINE.Router(&[_]zix.ENGINE.Route{...})`. Breaking change for `Http`, `Http2`, `Grpc`, `Fix`, mirroring ADR-062's approach. Every example updates to the same call-site idiom.
- Names stay bare per namespace (`zix.Http2.Request`), not engine-prefixed.
- Handler-error wire policy: `Http1`, `Http2`, `Http3` auto-send 500 when the handler errors and nothing was sent (ADR-062 rule). `Grpc` and `Fix` pass errors through silently, current wire behavior kept, invoke site is `handler(&req, &res, &ctx) catch {}`.
- Raw expose: the raw `send*FD` surfaces stay public on `Http1`, `Http2`, `Grpc`, `Http3`. `Http` and `Fix` get no raw expose.
- Fix timeout fold: `server_timeout_ms` stops being a bare third `dispatch` arg. The effective-timeout calculation moves to where `Context` is built and `deadline_ns` carries the result. No raw timeout field is added.

**Rationale:** One handler vocabulary across all engines: when moving between engines the memory carries over, less learning curve. Building the trio at the invoke site keeps the tuned dispatch loops untouched (same pattern ADR-062 proved on Http1: stack-cheap views, byte-identical writers underneath).

**Parity matrix:** same name, same behavior, only where the protocol has the concept. A "no" means the concept does not exist in that protocol, so the method is absent, never a stub that lies.

| Member | Http / Http1 | Http2 | Http3 | Grpc | Fix |
| :- | :- | :- | :- | :- | :- |
| `Request.method` | yes | yes | yes | no (always POST) | no |
| `Request.path` | yes | yes | yes | yes | no |
| `Request.query` / `queryParam` / `queryParams` | yes | yes | no (handler parses `req.path` manually, no query API this pass) | no | no |
| `Request.pathParam` / `pathSegments` | yes | pathSegments only, no PARAM route kind this pass | PARAM route kind exists, but `pathParam` is a package free function (`zix.Http3.pathParam`) off a threadlocal, not a `Request` method | no | no |
| `Request.header` | yes | yes | no (no generic accessor; specific headers are pre-parsed into named `Request` fields: `authority`, `accept_encoding`) | yes | no |
| `Request.body` / `bodyReceived` | yes | yes | yes (plain field, no `bodyReceived` distinction) | yes (proto bytes) | no |
| `Request.getField` (typed field view) | no | no | no | no | yes |
| `Request.keepAlive` | yes | no (persistent by protocol) | no (same) | no | no |
| `Response.setStatus` / `setContentType` / `addHeader` | yes | yes | `setStatus` only, `content_type` is a plain field not wired to the wire yet, no `addHeader` (v1 HTTP/3 response path emits only `:status` and `content-encoding`) | no | no |
| `Response.send` / `sendJson` / `sendText` / `sendNoContent` | yes | yes | `send` only, no `sendJson` / `sendText` / `sendNoContent` this pass | no | no |
| `Response.sendRaw` (pre-built wire bytes verbatim) | yes | no (h2 has no flat pre-buildable wire form, everything is HPACK+framed) | no (no raw pre-built-bytes surface exposed this pass) | no | no |
| `Response.sendNegotiated` | yes | no (no compression negotiation exists for Http2 today, ADR-059's own track, out of scope this pass) | no (handler negotiates manually via `accept_encoding` + `setContentEncoding`, no `sendNegotiated` helper this pass) | no | no |
| `Response.setKeepAlive` | yes | no | no | no | no |
| `Response.sendStream` (SSE) / `sendFromCache` / `sendCached` | yes | out of scope this pass | out of scope this pass | `serveCached` / `sendCached` only, no SSE (pre-existing response-cache feature, not new this pass) | no |
| `Response.sendMessage` / `finish(status)` | no | no | no | yes | no |
| `Response.sendMessage(msg_type, fields)` | no | no | no | no | yes |
| `Context.withTimeout` / `setTimeout` / `withDeadline` / `isExpired` / `timedOut` | yes | yes | yes | yes | yes |
| `Context` io + per-request arena | yes | yes | yes | yes | yes |

**Guardrails:**

- No change to hot-path wire mechanics: `send*FD` writers stay byte-identical, the tuned `.EPOLL` / `.URING` dispatch loops are not touched internally, only what wraps their handler call.
- Must build clean on both `zig-0.16` and `zig-0.17`.
- Raw profiles must stay flat within the existing noise band on the isolate bench, no perf or memory regression.

## Checkpoints

Order is fixed: Fix -> Http -> Http2 -> Grpc -> Http3. A checkpoint ticks only when its engine builds clean on both compilers, tests cover the new surface, and its examples are migrated.

### 1. Fix

- `Request`: typed view over `fields`, reusing `getField`
- `Response`: builder over `buildMessage` plus the SOH-framed write, `sendMessage(msg_type, fields)`
- `Context`: timeout fold (effective-timeout calc at build, `deadline_ns` carries it, no raw field) plus timeout helper parity (`withTimeout`, `setTimeout`, `withDeadline`, `isExpired`, `timedOut`). `io` and a per-request arena added too (stack `FixedBufferAllocator`, no heap call, keeps the FIX core zero-heap-allocation)
- `HandlerFn` becomes `fn(*Request, *Response, *Context) anyerror!void`, errors pass through silently
- `Server.init(handler, config)` plus explicit `Router(Route)`. `handler` is `?HandlerFn`, null keeps the existing echo-only mode
- examples migrated, tests added, `zig-0.16` and `zig-0.17` green (1234/1234 tests, both compilers, `zig fmt` clean)

### 2. Http

- `Server.init(handler, config)` plus explicit `Router(Route)` export (trio already exists per ADR-062). Bigger than the one-liner implied: `Server` stopped being a comptime-generic-over-routes type (`HttpServerImpl(routes)`) and became one concrete struct holding `handler: HandlerFn`. `Router(routes).dispatch` changed from a `self`-taking method returning `!bool` to a plain `fn(req,res,ctx) anyerror!void` matching `HandlerFn` exactly, absorbing the static-file-fallback + 404 that `dispatch/common.zig` used to own externally (mirrors Http1's router). `Context` gained a `public_dir: []const u8` field so the router can reach it without a threadlocal (Http1 uses `tl_static_dir` instead, not changed)
- examples migrated (17 examples + uds_http), tests added/migrated (4 router/tls_dual test files), `zig-0.16` and `zig-0.17` green (1234/1234 tests, 175/175 steps, both compilers). Static-file-serving + 404 fallback verified end to end by hand (curl against a running `example-http_static`), not just compiled

### 3. Http2

- `Request` / `Response` / `Context` per parity matrix corrected above (no `keepAlive`, no PARAM route kind/`pathParam` this pass, no `sendNegotiated`/`sendRaw`, EXACT+PREFIX matching only, matching Http2's pre-existing route kinds). New files `request.zig`, `response.zig`, `context.zig`, `router.zig` (one-file-one-responsibility, mirrors Http1's structure). `Context` gained `io` + a stack-arena allocator (`FixedBufferAllocator`, no heap call) and `handler_timeout_ms` added to `Http2ServerConfig`/`ServeOpts` (Http2 had no timeout concept at all before this)
- `HandlerFn` becomes trio + `anyerror!void`, auto-500 when nothing sent (`core.invokeHandler`, mirrors ADR-062)
- internal low-level dispatch (`dispatchStream` in core.zig, `muxDispatch` in mux.zig, the upgrade-path dispatch in `serveH2cUpgrade`) stays the entry point, builds the trio once and calls `invokeHandler`
- `Server.init(handler, config)` plus explicit `Router(Route)`. Bigger than Fix/Http: Http2's OLD router was comptime-threaded through ~20 function signatures across `core.zig`, `mux.zig`, all 5 `dispatch/*.zig` files, and both TLS paths (`tls_serve.zig`, `tls_mux.zig`), not baked into the server type once. Every `comptime routes: []const Route` parameter became a plain runtime `handler: HandlerFn` (dropping `comptime` entirely, since routing is now fully resolved by the caller's `Router(...).dispatch`), and 3 comptime-generic worker-function factories (`epollMuxWorkerFn`, `uringMuxWorkerFn`, `workerFn` in tls_mux.zig) flattened into plain functions carrying `handler` as a context field instead
- wire byte-identity vs `sendResponseFD` asserted in tests (`response.zig`'s own test suite)
- examples migrated (5 `http2_basic_*`), tests added/migrated (4 test files: edge/integration server_test, tls_dual_test, behaviour config_test), `zig-0.16` and `zig-0.17` green (1245/1245 tests, 142/142 steps, both compilers). Verified end to end by hand: curled a running `example-http2_basic_1_async` over h2c prior-knowledge

### 4. Grpc

- `Request` (`path`, `header`, `recvMessage`), `Response` (`sendHeaders` / `sendMessage` / `finish` / `serveCached` / `sendCached`), both thin delegating wrappers holding a `*GrpcContext` pointer so the tuned internals (gzip, DATA-frame coalescing, cork/stage buffer, write mutex) stay untouched
- `GrpcContext` carries on as `Context`, gained `io` + a stack-arena allocator (`FixedBufferAllocator`, no heap call), plus `withTimeout` / `setTimeout` / `withDeadline` / `timedOut` for parity with the other engines (`isExpired` stays the primary check)
- `HandlerFn` becomes trio + `anyerror!void`, errors pass through silently (`catch {}` at invoke sites, unchanged wire behavior)
- `Server.init` deviates from the otherwise-uniform `Server.init(handler, config)` shape: it takes `Server.init(Router(&routes), config)`, the comptime Router TYPE, not `.dispatch`. Reason: `Route.is_server_streaming` is metadata the ENGINE reads before invoking the handler, to pick sync-inline dispatch (unary, cheap) vs task-spawn dispatch (streaming, needed so a long-running stream does not block other h2 streams on the same connection). That decision must happen before any handler runs, so a bare opaque `handler: HandlerFn` cannot carry it. Settled empirically, not by inspection: a scratchpad PoC (`grpc_dispatch_poc.zig`, isolated processes, 3s runs, this box, 2026-07-26) measured direct-call dispatch at 44.8M RPS/1 core, `io.async` task-spawn (64 concurrent) at 1.14M RPS needing ~4.7 cores (~185x worse per-core), and raw `std.Thread.spawn` at 5,954 RPS total (~7,500x worse). Unifying onto always-task-spawn was not an acceptable simplification, so `Router(routes)` gained `pub const route_slice: []const Route = routes;` and every dispatch model (`dispatch/*.zig`, `tls_serve.zig`, `tls_mux.zig`) keeps `comptime RouterType: type` instead of dropping to a runtime handler value
- examples migrated (11 `grpc_*` + `tls_grpc_basic`), tests added/migrated (4 test files: edge/integration server_test, tls_dual_test, behaviour config_test), `zig-0.16` and `zig-0.17` green (both `test-all` and `examples`). Verified end to end by hand: `example-grpc_client` against a running `example-grpc_server_1_async` (unary + streaming), and `grpcurl` against `example-grpc_multi_server` (real protobuf field decoding, two services on one port)

### 5. Http3

- `Context` added: `stream_id` (the raw escape hatch, QUIC has no per-request fd), `deadline_ns` + `withTimeout` / `setTimeout` / `withDeadline` / `isExpired` / `timedOut`, `io` + a stack-arena `allocator` (`FixedBufferAllocator`, `CTX_ARENA_BYTES`), matching the other four engines. New `handler_timeout_ms` on `Http3ServerConfig` (had zero timeout concept before), seeded onto `Context.deadline_ns` at dispatch
- `HandlerFn` becomes trio + `anyerror!void`. `Response` gained a `sent: bool` flag (flipped by `send`). `core.invokeHandler` builds the Context and auto-500s (`res.status = 500; res.body = ""`) only when the handler errored and `!res.sent`, mirroring `core.invokeHandler` on Http2/Grpc. Only one real invoke site existed (`dispatch/common.zig`'s `sendResponseFD`, one call inside its per-packet request loop), so this landed with far less surface than Http2/Grpc: no comptime-routes threading to unwind, `comptime handler: core.HandlerFn` stays exactly as it already was at every `dispatch/*.zig` factory function, only the `HandlerFn` typedef's shape changed
- `Server.init(handler, config)` idiom confirmed unchanged (was already in place, `handler` stays a comptime value baked into `Http3ServerImpl(handler)`). `Router(routes).dispatch` updated to the trio signature and to propagate errors (`return handler(req, res, ctx)` at each match arm)
- examples migrated (`examples/tls/http3_basic.zig`, 4 handlers: `home`, `baseline`, `big`, `negotiated`), tests added/migrated (core.zig gained 2 new auto-500 tests plus the existing Response/negotiate/timeout tests updated to the trio, router.zig's dispatch test updated), `zig-0.16` and `zig-0.17` green (`test-all` + `examples`). Verified end to end by hand with `curl --http3-only` against a running `example-http3_basic`: all four routes (plain body, query-sum, 256 KiB multi-packet body, brotli content negotiation) round-tripped correctly

### All five engines complete

Fix, Http, Http2, Grpc, and Http3 checkpoints are all done and ticked above (2026-07-26). The trio + explicit-Router idiom is now uniform across the family, with Grpc's one deliberate, PoC-justified exception (`Server.init(Router(&routes), config)`, checkpoint 4). Remaining work is the Closing gate below, none of it started yet.

### Closing gate

- `zig fmt` clean, full test suite green on both compilers (`test-all` 1249/1249 tests, 131/131 steps, `examples` 205/205 steps, `zig-0.16` and `zig-0.17`, plus the full `scripts/build-all-targets.sh` matrix across all 7 targets)
- promote to `docs/adr-en.md` and `docs/adr-id.md` (2026-07-27, as ADR-063, right after ADR-062)
