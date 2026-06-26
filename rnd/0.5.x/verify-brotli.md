# verify-brotli: brotli CLI decoder conformance gate (D1-D7)

The interop gate for the zix brotli decoder PoC. The layered unit tests only check
self-consistency against hand-built bitstreams. This proves the decoder reproduces, byte
for byte, what a real encoder (`brotli` 1.x) emits across a quality and window matrix. The
same external-vector approach as the deflate python-`zlib` test.

Oracle: the system `brotli` CLI (`brotli -q -w -c`). Subject: `brotli_conformance_poc.zig`
(imports D2..D6), driven by `perf-conformance-brotli.sh`.

## Steps

```sh
# one command: builds the corpus, compresses every input across q0/5/9/11 x w10/18/22/24
# (plus a >16 MiB input at q1), then decodes each .br with the PoC and diffs vs the source.
bash rnd/0.5.x/perf-conformance-brotli.sh
```

The corpus is 9 inputs chosen to exercise every decoder path:
| input | path it forces |
| :- | :- |
| empty.bin | ISLASTEMPTY meta-block |
| one.bin | single-literal block |
| fox.bin | static dictionary references + transforms |
| essay.bin | dictionary-heavy text, long back-references |
| rfc.bin | large mixed text (multiple meta-blocks) |
| mixed.bin | source + markdown, varied symbol distribution |
| random.bin | incompressible, ISUNCOMPRESSED meta-blocks |
| big.bin | repetitive, provokes mid-data block-switch |
| huge.bin | >16 MiB, MLEN caps at 2^24 so multiple meta-blocks |

## Expected

```
corpus: 9 inputs, 130 compressed vectors
conformance: 130 passed, 0 failed
coverage: meta-blocks=1223 compressed=1128 uncompressed=95 metadata=0 block-switch=40 multi-meta-block-files=19
```

- `130 passed, 0 failed`: every vector decoded byte-exact (the gate).
- coverage confirms the hard paths were actually hit, not skipped:
  - `compressed` + `uncompressed` meta-blocks both > 0
  - `block-switch=40`: NBLTYPES >= 2 mid-data switches decoded
  - `multi-meta-block-files=19`: the cross-meta-block state (p1/p2, distance ring, output)
    persists correctly
- `metadata=0` is expected: the CLI never emits metadata meta-blocks (MNIBBLES=0). That path
  is covered by a hand-crafted in-code test in `brotli_conformance_poc.zig`, not by this gate.

Exact coverage counts shift a little with the installed `brotli` version (encoder choices,
not a decoder change). Observed under `brotli 1.2.0`: `uncompressed=95`. The pass count must
stay `130/130` regardless.

## If it fails

- one vector fails, rest pass: a path that only that input exercises. The failing `.br` is the
  corpus file at that q/w cell. Decode it alone with `zig run brotli_conformance_poc.zig -- <file>`
  to isolate.
- many fail at the same q/w: a window-size (WBITS) or quality-specific framing bug.
- all uncompressed inputs fail: the ISUNCOMPRESSED copy path (sec 9.2).
- text inputs fail but random passes: the static dictionary or transform path (sec 8, D6).
- `brotli: command not found`: install the CLI (`pacman -S brotli`); it is the oracle, the gate
  cannot run without it.
