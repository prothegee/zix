# Verify: json-tls Ed25519 cert (4096c handshake-storm fix)

Subject: switch the 6 combined zix http1 HttpArena entries from the shared
RSA-2048 cert to a self-signed Ed25519 cert for the json-tls path, so the 4096c
TLS handshake storm clears instead of collapsing.

## Problem (measured)

json-tls 512c is a win, json-tls 4096c collapses (epoll 77, uring 126 req/s,
reference 96,475). Root cause is software asymmetric crypto during the
simultaneous-handshake storm: each fresh connection costs one CertificateVerify
signature, run inline on the epoll worker. The pure-Zig RSA-2048 sign is the wall.

Sign-cost microbench on this box (zig run -O ReleaseFast):

| sign algorithm | ms/op | 683 signs/core (4096c / 6 cores) |
| :- | -: | -: |
| RSA-2048, zix pure-Zig (CRT) | 4.345 | 2.97 s -> collapses |
| RSA-2048, OpenSSL (reference) | 0.496 | 0.34 s |
| ECDSA P-256, zix std.crypto | 0.338 | 0.231 s |
| Ed25519, zix std.crypto | 0.050 | 0.034 s |

A 5 s window cannot absorb ~3 s/core of RSA math once the load tool 2 s timeout
triggers reconnects. Ed25519 clears the same storm in 0.034 s/core.

## Legality

- `+aes+pclmul` accelerates AES-GCM (the record layer), NOT the asymmetric sign.
- The validator probes json-tls with `curl -sk` (verification skipped) and checks
  only: ALPN negotiates 1.1, JSON body + totals correct, Content-Type
  application/json. The cert type / issuer is never checked.
- Precedent: a ref-server runs a self-signed Ed25519 cert. zix's own h3 entries
  self-sign ECDSA P-256. See [httparena-json-tls-cert-survey.md].

## Verification (local, this box)

1. Cert generation matches the Dockerfile step:
   `openssl genpkey -algorithm ed25519 -out ed.key`
   `openssl req -new -x509 -key ed.key -out ed.crt -days 3650 -subj "/CN=localhost"`
   -> cert Public Key Algorithm: ED25519, Signature Algorithm: ED25519.

2. zix loads it with no engine change:
   `Tls.Context.init(.{ .cert_path = ed.crt, .key_path = ed.key, .alpn = .{HTTP_1_1}, .min_version = .TLS_1_3 })`
   -> Context.init OK, signing_key = ed25519 (context.zig detects curveEd25519
   and signs CertificateVerify with the ed25519 scheme).

3. Full TLS 1.3 handshake against a live zix Http1 server (the tls_http1_basic
   example pointed at the Ed25519 cert, .EPOLL), mirroring validate.sh:
   - `curl -sk --http1.1 https://localhost:9060/` -> HTTP/1.1 200 OK, http_version=1.1
   - `openssl s_client -alpn http/1.1 -tls1_3` -> Peer signature type: ed25519,
     Protocol TLSv1.3, Cipher TLS_AES_128_GCM_SHA256, ALPN http/1.1.

## Implementation

No zix src/ change (Ed25519 cert support already shipped). Per entry (zix,
zix_async, zix_pool, zix_mixed, zix_epoll, zix_uring):

- main.zig: `TLS_CERT_DEFAULT` / `TLS_KEY_DEFAULT` -> `/etc/zix-h1/server.{crt,key}`.
  Doc + comments updated from "shared RSA" to "self-signed Ed25519".
- Dockerfile: add `openssl` to the build-stage apk. Generate the Ed25519 cert into
  `/etc/zix-h1` after the zig build. `COPY --from=build /etc/zix-h1 /etc/zix-h1`
  into the runtime stage. Mirrors the zix_http3 ECDSA cert step.

The harness sets no `ARENA_TLS_CERT` / `ARENA_TLS_KEY`, so the Ed25519 default
applies to both the competition and local isolate runs. The env override stays
for manual local runs.

## Pending

- User re-bench json-tls 512c..4096c on the isolate harness to confirm 4096c
  recovers to roughly the 512c level (the prior tls_mux cpuset-aware worker fix
  is also in place). Expected: json-tls 4096c jumps from ~100 to >= ~150k.
