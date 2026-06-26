#!/usr/bin/env bash
# Brotli encoder interop gate (phase E4, last-distance ring buffer).
#
# Encodes a corpus with the zix E4 encoder PoC (ring-buffer distance reuse), decodes each
# stream with the system `brotli -dc`, and compares byte-for-byte. Structured / fixed-gap
# data is encoded by both E3 (no ring) and E4 to show the ring win.
#
# Usage: rnd/0.5.x/verify-brotli-encoder-dist.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cd "$repo"

# corpus: a CSV with a running counter (one repeating row gap), fixed-width records, random,
# and real text.
awk 'BEGIN{for(i=0;i<400;i++)printf "2026-06-23,zix,ok,%05d\n",i}' > "$work/csv.bin"
awk 'BEGIN{for(i=0;i<300;i++)printf "field-a,field-b,field-c,"}' > "$work/rec.bin"
head -c 8192 /dev/urandom > "$work/rand.bin"
cat README-en.md > "$work/readme.bin" 2>/dev/null || printf 'fallback text' > "$work/readme.bin"

pass=0
fail=0
for f in "$work"/*.bin; do
  e4="$f.e4.br"
  e3="$f.e3.br"

  zig run rnd/0.5.x/brotli_encoder_dist_poc.zig -- "$f" "$e4"
  zig run rnd/0.5.x/brotli_encoder_lz_poc.zig -- "$f" "$e3"

  if brotli -dc "$e4" | cmp -s - "$f"; then
    pass=$((pass + 1))
    printf 'OK   %-11s in=%s  E3=%s  E4=%s\n' "$(basename "$f")" "$(wc -c <"$f")" "$(wc -c <"$e3")" "$(wc -c <"$e4")"
  else
    fail=$((fail + 1))
    echo "FAIL $(basename "$f"): brotli -dc output differs from original"
  fi
done

echo "encoder-dist interop: $pass passed, $fail failed"
test "$fail" -eq 0
