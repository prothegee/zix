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
- [ ] C4: AEAD confidentiality / integrity limits + constant-time send / receive paths (9001 6.6, 9.5)

## Layer Q: QUIC transport (RFC 9000, in-process tests on crafted packets)

- [ ] Q1: varint codec + sample encodings (Appendix A), long / short header parse (Fixed Bit, CID <= 20)
- [ ] Q2: frame parse / encode, unknown -> FRAME_ENCODING_ERROR, disallowed -> PROTOCOL_VIOLATION
- [ ] Q3: connection IDs (NEW / RETIRE, active_connection_id_limit), stream state machine + 62-bit ids
- [ ] Q4: flow control (per-stream + connection) -> FLOW_CONTROL_ERROR, ACK, PATH_CHALLENGE / RESPONSE
- [ ] Q5: CONNECTION_CLOSE spaces, draining, stateless reset, 3x anti-amplification + 1200-byte floor

## Layer T: TLS 1.3 over QUIC (RFC 9001 + 8446, end-to-end gate = curl --http3)

- [ ] T1: handshake data only in CRYPTO frames, no TLS record protection, derive the "quic" keys per level
- [ ] T2: terminate if TLS < 1.3, discard Initial keys after first Handshake packet, reject 0-RTT
- [ ] T3: full handshake completes with curl --http3 (the first live oracle)

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

C -> Q -> T -> P -> H -> L, then integration. Layer C (C1-C3 done) is the self-contained deterministic
half and de-risks the rest. Layer T is the first live gate (curl --http3). The transport state machine
(Q) and QPACK synchronization (P 2.2) are the long poles. None of this is benchmark-gated until I4.
