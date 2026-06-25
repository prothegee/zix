# Verify: QPACK interop (http3-plan.md phase P4)

P1 / P2 / P3 proved each QPACK piece in isolation. P4 ties them together and checks interoperability.
It has two halves, and they are honestly different in what they can prove right now.

## Two halves

- **Self-consistency (deterministic, done).** Encode a header list with zix's encoder and decode it
  back with zix's decoder, confirming the result is byte-identical to the input. This exercises the
  Encoded Field Section Prefix and three representations together (Indexed, Literal with Name
  Reference, Literal with Literal Name), and pins the wire bytes the static representations must
  produce (e.g. :method GET is 0xd1). Proven in `qpack_p4_poc.zig`.
- **Cross-implementation (now live via curl).** A real third-party QPACK on both directions exercises
  interop against the assembled engine: curl --http3 Huffman-encodes the request `:path` (RFC 7541
  Appendix B) and the server decodes it (`huffman.zig` + `qpack.zig`), and curl decodes the server's
  QPACK-encoded `:status`. That is encode-and-decode-and-compare against another implementation on the
  live wire (HTTP/3 200). The static `.qif` corpus sweep (dynamic table + Huffman at varied settings)
  is still an optional follow-up, since the live engine uses the static table only.

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
- Cross-impl is covered live by `zig build test-runner-http3` (and the curl --http3 round trip): the
  server decodes curl's Huffman `:path` and curl decodes the server's QPACK `:status`. The static
  `.qif` corpus sweep stays an optional follow-up when `QPACK_INTEROP_DIR` is set.
