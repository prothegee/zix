# zix.Tls client plan (zix 0.5.x)

The native client-side TLS handshake. It is the mirror of the server (`connection.zig` /
`tls12_connection.zig`): same crypto, opposite role. Decision + policy are ADR-045 / ADR-046, the
1.2 detail is `tls12-plan.md`. This is the lean plan, not a full spec.

## Why it exists

`zix.Http.Client` wraps `std.http.Client`, which is HTTP/1-only and CANNOT offer ALPN, so h2 client
requests return `error.UnsupportedVersion`. The zix.Tls client is the ALPN-capable backend, and it
adds the part the server never needed: verifying the peer certificate.

## Scope

- TLS 1.3 preferred, TLS 1.2 floor (same version policy as the server, ADR-045).
- Offers ALPN (h2 / http/1.1), verifies the server cert chain (RFC 5280) + identity (RFC 6125).
- Configured from the EXISTING flat `HttpClientConfig`: an `https://` URL opts in, plus
  `tls_verify: bool = true`, `tls_ca_path` (custom root, already added), `tls_alpn`.
- Additive. The cleartext client path stays default and untouched.

## Relations

```mermaid
graph TD
    C["zix.Tls CLIENT (new)"]

    subgraph shared["src/tls shared layers (already built for the server)"]
        L1["wire / key_schedule / record"]
        L2["handshake / extensions (ALPN) / certificate"]
        L3["tls12_prf / tls12_record (the 1.2 floor)"]
    end

    subgraph new["new surface the client adds"]
        F["client flow: ClientHello+ALPN, parse ServerHello, client Finished"]
        V["X.509 path validation (RFC 5280) + identity (RFC 6125)"]
    end

    CFG["HttpClientConfig (flat): https + tls_verify + tls_ca_path + tls_alpn"]

    C --> L1
    C --> L2
    C --> L3
    C --> F
    C --> V
    CFG --> C

    V -. "same cert-verify machinery" .-> MTLS["server mTLS / Layer V"]

    C --> H2C["zix.Http.Client (enables http_version=2)"]
    C --> WS["ws_client.zig (wss)"]
    C --> SSE["sse_client.zig (TLS)"]
    C --> GRPC["grpc/client.zig (gRPC over TLS)"]
    C --> RUN["test-runner-tls-http2 (#15)"]

    SRV["zix.Tls SERVER (done)"] --> L1
    SRV --> L2
    SRV --> L3
    SRV --> MTLS
```

- Reuses (shared with the server): wire, key_schedule + tls12_prf, record + tls12_record, handshake,
  extensions (ALPN), certificate. No crypto is re-implemented.
- Adds: the client flow + cert verification. The verification module is reused by server mTLS
  (Layer V), validating a CLIENT cert is the same machinery as validating the SERVER cert.
- Plugs into: `zix.Http.Client` as the ALPN-capable TLS backend, which unblocks h2 client requests.
- Consumed by: the deferred h2 runner (#15), ws_client (wss), sse_client, grpc client over TLS.

## What to build (de-risk bottom-up, PoC-first like the server)

| Layer | What | Reuses |
| :- | :- | :- |
| CH | build ClientHello: supported_versions, key_share (x25519 + secp256r1), signature_algorithms, server_name, ALPN | handshake, extensions, wire |
| SH | parse ServerHello + the server flight, derive client-side keys | key_schedule, record, wire |
| FIN | client Finished, switch to app keys | key_schedule, certificate |
| VER | verify the server cert chain (RFC 5280) + DNS-ID (RFC 6125) | certificate (new path-validation code) |
| 12 | the 1.2 client variant (PRF schedule, ServerKeyExchange verify, ClientKeyExchange) | tls12_prf, tls12_record |
| INT | plug into zix.Http.Client, then the h2 runner | client.zig, zix.Http2 frames |

## Status

CH + SH + FIN + VER LANDED in `src/tls/client.zig` (sans-I/O `start` / `finish` + `ClientConnection`),
green Zig 0.16 + 0.17:
- CH+SH+FIN: full 1.3 handshake against connection.serverHandshake (RFC 8448 oracle), server Finished
  verified, client Finished accepted, app-data round trip both directions.
- VER: finish verifies the server CertificateVerify (RFC 8446 4.4.3, proves the peer holds the
  end-entity cert key), lifting the pubkey via std.crypto.Certificate. The cert chain + hostname
  (RFC 5280 / 6125) are verified with std X.509 in a test (parsed.verify + verifyHostName on the
  self-signed fixture). That trust step is the CALLER's job at INT (it owns the trust store /
  tls_ca_path Bundle), so finish does the handshake binding and the caller does the chain/hostname.

