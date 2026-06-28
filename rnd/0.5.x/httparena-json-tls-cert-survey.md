# HttpArena json-tls certificate survey

Record of what certificate every json-tls entry presents, to settle whether a
self-signed Ed25519 cert is legal for the zix entries. Captured 2026-06-27 from
the local HttpArena checkout (`../HttpArena/frameworks/*`).

## Question

The json-tls profile (GET /json over HTTP/1.1 + TLS 1.3 on :8081) ships a shared
RSA-2048 cert mounted at /certs. Software RSA-2048 signing is the bottleneck that
collapses the zix json-tls run at 4096c (see the bench note). Is presenting a
self-signed Ed25519 (or ECDSA) cert instead of the mounted RSA cert allowed?

## Rule check

- No written rule mandates the shared cert or a key type. The README, the
  test-profiles doc, and the openapi contract require only: HTTP/1.1 over TLS 1.3
  on :8081, ALPN http/1.1.
- The validator never checks the cert. `scripts/validate.sh` probes json-tls with
  `curl -sk` (verification skipped) and asserts only: ALPN negotiates 1.1, the
  JSON body and totals are correct across 3 (count, m) pairs, and Content-Type is
  application/json.
- Verdict: a self-signed Ed25519 / ECDSA cert is legal for json-tls.

## Survey: cert per json-tls entry

50 entries subscribe to json-tls. 49 present the shared RSA-2048 cert. 1 presents
a self-signed Ed25519 cert, and that one is a dedicated single-profile entry.

| cert | count | entries |
| :- | -: | :- |
| RSA-2048 (shared /certs) | 49 | 43 ref-server entries + zix, zix_async, zix_epoll, zix_mixed, zix_pool, zix_uring |
| Ed25519 (self-signed) | 1 | one ref-server (json-tls only) |

Notes:
- The lone Ed25519 entry is a dedicated json-tls-only profile. Its sibling entry
  does NOT subscribe json-tls, so the only Ed25519 json-tls in the field is an
  isolated single-profile entry.
- One ref-server loads the shared cert from config (`config-multi.json` -> /certs/server.crt).
- Several ref-servers read /certs/server.crt directly in their server source.
- One ref-server terminates TLS in a separate reverse-proxy front, presumed shared
  /certs (no self-signed cert generation in the entry).

## zix family, non-json-tls TLS entries (for context)

| entry | profiles | cert |
| :- | :- | :- |
| zix_http3_epoll / zix_http3_uring | baseline-h3, static-h3 | self-signed ECDSA P-256 (forced: an RSA flight overflows the QUIC v1 single-packet handshake) |
| zix_http2_epoll / zix_http2_uring | baseline-h2, static-h2, h2c | shared RSA-2048 (/certs) |
| zix_grpc_epoll / zix_grpc_uring | unary/stream-grpc-tls | shared RSA-2048 (/certs) |

So within zix, the h3 entries already self-sign (ECDSA P-256) because they must.
The h1 / h2 / grpc TLS paths use the shared RSA cert today.

## Decision

Switch the 6 combined zix http1 entries (zix, zix_async, zix_pool, zix_mixed,
zix_epoll, zix_uring) to a self-signed Ed25519 cert for the json-tls path.
Ed25519 signing in std.crypto is ~0.050 ms/op versus ~4.345 ms/op for the
pure-Zig RSA-2048 CRT path, which clears the 4096c handshake storm in ~0.034 s
per core instead of ~2.97 s. zix loads Ed25519 certs natively (no engine change):
`context.zig` detects the curveEd25519 key from the cert and signs
CertificateVerify with ed25519.
