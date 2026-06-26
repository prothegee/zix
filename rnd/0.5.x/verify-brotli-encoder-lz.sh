#!/usr/bin/env bash
# Brotli encoder interop gate (phase E3, LZ77 matching).
#
# Encodes a corpus with the zix E3 encoder PoC (hash-chain matcher + insert-and-copy
# commands), decodes each stream with the system `brotli -dc`, and compares byte-for-byte.
# This proves the copy commands, distance codes, and multi-symbol command/distance prefix
# codes are real brotli the reference decoder accepts.
#
# Usage: rnd/0.5.x/verify-brotli-encoder-lz.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cd "$repo"

# corpus: a short repeat, a heavily repeated phrase, a long single-byte run, incompressible
# random, and real text.
printf 'the quick brown fox the quick brown fox the quick brown fox' > "$work/rep.bin"
awk 'BEGIN{for(i=0;i<500;i++)printf "lorem ipsum dolor sit amet "}' > "$work/lorem.bin"
awk 'BEGIN{for(i=0;i<2000;i++)printf "abcdefgh"}' > "$work/run.bin"
head -c 8192 /dev/urandom > "$work/rand.bin"
cat README-en.md > "$work/readme.bin" 2>/dev/null || printf 'fallback text' > "$work/readme.bin"

pass=0
fail=0
for f in "$work"/*.bin; do
  br="$f.br"

  zig run rnd/0.5.x/brotli_encoder_lz_poc.zig -- "$f" "$br"

  if brotli -dc "$br" | cmp -s - "$f"; then
    pass=$((pass + 1))
    printf 'OK   %-12s %s -> %s\n' "$(basename "$f")" "$(wc -c <"$f")" "$(wc -c <"$br")"
  else
    fail=$((fail + 1))
    echo "FAIL $(basename "$f"): brotli -dc output differs from original"
  fi
done

echo "encoder-lz interop: $pass passed, $fail failed"
test "$fail" -eq 0
