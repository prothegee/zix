#!/usr/bin/env bash
#
# on-box TLS posture check for the zix TLS server (port 9060): openssl + curl + nmap + testssl.
#
# Usage:  zig build example-tls_http1_basic && bash rnd/0.5.x/verify-tls-posture.sh
# Deps:   openssl, curl, nmap (present). testssl for the A+ grade: sudo pacman -S testssl.sh.
# Expect: 1. openssl TLSv1.3 + TLS_AES_128_GCM_SHA256, cert CN=localhost
#         2. curl HTTP 200 (ssl_verify=18 = self-signed, expected)
#         3. nmap TLSv1.2 ECDHE-ECDSA-AES128-GCM (secp256r1) grade A (nmap tops at A)
#         4. testssl Overall Grade A+ (Final Score 92, HSTS bonus), via --add-ca on the fixture
#
# nmap under-enumerates 1.3 (shows only 1.2); openssl proves 1.3. testssl caps to T without --add-ca
# (self-signed = untrusted chain, as SSL Labs does in production); a real CA cert reaches A+ directly.

set -u

PORT=9060
BIN=./zig-out/bin/example-tls_http1_basic
CA=examples/tls/certs/ecdsa_p256_cert.pem

if [ ! -x "$BIN" ]; then
    echo "missing $BIN, run: zig build example-tls_http1_basic"
    exit 1
fi

"$BIN" >/tmp/zix_tls_posture_srv.log 2>&1 &
SRV=$!

# wait for the port to accept before probing.
for _ in $(seq 1 40); do
    (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && { exec 3>&-; break; }
    sleep 0.1
done

echo "=== 1. openssl s_client: version + cipher + cert ==="
printf 'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' \
    | openssl s_client -connect 127.0.0.1:$PORT -servername localhost -tls1_3 2>/dev/null \
    | grep -E 'Protocol|Cipher is|subject=|issuer=' | head -8

echo
echo "=== 2. curl https ==="
curl -sk --tlsv1.3 https://localhost:$PORT/ -o /dev/null \
    -w 'curl: HTTP %{http_code}, ssl_verify=%{ssl_verify_result}\n' \
    --resolve localhost:$PORT:127.0.0.1

echo
echo "=== 3. nmap ssl-enum-ciphers: protocol + cipher posture (tops at grade A) ==="
nmap -Pn -p $PORT --script ssl-enum-ciphers 127.0.0.1 2>/dev/null \
    | grep -E 'TLSv|TLS_|cipher preference|least strength|SSLv'

echo
echo "=== 4. testssl: the SSL Labs A+ grade (--add-ca trusts the self-signed fixture) ==="
TESTSSL="$(command -v testssl || command -v testssl.sh)"
if [ -n "$TESTSSL" ]; then
    "$TESTSSL" --add-ca "$CA" --color 0 127.0.0.1:$PORT 2>/dev/null \
        | grep -E 'Trust \(hostname\)|Chain of trust|Protocol Support|Key Exchange|Cipher Strength|Final Score|Overall Grade|Grade cap'
else
    echo "testssl not installed. Install it for the A+ grade:  sudo pacman -S testssl.sh"
    echo "(nmap above proves grade A. The A+ delta is the HSTS bonus, which testssl scores.)"
fi

kill "$SRV" 2>/dev/null
wait "$SRV" 2>/dev/null
echo
echo "=== server stopped ==="
