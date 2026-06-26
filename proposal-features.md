# Proposed Features (zix)

> This is an informational proposal document, not a commitment. It lists candidate
features beyond the current set, grounded in what is actually absent from `src/` as of
this writing. Status is one of: `roadmap` (already intended), `candidate` (new idea).

<br>

## Pure-Zig Feasibility Legend

A zix goal is zero external libraries (std plus raw Linux syscalls only). Each subject
below carries a **Pure-Zig** line using one of these verdicts:

| Verdict | Meaning |
| :- | :- |
| `reachable` | Doable with std and raw syscalls. Effort only, no dependency. |
| `std-gap` | std offers nothing for a sub-part. Pure-Zig is still possible, but you author library-sized code, so prefer avoiding that sub-part. |
| `build-tool` | Needs an external build-time tool, not a linked runtime library. |

Verified against the Zig 0.16 std on this machine: `std.crypto.tls` is client-only (no
server), `std.compress.flate` compresses (gzip / deflate / zlib) but there is no brotli
and zstd is decompress-only, `std.crypto.sign.ecdsa` signs but there is no RSA
private-key signing, `recvmmsg` / `sendmmsg` / `mmsghdr` and `sigaction` are present.

<br>

## Already Present (not proposed here)

These were checked and already exist, so they are out of scope for this document:

| Feature | Where |
| :- | :- |
| Multipart form upload parsing | `src/tcp/http/upload.zig` (`MultipartParser`) |
| WebSocket control frames (ping auto-ponged, close auto-echoed) | `src/tcp/http1/websocket.zig`, `src/tcp/http/websocket.zig` |
| Server-Sent Events (SSE) | `zix.Http1`, `zix.Http` |
| Range requests (`parseRange`) | `src/tcp/http1/core.zig` |
| Per-worker response cache (ADR-036) | `zix.Http1`, `zix.Http`, `zix.Grpc` |
| Backpressure under EPOLL / URING | engine write paths |

<br>

## Transport and Security

__*1. TLS / mTLS termination:*__ `roadmap`

Every engine speaks plaintext or h2c today, so anything edge-facing needs an external
terminator. A TLS transport that wraps the existing engines (and mutual TLS for service
to service) is the single largest gap for public-facing use. A PoC exists outside `src/`.

> The biggest deployment blocker. Without it, zix sits behind a proxy on any public edge.

**Pure-Zig:** `reachable` (large). std ships only `tls.Client`, so the work is writing the
TLS 1.3 server handshake on top of std.crypto's existing AEAD, HKDF, and `HandshakeCipher`
key-schedule primitives. Use an ECDSA (P-256) or Ed25519 server certificate: std has
ECDSA and Ed25519 signing but no RSA private-key signing, so an RSA certificate is the one
blocked sub-case. No OpenSSL or external crypto is required.

<br>

__*2. HTTP/3 / QUIC over UDP:*__ `roadmap`

A QUIC transport with HTTP/3 framing, built on the existing `zix.Udp`. Long horizon
(depends on std gaps), but the UDP engine is already a natural foundation.

> Future-facing. Completes the HTTP version ladder (1.1, 2, 3) under one model.

**Pure-Zig:** `reachable` (largest). std has every crypto primitive QUIC needs (AEAD
packet and header protection, the TLS 1.3 handshake crypto) but no QUIC and no TLS server,
so you implement the QUIC transport (packets, streams, flow and congestion control, loss
recovery) plus the server handshake. Same ECDSA / Ed25519 over RSA certificate caveat as
subject 1. By far the biggest item, but no external library.

<br>

## HTTP Completeness

__*3. Response compression:*__ `candidate`

`gzip` / `deflate` / `brotli` with `Accept-Encoding` negotiation. Composes with the
response cache: cache the compressed bytes once, replay them with no re-encode.

> High bandwidth payoff, and it strengthens the cache story rather than competing with it.

**Pure-Zig:** `reachable` for gzip and deflate, `std-gap` for brotli and zstd.
`std.compress.flate.Compress` with `Container.gzip` gives gzip and deflate today. brotli
is absent from std and zstd is decompress-only, so either would mean authoring a
compressor (brotli also embeds a roughly 120 KB static dictionary). Outcome: gzip and
deflate shipped first; brotli was then authored in-tree from RFC 7932 and shipped too
(still dependency-free), zstd dropped.

