#!/usr/bin/env bash
# Brotli encoder interop gate (phase E7, quality levels + never-expand fallback).
#
# Compresses a corpus at several quality levels with the zix E7 front-end, decodes each with
# the system `brotli -dc`, and compares byte-for-byte. Also checks the output never grows past
# the input plus the store header (the never-expand guarantee).
#
# Usage: rnd/0.5.x/verify-brotli-encoder-quality.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cd "$repo"

cat README-en.md > "$work/readme.bin" 2>/dev/null || printf 'the world and the people' > "$work/readme.bin"
awk 'BEGIN{for(i=0;i<200;i++)printf "lorem ipsum dolor sit amet "}' > "$work/lorem.bin"
printf 'information about the government of the people for the people' > "$work/short.bin"
head -c 8192 /dev/urandom > "$work/rand.bin"

pass=0
fail=0
for f in "$work"/*.bin; do
  in_size="$(wc -c <"$f")"
  for q in 0 1 5 9 11; do
    br="$f.q$q.br"
    zig run rnd/0.5.x/brotli_encoder_quality_poc.zig -- "$f" "$br" "$q"

    out_size="$(wc -c <"$br")"
    if ! brotli -dc "$br" | cmp -s - "$f"; then
      fail=$((fail + 1))
      echo "FAIL $(basename "$f") q$q: brotli -dc mismatch"
      continue
    fi
    if [ "$out_size" -gt $((in_size + 8)) ]; then
      fail=$((fail + 1))
      echo "FAIL $(basename "$f") q$q: expanded ($in_size -> $out_size)"
      continue
    fi
    pass=$((pass + 1))
  done

  # report the q5 size per input.
  printf 'OK   %-11s in=%6s  q5=%s\n' "$(basename "$f")" "$in_size" "$(wc -c <"$f.q5.br")"
done

echo "encoder-quality interop: $pass passed, $fail failed"
test "$fail" -eq 0
