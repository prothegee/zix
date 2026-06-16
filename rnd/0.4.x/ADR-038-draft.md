# ADR-038 (accepted record)

Records the `zix.Tcp` server API reshape: bake the handler at comptime and expose
a single `run`, mirroring the `zix.Http1` / `zix.Grpc` server shape. Folded into
`docs/adr-en.md` (before the `end of adr` footer) and mirrored into
`docs/adr-id.md`. Kept here as the rnd record. This is a consistency and clarity
change, not a measured one (the per-connection TCP handler is a cold dispatch
point), so there is no PoC benchmark, only the before/after API and the
verification result.

---

## ADR-038: `zix.Tcp` server bakes the handler at comptime, single `run`, mirroring the engine server shape

**Status:** Accepted

**Context:** Every zix server engine except `zix.Tcp` bakes its handler (or route
table) into the server type at `init`, so the handler is comptime-known and `run`
takes no handler argument (`zix.Http1`, `zix.Http2`, `zix.Grpc`). `zix.Tcp` was the
exception: it took the handler as a runtime function pointer through
`runWith(io, handler)`, with `run(io)` as a separate entry that used the built-in
echo handler, plus `runFramed(io, frame_fn)` for the per-frame callback. The split
and the runtime pointer were inconsistent with the other engines and with the
project's explicit-over-implicit and comptime-where-structural principles. The
asymmetry was already half-resolved: the per-frame `FrameFn` (`runFramed`) was
comptime, only the per-connection `HandlerFn` was runtime. The per-connection
blocking handler runs once per accepted connection (a cold dispatch point), so
devirtualizing it is negligible, unlike `zix.Http1`'s per-request handler or the
per-frame `FrameFn`, which is why those are already comptime.

**Decision:** Mirror the `zix.Http1` / `zix.Grpc` server shape. The handler (or
per-frame callback) is baked into the server type at `init`, so `run` takes only
`io`. `zix.Tcp.Server` becomes a fieldless namespace with comptime constructors over
two private factory types: `TcpServerImpl(comptime handler)` and
`TcpFramedServerImpl(comptime frame_fn)`.

Before and after:

```zig
// before
var server = try zix.Tcp.Server.initArgs(.{ .ip = IP, .port = PORT }, args);
defer server.deinit();
try server.runWith(process.io, myHandler);     // or run(io) for the echo default
try server.runFramed(process.io, myFrameFn);   // per-frame callback path

// after
var server = try zix.Tcp.Server.initArgs(myHandler, .{ .ip = IP, .port = PORT }, args);
defer server.deinit();
try server.run(process.io);

// echo default is explicit now
var server = try zix.Tcp.Server.init(zix.Tcp.echoHandler, .{ .ip = IP, .port = PORT });

// per-frame callback path
var server = try zix.Tcp.Server.initFramed(myFrameFn, .{ .ip = IP, .port = PORT });
try server.run(process.io);
```

Constructor map:

| Constructor | Returns | Contract |
| :- | :- | :- |
| `Server.init(comptime handler, config)` / `initArgs(..., args)` | `TcpServerImpl(handler)` | per-connection `HandlerFn` (owns the stream) |
| `Server.initFramed(comptime frame_fn, config)` / `initFramedArgs(..., args)` | `TcpFramedServerImpl(frame_fn)` | per-frame `FrameFn` (engine owns the connection) |

Two factory types (rather than one type with an optional second comptime parameter,
as `zix.Http1` uses for `(handler, raw_fn)`) follow a compose-versus-alternative
rule. In `zix.Http1` the raw interceptor composes with the handler (same connection,
a pre-parse hook), so one impl carries both. In `zix.Tcp`, `HandlerFn` (owns the
connection, blocks) and `FrameFn` (engine-owned, never blocks, runs on the `.URING`
ring) are mutually exclusive contracts: a connection cannot be both hand-owned and
engine-deframed. Two factory types keep that impossible state unrepresentable.

`io` stays a `run(io)` argument rather than a config field (unlike `zix.Http1` /
`zix.Grpc`, whose `io` lives in config). Moving `io` into `TcpServerConfig` for full
shape parity (which would also resolve the io-placement inconsistency across the
server configs) is a separate, larger change spanning the config struct and every
call site, deferred to its own decision.

**Consequences:**
- Breaking API change: `runWith` and `runFramed` are gone, `run(io)` is the only run
  path, and the constructor carries the handler. The internal worker functions
  (`serveDispatch`, `runEpoll`, and the pool / async / epoll entries) keep the
  handler as a runtime value, exactly as `zix.Http1`'s `runAsync` / `runPool` /
  `runMixed` do. The comptime binding is at the type boundary (no runtime
  registration), not a hot-loop devirtualization.
- The handler must be comptime-known. A runtime-selected handler
  (`const h = pick(cfg)`) now branches at the call site. This is the one
  expressiveness cost, accepted on principle for the raw-TCP engine.
- Supersedes the extension API names in ADR-037: the blocking path is
  `Server.init(handler, config)` then `run(io)` (was `runWith`), the framed ring
  path is `Server.initFramed(frame_fn, config)` then `run(io)` (was `runFramed`).
  `.URING` still folds to `.EPOLL` for the per-connection handler and runs natively
  for the framed callback.
- Verified: the library compiles, all five `tcp_server_*` examples compile, the
  unit / integration / edge / behaviour suites pass, and all five end-to-end runners
  (async, pool, mixed, epoll, uring) pass.

---
