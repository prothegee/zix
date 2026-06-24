# Verify: QPACK interop (http3-plan.md phase P4)

P1 / P2 / P3 proved each QPACK piece in isolation. P4 ties them together and checks interoperability.
It has two halves, and they are honestly different in what they can prove right now.

## Two halves

- **Self-consistency (deterministic, done).** Encode a header list with zix's encoder and decode it
  back with zix's decoder, confirming the result is byte-identical to the input. This exercises the
  Encoded Field Section Prefix and three representations together (Indexed, Literal with Name
  Reference, Literal with Literal Name), and pins the wire bytes the static representations must
  produce (e.g. :method GET is 0xd1). Proven in `qpack_p4_poc.zig`.
- **Cross-implementation (pending fixtures).** Decode encoded streams produced by *another* QPACK
  implementation and compare the decode to the original header list. This is the real interop signal,
  and it needs the qpack-interop test data: `.qif` files (the decoded header lists) and the `.out` /
  `.enc` encoded streams various implementations produced at various dynamic-table settings. Those
  fixtures are not in the tree, and the streams exercise the dynamic table and Huffman, so the full
  decode-and-compare driver lands with the integrated QPACK decoder. Until then this half is reported
  PENDING, not faked.

## Oracle

RFC 9204 section 4.5 for the self round trip; the qpack-interop corpus (decode-and-compare against
`.qif`) for the cross-impl half.

## Run

```sh
bash rnd/0.5.x/verify-qpack-p4.sh
```

Once the qpack-interop fixtures are fetched:

```sh
QPACK_INTEROP_DIR=/path/to/qifs bash rnd/0.5.x/verify-qpack-p4.sh
```

## Expect

- Step 1 prints `PASS` for the zix encode -> decode self round trip.
- Step 2 reports `PENDING` with no fixtures (self consistency proven, cross-impl not run, not faked),
  or notes the fixtures and defers the full driver to Layer P integration when `QPACK_INTEROP_DIR`
  is set.
