# verify-brotli-encoder-lz: brotli CLI interop gate (E3, LZ77)

The interop gate for the zix E3 encoder PoC (LZ77 matching). The in-code tests round-trip
against the zix decoder. This proves the copy commands are real brotli: every stream decodes
byte-exact through the system `brotli -dc`.

Oracle: the system `brotli` CLI (`brotli -dc`). Subject: `brotli_encoder_lz_poc.zig` in its
file mode (`<input> <output.br>`), driven by `verify-brotli-encoder-lz.sh`.

E3 adds a greedy hash-chain match finder feeding insert-and-copy commands with explicit
distance codes. It does not yet reuse the last-distance ring buffer (E4) or build optimal
Huffman / context codes (E5), so the trees are fixed balanced codes. Ratio is real on
repetitive data and a few bytes larger than the input on incompressible data.

## Steps

```sh
# encodes the corpus with the zix E3 encoder, decodes each with brotli -dc, diffs.
bash rnd/0.5.x/verify-brotli-encoder-lz.sh
```

Single-file spot check:

```sh
awk 'BEGIN{for(i=0;i<200;i++)printf "lorem ipsum dolor "}' > /tmp/in.bin
zig run rnd/0.5.x/brotli_encoder_lz_poc.zig -- /tmp/in.bin /tmp/out.br
brotli -dc /tmp/out.br | cmp -s - /tmp/in.bin && echo OK
```

The corpus exercises the matcher:
| input | what it forces |
| :- | :- |
| rep.bin | a few back-references at short distance |
| lorem.bin | heavy repetition, long matches, big ratio |
| run.bin | a long single-byte run, the max-match split |
| rand.bin | no matches, degrades to a literal block (grows a little) |
| readme.bin | real text, mixed literals and matches |

## Expected

```
encoder-lz interop: 5 passed, 0 failed
```

- every stream decodes byte-exact under `brotli -dc` (the gate, exit code 0).
- repetitive inputs shrink sharply (lorem and run to a few dozen bytes, README-en.md to about
  35 percent). rand.bin grows a few bytes (expected, no matches plus the tree headers).

## If it fails

- lorem/run/readme fail but rand passes: a copy-command bug. Likely the distance code (sec 4,
  the inverse of readDistance for NPOSTFIX=0 / NDIRECT=0), the copy-length code, or the
  command-symbol cell selection.
- rand fails too: the multi-symbol command or distance prefix code (the complex code or its
  code-length-code), or the meta-block ending (the final command must reach MLEN exactly).
- everything fails before output: the preamble or literal code (shared with E2, check
  verify-brotli-encoder-literal first).
- `brotli: command not found`: install the CLI (`pacman -S brotli`); it is the oracle.
