#!/usr/bin/env bash
# Brotli encoder interop gate (phase E6, static dictionary references, identity transform).
#
# Encodes short English texts with the zix E6 encoder PoC (dictionary-word references),
# decodes each with the system `brotli -dc`, and compares byte-for-byte. E5 (no dictionary)
# and `brotli -q 5` are encoded for reference, since the dictionary mainly helps short text.
#
# Usage: rnd/0.5.x/verify-brotli-encoder-dictref.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cd "$repo"

printf 'The quick brown fox and the lazy dog went to the market today and tomorrow.' > "$work/t1.bin"
printf 'information about the government of the people for the people of the world' > "$work/t2.bin"
head -c 4000 README-en.md > "$work/readme4k.bin" 2>/dev/null || printf 'the world and the people' > "$work/readme4k.bin"
head -c 4096 /dev/urandom > "$work/rand.bin"

pass=0
fail=0
for f in "$work"/*.bin; do
  e6="$f.e6.br"
  e5="$f.e5.br"

  zig run rnd/0.5.x/brotli_encoder_dictref_poc.zig -- "$f" "$e6"
  zig run rnd/0.5.x/brotli_encoder_huff_poc.zig -- "$f" "$e5"
  q5="$(brotli -q 5 -c "$f" | wc -c)"

  if brotli -dc "$e6" | cmp -s - "$f"; then
    pass=$((pass + 1))
    printf 'OK   %-12s in=%5s  E5=%5s  E6=%5s  brotli-q5=%s\n' \
      "$(basename "$f")" "$(wc -c <"$f")" "$(wc -c <"$e5")" "$(wc -c <"$e6")" "$q5"
  else
    fail=$((fail + 1))
    echo "FAIL $(basename "$f"): brotli -dc output differs from original"
  fi
done

echo "encoder-dictref interop: $pass passed, $fail failed"
test "$fail" -eq 0
