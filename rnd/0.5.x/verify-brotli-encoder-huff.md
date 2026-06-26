# verify-brotli-encoder-huff: brotli CLI interop gate (E5, dynamic Huffman)

The interop gate for the zix E5 encoder PoC (optimal Huffman codes). The in-code tests
round-trip against the zix decoder. This proves the dynamic per-block codes are real brotli:
every stream decodes byte-exact through the system `brotli -dc`.

Oracle: the system `brotli` CLI (`brotli -dc`, plus `brotli -q 5` for a reference size).
Subject: `brotli_encoder_huff_poc.zig` in its file mode (`<input> <output.br>`), driven by
`verify-brotli-encoder-huff.sh`.

E5 replaces the fixed balanced codes of E2..E4 with optimal length-limited Huffman over the
real symbol frequencies, for all three trees. It keeps one literal tree (NTREESL = 1);
per-block literal context modeling (NTREESL > 1 with a context map) is the remaining E5
sub-step. Even so, E5 lands within a few percent of `brotli -q 5` on text and code.

## Steps

```sh
# encodes the corpus with E5 (and E4 + brotli -q5 for reference), decodes E5 with brotli -dc.
bash rnd/0.5.x/verify-brotli-encoder-huff.sh
```

## Expected

```
encoder-huff interop: 4 passed, 0 failed
```

- every E5 stream decodes byte-exact under `brotli -dc` (the gate, exit code 0).
- E5 is clearly smaller than E4 on text and code, and within a few percent of `brotli -q 5`:
  README-en.md about 32267 (E4) -> 28982 (E5), brotli-q5 about 27806.
- rand.bin still grows slightly: a high-entropy input has no good code and E5 always emits a
  compressed block. The store-or-compress choice is an E7 quality step.

## If it fails

- everything compressible fails: the Huffman length build (the 15-bit cap redistribution) or
  the canonical code assignment. Cross-check `huffmanLengths` produces a complete code (the
  in-code kraft-sum test).
- only large/skewed inputs fail: the 15-bit length cap (a code longer than 15 bits is invalid
  in brotli). The overflow redistribution must bring every length to <= 15.
- the failure matches E4 too: a shared bug in the matcher, ring, or command machinery, run
  verify-brotli-encoder-dist first.
- `brotli: command not found`: install the CLI (`pacman -S brotli`); it is the oracle.
