# verify-brotli-encoder: brotli CLI interop gate (E1, store-only)

The interop gate for the zix brotli encoder PoC. The in-code tests in
`brotli_encoder_poc.zig` only round-trip against the zix decoder. This proves the encoder
emits real brotli that the reference decoder accepts: every E1 stream decodes byte-exact
through the system `brotli -dc`.

Oracle: the system `brotli` CLI (`brotli -dc`). Subject: `brotli_encoder_poc.zig` in its
file mode (`<input> <output.br>`), driven by `verify-brotli-encoder.sh`.

E1 is store-only (ISUNCOMPRESSED=1 meta-blocks, zero compression), so the `.br` is slightly
larger than the input. That is expected: E1 gates framing correctness, not ratio. Ratio
arrives with the E2+ compressed paths.

## Steps

```sh
# encodes the corpus with the zix encoder, then decodes each with brotli -dc and diffs.
bash rnd/0.5.x/verify-brotli-encoder.sh
```

Single-file spot check:

```sh
printf 'hello over brotli E1' > /tmp/in.bin
zig run rnd/0.5.x/brotli_encoder_poc.zig -- /tmp/in.bin /tmp/out.br
brotli -dc /tmp/out.br        # prints: hello over brotli E1
```

The corpus exercises each E1 path:
| input | path it forces |
| :- | :- |
| empty.bin | stream header + empty last meta-block only |
| one.bin | single 4-nibble MLEN meta-block |
| fox.bin | multi-byte literal copy |
| big.bin | >64 KiB, the 5-nibble MLEN selection |
| readme.bin | larger real text |

## Expected

```
encoder interop: 5 passed, 0 failed
```

- every stream decodes byte-exact under `brotli -dc` (the gate, exit code 0).
- the single-file spot check prints the original text back.

## If it fails

- one input fails: a size-specific framing bug. big.bin alone failing points at the 5-nibble
  MLEN path (the >4-nibble non-zero-top-nibble rule, sec 9.2).
- `brotli -dc` errors before any output: a stream-header (WBITS) or meta-block-header bug, the
  ISLAST / MNIBBLES / ISUNCOMPRESSED bit order.
- empty.bin fails but others pass: the empty last meta-block (ISLAST=1, ISLASTEMPTY=1) or the
  zero fill of the final byte.
- `brotli: command not found`: install the CLI (`pacman -S brotli`); it is the oracle.
