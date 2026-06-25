# ADR-051 draft: HTTP/3 over QUIC engine

Lean note. The full record lives in `docs/adr-en.md` / `docs/adr-id.md` (ADR-051).

## Decision in one line

Author HTTP/3 pure-Zig from the RFCs as `zix.Http3` on the `zix.Udp` datagram substrate, reusing `src/tls` for the TLS 1.3 handshake carried over QUIC CRYPTO frames.

## Why

QUIC is a large surface (packet protection, transport state machine, loss recovery, QPACK, HTTP/3 framing, TLS-in-CRYPTO). `std` has the crypto primitives but no QUIC wiring. One handshake implementation across TCP and QUIC, no C library, no perf / memory regression.

## Shape

- RFCs: 9000 transport, 9001 QUIC-TLS, 9002 recovery, 9114 HTTP/3, 9204 QPACK.
- Deterministic layers built + vector-proven bottom-up before assembly: crypto, protection, keyschedule, qpack, huffman, packet, varint, frame, recovery, h3.
- v1 ships as one single-worker recv loop with internal connection-id demux (Destination CID, Source-CID fallback), migration-safe by construction. `.EPOLL` / `.URING` fold to the v1 worker.
- Comptime `Router`, same shape as `zix.Http1` / `zix.Http2`. TLS 1.3 mandatory via the same `Tls.Context` (ADR-047).
- Exports its low-level primitives so a peer (the hermetic native test client) can build the other side of the wire.

## Landed

- `src/udp/http3/` (deterministic layers + engine layer + live-handshake driver), RFC vectors in `test {}`.
- `examples/http3_basic.zig` (port 9063, ECDSA P-256). Validated by `curl --http3` and the hermetic native client `tests/runner/http3_client.zig` (`test-runner-http3`, folded into `test-runner-all`).
- Green on Zig 0.16 and 0.17.

## Deferred

Per-core CID steering (v2, ADR-049 phase 3), QPACK dynamic table, loss / congestion in the hot path, key update, migration beyond v1 demux, QUIC Interop Runner + qlog, the 64-core HttpArena gate.
