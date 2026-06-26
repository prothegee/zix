#!/usr/bin/env bash
# Brotli encoder interop gate (phase E2, literal-only compressed meta-blocks).
#
# Encodes a corpus with the zix E2 encoder PoC, then decodes each stream with the system
# `brotli -dc` and compares byte-for-byte against the original. This proves the compressed
# meta-block (preamble + literal / insert-and-copy / distance prefix codes + the single
# insert command) is real brotli the reference decoder accepts.
#
# Usage: rnd/0.5.x/verify-brotli-encoder-literal.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cd "$repo"

# corpus: 1..4 distinct bytes (simple prefix code) and many distinct bytes (balanced
# complex code), plus incompressible and real-text inputs.
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$work/k1.bin"
printf 'abababababababababababab' > "$work/k2.bin"
printf 'abcabcabcabcabcabcabcabc' > "$work/k3.bin"
printf 'abcdabcdabcdabcdabcdabcd' > "$work/k4.bin"
printf 'the quick brown fox jumps over the lazy dog 0123456789' > "$work/many.bin"
head -c 4096 /dev/urandom > "$work/rand.bin"
cat README-en.md > "$work/readme.bin" 2>/dev/null || printf 'fallback text' > "$work/readme.bin"

pass=0
fail=0
for f in "$work"/*.bin; do
  br="$f.br"

  zig run rnd/0.5.x/brotli_encoder_literal_poc.zig -- "$f" "$br"

  if brotli -dc "$br" | cmp -s - "$f"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $(basename "$f"): brotli -dc output differs from original"
  fi
done

echo "encoder-literal interop: $pass passed, $fail failed"
test "$fail" -eq 0
