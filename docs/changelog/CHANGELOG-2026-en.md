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

- Qux:
    - Quux

<br>

__*Fix:*__

- ISSUE_FIX_SHORT_NAME:
    - ISSUE_LINK
    - SHORT_SUMMARY
    - PROFILE_CONTRIBUTOR:
        - NAME_OR_USERNAME / PROFILE_LINK

    ---

- SAME_AS_ABOVE:
    - BUT JUST ONE

<br>

## PREVIOUS_CHANGELOG
...
```
-->

<br>

## MAJOR.MINOR.x (TBA)

__*Update:*__

- Two internal database drivers, `postgrez` (PostgreSQL) and `rediz` (Redis), pure Zig std only, no C dependency:
    - `postgrez`: wire protocol 3.2 with an in-place 3.0 fallback (PostgreSQL 15 minimum), binary-first value encoding with a text fallback per parameter, prepared statements, query pipelining, a batching `Executor`, a thread-safe `Pool`, SCRAM and SCRAM-PLUS (channel binding) plus cleartext auth, TLS 1.3, COPY streaming, LISTEN and NOTIFY.
    - `rediz`: RESP3 via HELLO with an in-place RESP2 fallback (Redis 7 and 8), typed value helpers plus a raw command escape hatch, command pipelining and a deferred write-behind path, a thread-safe `Pool`, TLS 1.3.
    - Both drivers share a `dispatch_model` config: `.ASYNC` (the pooled / executor path, the default) or `.EPOLL` / `.URING` (`Transport`, a single-thread multiplexed dispatch that pipelines many requests per connection, cleartext only).
    - Docs: `docs/driver/postgrez` and `docs/driver/rediz` (README, HLD, LLD, config reference, English and Indonesian).

<br>

__*Fix:*__
- TBA

<br>

## 0.5.0-rc1 (2026-07-15)

__*Update:*__
- Zig 0.17 (experimental) support: one source tree builds on Zig 0.16.x and 0.17.x, the few `std.Io` API divergences gated behind a comptime `ZIG_SEMVER` check (ADR-044).

- Breaking: `dispatch_model` is now a required config field with no default. Every server config (`Http1ServerConfig`, `HttpServerConfig`, `Http2ServerConfig`, `GrpcServerConfig`, `FixServerConfig`, `TcpServerConfig`, `UdpServerConfig`, `Http3ServerConfig`) drops the `.ASYNC` default, so the caller must set `dispatch_model` explicitly.

- Breaking: `Server.init` is uniform and infallible across the HTTP-family engines (ADR-014):
    - `zix.Http`, `zix.Http2`, `zix.Grpc`, and `zix.Http3` now store the config at `init` and cannot fail, with port and TLS validation moved to `run()` (`error.PortNotConfigured`, `error.TlsRequired`). This matches `zix.Http1`, so every engine constructs the same way: `init` bakes the comptime handler or route table into the type, `run()` validates then serves.
    - `zix.Http3` gains a `Server` struct: `zix.Http3.Server.init(handler, config)` replaces the `zix.Http3.Http3(handler)` generic-function entry point (the generic is now the private `Http3ServerImpl`).
    - `zix.Http.Server.init` drops its leading comptime `stack_threshold` argument, so the call is `Server.init(routes, config)`. The per-connection read buffer sits on the connection thread stack when `max_recv_buf` fits the internal `stack_read_buf_max` (4096) and heap-allocates otherwise, with `max_recv_buf` (config) the tuning knob. The unused `HttpServerConfig` field `max_client_response` is removed.
    - Migration: `zix.Http.Server.init(4096, &routes, cfg)` becomes `zix.Http.Server.init(&routes, cfg)`. `const S = zix.Http3.Http3(handler); var s = try S.init(cfg)` becomes `var s = zix.Http3.Server.init(handler, cfg)`. Drop `try` on `zix.Http2` / `zix.Grpc` / `zix.Http` init (an invalid port now surfaces from `run()`). Remove any `.max_client_response = N` from an `HttpServerConfig`.

- `zix.Http` https serve path (ADR-053):
    - `zix.Http` gains opt-in TLS (`config.tls`), the third HTTP engine to serve https/1.1. Each connection runs the handshake (TLS 1.3, with a 1.2 ECDSA fallback) and the keep-alive request loop on its own worker thread, the router response captured through the engine's existing response sink and encrypted, so a handler writes a normal Response and the cleartext path adds no hot-path cost. Buffered responses by default (WebSocket is a follow-up, SSE / streaming over TLS landed in ADR-054). New example `examples/tls/tls_http_basic.zig` (port 9071).
    - The multiplexed Http2 and gRPC TLS workers now pin per-core and size the worker count by the available cpuset (ADR-052 parity with Http1's `tls_mux`), so a cgroup-pinned cpuset no longer oversubscribes one core under a handshake storm.

    ---

- SSE / streaming over TLS (ADR-054):
    - `zix.Http` and `zix.Http1` serve Server-Sent Events over TLS on the thread-per-connection path (`.ASYNC` / `.POOL` / `.MIXED`). A per-connection stream sink (`TlsStreamSink`, type-erased over the live TLS 1.3 / 1.2 connection) encrypts one TLS record per write and sends it immediately, replacing the buffered capture only when a handler opts into streaming. `fdWriteAll` checks the buffered sink first, then the stream sink, so a normal response keeps the buffered fast path untouched.
    - `zix.Http` reuses `res.stream()` (no new public symbol, it now keeps the stream sink active over TLS). `zix.Http1` gains `beginStream()`, a no-op in cleartext, so one fd-handler serves cleartext and TLS. The multiplexed `tls_mux` path (`.EPOLL` / `.URING`) stays request / response only (later lifted by ADR-060 below).
    - New examples `examples/tls/tls_http_sse.zig` (port 9072) and `examples/tls/tls_http1_sse.zig` (port 9073), with runner steps `test-runner-tls-http-sse` / `test-runner-tls-http1-sse` (native `zix.Tls` client, no curl), folded into `test-runner-all`. `examples/http1_sse.zig` now calls `beginStream()`.

    ---

- WebSocket over TLS (ADR-055):
    - `zix.Http` and `zix.Http1` serve WebSocket over TLS (wss) on the thread-per-connection path (`.ASYNC` / `.POOL` / `.MIXED`). A handler calls `WebSocket.serveTls(fd, key, on_frame)`: it sends the `101` encrypted through the ADR-054 stream sink and registers a handoff, then the https serve loop runs an inline frame loop over the TLS session (decrypt records, parse frames, `on_frame` for text / binary, ping auto-ponged, close auto-echoed). Outbound frames re-use the ADR-054 stream sink, so each pump pass encrypts its coalesced frames as one record.
    - `zix.Http1` re-uses its existing frame codec (`parseFrame` / `pump` / `send`) and the `requestWebSocket` / `takeWebSocket` handoff. `zix.Http` gains the matching engine-driven pieces (`WsFrameFn`, `send`, `pump`, the handoff, `upgradeFd`), so the same `on_frame(fd, opcode, payload)` and `serveTls` work on both engines. Rooms / broadcast are not served over TLS (per-session encryption), so wss is per-connection / echo. The multiplexed `tls_mux` path stays request / response only (later lifted for `zix.Http1` by ADR-060 below).
    - New examples `examples/tls/tls_http1_ws.zig` (port 9074) and `examples/tls/tls_http_ws.zig` (port 9075), with runner steps `test-runner-tls-http1-ws` / `test-runner-tls-http-ws` (native `zix.Tls` client, no websocat), folded into `test-runner-all`.

    ---

- TLS dual listener (ADR-060):
    - New flat config field `tls_port: u16 = 0` on `Http1ServerConfig`, `HttpServerConfig`, `Http2ServerConfig`, and `GrpcServerConfig`: with `tls` set and `tls_port` non-zero, ONE server serves cleartext on `port` AND TLS on `tls_port` from the same worker fleet, replacing the two-launch setup that duplicated workers, fd tables, and caches. `tls_port == port` is rejected at `run()` (`error.TlsPortConflict`). Defaults unchanged: `tls` null stays cleartext-only, `tls` set with `tls_port` 0 stays TLS-only.
    - The per-connection TLS transport is shared in `src/multiplexers/tls_conn.zig` (session + backpressure staging + fd slot table), replacing four near-identical copies in the `tls_mux.zig` files. Engine loops stay per-engine (ADR-050).
    - Under `.URING` the TLS side rides the ring (`tls_accept` / `tls_recv` / `tls_send` user_data ops), no hidden epoll fleet. Under `.EPOLL` the TLS listener joins the same epoll, tagged in the event data word. The thread models serve the TLS side with one extra accept thread.
    - The `zix.Http1` mux loop now hosts WebSocket and SSE over TLS (encrypt-on-write through the per-connection stream sink), and the `zix.Http` mux loop hosts `res.stream()` over TLS, lifting the ADR-054 / ADR-055 thread-path restriction there.
    - New example `examples/tls/tls_http1_dual.zig` (ports 9076 cleartext / 9077 TLS), runner check `tls-http1-dual`, and per-engine dual-listener integration tests.

    ---

- `zix.Http2` native `.EPOLL` / `.URING` dispatch (ADR-043):
    - `zix.Http2` h2c gains the shared-nothing multiplexed loops it previously folded to `.POOL`. A resumable h2 mux state machine (`src/tcp/http2/mux.zig`, one `MuxConn` per fd, the read accumulator persists across readable events) is driven by `dispatch/epoll.zig` (one `SO_REUSEPORT` listener plus epoll plus a slab `ConnTable` per worker) and `dispatch/uring.zig` (one io_uring ring per worker, multishot accept, generation-tagged `user_data`). On the ring the worker owns accept plus recv and the handler writes the reply straight to the non-blocking fd (no per-stream cork). `.URING` probes the ring at startup and falls back to `.EPOLL` when io_uring is unavailable, both fold to `.POOL` off Linux.
    - `zix.Http2.Router` gains query-stripping and `.kind = .PREFIX`, mirroring `zix.Http1`: the query is stripped before matching, EXACT routes use a `StaticStringMap`, PREFIX matches the longest registered prefix on a segment boundary. `RouteKind` is exported.
    - New example family `examples/http2_basic_{1_async,2_pool,3_mixed,4_epoll,5_uring}.zig` (ports 9065-9069) with runner steps `test-runner-http2-{async,pool,mixed,epoll,uring}`, folded into `test-runner-all`.

    ---

- `zix.Http2` memory and throughput optimization (per-worker stream-slot pool, ADR-058):
    - Per-worker stream-slot pool (`src/tcp/http2/mux.zig`): the `.EPOLL` / `.URING` mux borrows each stream's slot (header table plus body / scratch buffers) from a thread-local free-list on stream open and returns it on close, so resident stream memory tracks concurrent streams instead of `connections * max_streams`. Each connection keeps only a `max_streams`-wide pointer array, and the steady state does no per-stream allocation (buffers reused across borrows). At 4096 connections this cut baseline-h2c memory about 6x while lifting throughput 8 to 20 percent, because the pooled hot slots have a tighter cache working set than the old sparse per-connection table.
    - HPACK response-header prefix cache (`src/tcp/http2/hpack.zig`, `respHeaderBlock`): the `[:status, content-type, content-encoding]` block for a hot triple is encoded once and reused byte-identical across connections (a stateless encoder, never the dynamic table), only `content-length` is encoded per reply. Lifted the small-body cells 18 to 26 percent at lower CPU.
    - Seal-in-place on the TLS 1.3 record path (`src/tls/record.zig` `protect2`, `src/tls/connection.zig` `writeAppData2`, `src/tcp/tls/tls_session.zig` `encrypt2`): a gather-encrypt that seals two plaintext slices into one record without a staging copy.
    - Config defaults: `Http2ServerConfig` / `ServeOpts` default `max_streams` 16 to 128 (advertised concurrency, cheap now the slot is pooled) and `max_body` 64 KiB to 16 KiB (buffered request body per stream, a larger body sheds the stream with 413). `max_header_scratch` stays 4 KiB.

- `zix.Grpc` memory and throughput optimization (per-worker stream-slot pool, ADR-058):
    - Per-worker stream-slot pool (`src/tcp/http2/grpc/core.zig`): the `.EPOLL` / `.URING` gRPC mux borrows each stream's slot (header table plus body / scratch buffers) from a thread-local free-list on stream open and returns it on close, so resident stream memory tracks concurrent streams instead of `connections * max_streams`. Each connection keeps only a `max_streams`-wide pointer array, and the steady state does no per-stream allocation (buffers reused across borrows). At 1024 connections this cut unary-grpc memory about 12x (916 to 77 MiB) while lifting throughput 8 to 11 percent, the same both-axes result as the Http2 pool. The blocking `.ASYNC` / `.POOL` / `.MIXED` path keeps its own per-connection arrays, unchanged.
    - Config defaults: `GrpcServerConfig` / `GrpcServeOpts` default `max_streams` 16 to 128 (advertised concurrency, cheap now the slot is pooled) and `max_body` 64 KiB to 16 KiB (buffered request body per stream, a larger body sheds the stream with RESOURCE_EXHAUSTED). `max_header_scratch` stays 4 KiB.

    ---

- gRPC over TLS and a shared h2-over-TLS terminator:
    - `zix.Grpc` serves native TLS (TLS 1.3, with a 1.2 fallback, ALPN h2) via `tls: ?*Tls.Context`, additive over the h2c default. The TLS path drives the resumable gRPC mux state machine (`grpcMuxProcessRing`) directly over the decrypted records, the same single-owner engine as the cleartext `.EPOLL` / `.URING` models, so it has no per-stream write races.
    - The h2-over-TLS terminator is factored into a shared, engine-agnostic `src/tcp/tls/h2_terminator.zig` (handshake 1.3 / 1.2, ALPN h2). It runs a caller-supplied inline-mux driver over the decrypted records and seals the engine's frames back into TLS records through a thread-local write hook, with no socketpair and no second thread. `zix.Http2` and `zix.Grpc` `tls_serve.zig` are thin wrappers supplying the driver.
    - Multiplexed TLS dispatch (ADR-052): for `.EPOLL` / `.URING`, one `SO_REUSEPORT` epoll worker per core terminates TLS in place via a resumable TLS 1.3 session (`src/tcp/tls/tls_session.zig`) and multiplexes many connections per worker (`tls_mux.zig`), so Http2 https and gRPC TLS no longer spawn a thread per connection at high concurrency. `.ASYNC` / `.POOL` / `.MIXED` keep the thread-per-connection terminator, which also serves the 1.2 fallback.
    - Docs `hld-grpc`, `hld-tls`, `lld-tls`, and `hld-grpc-proxy` (en and -id) updated for native gRPC TLS.

    ---

- Response compression (gzip / deflate / brotli):
    - `Accept-Encoding` negotiation with gzip and deflate. New shared codec `src/utils/compression/flate.zig` (container-parameterized over `std.compress.flate`: gzip = RFC 1952, deflate = zlib-wrapped RFC 1950, not raw) plus the `compression.zig` facade (q-value negotiation, `q=0` and wildcard handling, size floor, already-compressed media-type skip, encode/decode dispatch).
    - brotli (`br`) joins the facade as `src/utils/compression/brotli.zig`, an in-tree codec authored from RFC 7932 (std has no brotli): a complete decoder plus an encoder, embedding the 122,784-byte Appendix A static dictionary (`brotli_dictionary.bin`). `.BR` is in `supported_default`, but gzip stays the default at equal q (the in-tree encoder is not yet competitive with gzip on small bodies), so brotli is served when the client prefers it. Interop is verified both ways against the system `brotli` CLI. The encoder always also produces a store-only stream and returns the smaller, so a body never grows (a tiny body simply falls back to identity).
    - `zix.Http1` serves it via `core.writeNegotiated(fd, head, status, content_type, body)`, `zix.Http` via `Response.sendNegotiated(req, body)`, both setting `Content-Encoding` and `Vary: Accept-Encoding`. Active under `.EPOLL` and `.URING`, off by default. gRPC keeps its own per-message `grpc-encoding`, the raw transports have no HTTP negotiation.
    - `std.compress.flate.Compress` is about 230 KB and is built on the handler stack frame, so a compressing worker spawns with a 2 MiB stack (demand-paged, near-zero RSS) instead of the default 512 KB. The brotli encoder builds its dictionary index on the heap and the dictionary itself is `@embedFile` `.rodata`, so it adds no stack pressure.
    - Codec caller-buffer parity: `brotli.zig` gains `compressBrotli` / `decompressBrotli` (a buffer-into variant beside each alloc variant), so it mirrors `flate.zig`'s four-function shape. `flate.zig` and `brotli.zig` now expose matching named `EncodeError` / `DecodeError` (`BufferTooSmall` shared), and `compressBound` documents that brotli never expands while flate can. The bespoke `writeGzipCached` stays gzip-only by design (a json-comp A/B showed the unified replacement regresses about 1.2 to 6.8%), so no `writeBrotliCached` twin is added, brotli rides `writeNegotiated`.
    - New examples `http1_compression` (port 9058) and `http_compression` (port 9059), each with `/data` (negotiated) plus explicit `/gzip` `/deflate` `/br` routes that force one coding through the `compression.encode` facade. Individual runner steps `test-runner-http1-compression` / `test-runner-http-compression` (raw-socket, exercising br / gzip / deflate / identity / size-floor), and both examples are folded into `test-runner-all` as the `http-compression` / `http1-compression` rows (raw-socket read, decode, value-check each coding), taking the runner to 69 protocols.

    ---

- TLS (https / h2), pure-Zig on `std.crypto`, no OpenSSL:
    - TLS 1.3 server (RFC 8446) plus a TLS 1.2 floor (RFC 5246 / 5288, ECDHE-ECDSA-AES128-GCM), 1.3 preferred, never below 1.2 (1.0 / 1.1 / SSL never offered, RFC 8996). Sans-I/O handshake in `src/tls`, the HTTP engine owns the socket loop.
    - Native verifying client `zix.Tls.Client` (1.3) and `zix.Tls.Client12` (1.2): offers ALPN, verifies the server signature and the X.509 chain + hostname (RFC 5280 / 6125).
    - https is opt-in and additive (ADR-046): `zix.Http1` serves https/1.1 and `zix.Http2` serves h2 over TLS (ALPN h2), both a gated path in front of the unchanged cleartext engines. HelloRetryRequest, inbound-alert handling, and the misdirected-request 421 (RFC 9110 7.4) are wired.
    - Server TLS is configured by a user-owned `Tls.Context` object (ADR-047), mirroring the logger: `Tls.Context.init(allocator, io, config)` loads the cert / key and validates the policy once. `Tls.Context.Config` exposes `cert_path`, `key_path`, `alpn`, `min_version` / `max_version`, `curves`, `ciphers`, `prefer_server_ciphers`, `hsts_max_age_s`. Curves and ciphers are validated allow-lists (an unsupported value is a startup error). ECDSA P-256 and Ed25519 certificates, ECDHE-only (no dhparam).
    - RSA server certificates (ADR-048): an RSA cert signs the TLS 1.3 CertificateVerify with `rsa_pss_rsae_sha256` (pure-Zig, a constant-time Montgomery modexp in `montgomery.zig` plus EMSA-PKCS1-v1_5 / EMSA-PSS, RSA-2048 minimum). RSA requires TLS 1.3, the default cert type stays ECDSA P-256.
    - New examples in `examples/tls/`: `tls_http1_basic` (9060), `tls_http2_basic` (9061), `tls_http1_ed25519` (9062), with runner steps folded into `test-runner-all`.
    - Docs: `docs/hld-tls-en.md` / `docs/lld-tls-en.md` (and -id), ADR-045 / 046 / 047 / 048.

    ---

- Raw-bytes UDP datagram mode `zix.Udp.Raw` (ADR-049):
    - `zix.Udp.Raw(handler)` serves variable-length datagrams (up to `max_recv_buf`) alongside the typed `zix.Udp.Server(Packet)`. The handler takes the datagram bytes, the peer, and a `Sink` to reply through. On Linux it batches receive / send via `recvmmsg` / `sendmmsg`, replies coalescing into one `sendmmsg` per received batch, with per-core `SO_REUSEPORT` workers under `.EPOLL` / `.URING` (a single worker under `.ASYNC` / `.POOL` / `.MIXED`).
    - Dispatch is partitioned per ADR-043: `src/udp/dispatch/` (one file per model plus `common.zig`) with a thin `run()` switch, plus `src/udp/datagram.zig` (raw-fd socket + `recvmmsg` / `sendmmsg` primitives) and `src/udp/core.zig` (`HandlerFn`, `Sink`). The typed `Server(Packet)` is unchanged, a non-ASYNC `dispatch_model` on it folds with a logged notice. Non-Linux falls back to a single `std.Io.net` loop.
    - New example `examples/udp_server_raw.zig` (port 9064) with runner step `test-runner-udp-raw`, folded into `test-runner-all`. GSO and a dedicated io_uring submission path behind `.URING` land later with ADR-056 (below), GRO / ECN stay deferred.

    ---

- HTTP/3 over QUIC engine `zix.Http3`, pure-Zig on `std.crypto`, on the `zix.Udp` substrate (ADR-051):
    - `zix.Http3.Server.init(handler, config)` serves HTTP/3 (RFC 9114) over QUIC (RFC 9000 / 9001 / 9002), with a comptime `zix.Http3.Router` mirroring `zix.Http1` / `zix.Http2` (EXACT / PARAM / PREFIX, query stripped before matching). TLS 1.3 is mandatory, configured by the same user-owned `Tls.Context` as the TCP engines.
    - The deterministic QUIC / TLS / QPACK layers are pure-Zig from the RFCs: packet protection (header protection plus AEAD), the key schedule (Initial / Handshake / 1-RTT), CRYPTO-stream TLS 1.3 handshake (ServerHello plus the EE / Certificate / CertificateVerify / Finished flight), QPACK static-table field lines, and the RFC 7541 Huffman decoder for request paths.
    - Dispatch models (Linux-only): `.ASYNC` runs one single-worker recv loop with internal connection-id demux (migration-safe). `.POOL` / `.MIXED` run one SO_REUSEPORT recvmmsg worker per core, and `.EPOLL` / `.URING` add epoll readiness / io_uring completion on that per-core shape (`.URING` folds to the epoll worker loop when io_uring is unavailable). Per-core connection-id steering is deferred (ADR-049 phase 3, ADR-050).
    - Hot-path loss recovery and congestion control (ADR-056, superseding the ADR-051 deferrals): ACK-driven loss detection (RFC 9002), an RTT estimator, a Probe Timeout with backoff, and a NewReno congestion window now run on the serve path, so a lossy path recovers instead of a dropped tail packet stalling the whole response. A timer-driven maintenance sweep (every 5 ms) re-pumps a timed-out in-flight range. Only ack-detected loss cuts the congestion window, a PTO retransmits without reducing cwnd (RFC 9002 6.2). The `.EPOLL` and `.URING` models now run real per-core `SO_REUSEPORT` workers (each owns its own connection-id table, `.URING` a real io_uring ring falling back to the `.EPOLL` loop) instead of folding to the single v1 worker. A connection slot is reclaimed only on close or idle past `max_idle_ms`, never on loss, so a live-but-lossy peer stays connected. On the same cut `zix.Udp` raw gains its ADR-049 phase two (a real io_uring recv ring behind `.URING` plus UDP GSO). Cross-core connection-id steering for mid-connection migration stays deferred.
    - `zix.Http3` exports its low-level primitives (`crypto`, `protection`, `keyschedule`, `qpack`, `huffman`, `packet`, `varint`, `frame`, plus `tls_key_schedule`), the same way `zix.Http2` exports its frame / HPACK primitives, so a peer can build the other side of the wire.
    - New example `examples/tls/http3_basic.zig` (port 9063). The runner drives a hermetic native QUIC client hand-rolled from those primitives (no external tool), with runner step `test-runner-http3` folded into `test-runner-all`.
    - Docs: `docs/hld-http3-en.md` / `docs/lld-http3-en.md` (and -id).

    ---

- `zix.utils.multipart` (multipart parser relocated):
    - The `multipart/form-data` parser moved from `src/tcp/http/upload.zig` to `src/utils/multipart.zig`, protocol-agnostic byte parsing shared by `zix.Http` and `zix.Http1`. Types renamed `MultipartParser` to `Parser` and `MultipartField` to `Field`, so the canonical path is `zix.utils.multipart.Parser` / `zix.utils.multipart.Field`. `zix.Http.Multipart` / `zix.Http.MultipartField` stay as thin aliases (no break). `examples/http_static.zig` and `examples/http1_static.zig` call the canonical path, and `examples/http1_static.zig` gains a second upload route (`/upload-multipart`) demonstrating it on `zix.Http1`.

    ---

- Server config (knob) added:
    - `compress` (bool), `compression_min_size` (usize), and `compression_max_out` (usize) on `zix.Http1` and `zix.Http`. The gzip-specific `max_gzip_out` was renamed to the codec-agnostic `compression_max_out`.
    - `tls` (`?*Tls.Context`) on `zix.Http1`, `zix.Http2`, and `zix.Grpc`, the https opt-in gate. Replaces the flat `tls_cert_path` / `tls_key_path` / `tls_alpn` / Http1 `hsts_max_age_s` fields (ADR-047).
    - `dispatch_model`, `workers`, `reuse_address`, `recv_batch`, `send_batch`, `max_recv_buf` on `zix.Udp` (`UdpServerConfig`), used by the raw path (`zix.Udp.Raw`, ADR-049). Additive, the typed `Server(Packet)` is unchanged.
    - `public_dir` and `public_dir_upload` on `zix.Http1` (`Http1ServerConfig`), static file serving for unmatched routes mirroring `zix.Http`. A non-empty `public_dir` is validated at `run()` and yields `error.PublicDirNotFound` when absent.
    - `uring_send_buf_size` (default 16 KiB), `uring_idle_pool_floor` (default 8), and `uring_idle_pool_ceiling` (default 256) on `zix.Http1` (`Http1ServerConfig`), tuning the `.URING` per-connection send buffer and the warm reconnect-pool bounds (see the Http1 / Http memory optimization entry).

    ---

- gRPC server-streaming DATA-frame coalescing (ADR-057):
    - `zix.Grpc` server-streaming packs consecutive messages into fewer, larger HTTP/2 DATA frames (up to the 16 KiB default max frame size) instead of one DATA frame per message. A `count = 5000` reply drops from 5000 tiny DATA frames to about 3, cutting the frame-header bytes on the wire and the client's per-frame parse cost. The fix lives in the shared `muxDispatch`, so `.URING`, `.EPOLL`, and both TLS mux paths inherit it. Unary keeps one frame per message and is byte-for-byte unchanged. The thread path (`.ASYNC` / `.POOL` / `.MIXED`) is not coalesced yet. The bundled `zix.Grpc.Client` unpacks multiple messages from one DATA frame (each `recvResponse` drains the frame's leftover before reading the next), matching the coalescing.

    ---

- HTTP/3 content-encoding negotiation:
    - `zix.Http3` gains content-negotiation on the response. `req.accept_encoding` exposes the client's Accept-Encoding (decoded from the QPACK static entry 31 or a literal, Huffman expanded), and a handler calls `res.setContentEncoding(.br)` / `.gzip`, which emits the `content-encoding` response header as one QPACK indexed line (static index 42 br / 43 gzip). The engine never compresses on the send path: the handler serves an already-compressed body (a pre-built `.br` / `.gz` file), so there is no per-request codec cost and the perf / memory rule holds. Serving the smaller pre-compressed variant is fewer packets per response, which is what moves static serving.
    - The QPACK static table extends from indices 0..28 to 0..43 (RFC 9204 Appendix A), covering `accept-encoding` (31) and `content-encoding` br / gzip (42 / 43). The request decoder scans past the pseudo-headers to capture `accept-encoding`, and `buildRequestStreamContent` / `buildStreamPrefix` emit the `content-encoding` line (`SendStream` stores the coding so a resumed multi-packet body keeps its header). The change lives in the shared `dispatch/common.zig`, so every dispatch model inherits it.
    - `zix.Http3.ContentEncoding` is exported. `examples/tls/http3_basic.zig` gains a `/negotiated` route that serves a brotli-precompressed body with `content-encoding: br` when the client accepts br. Docs `hld-http3`, `lld-http3` (en and -id) updated.

    ---

- HTTP/3 rolling flow-control credit (MAX_STREAMS + MAX_DATA):
    - The QUIC handshake advertises two one-time budgets to the client, `max_streams` request streams and `initial_max_data` (1 MiB) of request bytes across the connection. Both are now rolled forward as the client spends them: the MAX_STREAMS grant (frame 0x12, `replenishBidiStreams`) rises as request streams retire, and the MAX_DATA grant (frame 0x10, `replenishMaxData`) rises as request bytes are consumed. Each grant is emitted once consumption crosses half its window and rides the coalesced reply prologue like the ACK.
    - Fixes a connection-lifetime deadlock: without the byte grant, a connection went silent after about `initial_max_data` of requests, the client blocked on connection flow control and its last in-flight requests were never answered, so a long-lived connection's throughput capped at a hardware-independent constant. With both grants rolling, a connection serves indefinitely.
    - New pieces: `flight.initial_max_data` (the advertised value and the replenish window, one const), `Connection.replenishMaxData`, `request.streamBytes` (sums a packet's STREAM payload bytes across all streams, since connection-level flow control counts them all), and `response.buildMaxData` plus `Framing.max_data`. The wiring lives in the shared `dispatch/common.zig`, so every dispatch model inherits it. Unit tests cover the replenish math, the frame encoding, and the byte counting.

    ---

- Response-API send / write / FD naming taxonomy (ADR-059):
    - The response-writing surface is renamed on two independent axes so a call site reads unambiguously: a function that sends a response, or any outbound communication, is `send*`, a pure write with no send is `write*`, and a signature that takes a raw `fd` parameter ends in `FD` (an fd held inside a struct, reached through `self`, does not count, so object methods stay clean).
    - Breaking for code calling the response helpers directly. The core fd-level helpers rename across every engine: `fdWriteAll` -> `writeAllFD`, `fdWriteAllRaw` -> `writeAllRawFD`, `writeSimple` -> `sendSimpleFD`, `writeSimpleNoBody` -> `sendSimpleNoBodyFD`, `writeJson` -> `sendJsonFD`, `writeGzip` -> `sendGzipFD`, `writeGzipCached` -> `sendGzipCachedFD`, `writeBrotli` -> `sendBrotliFD`, `writeNegotiated` -> `sendNegotiateFD`, `writeChunkedStart` / `writeChunk` / `writeChunkedEnd` -> `sendChunkedStartFD` / `sendChunkFD` / `sendChunkedEndFD`, `writeRange` -> `sendRangeFD`, `write100Continue` -> `send100ContinueFD`. Function bodies and parameters are unchanged, only names and the doc / comment text that references them.
    - Compression-capable engines expose the same six: `sendGzipFD`, `sendGzipCachedFD`, `sendBrotliFD`, `sendBrotliCachedFD`, `sendNegotiateFD`, `sendNegotiateCachedFD`. Negotiate routes internally through the shared gzip / brotli path, so the compression policy lives in one place, and the precompressed / caller-encoded primitive (`sendResponseEncodedFD`) stays as the layer those six build on.
    - Rolled out engine by engine (`zix.Http1`, its WebSocket, `zix.Http2`, `zix.Grpc`, `zix.Http3`, then the full server plus shared tls / dispatch), each step gated by the full test suite. HttpArena entries and the bundled examples move to the new names (call sites only, no behavior change). Docs `hld-http1`, `lld-http1`, `lld-http`, `lld-http2`, `lld-grpc`, `lld-tls` (en and -id) updated. See ADR-059.

    ---

- `zix.Http1` and `zix.Http` memory optimization (EPOLL recv-slab compaction, URING idle-pool bound):
    - EPOLL recv-slab compaction (`src/tcp/http1/dispatch/epoll.zig`, ported to `zix.Http`'s `dispatch/common.zig`): the per-worker receive slab was indexed by global fd (`slab[fd * buf_size]`), so touched pages scattered across the whole 64K-fd space and held far more resident than the live connection set needed. A compact per-worker slot free-list (each `Conn` carries a `slot`, `acquireSlot` reuses a closed slot before bumping a high-water mark, `free` returns the page-aligned stride via `MADV_DONTNEED`) packs resident memory to the live count regardless of fd values. At high connection counts this cut peak Http1 memory about 2.5x (roughly 704 to 281 MiB), bringing `.EPOLL` to `.URING` parity, with throughput held within loopback noise.
    - URING idle-pool bound (`src/tcp/http1/dispatch/uring.zig`): the warm reconnect pool now evicts its least-recently-used tail (`evictColdTail`, a warm MRU list plus a cold stack) past a bound, shrinks a grown per-connection `send_buf` back to the base size on release, and prewarms a small resident floor at startup to avoid a cold-start page-fault storm. Reclaiming the cold tail (not the hot head a reconnect grabs next) keeps the reclaim off the churn hot path, so memory drops without a throughput cost. Bounded by the `uring_send_buf_size` / `uring_idle_pool_floor` / `uring_idle_pool_ceiling` config knobs above.

    ---

- Worker CPU placement (Linux multiplexed engines, ADR-061):
    - New flat config field `reuseport_cbpf: bool = false` on every server config except `zix.Uds`: attach SO_ATTACH_REUSEPORT_CBPF steering to the per-worker `SO_REUSEPORT` group (`src/multiplexers/reuseport.zig`), so the kernel hands a new connection (TCP) or each datagram (UDP) to listener index = receiving CPU mod workers instead of hashing the 4-tuple. Listeners bind inside racing worker threads, so a startup-only bind-order gate serializes the group joins (worker i = group index i). Opt-in, default false: rps-neutral on a loopback box, it targets multi-CPU hosts where NIC RSS spreads softirqs. Never enable it on the QUIC path: per-packet steering breaks QUIC flow affinity (a flow's packets land on different workers) and collapses throughput.
    - Worker pinning extends to `zix.Tcp` and `zix.Fix` (`.EPOLL` / `.URING` workers, cpuset-aware count plus per-core pin), and every engine's pin order now fills physical cores first, SMT siblings after (sysfs topology, mask order kept when sysfs is absent).
    - Per-worker load counters report at worker exit through the system logger (requests, frames, accepted connections, or messages, per engine), so a skewed distribution across workers is observable. The two h2-mux engines (`zix.Http2`, `zix.Grpc`) do not carry the counter: a threadlocal increment in their mux hot loop measured about 1 percent of throughput at multi-million req/s, so it stays off their hot path.

- `zix.Udp` raw `.URING` multishot receive: the per-core ring arms a multishot `recvmsg` with a provided buffer ring (mirroring `zix.Http3`'s recv layer, 256 buffers), replacing per-completion re-arms, with the one-shot slot pool kept as the fallback.

    ---

- `.URING` submission-queue backpressure (process queue):
    - New flat config field `process_queue_len: usize = 0` on `Http1ServerConfig` and `HttpServerConfig`: under `.URING`, a recv or send re-arm that finds the submission queue full is parked on a per-worker FIFO ring of this length (references only, fd plus generation, reject-newest) and retried on the next loop pass instead of closing the connection. 0 (default) keeps the feature off, and it has no effect under the other dispatch models. Size it to about the peak concurrent connections per worker.
    - Lost-accept re-arm fix across the `zix.Http1`, `zix.Http`, `zix.Grpc`, and `zix.Http2` `.URING` dispatches: a multishot-accept re-arm dropped on a full SQ left the worker unable to accept again while the kernel backlog filled. The worker now records the miss (`accept_pending` / `tls_accept_pending`) and retries the arm right after the next submit, so a full SQ no longer wedges accept.
    - `zix.Http3` `.URING` submission-queue losses fixed (`src/udp/http3/dispatch/uring.zig`): a multishot `recvmsg` re-arm lost to a full SQ left the worker permanently deaf (a sticky `recv_unarmed` retry now re-arms it), a one-shot slot re-arm lost to a full SQ leaked the slot (a bounded pending re-arm list now recovers it), and a send tail capped by a full SQ was discarded on the buffer swap (the swap now defers while a tail is still unsent).
    - Oversize request body sheds instead of truncating: `zix.Http2` answers a DATA body past the stream buffer with `413` and END_STREAM (crediting only the connection window for the discarded bytes), and `zix.Grpc` ends the stream with `RESOURCE_EXHAUSTED` trailers. Previously the body was silently truncated to the cap, which could dispatch a corrupt message. A later DATA frame for a shed stream is answered with RST_STREAM, and the connection's other streams continue.

<br>

__*Fix:*__

- `zix.Http1` large-body drain under the thread models:
    - Under `.ASYNC` / `.POOL` / `.MIXED`, a request body larger than the receive buffer was truncated at the buffer boundary and its unread bytes corrupted the next keep-alive request on the connection. The thread path now drains the remainder before serving the next request, matching the `.EPOLL` / `.URING` behavior.

    ---

- `zix.Http` request-body truncation under `.EPOLL` / `.URING`:
    - A multi-segment request body (a large or chunked upload split across reads) was truncated when `body()` / `readChunkedBody()` hit `EAGAIN` mid-body. The reader now polls the fd and retries up to `body_read_timeout_ms` (default 30s), so an upload is read in full. The hot GET path returns early and pays nothing.

<br>

## 0.4.0 (2026-06-19)

__*Update:*__
- io_uring churn scaling and on-ring response overflow (ADR-041):
    - `zix.Http1` `.URING` teardown now rings the close (`prep_close`, tagged with a new shared `OpKind.close`) instead of a synchronous `linux.close`, recycling the connection slot first and falling back to a synchronous close only when the SQ is momentarily full. Under connection churn the synchronous close blocked the worker between connections, so the ring barely engaged its cores. With the ring close the worker keeps reaping completions across teardowns. On the 64-core box this lifts the churn cells (limited-conn, json) from far behind `.EPOLL` to parity or better, at a fraction of the memory, so `.URING` now reaches parity or better on every measured cell.
    - `RespSink` (`tcp/http1/core.zig`) grows its staging buffer on overflow when backed by an allocator: the `.URING` loop installs it over the per-connection `send_buf` with a 1 MiB cap (`URING_SEND_BUF_MAX`), so a response larger than the staged buffer grows in place (power-of-two realloc, never shrinks, reused by the recycled connection) and still leaves as one on-ring send, instead of stalling the worker on a blocking off-ring write. The `.EPOLL` path installs no grow allocator and is unchanged (flush-on-overflow).
    - The shared io_uring `OpKind` and ring helpers moved from `src/tcp/io_uring` to `src/multiplexers/ring.zig`. Every io_uring engine carries a `.close => {}` arm. Only `zix.Http1` arms the ring close for now.

    ---

- Server `io` into config and `zix.Uds` handler-at-init (ADR-039):
    - `zix.Tcp`, `zix.Udp`, and `zix.Uds` now carry `io: std.Io` as the first config field, so `run()` takes no argument, matching the five engine servers. Every zix server is now constructed with a config that carries `io` and served with a no-argument `run()`.
    - `zix.Uds` adopts the ADR-038 factory shape: `Server.init(comptime handler, config)` bakes the handler into the type, and the built-in `zix.Uds.echoHandler` is passed explicitly. The `run(io, handler)` / `runWith` path is removed.
    - Breaking: every `zix.Tcp` / `zix.Udp` / `zix.Uds` server call site adds `.io = process.io` and drops the `run` argument. Clients keep `io` as a `connect()` parameter (deferred to a separate decision).

    ---

- io_uring dispatch model (`.URING`, ADR-037):
    - New shared-nothing `.URING = 4` dispatch model: same thread-per-core topology as `.EPOLL` (one `SO_REUSEPORT` listener and one completion ring per worker, no shared queue), but completion-based, so most syscall transitions are batched into the ring. Linux-only, falls back to `.POOL` on non-Linux.
    - Native across `zix.Http1` (reference engine, plus the WebSocket pump on a `BufferGroup`), `zix.Http`, `zix.Grpc` (multiplexed h2), and `zix.Fix` (resumable `core.processFixRing` per readable batch). `zix.Http2` folds to `.POOL` and the `zix.Tcp` per-connection handler folds to `.EPOLL`.
    - Request bodies on the ring (`zix.Http1`): a chunked request body fully present in the recv buffer is decoded in place, and a body larger than `max_recv_buf` is answered then its remainder is drained off the socket with a single `MSG_TRUNC` recv (the kernel discards the bytes in place, zero copy, capped at the declared length), mirroring the `.EPOLL` drain. So `.URING` serves large uploads and chunked requests, not only buffered ones.
    - On loopback `.URING` matches `.EPOLL` on throughput and total CPU, winning mainly on per-request cache locality. Prefer `.EPOLL` by default, `.URING` for sustained, pipelined load.

    ---

- `zix.Tcp` server API reshape (ADR-038):
    - The handler is baked into the server type at `init`, so `run` takes no handler argument, mirroring `zix.Http1` / `zix.Grpc` (ADR-039 then moves `io` into config, so `run()` takes nothing). `zix.Tcp.Server` is now a fieldless namespace with comptime constructors `init(handler, config)` / `initArgs(handler, config, args)` (per-connection) and `initFramed(frame_fn, config)` / `initFramedArgs(frame_fn, config, args)` (per-frame ring).
    - Breaking: `runWith` and `runFramed` are removed. The built-in echo default is the public `zix.Tcp.echoHandler`, passed explicitly. The per-connection handler runs `.ASYNC` / `.POOL` / `.MIXED` / `.EPOLL` (`.URING` folds to `.EPOLL`). The new per-frame `FrameFn` callback (`initFramed`) runs natively on the `.URING` ring.

    ---

- `Http2ServerConfig.logger`:
    - New optional `logger: ?*Logger` field on `Http2ServerConfig`, for consistency with the other server configs. When set, `zix.Http2` lifecycle lines route through `logger.system(.INFO, "http2", ...)` instead of the Debug-only `std.debug.print`.

    ---

- `zix.Http2` frame constants:
    - The HTTP/2 frame-type bytes are renamed from `FT_*` to the spelled-out `FRAME_TYPE_*` (`FT_DATA` -> `FRAME_TYPE_DATA`, and so on). Breaking for any code referencing `zix.Http2.FT_*`.
    - New `pub const FRAME_HEADER_LEN` (9) in the h2 frame module (re-exported from `zix.Http2`) names the 9-octet frame header length, replacing the inline `9` literals across the h2 and gRPC frame codecs.

    ---

- Response cache awareness (opt-in, ADR-036):
    - New shared `src/utils/response_cache.zig`: a per-worker, lock-free precomputed-response cache (structure-of-arrays slab, open addressing, lazy on-access TTL). Off by default, installed under `.EPOLL` and `.URING`. The other dispatch models leave it uninstalled and the API degrades to a plain send.
    - Five flat config fields with identical names across `Http1ServerConfig`, `HttpServerConfig`, and `GrpcServerConfig`: `response_cache` (`bool`, default `false`), `cache_max_entries` (`u32`), `cache_max_value_bytes` (`u32`), `cache_ttl_ms` (`u32`), and `cache_max_total_bytes` (`usize`).
    - `zix.Http`: `res.serveCached(req)` and `res.sendCached(req, body, ttl)` cache the full serialized response, keyed on method, path, and query. `zix.Http1` keeps `cacheLookup` / `cacheStore` / `writeWithCache`.
    - `zix.Grpc` (unary): `ctx.serveCached(content_type)` and `ctx.sendCached(content_type, data, ttl)` cache the response message, keyed on path plus request body, re-framed per stream so HPACK and stream id stay correct.
    - Measured crossover near 4 KiB: heavy ~32 KiB JSON +34% throughput at c512, zero regression below ~2 KiB. See ADR-036.

    ---

- WebSocket build-once broadcast fanout:
    - New `zix.Http1.WebSocket.broadcast(conns, opcode, payload)`: serializes the frame once and writes the same bytes to every fd in a caller-maintained room, so a broadcast costs one serialization regardless of member count. A failed write to a dead peer is skipped (the EPOLL engine reaps that fd on its next event), and the large-payload path builds the header once and writes the payload without a staging copy.
    - `zix.Http.WebSocket.RoomMap.broadcast` reuses a single staging buffer across all members instead of re-creating one per connection (build once, fan out).

    ---

- Http epoll shared-nothing:
    - `zix.Http` `.EPOLL` was rewritten from a centralized model (one accept thread pushing to a shared `ConnQueue`, pool workers popping) into a shared-nothing architecture matching `zix.Http1`. Each worker binds its own `SO_REUSEPORT` listener, creates its own `epoll` instance, and runs its own level-triggered event loop. The kernel distributes new connections across workers with no shared queue, no mutex, and no fd handoff.
    - `workers` (not `pool_size`) is now the EPOLL worker count for `zix.Http`. `0` selects cpu_count. `pool_size` is silently ignored for `.EPOLL` (callers using `.pool_size = N` with `.EPOLL` must migrate to `.workers = N`).
    - Level-triggered `EPOLLIN` replaces `EPOLLONESHOT`. No explicit re-arm after each request: connections stay registered and re-fire when new data arrives.
    - Throughput: 428k to 451k req/s at c1000 (`wrk -c1000 -t4 -d10s`), closing the gap vs `zix.Http1` from 11% to 6.8%. Remaining gap is structural (arena allocation per request). See ADR-034.

    ---

- Http1 EPOLL slab, RawFn, and Date control:
    - `zix.Http1` `.EPOLL` now backs each registered connection with a per-connection receive buffer slab (`ConnTable`), sized by `max_recv_buf`, so a connection accumulates a full request without re-allocating per event.
    - New `zix.Http1.RawFn` handler type plus `zix.Http1.Server.initRaw`: a raw handler receives the connection fd and the parsed head and owns the wire directly, bypassing the managed response path for full control (streaming, custom framing).
    - New `send_date_header` config field (default `true` for RFC 7231 compliance). Set `false` to drop the `Date` header and save 37 bytes per response on hot paths where the client does not need it.
    - `buildSimpleHeaderInto` writes the status line and headers into a caller sink, the fast path for the slab writer.

    ---

- WebSocket optimization:
    - SIMD unmask: `parseFrame` in both `zix.Http1` and `zix.Http` WebSocket engines now unmasks the client payload with a 16-wide `@Vector(16, u8)` XOR against a replicated 4-byte mask, with a scalar tail for the remainder. Replaces the per-byte `i % 4` loop.
    - New `ws_recv_buf` config field on `Http1ServerConfig` (default `0`, falls back to `max_recv_buf`). Set larger than `max_recv_buf` to give EPOLL WebSocket connections more room to accumulate pipelined frames before a compact and re-read.
    - `zix.Http1` EPOLL WebSocket reads now drain to `EAGAIN` per wakeup (read all available frames in one event) and coalesce writes, instead of one frame per wakeup.
    - `zix.Http` WebSocket: `buildHeader` (header-only framing into a caller buffer), cleaned `RoomMap` broadcast path.

    ---

- gRPC mux per-connection staging and corking:
    - `GrpcMuxConn` now owns a 64 KB `stage_buf` (was an inline 4096-byte `ReplyStage.buf`). One streaming call of ~5000 messages (~85 KB peak) flushes in two writes, and ~100 concurrent unary replies (~6 KB) coalesce into one write. `ReplyStage.buf` is now a caller-owned slice. The blocking inline path keeps a 4096-byte stack backing.
    - Server SETTINGS frame is precomputed once per connection: `buildSettingsFrame` fills a 33-byte blob in `GrpcMuxConn.init`, and the handshake appends it as-is instead of re-encoding the parameter loop on every connection.
    - `TCP_CORK` wraps streaming handlers in `muxDispatch`: the kernel coalesces the multiple intermediate stage flushes a streaming handler produces into fewer TCP segments, then uncorks on return. Unary replies are unaffected (already single-write). No-op on non-Linux.

    ---

- Dynamic epoll timeout (gRPC, TCP, FIX workers):
    - The EPOLL worker loop now flips `epoll_wait` timeout to `0` after a batch of active events (busy-poll for the next ready batch) and back to `-1` (block) when a wakeup returns zero events. Trades a tight spin under load for lower latency between back-to-back batches without burning a core while idle.

    ---

- Build split:
    - `build.zig` was split into focused sub-files imported by the root: `zix-build-examples.zig`, `zix-build-tests.zig`, `zix-build-test_runner.zig`. The root `build.zig` shrank from ~682 lines to the module and step wiring. No build-command changes.
    - The library root source file was renamed `src/zix.zig` to `src/lib.zig` (matching Zig's `lib.zig` convention). The module is still registered as `b.addModule("zix", ...)`, so the public API is unchanged: consumers still `@import("zix")` and use `zix.Http`, `zix.Grpc`, etc.

    ---

- Unified, Debug-gated server init logging:
    - Every server (`zix.Http`, `zix.Http1`, `zix.Http2`, `zix.Grpc`, `zix.Fix`, `zix.Tcp`, `zix.Udp`, `zix.Uds`) now emits lifecycle lines (listening, EPOLL fallback, accept errors) through one gated `logSystem` shape: route to `config.logger` when set, otherwise `std.debug.print` only in Debug builds, silent in release. A release server with no logger emits no init noise.
    - Removed the junk and duplicate raw prints: `zix.Grpc` previously printed each listening line raw and also logged it. `zix.Http2`/`zix.Fix`/`zix.Tcp` printed raw lifecycle/fallback lines unconditionally. `zix.Udp`/`zix.Uds` init lines now also appear in Debug builds without a logger (were logger-only before).
    - `zix.Channel.init` gained a Debug-only init notice (`zix channel: init <T> cap=<N>`), suppressed in release and under the test runner (`builtin.is_test`) to avoid poisoning the test IPC.
    - Reworded a `src/tcp/http1/server.zig` comment to drop a stale external benchmark reference.

    ---

<br>

__*Fix:*__

- gRPC and HTTP/2 stream write under EPOLL:
    - `fdWriteAll` (`src/tcp/http2/frame.zig`) now handles `EAGAIN` on a non-blocking EPOLL socket with a full send buffer: it polls the fd for writable then retries, instead of treating the partial write as a broken pipe. Blocking sockets never hit this branch. Fixes truncated streaming replies and spurious stream errors under high concurrency.

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
