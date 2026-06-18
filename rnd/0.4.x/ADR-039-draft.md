# ADR-039 (accepted record)

Records the `io`-into-config move for the three non-engine servers (`zix.Tcp`,
`zix.Udp`, `zix.Uds`) plus the `zix.Uds` handler-at-`init` reshape, so every zix
server is constructed with a config that carries `io` and served with a
no-argument `run()`. Folded into `docs/adr-en.md` (before the `end of adr`
footer) and mirrored into `docs/adr-id.md`. Kept here as the rnd record. This is
a consistency change (the last server-shape divergence), not a measured one, so
there is no PoC benchmark, only the before/after API and the verification result.

---

## ADR-039: `zix.Tcp` / `zix.Udp` / `zix.Uds` move `io` into the server config and `zix.Uds` bakes the handler at comptime, unifying the server shape on `run()`

**Status:** Accepted

**Context:** Five server engines (`zix.Http`, `zix.Http1`, `zix.Http2`,
`zix.Grpc`, `zix.Fix`) carry `io: std.Io` in their config, so `run()` takes no
argument. The three remaining servers diverged: `zix.Tcp` and `zix.Udp` took `io`
as a `run(io)` parameter, and `zix.Uds` took both `io` and the handler at run
(`run(io, handler)`). ADR-038 baked the `zix.Tcp` handler at `init` but deferred
the `io` placement. The engine servers prove the move is safe, and the internal
workers already take `io` as a plain value.

Before and after:

```zig
// before
var server = try zix.Tcp.Server.init(myHandler, .{ .ip = IP, .port = PORT });
defer server.deinit();
try server.run(process.io);

var server = try MyServer.init(.{ .allocator = a, .ip = IP, .port = PORT });
try server.run(process.io);

var server = try zix.Uds.Server.init(.{ .path = P, .allocator = a });
try server.run(process.io, myHandler);     // handler at run

// after
var server = try zix.Tcp.Server.init(myHandler, .{ .io = process.io, .ip = IP, .port = PORT });
defer server.deinit();
try server.run();

var server = try MyServer.init(.{ .io = process.io, .allocator = a, .ip = IP, .port = PORT });
try server.run();

var server = try zix.Uds.Server.init(myHandler, .{ .io = process.io, .path = P, .allocator = a });
try server.run();                           // handler baked at init
```

**Decision:**
- Add `io: std.Io` as the first, required field of `TcpServerConfig`,
  `UdpServerConfig`, and `UdsServerConfig`.
- `run()` takes no argument on all three. It reads `self.config.io` and passes it
  to the existing internal workers, so there is no hot-path or ownership change.
- `zix.Uds` adopts the ADR-038 factory shape: `Server.init(comptime handler, config)`
  returns a specialized type whose `run()` takes nothing. The built-in echo
  default is the public `zix.Uds.echoHandler`, passed explicitly. The old
  `run(io, handler)` / `runWith` path is removed.
- Clients keep `io` as a `connect()` / `init()` parameter, deferred to a separate
  decision (client `io` placement is already mixed across engines).

Uniform server constructor map:

| Server | Construct | Run |
| :- | :- | :- |
| `zix.Http` / `zix.Http1` / `zix.Http2` / `zix.Grpc` / `zix.Fix` | `Server.init(routes_or_handler, config)` | `run()` |
| `zix.Tcp` | `Server.init(handler, config)` / `initFramed(frame_fn, config)` | `run()` |
| `zix.Udp` | `Server(Packet).init(config)` | `run()` |
| `zix.Uds` | `Server.init(handler, config)` | `run()` |

**Consequences:**
- Breaking: every `zix.Tcp` / `zix.Udp` / `zix.Uds` server call site adds
  `.io = process.io` and drops the `run` argument. `zix.Uds` callers also pass the
  handler to `init`.
- `io` must outlive the server (same contract as the engine configs).
- Supersedes the `io` placement in ADR-038: the `zix.Tcp` run path is now `run()`
  (was `run(io)`). The handler-at-`init` decision is unchanged and extended to
  `zix.Uds`.
- Full server-shape parity across all eight servers.
- Verified: the library compiles, every `tcp_server_*` / `udp_server` /
  `uds_server` example compiles, the unit / integration / edge / behaviour suites
  pass, and the `tcp` (all five models), `udp`, and `uds` runners pass.
