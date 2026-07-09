# ADR-060 (accepted record)

Records the TLS dual listener: one flat `tls_port: u16 = 0` config field lets ONE server serve
cleartext on `port` and TLS on `tls_port` from the same worker fleet, on a shared per-connection
TLS transport (`src/multiplexers/tls_conn.zig`). Folded into the public ADR docs (en and id) as the
accepted ADR-060, kept here as the record.

## Status

Accepted. Landed on Http1, Http, Http2, and Grpc, every dispatch model, green on Zig 0.16 and 0.17.
Http3 is exempt (QUIC is always encrypted, one UDP listener). Perf gate: cleartext RPS / memory on
the isolate bench must not regress past 1% or the layout change reverts.

## Context

TLS was all-or-nothing per server: non-null `config.tls` flipped the whole server TLS-only, so
serving both transports took a second `Server` launch that duplicated the full runtime (worker
fleet, MAX_FD fd tables, epoll instances, response / static caches). The four `tls_mux.zig` files
carried near-identical copies of the per-connection TLS transport, `.URING` ran its TLS side on a
parallel epoll fleet, and WebSocket / SSE over TLS were confined to the thread path (ADR-054 /
ADR-055).

## Decision

| tls | tls_port | behavior |
| :- | :- | :- |
| null | any | cleartext only on port (unchanged, tls_port ignored) |
| set | 0 | TLS-only on port (unchanged) |
| set | non-zero | ONE server: cleartext on port + TLS on tls_port, same workers |

`tls_port == port` is `error.TlsPortConflict` at run(), validated before any thread spawns.

- Shared transport `src/multiplexers/tls_conn.zig`: resumable session, outbound-ciphertext
  backpressure staging, fd -> slot table. Engine loops stay per-engine (ADR-050).
- `.EPOLL`: the TLS listener joins the worker epoll, events tagged `tls_event_tag | fd` in the
  data word. The TLS table maps only when tls_port is active (zero cleartext layout change).
- `.URING`: TLS rides the ring (`tls_accept` / `tls_recv` / `tls_send` ops), half-duplex flush
  (staged ciphertext sent on-ring before the next recv arms, the buffer never moves under the
  kernel).
- Thread models: one extra accept thread (`serveTlsThread`) through the existing tls_serve path.
- The Http1 mux loop hosts WebSocket + SSE over TLS via a per-connection stream sink, zix.Http
  hosts `res.stream()` the same way (its WS stays thread-path, parity with its cleartext mux).
- ALPN stays engine-side (h2 engines enforce `alpnIsH2`, no per-engine override field), so one
  `Tls.Context` can back every engine in a process.

## Consequences

- Dual serving drops from 2 fleets / 2 fd tables / 2 cache sets to 1, plus a demand-paged TLS
  pointer slab when tls_port is active.
- Cleartext hot path unchanged apart from the u64 epoll-data registration form (same bytes for an
  fd) and one predictable branch per event.
- Coverage: tls_conn unit tests, per-engine dual-listener integration tests (ports 9210-9234),
  example `examples/tls/tls_http1_dual.zig` (9076 / 9077), runner check `tls-http1-dual`, verify
  doc `rnd/0.5.x/verify-tls-dual-listener.md`.
- HttpArena side: the `attempt 1` entries collapse their two-launch setups into `tls_port`.
