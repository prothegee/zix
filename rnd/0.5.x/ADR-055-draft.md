# ADR-055 draft: WebSocket over TLS for zix.Http and zix.Http1

Lean note. The full record lives in `docs/adr-en.md` / `docs/adr-id.md` (ADR-055).

## Decision in one line

On the thread-per-connection https path, serve a WebSocket by handing the upgraded connection a TLS-session-backed read / write surface (decrypt inbound records into frames, encrypt outbound frames into records), instead of the raw fd the cleartext WS path uses.

## Why

WS over TLS is the bidirectional sibling of SSE over TLS (ADR-054). SSE needed only a streaming write hook (server push, one direction). WS adds the read path: after the `101` upgrade, the engine must decrypt inbound records, parse frames, and encrypt outbound frames over the same live session. The cleartext WS entry takes a raw fd (`zix.Http1.WebSocket.serve(fd, ...)`) or a plaintext stream (`zix.Http.WebSocket.upgrade(stream, ...)`), neither of which exists over TLS (the fd is the `-1` sentinel).

## Shape

Reuse the ADR-054 stream sink for the write half, add a TLS-aware read half, expose a TLS serve entry per engine:

As built: one engine-driven entry per engine, `WebSocket.serveTls(fd, key, on_frame)`, with the frame loop owned by the https serve thread (not the handler). The handler registers a handoff, the serve loop runs the loop inline.

| Piece | zix.Http1 | zix.Http |
| :- | :- | :- |
| cleartext entry (today) | `WebSocket.serve(fd, key, on_frame)` | `WebSocket.upgrade(stream, io, accept)` + `Conn` / `RoomMap` |
| TLS entry (new) | `WebSocket.serveTls(fd, key, on_frame)` | `WebSocket.serveTls(fd, key, on_frame)` |
| `101` response | written through the ADR-054 stream sink (encrypted) | same |
| frame loop | `serveWsTls`: decrypt record -> `pump` (parse + on_frame) -> stream sink encrypts | same |

`serveTls` detaches the buffered capture, writes the `101` through the stream sink (encrypted), and registers the handoff (`requestWebSocket`). After the handler returns, `serveRequests` takes the handoff (`takeWebSocket`) and runs `serveWsTls`: read ciphertext record, `conn.readAppData`, accumulate, `pump` complete frames (text / binary -> on_frame, ping auto-ponged, close auto-echoed). Outbound frames flow through `fdWriteAll` -> the stream sink -> `conn.writeAppData`, one record per pump pass. `zix.Http` gains the engine-driven pieces (`WsFrameFn`, `send`, `pump`, the handoff, `upgradeFd`) so both engines share the `on_frame(fd, opcode, payload)` shape. Rooms / broadcast stay cleartext-only (per-session encryption), so wss is per-connection.

## Constraint

Thread-per-connection only (`.ASYNC` / `.POOL` / `.MIXED`), same as ADR-054: a WS connection is long-lived and owns its thread. `.EPOLL` / `.URING` TLS stays request / response only.

Inbound frame size is bounded by the request plaintext buffer (one decrypted record at a time). A control frame fits trivially, a large data frame may span records (handled the same way `serveRequests` accumulates a body).

## Examples

- `examples/tls/tls_http1_ws.zig` (port 9074)
- `examples/tls/tls_http_ws.zig` (port 9075)

## Open

- LANDED on ADR-054 (the stream sink is the write half), green Zig 0.16 / 0.17, runners folded into `test-runner-all`.
- Masking / fragmentation / control-frame handling reuse the existing cleartext `websocket.zig` framing, only the transport (raw fd -> TLS session) changes.
- A multiplexed `tls_mux` WS path is out of scope (same reasoning as ADR-054).
