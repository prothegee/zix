# verify-brotli-encoder-quality: brotli CLI interop gate (E7, quality + fallback)

The interop gate for the zix E7 encoder front-end (quality levels and the never-expand store
fallback). The in-code tests round-trip against the zix decoder. This proves every quality
level produces real brotli: each stream decodes byte-exact through the system `brotli -dc`,
and never grows past the input plus the store header.

Oracle: the system `brotli` CLI (`brotli -dc`). Subject: `brotli_encoder_quality_poc.zig` in
its file mode (`<input> <output.br> [quality]`), driven by `verify-brotli-encoder-quality.sh`.

E7 maps a quality 0..11 to encoder effort (q0 greedy no-dictionary, higher q widens the match
search and uses the dictionary) and always also produces an E1 store-only stream, returning
the smaller. When the dictionary is on it also encodes a no-dictionary variant and keeps the
smaller, so the dictionary never hurts. Block splitting is the remaining E7 ratio refinement.

## Steps

```sh
# compresses each input at q0/1/5/9/11, decodes with brotli -dc, checks never-expand.
bash rnd/0.5.x/verify-brotli-encoder-quality.sh
```

Single-file at a chosen quality:

```sh
zig run rnd/0.5.x/brotli_encoder_quality_poc.zig -- README-en.md /tmp/out.br 5
brotli -dc /tmp/out.br | cmp -s - README-en.md && echo OK
```

## Expected

```
encoder-quality interop: 20 passed, 0 failed
```

- every (input, quality) stream decodes byte-exact under `brotli -dc` (the gate).
- no output exceeds its input by more than the store header (the never-expand check). rand.bin
  stays at about its input size (the store fallback); README-en.md reaches about 28 KB at q5;
  short text and repetitive data shrink sharply.

## If it fails

- a "expanded" failure: the store fallback did not win when it should have. Check
  compressBrotliAlloc returns the smaller of compressed and stored.
- a specific quality fails to decode but others pass: that quality's effort params produced an
  invalid stream, check qualityParams and that every params value flows through the E6 encoder.
- everything fails: a shared-pipeline regression, run verify-brotli-encoder-dictref (E6) first.
- `brotli: command not found`: install the CLI (`pacman -S brotli`); it is the oracle.
