# HTTP/3 plan (full path from PoC to shipped engine)

HTTP/3 is authored pure-Zig from the RFCs, no external library. The five layers are fully specified
and all vendored under `rnd/rfc/`: 9000 (QUIC transport), 9001 (QUIC-TLS, packet protection), 9002
(loss / congestion), 9114 (HTTP/3), 9204 (QPACK). RFC MUST / MUST NOT detail and the running tracker
live in `rnd/checklist-0.5.x-http3.md` and `rnd/rfc/http3-conformance-must-checklist.md`.

Bottom-up, like the brotli decoder-first order: you cannot test H3 framing without QUIC streams,
which need the handshake, which needs packet protection, which needs the crypto. So Layer C first,
each phase proven against a deterministic oracle before the next builds on it.

## std-gap

`std.crypto` ships every cryptographic primitive QUIC needs. The gap is the QUIC / H3 wiring, plus
one piece zix already wrote.

| Piece | std gives | zix authors |
| :- | :- | :- |
| AEAD (AES-128/256-GCM, ChaCha20-Poly1305), AES-ECB mask, HKDF, SHA-256 | yes | the RFC 9001 key labels + packet / header protection |
| TLS 1.3 handshake state machine | no | already in `src/tls` (key_schedule, handshake, certificate); QUIC reuses it, only the record layer differs |
| QUIC transport, QPACK, H3 framing, loss / congestion | no | authored from RFC 9000 / 9204 / 9114 / 9002 |
| datagram I/O (recvmmsg / sendmmsg) | n/a | already in `src/udp` (zix.Udp) |

## Prerequisite: TLS 1.3 (settled)

- [x] pure-Zig TLS 1.3 server handshake exists (`src/tls`), so no C library. QUIC reuses the
  handshake messages + `key_schedule` secrets, adding the RFC 9001 "quic" labels and CRYPTO-frame
  carriage. ECDSA / Ed25519 / RSA signing already land.
- [ ] ALPN "h3", SNI, and the `quic_transport_parameters` extension (0x39) over the existing handshake

## Layer C: crypto + packet protection (RFC 9001, deterministic oracle = Appendix A vectors)

- [x] C1: Initial secret derivation + AEAD packet protection + header protection. Proven in
  `rnd/0.5.x/quic_initial_poc.zig` against RFC 9001 Appendix A: 15 vectors byte-exact (A.1 secrets +
  key / iv / hp for both directions, A.2 sample / mask / protected header / packet head / tag). Gate
  `verify-quic-initial.sh` (doc `verify-quic-initial.md`).
- [x] C2: Retry integrity tag (AES-128-GCM, fixed v1 key + nonce, RFC 9001 5.8). Proven in
  `rnd/0.5.x/quic_retry_poc.zig` against Appendix A.4: 4 vectors byte-exact (key + nonce derived from
  the published secret, tag over the pseudo-packet, full reconstructed Retry packet). Gate
  `verify-quic-retry.sh` (doc `verify-quic-retry.md`).
- [x] C3: ChaCha20-Poly1305 short-header protection + key-update secret. Proven in
  `rnd/0.5.x/quic_keyupdate_poc.zig` against RFC 9001 5.4.4 / 6.1 / Appendix A.5: 10 vectors
  byte-exact (key / iv / hp / ku derivation, ChaCha20-based header mask, protected short-header
  packet). Gate `verify-quic-keyupdate.sh` (doc `verify-quic-keyupdate.md`). Retaining old keys +
  two receive-key sets across a phase flip is connection state, deferred to Layer Q.
- [x] C4: AEAD confidentiality / integrity limits + constant-time send / receive paths. Proven in
  `rnd/0.5.x/quic_aead_limits_poc.zig` against RFC 9001 6.6 / 9.5: 20 checks (per-AEAD 2^23 / 2^52 /
  2^36 limits, send / receive accounting -> key update or AEAD_LIMIT_REACHED close, constant-time
  authenticated tamper rejection on flipped tag / ciphertext / header). Gate
  `verify-quic-aead-limits.sh` (doc `verify-quic-aead-limits.md`). Layer C complete.

## Layer Q: QUIC transport (RFC 9000, in-process tests on crafted packets)

- [x] Q1: varint codec + sample encodings (Appendix A), long / short header parse (Fixed Bit, CID <= 20).
  Proven in `rnd/0.5.x/quic_transport_q1_poc.zig` against RFC 9000 16 / 17 / Appendix A: 34 checks
  (A.1 varint decode + encode + Table 4 boundaries, A.2 / A.3 packet number, long / short header
  parse + invariant rejects). Gate `verify-quic-transport-q1.sh` (doc `verify-quic-transport-q1.md`).
- [x] Q2: frame parse / encode, unknown -> FRAME_ENCODING_ERROR, disallowed -> PROTOCOL_VIOLATION.
  Proven in `rnd/0.5.x/quic_transport_q2_poc.zig` against RFC 9000 12.4 / 12.5 / 19: 32 checks
  (PADDING / PING / CRYPTO / STREAM parse with OFF / LEN / FIN bits, unknown + non-minimal type
  rejects, Table 3 number-space permission matrix). Gate `verify-quic-transport-q2.sh` (doc
  `verify-quic-transport-q2.md`).
