# ADR-054 draft: SSE / streaming over TLS for zix.Http and zix.Http1

Lean note. The full record lives in `docs/adr-en.md` / `docs/adr-id.md` (ADR-054).

## Decision in one line

On the thread-per-connection https path, let a streaming handler (SSE) write each chunk through a thread-local stream sink that encrypts one TLS record per write and sends it immediately, instead of the buffered capture that holds the whole response and encrypts it once.

## Why

The https serve path (ADR-053 for `zix.Http`, the approach-A path for `zix.Http1`) captures the handler's plaintext into a buffer behind a `-1` sentinel fd, encrypts that buffer once, and sends it. That is correct for request / response, but a streaming handler never returns: it loops emitting events, so a buffered capture either deadlocks (the handler never hits the encrypt step) or overflows (`ResponseTooLarge`). SSE over TLS was out of scope in ADR-053 for exactly this reason.

A streaming write hook closes that gap without touching the buffered fast path for normal responses.

## Shape

One thread-local stream sink per engine, type-erased over the live TLS connection (1.3 and 1.2 share it):

| Piece | zix.Http | zix.Http1 |
| :- | :- | :- |
| sink + thread-local | `TlsStreamSink` + `tl_tls_stream` in `src/tcp/http/response.zig` | same in `src/tcp/http1/core.zig` |
| write chokepoint | `fdWriteAll` gains a stream branch | `fdWriteAll` gains a stream branch |
| opt-in switch | `res.stream()` (existing) detaches the buffered sink | `beginStream()` (new) detaches the buffered sink |
| serve loop install | `serveRequests` in `src/tcp/http/tls_serve.zig` | `serveRequests` in `src/tcp/http1/tls_serve.zig` |

Precedence in `fdWriteAll`: buffered sink (`tl_resp_sink`) first, then the stream sink (`tl_tls_stream`), then the raw fd. During buffered capture both are armed and the buffered sink wins. The opt-in switch nulls the buffered sink, so subsequent writes fall through to the stream sink, which calls `conn.writeAppData` (one record) then `writeAll` to the real fd. The serve loop detects the nulled buffered sink as the streamed outcome and closes with `close_notify` instead of encrypting an empty buffer.

`zix.Http` exposes no new public symbol (`res.stream()` just gains TLS capability). `zix.Http1` gains one public no-op-in-cleartext call, `beginStream()`, so the same fd-handler works cleartext and over TLS.

## Constraint

Thread-per-connection only (`.ASYNC` / `.POOL` / `.MIXED`). The streaming handler parks its own per-connection thread, which is exactly the model the https path already uses. `.EPOLL` / `.URING` terminate TLS in the multiplexed `tls_mux` loop (ADR-052 shape) and stay buffered-only: hosting a long-lived stream there needs event-loop state-machine work, out of scope here. SSE on `zix.Http` already requires `workers = 1` even in cleartext, so TLS inherits that, not a new limit.

Per-event size is bounded by one TLS record (~16 KiB plaintext). An SSE event is tiny, so this is not a practical limit.

## Examples

- `examples/tls/tls_http_sse.zig` (port 9072)
- `examples/tls/tls_http1_sse.zig` (port 9073)
- `examples/http1_sse.zig` updated to call `beginStream()` so the one handler serves cleartext and TLS unchanged.

## Open

- WebSocket over TLS is the sibling gap (bidirectional, needs the read path). That is ADR-055, built on this sink.
- The multiplexed `tls_mux` path stays buffered. Streaming there is a later step if a benchmark needs it.
