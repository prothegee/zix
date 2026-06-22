# TLS 1.3 (zix TLS) 0.5.x checklist

Checkbox tracker only. RFC MUST/MUST NOT detail lives in
`rnd/rfc/tls-conformance-must-checklist.md` (RFC 8446 TLS 1.3, 7301 ALPN, 6066 SNI, 5280
X.509 path, 6125 identity). Target agreed with user: full conformance pass, plus the SSL
Labs A+ grade.

Why this is unlike the HTTP engines: TLS is a LAYER, not a standalone engine. It sits under
Http1 and Http2 (https, h2) and is the gating prerequisite for Http3, where the same
handshake is carried in QUIC CRYPTO frames with QUIC packet protection instead of the TLS
record layer (RFC 9001, see the Http3 checklist). It is also a security boundary, so
verification leans hard on adversarial / negative testing (malformed handshakes, downgrade,
bad MACs), not only the happy path.

Hard rule: every item is a dual gate, conformant AND perf/memory-neutral. TLS does
asymmetric crypto per connection (ECDHE + a signature), so the levers are session
resumption (PSK tickets) and lean per-connection key state. No item ships if it regresses
the 1% gate or grows the footprint (see the HTTP raw perf/memory constraint).

State: greenfield in src, but the offline-verifiable layers are DONE against the RFC 8448 oracle
on Zig 0.16 and 0.17, three PoCs under rnd/0.5.x driven by tls-conformance.sh (plan tls-plan.md):
Layer K (tls_keyschedule_poc.zig, key schedule + record protection), Layer H
(tls_handshake_poc.zig, ClientHello parse + negotiate + byte-exact ServerHello + negative MUSTs),
and Layer C (tls_cert_poc.zig, Certificate + CertificateVerify + Finished byte-exact vs the trace),
and Layer X (tls_extensions_poc.zig, EncryptedExtensions byte-exact + ALPN + SNI). P0 has
STARTED and the interop gate is LIVE: tls_server_poc.zig composes K + H + X + C in memory, and
tls_server_live.zig runs the full handshake over a real socket with a fresh per-connection
ephemeral key. gate 2 of tls-conformance.sh now asserts BOTH clients: openssl s_client runs a
complete TLS 1.3 handshake (ServerHello, EncryptedExtensions, Certificate, CertificateVerify,
Finished all accepted, application data decrypted, ECDSA P-256) and curl negotiates
TLSv1.3 / TLS_AES_128_GCM_SHA256 / x25519 through the same flight. Build-
vs-bind is decided (pure-Zig) and the ECDSA P-256 + Ed25519 cert fixtures exist. std.crypto has
every primitive (AES-128/256-GCM, AES-CCM, ChaCha20-Poly1305, HKDF, HMAC, SHA-256/384, X25519,
Ed25519, ECDSA). The receive side is also done in the live PoC: it reads + verifies the client
Finished, deprotects the client request, and sends close_notify (full 1-RTT, both record
directions). The move into src/ has Layer K + H + X + C landed: src/tls/ has wire.zig,
key_schedule.zig, record.zig, alert.zig, handshake.zig, extensions.zig, certificate.zig (RFC 8448
unit tests, green under `zig build unit-test` on Zig 0.16 and 0.17, additive only, cleartext
engines untouched, enums with UPPER_CASE values throughout). connection.zig (sans-I/O server
handshake state machine) + Tls.zig are landed too, and `zix.Tls` is a public export. Http1 wiring
WORKS (approach A): flat tls_* config fields on Http1ServerConfig, a PEM/SEC1 cert+key loader
(src/tls/pem.zig), and a gated blocking serveConnTls (src/tcp/http1/tls_serve.zig) that does the
handshake via zix.Tls, then per request decrypts -> core.parseHead -> runs the existing fd-handler
over a pipe -> encrypts the response. examples/tls/tls_http1_basic.zig (port 9060) serves
https/1.1: BOTH openssl s_client and curl get HTTP/1.1 200 + body + HSTS over TLSv1.3 /
TLS_AES_128_GCM_SHA256 / x25519. Registered in zix-build-examples.zig, green under
`zig build example-tls` + `zig build unit-test` on Zig 0.16 and 0.17. The in-build runner
(tests/runner/tls_http1_basic_runner.zig + zix-build-test_runner.zig row, port 9060) drives the
NATIVE zix.Http.Client as the TLS client (no curl, no external dependency): it trusts the fixture
cert through the new HttpClientConfig.tls_ca_path field, connects to https://localhost:9060/ (cert
SAN DNS:localhost), and asserts 200 + body + HSTS. `test-runner-tls-http1` is GREEN on Zig 0.16 and
0.17, and tls-http1 is now folded into the monolithic test-runner-all (all 57 protocols pass on both
toolchains): zix.Http.Client gained TLS via tls_ca_path (lazy ca_bundle.rescan +
addCertsFromFilePath on the first https request), so the aggregate runner exercises https too. A zix
TLS CLIENT that VERIFIES the chain end to end is a separate future item
(client-side handshake + X.509/identity verification, configurable from the existing
HttpClientConfig via an https:// URL + flat trust fields), recorded in rnd/roadmap-0.5.x.md under
the TLS section, NOT a box in this server checklist. cleartext EPOLL / URING path untouched.

h2-over-TLS has LANDED on the SERVER side. ALPN negotiation, hardcoded to none before, is now
wired end to end: handshake.zig captures the client ProtocolNameList, connection.zig serverHandshake
takes alpn_prefs, selects one (no overlap -> error.NoApplicationProtocol), emits it in
EncryptedExtensions, and exposes it as HandshakeResult.alpn. Flat tls_* fields on Http2ServerConfig
plus a gated terminator (src/tcp/http2/tls_serve.zig) do the handshake (ALPN .H2), then run the
UNCHANGED h2c engine (core.serveConn) behind a socketpair: a poll loop decrypts inbound client
records to plaintext and encrypts the engine's frames back, so the cleartext ASYNC / POOL / MIXED
models are untouched. examples/tls/tls_http2_basic.zig (port 9061) serves h2: a manual `curl --http2`
returned http_version=2 + HTTP 200 (the server is TLS 1.3-only, so the handshake is 1.3). NOT yet
verified: the response BODY bytes (the in-sandbox server is signal-killed before curl prints them)
and a repeatable assertion, both of which await the h2 runner (deferred, below). The h2 handshake
itself is covered live by the shared Tls.serverHandshake the http1 native runner exercises.
Registered in zix-build-examples.zig, green under `zig build example-tls` + `zig build unit-test` on
Zig 0.16 and 0.17. The h2 RUNNER is DEFERRED: it
needs a TLS client that OFFERS ALPN h2, and neither std.crypto.tls.Client (no ALPN option in its
ClientHello) nor zix (server-only handshake today) provides one. So the native verifying zix TLS
CLIENT (ALPN offer + X.509 chain verification, reused by the h2 runner and a future http_version=2
zix.Http.Client) is promoted to its OWN milestone, recorded in rnd/roadmap-0.5.x.md, and the
test-runner-tls-http2 box waits on it. Remaining after that: Layer V X.509 path validation (RFC 5280,
mTLS) and alerts. See rnd/0.5.x/tls-plan.md.

connection.serverHandshake now ROUTES THROUGH handshake.negotiate() (it was bypassed before, with
cipher / group hardcoded): the live server enforces offers_tls13, missing_extension, and cipher /
group selection on the wire, and rejects a no-overlap group with handshake_failure (the negotiate
HANDSHAKE_FAILURE alert -> error.HandshakeFailure, alert-record SEND is still Layer A; HRR EMISSION
and post-handshake renegotiation -> unexpected_message are still future, so that compound Layer H box
stays unchecked). The MTI key-exchange group secp256r1 (RFC 8446 9.1, MUST) plus X25519 (SHOULD) are
now both implemented (connection.computeKeyExchange via std.crypto.ecc.P256, X coordinate shared
secret, X25519 preferred), unit-tested (ECDH symmetry + a P-256-only ClientHello driving a full
serverHandshake with a 65-byte uncompressed key_share echoed); not yet exercised by a live P-256 client. server_cipher_prefs is trimmed to the one implemented suite
TLS_AES_128_GCM_SHA256 (the key schedule is SHA-256 throughout, so AES_256/SHA-384 + ChaCha20 are
future), removing the latent prefs-vs-implementation gap. The tls_http1 native runner needed NO change
(std.crypto.tls.Client offers an X25519 key_share, the server prefers X25519, so negotiate picks it
with no HRR): test-runner-tls-http1 + test-runner-all stay GREEN on Zig 0.16 and 0.17, which is the
LIVE end-to-end proof of the negotiate wiring (a real standards-based TLS 1.3 client,
std.crypto.tls.Client, through the shared Tls.serverHandshake).

Version policy: TLS 1.3 default and the only required version, TLS 1.2 optional fallback,
1.1 / 1.0 / SSL never offered (RFC 8996). A+ falls out of TLS-1.3-only plus ECDHE forward
secrecy plus an ECDSA / Ed25519 cert (no RSA needed).

Tools: openssl s_client (primary interop, full TLS 1.3), curl (ALPN / h2 negotiation),
std.crypto.tls Client (independent Zig client). Posture scanners testssl.sh / sslyze /
nmap ssl-enum-ciphers (fetch the missing ones), tlsfuzzer for adversarial / negative
conformance, SSL Labs (Qualys) online for the A+ grade. Vector oracle: RFC 8448 example
TLS 1.3 handshake traces (byte-level), the analog of RFC 9001 Appendix A for QUIC.

## Prerequisite: build-vs-bind decision + certificate

- [x] decision: pure-Zig TLS 1.3 server handshake (std has the primitives + a client to mirror) vs bind a C library (BoringSSL / quictls)
- [x] generate an ECDSA P-256 (or Ed25519) server certificate + key, document the path
- [x] X.509 encode / parse for the server Certificate message (RFC 5280 minimum)

## P0: pipeline (TLS is a layer, exercised through Http1 first)

- [x] https Http1 example on a unique port, then h2-over-TLS once ALPN works
- [x] runner asserting handshake + response (http1: the NATIVE zix.Http.Client, folded into test-runner-all; openssl s_client + curl are the manual interop tools, see the Interop section. h2 runner deferred to the zix.Tls client milestone.)
- [x] register in zix-build-examples.zig + tests/runner + zix-build-test_runner.zig
- [x] green under `zig build examples` + `test-runner-all` on Zig 0.16 and 0.17

## Layer K: key schedule + record protection (RFC 8446 sec 5, 7)

Verified against RFC 8448 byte-level traces (deterministic oracle), pure-Zig.

- [x] HKDF-Expand-Label + Derive-Secret, label prefix "tls13 ", transcript hash
- [x] handshake-traffic and application-traffic key derivation
- [x] AEAD record protect / deprotect, opaque_type application_data(23), legacy_version 0x0303
- [x] record limits: TLSCiphertext.length <= 2^14 + 256 -> record_overflow, deprotect fail -> bad_record_mac
- [ ] sequence number starts 0 per key, rekey / terminate on 64-bit wrap

## Layer H: handshake flow + version negotiation (RFC 8446 sec 4)

- [x] ClientHello parse: legacy_version 0x0303, supported_versions lists 0x0304, compression byte 0
- [x] server flight order: ServerHello, EncryptedExtensions, [CertReq], Certificate, CertificateVerify, Finished
- [ ] HelloRetryRequest when group selected but no compatible key_share [DETECTION only: negotiate() returns .hello_retry_request (unit-tested), but serverHandshake does NOT emit an HRR message yet, it returns error.HelloRetryRequestUnsupported. In practice clients offer an X25519 or secp256r1 key_share, so it does not trigger. HRR EMISSION + the second ClientHello flight are future.]
- [ ] no group overlap -> handshake_failure, no renegotiation -> unexpected_message
- [ ] downgrade sentinel in ServerHello.random when negotiating 1.2 (DOWNGRD\x01) or lower (\x00) [N/A while 1.3-only: the server has NO downgrade path (negotiate -> .legacy_version -> error.UnsupportedTlsVersion, the connection is dropped), so it never emits the sentinel. Required only if TLS 1.2 fallback is added. No DOWNGRD code exists today.]
- [x] mandatory crypto: TLS_AES_128_GCM_SHA256, secp256r1, ecdsa_secp256r1_sha256 sig

## Layer X: extensions, ALPN, SNI (RFC 8446 4.2, 7301, 6066)

- [ ] MUST-handle set: supported_versions, supported_groups, key_share, signature_algorithms, server_name, cookie
- [x] missing signature_algorithms / supported_groups (non-PSK) -> missing_extension
- [x] no extension the client did not offer in ServerHello / EncryptedExtensions / Certificate
- [x] ALPN: exactly one ProtocolName, in EncryptedExtensions, no overlap -> no_application_protocol (120)
- [x] SNI: one name per type, empty server_name ack when used for cert selection

## Layer C: certificate, CertificateVerify, Finished (RFC 8446 4.4)

- [x] Certificate message non-empty, X.509v3, end-entity first, digitalSignature key usage
- [x] CertificateVerify over the 64x0x20 pad + "TLS 1.3, server CertificateVerify" + 0x00 + transcript hash
- [ ] signing with ECDSA P-256 / Ed25519 from client signature_algorithms, no SHA-1, verify fail -> decrypt_error
- [x] Finished: HKDF-Expand-Label(BaseKey, "finished", ...), verify_data fail -> decrypt_error

## Layer V: cert path validation + identity (RFC 5280, 6125) [mTLS / chain]

- [ ] per-cert: signature verifies, validity window, issuer chaining, name constraints
- [ ] basicConstraints cA TRUE on intermediates, keyCertSign, pathLenConstraint, critical-ext rejection
- [ ] DNS-ID match (case-insensitive, subjectAltName dNSName preferred, CN-ID last resort)

## Layer A: alerts + error handling (RFC 8446 sec 6)

- [ ] fatal alert -> immediate close, both sides, secrets forgotten
- [ ] close_notify before write-side close, ignore data after closure alert
- [x] decode_error on unparseable, illegal_parameter on semantically invalid
- [ ] the condition -> fatal-alert matrix from the conformance checklist exercised

## Layer 0RTT: early data + downgrade MUST NOTs (RFC 8446 4.2.10, 8)

- [ ] early_data: exactly one of ignore / HelloRetryRequest / accept, never a subset
- [ ] accept only with first PSK + matching version / cipher / ALPN, at-most-once per instance
- [ ] Application Data never sent unprotected, no status_request_v2

## Interop, posture, and the A+ grade

- [ ] openssl s_client full handshake + data, both ECDSA and Ed25519 cert
- [x] curl https + ALPN selects h2 / http/1.1 correctly
- [x] std.crypto.tls Client (independent Zig client) round trip
- [ ] testssl.sh / sslyze / nmap ssl-enum-ciphers: TLS 1.3 only, FS suites, no weak protocols
- [ ] tlsfuzzer adversarial / negative suite, alert behavior correct
- [ ] SSL Labs (Qualys) A+ grade (or the offline testssl.sh equivalent)

## Perf / memory gate

Design, levers, configuration, and the https performance band live in
`rnd/checklist-0.5.x-tls-perf.md` (split out, since they are engineering trade-offs, not RFC
conformance). The short version:

- [ ] cleartext is the default and untouched, https is an opt-in parallel path
- [ ] https held to its own band (not the strict 1% rule), see the perf tracker
