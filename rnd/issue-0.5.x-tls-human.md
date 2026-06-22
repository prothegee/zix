# TLS 1.3 server (pure-Zig)

## Context

zix needs its own TLS 1.3 server, because Zig std ships a client only (`crypto/tls.zig:39`
exports `Client`, no `Server`). The hardest cryptographic piece, Layer K (key schedule + record
protection), is already done and verified against the RFC 8448 deterministic oracle on both Zig
0.16 and 0.17. What remains is the structural state machine on top. This engine is the gate for
https, h2-over-TLS, and HTTP/3.

References: `rnd/rfc/tls-conformance-must-checklist.md` (RFC 8446, RFC 7301 ALPN, RFC 6066 SNI,
RFC 5280 X.509, RFC 6125 identity). Tracker: `rnd/checklist-0.5.x-tls.md`. Plan:
`rnd/0.5.x/tls-plan.md`.

## Already done

- [x] Build-vs-bind decision: pure-Zig (no BoringSSL / quictls / OpenSSL). std has every primitive
      plus a client to mirror, so the gap is only the server state machine + X.509 path
      validation. (`tls-plan.md`)
- [x] Cert fixtures generated (`rnd/0.5.x/tls-certs/`): ECDSA P-256 (conformance + A+ default) and
      Ed25519 (interop), both `CN=localhost` + SAN `DNS:localhost,IP:127.0.0.1`. No RSA (optional,
      off-path).
- [x] Layer K verified (`tls_keyschedule_poc.zig`, 24/24 vectors, both toolchains via
      `tls-conformance.sh`): X25519 ECDHE from the trace, transcript hashes, the full secret tree
      (Early / Handshake / Master + client and server handshake and application traffic + exporter
      master), HKDF-Expand-Label / Derive-Secret from RFC 8446 7.1, handshake and application
      traffic keys + Finished key, and AEAD deprotect of the real 679-octet server flight. Not yet
      exercised (lands with the live record layer): the record_overflow limit (2^14 + 256) and the
      64-bit seq-wrap rekey.

## Remaining layers

Build order is K (done), then H, X, C, then the P0 pipeline. std gives the primitives (AEAD,
X25519, secp256r1 ECDSA, Ed25519) and the Client as a cross-test oracle. Everything structural
below must be authored.

| Layer | Scope (headline MUSTs) | std gives | Author |
| :- | :- | :- | :- |
| H, handshake (8446 4) | ClientHello parse, version only from supported_versions (0x0304), legacy_compression one 0-byte, flight order SH / EE / [CertReq] / Cert / CertVerify / Finished, HRR on no key_share, no-overlap -> handshake_failure, downgrade sentinel, no reneg -> unexpected_message | primitives + Client oracle | full CH parser, SH / HRR serializer, negotiation, sequencing |
| X, extensions (8446 4.2, 7301, 6066) | MUST-handle supported_versions, supported_groups, key_share, signature_algorithms (+_cert), server_name, cookie. ALPN one ProtocolName in EncryptedExtensions, no overlap -> no_application_protocol (120). SNI <= 1 per type, no literal IP, empty ack on cert select | nothing structural | all extension parse / emit (folds into the H PoC) |
| C, cert + verify + finished (8446 4.4) | Cert non-empty X.509v3 end-entity-first, CertificateVerify over the 64x 0x20 pad + context + transcript hash (ECDSA P-256 / Ed25519, no SHA-1) -> decrypt_error on fail, Finished verify_data | ECDSA / Ed25519 sign, Finished key (Layer K) | DER encode of the Cert message, CertVerify pad signing, Finished wiring |
| V, path validation (5280, 6125), mTLS | per-cert signature / validity / issuer chaining, basicConstraints cA + keyCertSign, pathLenConstraint, critical-ext reject, DNS-ID match (SAN dNSName preferred) | signature verify, X.509 parse (client ref) | the full 5280 path algorithm + 6125 matching (heaviest, deferred to mTLS) |
| A, alerts (8446 6) | fatal alert -> immediate bilateral close + forget secrets, close_notify before write close, decode_error / illegal_parameter, the condition-to-alert matrix | nothing | alert codec + error-to-alert map woven through every layer (cross-cutting) |
| 0-RTT (8446 4.2.10, 8) | early_data: exactly one of ignore / HRR / accept, accept only with first PSK + matching version / cipher / ALPN, at most once per instance, never unprotected, no status_request_v2 | nothing | PSK / ticket resumption (also the perf lever) + replay guard (lowest priority) |

## P0 pipeline (TLS is a layer, exercised through Http1 first)

- [ ] https Http1 example on a unique port, then h2-over-TLS once ALPN works.
- [ ] Runner driving openssl + curl (staged in `tls-conformance.sh` gate 2, auto-activates when a
      `tls_*` / `https_*` binary appears):
      `openssl s_client -connect 127.0.0.1:PORT -tls1_3 -alpn h2,http/1.1 -CAfile <cert>` and
      `curl -sv --cacert <cert> --tlsv1.3 https://localhost:PORT/`.
- [ ] Register in `zix-build-examples.zig` + tests/runner + `zix-build-test_runner.zig`, green
      under `zig build examples` + `test-runner-all` on Zig 0.16 and 0.17.
- [ ] Posture: testssl.sh / nmap ssl-enum-ciphers (TLS 1.3 only, forward-secret suites, no weak
      protocols), ultimately SSL Labs A+. Version policy: TLS 1.3 default / only-required, 1.2
      optional fallback, <= 1.1 never offered.

## Perf / memory

Cleartext stays the default and untouched. https is an opt-in parallel path held to its own band
(`rnd/checklist-0.5.x-tls-perf.md`), not the strict 1% gate. Levers: PSK ticket resumption + lean
per-connection key state.

## Next step

Write the Layer H PoC `tls_handshake_poc.zig`: ClientHello parse -> version / group / suite
negotiation -> ServerHello (+ HRR) serialization + flight sequencing. Oracle: the RFC 8448 trace
at the message level (CH / SH byte blobs already embedded in the Layer K PoC, lines 38-82), then
escalate to a live `openssl s_client`. Layer X folds in, with ALPN / SNI checked against curl
`--alpn` / openssl `-servername`.