The 1.2 client variant LANDED too (`src/tls/tls12_client.zig`, mirror of tls12_connection): start /
finish + ClientConnection, verifies the ServerKeyExchange signature (RFC 5246 7.4.3) via the
end-entity cert key, full handshake against the zix 1.2 server in-memory + app-data round trip,
green Zig 0.16 + 0.17.

INT in progress:
- the 1.3 client now OFFERS ALPN (ClientHello) and parses the server's selection from
  EncryptedExtensions (FinishResult.alpn), so it is h2-ready.
- proven over a REAL socketpair: the sans-I/O client drives a full https/1.1 request (handshake +
  CertVerify + GET + 200) against the zix server over real read/write + record framing.

h2 runner #15 LANDED: tests/runner/tls_http2_basic_runner.zig drives the native client (ALPN h2) over
TCP to example-tls_http2_basic, speaks h2 over the ClientConnection (zix.Http2 frames), asserts
:status 200. test-runner-tls-http2 PASS on Zig 0.16 + 0.17, no curl.

Chain + hostname trust is now WIRED into the request path. finish() surfaces the server end-entity
cert (FinishResult.serverCertDer), and FinishResult.verifyServerCert chains it to a caller-supplied
anchor (RFC 5280) + matches the hostname (RFC 6125) via cert_verify. Mirrored on the 1.2 client. The
h2 runner (tls_http2_basic_runner.zig) loads the fixture cert from disk as the out-of-band anchor and
calls verifyServerCert before sending the client Finished, so the runner no longer trusts the cert the
server sent. zix.Tls.pemToDer is exported for loading an anchor PEM. Unit-tested (good cert, wrong
host, outside validity window, missing cert), green Zig 0.16 + 0.17 (unit-test + test-runner-all).

INT is COMPLETE: zix.Http.Client now speaks h2 over TLS for general users. config.version = .HTTP_2
routes request() through the native transport src/tcp/http/h2_client.zig (HostName.connect for DNS,
TLS 1.3 handshake offering ALPN h2, FinishResult.verifyServerCert against config.tls_ca_path when
config.tls_verify, then one request/response over a single h2 stream: preface + SETTINGS + WINDOW_UPDATE
+ HEADERS [+ DATA], reply SETTINGS/PING ACKs, parse HEADERS :status + DATA body, stop at END_STREAM).
New flat config field tls_verify (default true), tls_ca_path reused as the one-link anchor. zix.Tls.pemToDer
exported. https only (http:// + HTTP_2 -> error.UnsupportedScheme), HTTP_3 still UnsupportedVersion.
Proven by tests/runner/tls_http2_client_runner.zig (zix.Http.Client.get over h2 -> 200 + body, no curl)
and unit tests (scheme guard, frame builders, PADDED/PRIORITY strip). Green Zig 0.16 + 0.17 (unit-test +
test-runner-all 58 + the new runner).

Known scope edges (later levers, not blockers): public-CA system roots (multi-link chain, today one
anchor only), response headers spanning CONTINUATION (-> error.UnsupportedH2), connection pooling /
multiple streams per connection (one request per connection today).

## Order

CH + SH + FIN first (a 1.3 client that completes a handshake against the zix server, no verify), then
VER (the new, security-critical path validation), then the 1.2 client variant, then INT. Each layer
verified against the zix server (loopback) and openssl s_server, green on Zig 0.16 + 0.17 before the
next. Public-tool checks recorded as verify-*.md.
