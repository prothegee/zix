#!/usr/bin/env bash
# Brotli decoder conformance driver (phase D7).
#
# Builds a corpus of varied inputs, compresses each with the system `brotli` CLI across a
# matrix of quality and window sizes, then decodes every .br with the zix PoC decoder and
# compares byte-for-byte against the original. This is the conformance + interop gate the
# eventual src/utils/compression/brotli.zig must also pass.
#
# Usage: rnd/0.5.x/perf-conformance-brotli.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
corpus="$(mktemp -d)"
trap 'rm -rf "$corpus"' EXIT

cd "$repo"

# corpus: empty, tiny, text (dictionary-heavy), repetitive (back-references), source code,
# pseudo-random (incompressible -> uncompressed meta-blocks), and a large mixed file
# (multiple meta-blocks + block-switch).
printf '' > "$corpus/empty.bin"
printf 'a' > "$corpus/one.bin"
awk 'BEGIN{for(i=0;i<12;i++)printf "the quick brown fox "}' > "$corpus/fox.bin"
awk 'BEGIN{for(i=0;i<200;i++)print "The world will know the truth about the world."}' > "$corpus/essay.bin"
cat rnd/rfc/rfc7932.txt > "$corpus/rfc.bin"
cat README-en.md docs/hld-http1-en.md src/zix.zig > "$corpus/mixed.bin" 2>/dev/null || cat README-en.md > "$corpus/mixed.bin"
head -c 65536 /dev/urandom > "$corpus/random.bin"
# a large repetitive file to push past one meta-block and provoke block-switch
{ for i in $(seq 1 4000); do printf 'line %d: lorem ipsum dolor sit amet, consectetur adipiscing elit\n' "$i"; done; } > "$corpus/big.bin"

vectors=()
for f in "$corpus"/*.bin; do
  for q in 0 5 9 11; do
    for w in 10 18 22 24; do
      out="$corpus/$(basename "$f" .bin)-q${q}-w${w}.br"
      brotli -q "$q" -w "$w" -c "$f" > "$out"
      # name the .br so its sibling original (strip .br) is the right .bin
      cp "$f" "${out%.br}"
      vectors+=("$out")
    done
  done
done

# a >16 MiB input forces brotli to emit more than one meta-block (MLEN caps at 2^24).
# Keep it to one fast quality / large window to bound the run time.
awk 'BEGIN{for(i=0;i<320000;i++)print "lorem ipsum dolor sit amet consectetur adipiscing elit sed"}' > "$corpus/huge.bin"
for w in 22 24; do
  out="$corpus/huge-q1-w${w}.br"
  brotli -q 1 -w "$w" -c "$corpus/huge.bin" > "$out"
  cp "$corpus/huge.bin" "${out%.br}"
  vectors+=("$out")
done

echo "corpus: $(ls "$corpus"/*.bin | wc -l) inputs, ${#vectors[@]} compressed vectors"
zig run rnd/0.5.x/brotli_conformance_poc.zig -- "${vectors[@]}"
