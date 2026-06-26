#!/usr/bin/env bash
# Brotli encoder interop gate (phase E1, store-only).
#
# Encodes a corpus with the zix encoder PoC, then decodes each stream with the system
# `brotli -dc` and compares byte-for-byte against the original. This proves the E1 framing
# (stream header + uncompressed meta-blocks + empty last block) is real brotli that the
# reference decoder accepts, not just self-consistent with the zix decoder.
#
# Usage: rnd/0.5.x/verify-brotli-encoder.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cd "$repo"

# corpus: empty, one byte, text, a >64 KiB block (the 5-nibble MLEN path), and a binary blob.
printf '' > "$work/empty.bin"
printf 'a' > "$work/one.bin"
awk 'BEGIN{for(i=0;i<12;i++)printf "the quick brown fox "}' > "$work/fox.bin"
head -c 70000 /dev/urandom > "$work/big.bin"
cat README-en.md > "$work/readme.bin" 2>/dev/null || printf 'fallback text' > "$work/readme.bin"

pass=0
fail=0
for f in "$work"/*.bin; do
  br="$work/$(basename "$f" .bin).br"

  zig run rnd/0.5.x/brotli_encoder_poc.zig -- "$f" "$br"

  if brotli -dc "$br" | cmp -s - "$f"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $(basename "$f"): brotli -dc output differs from original"
  fi
done

echo "encoder interop: $pass passed, $fail failed"
test "$fail" -eq 0