- [x] Q3: connection IDs (NEW / RETIRE, active_connection_id_limit), stream state machine + 62-bit ids.
  Proven in `rnd/0.5.x/quic_transport_q3_poc.zig` against RFC 9000 2.1 / 3 / 5.1.1 / 19.15: 29 checks
  (Table 1 stream types, Figure 2 / 3 send + receive state machines, NEW_CONNECTION_ID validation +
  CONNECTION_ID_LIMIT_ERROR + retire-floor monotonic). Gate `verify-quic-transport-q3.sh` (doc
  `verify-quic-transport-q3.md`).
- [x] Q4: flow control (per-stream + connection) -> FLOW_CONTROL_ERROR, ACK, PATH_CHALLENGE / RESPONSE.
  Proven in `rnd/0.5.x/quic_transport_q4_poc.zig` against RFC 9000 4 / 19.3 / 19.17 / 19.18: 20 checks
  (two-level flow control + only-increasing limits, ACK range arithmetic + ECN + delay decode +
  negative-range reject, path challenge echo). Gate `verify-quic-transport-q4.sh` (doc
  `verify-quic-transport-q4.md`).
- [x] Q5: CONNECTION_CLOSE spaces, draining, stateless reset, 3x anti-amplification + 1200-byte floor.
  Proven in `rnd/0.5.x/quic_transport_q5_poc.zig` against RFC 9000 8.1 / 10.2 / 10.3 / 19.19: 25
  checks (CONNECTION_CLOSE 0x1c / 0x1d layout, closing / draining states, stateless reset detection +
  size caps, 3x amplification limit + 1200-byte Initial floor). Gate `verify-quic-transport-q5.sh`
  (doc `verify-quic-transport-q5.md`). Layer Q complete.

## Layer T: TLS 1.3 over QUIC (RFC 9001 + 8446, end-to-end gate = curl --http3)

- [x] T1: handshake data only in CRYPTO frames, no TLS record protection, derive the "quic" keys per level.
  Proven in `rnd/0.5.x/quic_tls_t1_poc.zig` against RFC 9001 4 / 5.1: 11 checks (CRYPTO reassembly
  in-order / gap / out-of-order / overlap, handshake-layer not record-layer, per-level key derivation
  Initial-from-DCID + application-from-secret). Gate `verify-quic-tls-t1.sh` (doc `verify-quic-tls-t1.md`).
- [x] T2: terminate if TLS < 1.3, discard Initial keys after first Handshake packet, reject 0-RTT.
  Proven in `rnd/0.5.x/quic_tls_t2_poc.zig` against RFC 9001 4.2 / 4.9.1 / 4.6.2: 15 checks (TLS 1.3
  floor, role-split Initial-key discard + no-Initial-after, 0-RTT accept / reject signaling, zix
  default reject). Gate `verify-quic-tls-t2.sh` (doc `verify-quic-tls-t2.md`).
- [~] T3: full handshake completes with curl --http3 (the first live oracle). Gate harness in place
  (`verify-quic-tls-t3.sh`, doc `verify-quic-tls-t3.md`): curl HTTP/3 capability confirmed (8.20.0,
  ngtcp2 / nghttp3). The live handshake is PENDING the assembled server (Layer I), not faked. Re-run
  with `ZIX_HTTP3_SERVER` set once `src/udp/http3/` + an example exist.

## Layer P: QPACK header compression (RFC 9204)

- [ ] P1: encoder stream 0x02 + decoder stream 0x03 (at most one each), static table, prefix integers
- [ ] P2: dynamic table (entry size name+value+32, capacity, eviction), Required Insert Count / Base
- [ ] P3: decoder feedback (Section Ack, Stream Cancellation, Insert Count Increment), error codes
- [ ] P4: cross-impl QPACK interop (.qif encoded files, decode-and-compare)

## Layer H: HTTP/3 application (RFC 9114)

- [ ] H1: stream mapping (control stream uni 0x00), SETTINGS first, frame-per-stream matrix
- [ ] H2: request / response semantics (lowercase, pseudo-headers, content-length), malformed -> H3_MESSAGE_ERROR
- [ ] H3: GOAWAY monotonic id, server MUST NOT send MAX_PUSH_ID, all H3 error codes on trigger

## Layer L: loss detection + congestion (RFC 9002)

- [ ] L1: RTT sampling, min_rtt, ack_delay; loss declaration (packet + time threshold)
- [ ] L2: PTO (anti-deadlock, ack-eliciting probes); congestion (cwnd, recovery, persistent, pacing)

## Integration (into zix)

- [ ] I1: `src/udp/http3/` engine on zix.Udp (recvmmsg / sendmmsg batching, GSO / GRO if available)
- [ ] I2: http3 example with a unique UDP port + runner driving curl --http3-only, wired into the build
- [ ] I3: green under `zig build examples` + `test-runner-all` on Zig 0.16 and 0.17
- [ ] I4: gate. Lean per-connection state (no unbounded buffers / tables), 64c UDP throughput within
  the 1% URING gate, steady-state RSS / cgroup-peak neutral. QUIC is crypto-per-packet heavy, so this
  constraint bites hardest here.

## Interop and conformance

- [ ] curl --http3-only end-to-end round trip with correct H3 semantics
- [ ] QUIC Interop Runner: handshake, transfer, retry, resumption, 0-RTT, multiplexing, keyupdate, http3
- [ ] emit qlog traces, inspect with qvis

## Order and effort

C -> Q -> T -> P -> H -> L, then integration. Layers C (C1-C4) and Q (Q1-Q5) are done: the
self-contained deterministic half, RFC-vector and crafted-packet proven, which de-risks the rest.
Layer T is the first live gate (curl --http3). QPACK synchronization (P 2.2) is the next long pole.
None of this is benchmark-gated until I4.
