# ADR-053 (accepted record)

Records the https serve path for `zix.Http`: opt-in TLS via `config.tls` (a `*Tls.Context`),
mirroring Http1, with the router response captured behind a sentinel fd and encrypted once. Folded
into the public ADR docs (en and id) as the accepted ADR-053, kept here as the record.

## Status

Accepted. Landed on Zig 0.16 and 0.17, verified end-to-end with curl + openssl (TLS 1.3, ALPN
http/1.1, ECDSA P-256) on both execution paths. The request / response scope of this cut was later
widened: SSE / streaming over TLS by ADR-054, WebSocket over TLS by ADR-055, and the mux-path
hosting of both by ADR-060.

## Context

`zix.Http` (the arena engine) served cleartext only. Http1, Http2, and gRPC gained TLS (ADR-046,
ADR-052), so a deployment standardizing on `zix.Http` could not opt into TLS without an upstream
proxy.

## Decision

Gate a TLS serve path behind `config.tls`. The router response is captured into a buffer and
encrypted once: the path reuses the engine's existing `RespSink` / `tl_resp_sink` coalescing hook
(built for URING, ADR-037) by installing a sentinel-fd (-1) sink and running the normal
`processRequest`, so every Response write serializes into the buffer, no plaintext escape, no new
cleartext hot-path branch. Two execution paths share the capture, picked by `dispatch_model`:

- `.ASYNC` / `.POOL` / `.MIXED`: thread-per-connection (`src/tcp/http/tls_serve.zig`), one worker
  thread per connection for the handshake (TLS 1.3, with a 1.2 ECDSA fallback) and keep-alive.
- `.EPOLL` / `.URING`: multiplexed (`src/tcp/http/tls_mux.zig`), one SO_REUSEPORT epoll worker per
  core, a resumable handshake / record state machine per connection (`tls_session.zig`),
  cpuset-aware worker count and per-core pinning (the ADR-052 collapse fix).

## Consequences

- `HttpServerConfig` gains `tls: ?*Tls.Context = null`. Cert is ECDSA P-256, Ed25519, or RSA
  (detected from the cert), Ed25519 and RSA require TLS 1.3.
- The sentinel fd -1 makes a stray socket write fail safely instead of leaking plaintext.
- At this cut SSE / streaming and WebSocket were buffered-capture-incompatible (a blocking handler
  never returns, the buffer only flushes after it exits): `res.stream` detached the sink and
  surfaced `StreamingNotSupported`. The streaming write hook that lifts this (encrypt-per-chunk
  through a thread-local writer) landed as ADR-054 / ADR-055, and ADR-060 later hosted streaming on
  the mux path too.
- New example `examples/tls/tls_http_basic.zig` (port 9071).
