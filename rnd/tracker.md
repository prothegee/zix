# Tracker

Open items that need follow-up. Check off when resolved.

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
