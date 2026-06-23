# ADR-048 (proposal record)

> This is part of 0.5.x

Lean note. The full decision lives in `docs/adr-en.md` / `docs/adr-id.md` (ADR-048). This file
records the rnd-only rationale not carried into the public ADR.

## Objective
Implement RSA server certificate signing (reversing the "RSA optional" stance of ADR-045), so a
deployment that must serve a pre-issued RSA-2048 certificate can be served by zix.

## Decision (summary)
- `src/tls/rsa.zig`: key parse (PKCS#1 / PKCS#8 DER) plus EMSA-PKCS1-v1_5 and EMSA-PSS + MGF1, the
  modexp driven by `std.crypto.ff.Modulus` (the std-gap was padding + key parse, not bignum).
- `certificate.SigningKey` gains an `rsa` variant, `scheme()` -> `rsa_pss_rsae_sha256`.
- `Tls.Context.init` detects an `rsaEncryption` cert, parses the key, rejects below RSA-2048.
- RSA serves TLS 1.3 only (1.2 ServerKeyExchange is ECDSA-only). Default cert type unchanged (ECDSA).
- PSS salt injected per connection (serve getrandom -> handshakeOptions -> HandshakeOptions.pss_salt).

## rnd-only rationale (kept OUT of the public ADR)
- The concrete driver was the HttpArena `json-tls` category: the harness auto-mounts a SHARED
  RSA-2048 cert at `/certs/server.crt` (`sha256WithRSAEncryption`), and zix was ECDSA / Ed25519 only,
  so json-tls could not be served until zix could RSA-sign. The public ADR justifies RSA on general
  technical merit (serve a pre-issued RSA cert), not by naming the benchmark.
- No ECDSA-cert workaround was taken: the shared cert is fixed, so RSA had to be done properly.

## Phasing
Primitive-first PoCs under `rnd/0.5.x` gated by `verify-rsa.sh` (openssl oracle), then folded into
`src/tls`. See `rsa-plan.md` (R1 v1.5 -> R6 Tls.Context). R1-R6 landed.

## Gate
- `verify-rsa.sh`: v1.5 byte-exact vs openssl, PSS openssl-verified, key-parse modulus round-trip.
- In-tree: `src/tls/rsa.zig` + `certificate.zig` (CertificateVerify scheme 0x0804 + std PSS verify).
- Integration: `tests/integration/tls/rsa_test.zig` (Context loads RSA cert, std-verified PSS,
  rejects 1024-bit). `zig build test-all` green on Zig 0.16 and 0.17.
