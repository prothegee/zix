# verify-brotli-encoder-dist: brotli CLI interop gate (E4, ring buffer)

The interop gate for the zix E4 encoder PoC (last-distance ring buffer). The in-code tests
round-trip against the zix decoder. This proves the short distance codes are real brotli:
every stream decodes byte-exact through the system `brotli -dc`.

Oracle: the system `brotli` CLI (`brotli -dc`). Subject: `brotli_encoder_dist_poc.zig` in its
file mode (`<input> <output.br>`), driven by `verify-brotli-encoder-dist.sh`.

E4 sends a reused distance as a short code 0..15 (zero extra bits) instead of the explicit
extra-bit code. The encoder simulates the exact ring the decoder keeps. The gate encodes the
same corpus with E3 (no ring) and E4 to show the difference.

## Steps

```sh
# encodes the corpus with E4 (and E3 for comparison), decodes E4 with brotli -dc, diffs.
bash rnd/0.5.x/verify-brotli-encoder-dist.sh
```

The corpus targets the ring:
| input | what it forces |
| :- | :- |
| csv.bin | a CSV with a running counter, one repeating row gap (ring reuse) |
| rec.bin | fixed-width records, a single repeating distance |
| rand.bin | no matches, no distances (grows a little) |
| readme.bin | real text, many distinct distances |

## Expected

```
encoder-dist interop: 4 passed, 0 failed
```

- every E4 stream decodes byte-exact under `brotli -dc` (the gate, exit code 0).
- on structured data E4 is clearly smaller than E3 (csv about 1025 -> 583, a 43 percent drop).
- on high-distance-variety text E4 can be a few bytes larger than E3 (readme about 32117 ->
  32267): the extra short-code symbols dilute the fixed balanced distance tree. This is
  expected and is removed by E5's optimal, frequency-driven codes.

## If it fails

- csv/rec fail but rand passes: the ring simulation is out of step with the decoder. The most
  likely cause is the push rule (short code 0 must NOT push. Codes 1..15 and the explicit code
  must push the resolved distance) or a wrong short-code offset table (4..9 around the last
  distance, 10..15 around the second).
- everything compressible fails: the distance prefix code now spans short and explicit codes,
  check the multi-symbol HTREED (shared with E3).
- `brotli: command not found`: install the CLI (`pacman -S brotli`); it is the oracle.
