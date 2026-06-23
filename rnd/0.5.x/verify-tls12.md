# verify-tls12: openssl TLS 1.2 wire check

The RFC wire gate for the zix TLS 1.2 server path. The in-code self-test only checks
self-consistency, this proves a real client (openssl) completes the 1.2 handshake. Run in a real
terminal (a restricted sandbox signal-kills live servers).

Server: the existing https example (examples/tls/tls_http1_basic.zig, port 9060). `openssl -tls1_2`
sends a ClientHello with no 1.3 offer, so the server takes the 1.2 branch (serveConnTls12).

## Steps

```sh
# 1. build + run the https example
zig build example-tls
./zig-out/bin/example-tls_http1_basic &
SRV=$!

# 2. TLS 1.2 handshake + request
printf 'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' \
  | openssl s_client -connect 127.0.0.1:9060 -tls1_2 -servername localhost \
      -CAfile examples/tls/certs/ecdsa_p256_cert.pem -verify_return_error -quiet

# 3. regression: confirm 1.3 still works
printf 'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' \
  | openssl s_client -connect 127.0.0.1:9060 -tls1_3 -servername localhost \
      -CAfile examples/tls/certs/ecdsa_p256_cert.pem -verify_return_error -quiet

kill $SRV
```

## Expected

Step 2 (TLS 1.2):
- handshake completes, `Verify return code: 0 (ok)`
- `Protocol: TLSv1.2`, `Cipher: ECDHE-ECDSA-AES128-GCM-SHA256`
- response `HTTP/1.1 200 OK` + body `hello over tls 1.3`
  (the body string is the handler's literal text, the same handler serves both versions, so the
  "1.3" wording is cosmetic, not the negotiated version)

Step 3 (TLS 1.3):
- `Protocol: TLSv1.3`, `Cipher: TLS_AES_128_GCM_SHA256`, same 200 + body

## h2 over TLS 1.2 (the http2 example, port 9061)

```sh
./zig-out/bin/example-tls_http2_basic &
SRV=$!
curl -sk --http2 --tls-max 1.2 -w '\n[ver=%{http_version} code=%{http_code}]\n' https://localhost:9061/
kill $SRV
```
Expect: ALPN selects h2 over TLS 1.2, `ver=2 code=200`, body `hello over h2 tls 1.3`.
(again the body string is cosmetic, the handler is version-agnostic.)

## If it fails

- `Verify return code != 0`: cert / SAN issue (cert SAN is DNS:localhost, so `-servername localhost`).
- handshake error before the response: a 1.2 framing bug (ServerHello / Certificate /
  ServerKeyExchange / Finished), the thing this gate exists to catch.
