# verify-brotli-encoder-dictref: brotli CLI interop gate (E6, dictionary)

The interop gate for the zix E6 encoder PoC (static dictionary references). The in-code
tests round-trip against the zix decoder. This proves the dictionary references are real
brotli: every stream decodes byte-exact through the system `brotli -dc`.

Oracle: the system `brotli` CLI (`brotli -dc`, plus `brotli -q 5` for reference). Subject:
`brotli_encoder_dictref_poc.zig` in its file mode (`<input> <output.br>`), driven by
`verify-brotli-encoder-dictref.sh`.

E6 references words in the 122,784-byte static dictionary using the IDENTITY transform (the
word as-is): a copy whose distance lands past the available back distance, which the decoder
resolves to a dictionary word (sec 8). The 120 case / prefix / suffix transforms are a later
refinement. The dictionary mainly helps short text, where a word appears before any
self-reference exists.

## Steps

```sh
# encodes the corpus with E6 (and E5 + brotli -q5 for reference), decodes E6 with brotli -dc.
bash rnd/0.5.x/verify-brotli-encoder-dictref.sh
```

## Expected

```
encoder-dictref interop: 4 passed, 0 failed
```

- every E6 stream decodes byte-exact under `brotli -dc` (the gate, exit code 0).
- on short English text E6 is smaller than E5 (the dictionary path fires): for example the
  74-byte "information about the government ..." goes from about 113 (E5) to 53 (E6).
- on random data E6 equals E5 (no dictionary words match).

## If it fails

- a short-text input fails but random passes: the dictionary reference distance is wrong. The
  identity formula is distance = word_index + max_allowed + 1, where max_allowed = min(window,
  output_position) at the START of the copy (after this command's inserted literals). A common
  mistake is computing max_allowed at the wrong position, or pushing a dictionary distance to
  the last-distance ring (it must NOT be pushed).
- everything fails: shared machinery (Huffman, commands), run verify-brotli-encoder-huff first.
- `brotli: command not found`: install the CLI (`pacman -S brotli`); it is the oracle.