<br>

__*4. HTTP cache validators:*__ `candidate`

`ETag` plus `If-None-Match` and `If-Modified-Since`, answering `304 Not Modified`.
Complements static serving and the response cache.

> Cheap to add, and it cuts repeat-fetch bandwidth for static and cacheable responses.

**Pure-Zig:** `reachable` (trivial). Pure header logic plus std hashing for the ETag and
std date parsing for the conditional headers. No std gap.

<br>

__*5. HTTP/2 native EPOLL / URING path:*__ `roadmap`

`zix.Http2` currently folds to `.POOL` (no native shared-nothing loop). Bringing it onto
the EPOLL / URING topology closes the one dispatch-model asymmetry in the docs.

> Removes the lone exception in "all five dispatch models, natively".

**Pure-Zig:** `reachable`. A refactor of zix's own h2 frame and HPACK code onto the
existing shared-nothing loop. No external anything.

<br>

## Operations and Resilience

__*6. Graceful shutdown and connection draining:*__ `candidate`

A signal-driven stop (`SIGTERM`): stop accepting, finish in-flight requests, close within
a bounded deadline. Today only startup readiness and pool drain-on-exit exist, with no
in-flight draining. `SO_REUSEPORT` already provides the zero-downtime handoff half.

> Required for rolling deploys. Pairs with the reuseport topology zix already has.

**Pure-Zig:** `reachable`. `std.posix.sigaction` is present, and the rest is signal-safe
coordination over zix's own worker set. No std gap.

<br>

__*7. Observability and metrics:*__ `candidate`

Counters, a latency histogram, and a cache-hit ratio, exported as Prometheus text or via a
snapshot API. The logger covers events, not quantities. Shared-nothing fits per-worker
counters aggregated lock-free.

> Turns the existing per-protocol logger into a measurable surface for dashboards and SLOs.

**Pure-Zig:** `reachable`. `std.atomic` counters plus string formatting for the Prometheus
text format. An OTLP exporter would reuse zix's own gRPC engine, still pure-Zig.

<br>

__*8. Rate limiting and per-IP connection caps:*__ `candidate`

A token bucket or per-IP connection gauge, refusing or shedding past a threshold. Fits the
existing backpressure mechanics.

> A first line of defense that lives in the engine, not a sidecar.

**Pure-Zig:** `reachable`. std hash map plus atomics plus monotonic time. No std gap.

<br>

## Middleware Kit

__*9. Built-in middleware:*__ `candidate`

`zix.Http` already has middleware infrastructure, so these are composable additions: CORS,
request-id, and basic / bearer auth.

> Common cross-cutting needs as small, opt-in building blocks instead of hand-rolled code.

**Pure-Zig:** `reachable`. CORS, request-id (UUID via `std.crypto.random`), basic auth
(`std.base64`), and bearer or JWT auth (HMAC via `std.crypto.auth.hmac`, RS256 or ES256
verify via std) are all pure-Zig. Error handling stays on Zig's `error` union: a handler
returns an error and the engine maps it to a response. There is no panic-recover middleware
(that is a Go pattern: Zig has no stack unwinding, so a real `@panic` cannot be caught and
the request resumed).

<br>

## Protocol-Specific

__*10. gRPC ecosystem services:*__ `candidate`

`grpc.health.v1` health checking, server reflection, and gRPC-Web. Reflection and health
are near-mandatory for `grpcurl` and Kubernetes probes.

> Makes the gRPC engine interoperable with the standard tooling teams already use.

**Pure-Zig:** `reachable`, with reflection a `build-tool` case. health (grpc.health.v1)
and gRPC-Web are pure-Zig. Server reflection serves protobuf `FileDescriptor` sets that
realistically come from `protoc` at build time (an external tool, not a runtime library).
Hand-encoding the descriptors in pure Zig is possible but painful.

<br>

__*11. zix.Udp recvmmsg / sendmmsg batching:*__ `candidate`

Batch multiple datagrams per syscall on the UDP engine. Flagged internally as the larger
UDP throughput lever.

