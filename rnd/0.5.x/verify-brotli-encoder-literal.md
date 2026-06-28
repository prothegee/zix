# verify-brotli-encoder-literal: brotli CLI interop gate (E2, literal-only)

The interop gate for the zix E2 encoder PoC (literal-only compressed meta-blocks). The
in-code tests round-trip against the zix decoder. This proves the compressed meta-block is
real brotli: every stream decodes byte-exact through the system `brotli -dc`.

Oracle: the system `brotli` CLI (`brotli -dc`). Subject: `brotli_encoder_literal_poc.zig` in
its file mode (`<input> <output.br>`), driven by `verify-brotli-encoder-literal.sh`.

E2 has no LZ77 matching (that is E3) and no optimal Huffman or context modeling (that is E5).
Ratio comes only from the literal entropy code: a simple code on low-cardinality data and a
fixed balanced code (about log2(k) bits over k distinct bytes) otherwise. So a high-entropy
input can grow slightly, while real text shrinks.

## Steps

```sh
# encodes the corpus with the zix E2 encoder, decodes each with brotli -dc, diffs.
bash rnd/0.5.x/verify-brotli-encoder-literal.sh
```

Single-file spot check:

```sh
printf 'the quick brown fox' > /tmp/in.bin
zig run rnd/0.5.x/brotli_encoder_literal_poc.zig -- /tmp/in.bin /tmp/out.br
brotli -dc /tmp/out.br        # prints: the quick brown fox
```

The corpus exercises each literal-code path:
| input | literal code |
| :- | :- |
| k1.bin | 1 distinct byte, single-symbol code (zero bits per byte) |
| k2.bin | 2 distinct, simple nsym=2 |
| k3.bin | 3 distinct, simple nsym=3 |
| k4.bin | 4 distinct, simple nsym=4 |
| many.bin | many distinct, balanced complex code |
| rand.bin | full-entropy, balanced over ~256 symbols (grows a little) |
| readme.bin | real text, balanced code (shrinks, about 76 percent) |

## Expected

```
encoder-literal interop: 7 passed, 0 failed
```

- every stream decodes byte-exact under `brotli -dc` (the gate, exit code 0).
- readme.bin shrinks (real, if small, ratio). rand.bin may grow a few bytes (expected, E2 has
  no matching and a fixed code).

## If it fails

- only many/readme/rand fail: the balanced complex code (sec 3.5). The likely cause is the
  code-length-code description desyncing, the encoder must stop emitting code-length-code
  lengths the moment the code completes (space hits 0), exactly as the decoder stops reading.
- only k2/k3/k4 fail: the simple prefix code header (selector, NSYM, symbol values).
- k1 fails: the single-symbol code, or literal bits emitted when they should be zero.
- all fail before any output: the meta-block header or preamble (ISLAST, MLEN, NBLTYPES,
  NPOSTFIX/NDIRECT, NTREES) or the insert-and-copy command symbol.
- `brotli: command not found`: install the CLI (`pacman -S brotli`); it is the oracle.
