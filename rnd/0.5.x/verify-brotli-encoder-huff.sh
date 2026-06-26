#!/usr/bin/env bash
# Brotli encoder interop gate (phase E5, dynamic optimal Huffman codes).
#
# Encodes a corpus with the zix E5 encoder PoC (optimal length-limited Huffman for all three
# trees), decodes each with the system `brotli -dc`, and compares byte-for-byte. The same
# corpus is encoded with E4 (balanced codes) and `brotli -q 5` for reference.
#
# Usage: rnd/0.5.x/verify-brotli-encoder-huff.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cd "$repo"

cat README-en.md > "$work/readme.bin" 2>/dev/null || printf 'fallback text' > "$work/readme.bin"
cat src/lib.zig > "$work/code.bin"
awk 'BEGIN{for(i=0;i<400;i++)printf "2026-06-23,zix,ok,%05d\n",i}' > "$work/csv.bin"
head -c 8192 /dev/urandom > "$work/rand.bin"

pass=0
fail=0
for f in "$work"/*.bin; do
  e5="$f.e5.br"
  e4="$f.e4.br"

  zig run rnd/0.5.x/brotli_encoder_huff_poc.zig -- "$f" "$e5"
  zig run rnd/0.5.x/brotli_encoder_dist_poc.zig -- "$f" "$e4"
  q5="$(brotli -q 5 -c "$f" | wc -c)"

  if brotli -dc "$e5" | cmp -s - "$f"; then
    pass=$((pass + 1))
    printf 'OK   %-11s in=%6s  E4=%6s  E5=%6s  brotli-q5=%s\n' \
      "$(basename "$f")" "$(wc -c <"$f")" "$(wc -c <"$e4")" "$(wc -c <"$e5")" "$q5"
  else
    fail=$((fail + 1))
    echo "FAIL $(basename "$f"): brotli -dc output differs from original"
  fi
done

echo "encoder-huff interop: $pass passed, $fail failed"
test "$fail" -eq 0