> The highest-leverage change for UDP-heavy workloads.

**Pure-Zig:** `reachable`. `recvmmsg` / `sendmmsg` / `mmsghdr` are in `std.os.linux`, so
call them directly. No std gap.

<br>

## Pure-Zig Feasibility Summary

| # | Subject | Verdict | No-dependency note |
| :- | :- | :- | :- |
| 1 | TLS / mTLS | `reachable` (large) | write server handshake on std.crypto, ECDSA / Ed25519 cert not RSA |
| 2 | HTTP/3 / QUIC | `reachable` (largest) | std has the crypto, not the transport (same cert caveat) |
| 3 | Compression | `reachable` gzip / deflate, `std-gap` brotli / zstd | gzip / deflate + brotli authored in-tree shipped, zstd out |
| 4 | Cache validators | `reachable` | trivial |
| 5 | HTTP/2 native loop | `reachable` | refactor of own code |
| 6 | Graceful shutdown | `reachable` | `sigaction` present |
| 7 | Metrics | `reachable` | atomics plus text format |
| 8 | Rate limiting | `reachable` | map plus atomics plus time |
| 9 | Middleware | `reachable` | CORS, request-id, basic / bearer auth |
| 10 | gRPC health / reflection / web | `reachable`, reflection `build-tool` | reflection wants protoc descriptors |
| 11 | recvmmsg / sendmmsg | `reachable` | in `std.os.linux` |

Every subject is reachable in pure Zig. The only places std hands you nothing are brotli
/ zstd compression and RSA private-key signing. zstd and RSA are avoidable (use gzip /
deflate, use ECDSA / Ed25519 certificates); brotli was instead authored in-tree from
RFC 7932. TLS does not require OpenSSL.

<br>

## Suggested Priority

Impact-first, deployment over micro-optimization:

| Rank | Feature | Why first |
| :- | :- | :- |
| 1 | TLS / mTLS (#1) | Unblocks every public-facing deployment |
| 2 | Graceful shutdown (#6) | Unblocks rolling deploys |
| 3 | Response compression (#3) | Large bandwidth win, strengthens the cache |

The rest are valuable but secondary to getting zix deployable on a real edge.

<br>

## Extended

Smaller incremental engine follow-ups, below feature-level scope. Tag: `follow-up`.

__*1. TCP_CORK on the Http1 and Http2 EPOLL write paths:*__ `follow-up`

`TCP_CORK` already coalesces the response on the gRPC EPOLL path. Apply the same to the `zix.Http1` and `zix.Http2` EPOLL response writes so header and body leave as one segment.

__*2. Zero-copy large-body drain across the other URING engines:*__ `follow-up`

`zix.Http1` `.URING` drains an over-large body with one `MSG_TRUNC` recv. Carry it to `zix.Http` (a correctness gap: the URING path today drops a connection whose body exceeds `max_recv_buf`), audit `zix.Grpc` DATA-frame accumulation for a copy, and check WebSocket (lowest yield, frames are bounded).

__*3. Lean Context for `zix.Http1`:*__ `follow-up`

`zix.Http1` handlers take `fn(head, body, fd)` with no Request/Response/arena. A lean stack Context (no per-request arena) could unify the timeout and param thread-locals (ADR-029/033) behind one object. Deferred: comment-note-only chosen for now.

__*4. `zix.Http2` native EPOLL path:*__ `follow-up`

`zix.Http2` has no native epoll or uring loop and folds to `.POOL`. A native multiplexed EPOLL h2c path (as `zix.Grpc` already has) would let it scale like the other engines.

__*5. `zix.Tcp` PoC benchmark client:*__ `follow-up`

No off-the-shelf tool speaks the length-prefix framing, so `zix.Tcp` has no throughput numbers. Write a `zix.Tcp` PoC benchmark client (N concurrent conns, fixed duration, req/s plus latency) to bench ASYNC / POOL / MIXED, matching the HTTP PoC format.

__*6. FIX router and context notes:*__ `follow-up`

The FIX router and context design notes are not yet captured as an RnD spec. The shipped hld-fix docs and README FIX sections already cover it, only the RnD spec note lags.
