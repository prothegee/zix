# Tracker

Open items that need follow-up. Check off when resolved.

---

## UDS -- Implementation

Reference: `rnd/uds_specification.md`, `docs/hld-uds.md`, ADR-010

**std.Io.net verified (2026-05-09):**
- `std.Io.net.UnixAddress` exists: `init(path)`, `listen(io, opts) !Server`, `connect(io) !Stream`
- Stream mode only — datagram not exposed via `std.Io.net.UnixAddress`
- `has_unix_sockets` = false on WASI; Windows 10 RS4+ supported; true elsewhere
- Path cleanup (unlink) not handled by `std.Io` — requires `std.posix.unlink(path)` on deinit
- Max path length: 108 bytes (Linux/macOS); abstract namespace via null-byte prefix supported

**Design decisions needed before src:**
- [ ] Datagram mode: skip for v1 (stream only via std.Io.net) or add via raw std.posix?
- [ ] Compile-time guard strategy: `if (!std.Io.net.has_unix_sockets) @compileError(...)` or runtime error?

**Implementation checklist:**
- [ ] `src/uds/config.zig` -- `UdsServerConfig`, `UdsClientConfig`, `SocketMode` enum
- [ ] `src/uds/server.zig` -- `UdsServer` stream mode; path unlink on deinit
- [ ] `src/uds/client.zig` -- `UdsClient`
- [ ] `src/uds/Uds.zig` -- namespace aggregator
- [ ] `src/zix.zig` -- `pub const Uds = @import("uds/Uds.zig")`
- [ ] `src/zix.zig` unit test -- `refAllDecls` for all `uds/*.zig`
- [ ] `examples/uds_server.zig`
- [ ] `examples/uds_client.zig`
- [ ] `build.zig` -- example entries for both
- [ ] `tests/integration/uds_config_test.zig`
- [ ] `build.zig` -- integration test entry
- [ ] `docs/hld-uds.md` -- fill in actual design (currently empty stub)
- [ ] `docs/lld-uds.md` -- fill in implementation details (currently empty stub)
- [ ] `docs/adr.md` -- ADR-010 status: Proposed → Accepted once implemented
- [ ] `docs/concurrency.md` -- UDS rows: update from "planned" to actual model
- [ ] `README.md` -- add `zix.Uds` section
- [ ] `rnd/uds_specification.md` -- close open question: Zig 0.16 API verified

---

## Channel -- Implementation

Reference: `rnd/channel_specification.md`, `docs/hld-channel.md`, ADR-017 (Proposed)

**Design decisions needed before src:**
- [ ] Locking primitive: `std.Io.Mutex` + `std.Io.Condition` (fiber-safe) vs `std.Thread.Mutex` (OS threads only) — determines whether Channel works inside `io.concurrent` tasks
- [ ] Unbuffered (capacity = 0) rendezvous semantics: requires two-sided sync, more complex than ring buffer
- [ ] Internal storage: fixed ring buffer (comptime capacity) vs heap-allocated list (runtime capacity)
- [ ] Naming: `Channel` vs `Chan` — locked once first example ships
- [ ] `select`/multiplex: defer, but internal design must not preclude it

**Implementation checklist:**
- [ ] `src/channel/channel.zig` -- `Channel(comptime T: type)` generic
- [ ] `src/channel/Channel.zig` -- namespace aggregator
- [ ] `src/zix.zig` -- `pub const Channel = @import("channel/Channel.zig")`
- [ ] `src/zix.zig` unit test -- `refAllDecls` for `channel/channel.zig`
- [ ] `examples/channel_basic.zig` -- producer + consumer tasks via `io.concurrent`
- [ ] `build.zig` -- example entry
- [ ] `tests/integration/channel_test.zig`
- [ ] `build.zig` -- integration test entry
- [ ] `docs/hld-channel.md` -- fill in actual design (stub created)
- [ ] `docs/lld-channel.md` -- fill in implementation details (stub created)
- [ ] `docs/adr.md` -- ADR-017 status: Proposed → Accepted once implemented
- [ ] `README.md` -- add `zix.Channel` section

---

## Lifecycle & Signal Control

Reference: `rnd/server_lifecycle_proposal.md`

- [ ] Add ADR entry for atomic server lifecycle (`IDLE → RUNNING → STOPPING → STOPPED`)
- [ ] HTTP accept loop: replace `while (true)` with atomic status check
- [ ] HTTP keep-alive loop: check status, set `Connection: close` when stopping
- [ ] HTTP WebSocket frame loop: check status, send close frame when stopping
- [ ] UDP receive loop: check status between `receiveTimeout` calls
- [ ] Graceful shutdown: stop accepting new connections, finish active tasks
- [ ] Forced shutdown: close socket, break all loops immediately
- [ ] Update `docs/hld-http.md` and `docs/hld-udp.md` with lifecycle section

---

## src/zix.zig -- Planned Exports

- [ ] `pub const Channel = @import("channel/Channel.zig");` — add when `src/channel/` is implemented

---

## UDP -- Not Yet Implemented

Reference: `docs/hld-udp.md` Not Yet Implemented table

- [ ] `sendmmsg` batching: N sequential `send()` per broadcast → 1 syscall (Linux `sendmmsg`)
- [ ] Sub-millisecond `send_every`: rename field from milliseconds to nanoseconds if real-time control loops are needed

---

## HTTP -- ADR-012 Implementation (Proposed)

Reference: `docs/adr.md` ADR-012

- [ ] Add `not_found: ?HandlerFn = null` to `HttpServerConfig` — `null` keeps current built-in 404 plain text behavior
- [ ] Add `keep_alive: bool = true` to `HttpServerConfig` — `false` closes after each response
- [ ] Wire `not_found` into `server.zig` `handleConnection`: call config handler if set, else fall through to current 404
- [ ] Wire `keep_alive` into `server.zig` keep-alive loop: exit loop and set `Connection: close` when false
- [ ] Update ADR-012 status from Proposed → Accepted once implemented
- [ ] Update `docs/hld-http.md` `HttpServerConfig` section with the two new fields

---

###### end of tracker
