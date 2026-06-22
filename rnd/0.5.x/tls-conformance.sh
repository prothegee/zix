#!/usr/bin/env bash
# TLS 1.3 conformance + interop driver (Layer K now, P0 pipeline staged).
#
# Two gates, mirroring tls-plan.md:
#   1. Deterministic oracle (runs today): the Layer K key schedule + record protection PoC
#      verified byte-for-byte against the RFC 8448 Simple 1-RTT Handshake trace, on both the
#      Zig 0.16 and 0.17 toolchains (the ADR-044 dual-version gate).
#   2. Interop (staged): once the https handshake server lands, openssl s_client + curl drive
#      a real handshake against the ECDSA / Ed25519 cert fixtures. Skipped with a notice until
#      a server binary exists, so this script is green to run at every step.
#
# Usage: rnd/0.5.x/tls-conformance.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
certs="$here/tls-certs"

cd "$repo"

# comment spacer //
# gate 1: deterministic Layer K + H + C oracles, both toolchains.
echo "== gate 1: Layer K (key schedule) + H (handshake) + C (cert / verify / finished) vs RFC 8448 =="
for tool in zig zig-0.16 zig-0.17; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "-- $tool ($("$tool" version)) --"
    "$tool" run rnd/0.5.x/tls_keyschedule_poc.zig
    "$tool" run rnd/0.5.x/tls_handshake_poc.zig
    "$tool" run rnd/0.5.x/tls_extensions_poc.zig
    "$tool" run rnd/0.5.x/tls_cert_poc.zig
    "$tool" run rnd/0.5.x/tls_server_poc.zig
  fi
done

# comment spacer //
# gate 2: live interop, the pure-Zig server handshake driven by openssl s_client.
echo
echo "== gate 2: live openssl s_client interop (ECDSA P-256, TLS 1.3) =="
bin="$(mktemp -u)"
zig build-exe rnd/0.5.x/tls_server_live.zig -femit-bin="$bin"

"$bin" >/dev/null 2>&1 &
server_pid=$!
sleep 0.4

out="$(printf '' | timeout 6 openssl s_client -connect 127.0.0.1:4443 -tls1_3 -servername localhost 2>&1 || true)"
wait "$server_pid" 2>/dev/null || true

if echo "$out" | grep -q "zix-tls-ok" && echo "$out" | grep -q "TLSv1.3, Cipher is TLS_AES_128_GCM_SHA256"; then
  echo "  PASS  openssl s_client: full TLS 1.3 handshake + application data"
  echo "$out" | grep -iE "Protocol|Cipher is|Peer signature type" | sed 's/^/        /'
else
  echo "  FAIL  openssl interop"
  echo "$out" | tail -20
  exit 1
fi

# curl is the second independent client (ALPN / h2 negotiation path).
"$bin" >/dev/null 2>&1 &
curl_pid=$!
sleep 0.4
curl_out="$(curl -sv --tlsv1.3 -k https://localhost:4443/ 2>&1 || true)"
wait "$curl_pid" 2>/dev/null || true

if echo "$curl_out" | grep -q "SSL connection using TLSv1.3 / TLS_AES_128_GCM_SHA256"; then
  echo "  PASS  curl: TLS 1.3 handshake (ServerHello .. Finished accepted)"
else
  echo "  FAIL  curl interop"
  echo "$curl_out" | tail -20
  exit 1
fi
rm -f "$bin"
