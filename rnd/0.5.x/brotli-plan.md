# Brotli plan (full path from PoC to shipped codec)

Brotli is a std-gap: `std.compress` has flate / zstd / lzma / xz but NO brotli, so it
is authored from RFC 7932 (vendored at `rnd/rfc/rfc7932.txt`, self-contained: format +
Appendix A static dictionary + Appendix B transforms). Decoder-first: the decoder
validates the format understanding and the dictionary embed before the harder encoder.

Reference points throughout: RFC 7932 sections. Interop oracle: the system `brotli` CLI
(`brotli -c` / `brotli -dc`), the same external-vector approach used for the deflate
python-`zlib` test.

## Decoder (decompress)

- [x] D1: framing + bit reader + uncompressed path. The LSB-first bit reader, stream
  header WBITS (sec 9.1), meta-block header ISLAST / ISLASTEMPTY / MNIBBLES / MLEN /
  ISUNCOMPRESSED (sec 9.2), and the uncompressed meta-block copy. Proven in
  `rnd/0.5.x/brotli_decoder_poc.zig` against real CLI vectors (empty + uncompressed
  decode, compressed stops at the boundary with MLEN parsed correctly).
- [x] D2: prefix codes (sec 3). Canonical Huffman decode (sec 3.2), simple codes (sec
  3.4), and complex codes via the code-length code with the 16/17 repeat logic (sec
  3.5). Done in `rnd/0.5.x/brotli_prefix_poc.zig`, 5 unit tests pass (canonical example,
  single-symbol, static code-length-code table, simple nsym=2, complex [2,2,2,2] end to
  end). The core primitive every later phase consumes. Not yet wired into the framing
  decoder, the first prefix code sits behind the D3 preamble.
- [x] D3: block-switch preamble (sec 9.2 + sec 6). The NBLTYPES / NTREES variable-length
  code, the 26-symbol block-count code (base + extra), the per-category setup (block-type
  code, block-count code, first block count) for literals / insert-and-copy / distances,
  and NPOSTFIX / NDIRECT. Done in `rnd/0.5.x/brotli_meta_poc.zig` (imports D2), 7 tests
  pass, and it parses a REAL compressed meta-block preamble end to end (WBITS=24,
  MLEN=240, NBLTYPES all 1, NPOSTFIX=3, NDIRECT=120), stopping at the context modes.
- [x] D4: context modeling (sec 7). Context modes (LSB6 / MSB6 / UTF8 / Signed, sec 7.1),
  NTREESL / NTREESD (sec 9.2), and the context maps for literals and distances (sec 7.3)
  via RLEMAX, run-length-zero coding, the context-map prefix code, and the inverse
  move-to-front decode. Done in `rnd/0.5.x/brotli_context_poc.zig` (imports D3), 12 tests
  pass (7 D4 + 5 transitive D2), and it parses the REAL vector through the maps end to end
  (NTREESL=2 so a genuine 64-entry literal context map is decoded, NTREESD=1, landing at
  the per-block prefix codes). The context-ID lookups (sec 7.1 Lut0/1/2, sec 7.2) are the
  consumer side, deferred to D5.
- [x] D5: command loop (sec 9.3 + sec 4, 5, 7.1, 7.2). Reads the per-block-type prefix
  codes (HTREEL / HTREEI / HTREED), then runs the command loop: insert-and-copy length
  codes (sec 5, the 11-cell split into insert and copy codes), literal emission through
  the context model (sec 7.1 Lut0/1/2 context IDs indexing CMAPL), copy with backward
  distance (sec 4, the short-code ring buffer + direct codes + the NPOSTFIX / NDIRECT
  formula), and the distance context ID (sec 7.2). Done in
  `rnd/0.5.x/brotli_command_poc.zig` (imports D4), 9 tests + transitive (21 total) pass.
  Fully decodes a non-dictionary vector ('Zq7Kx9' x40, 240 bytes byte-exact vs
  `brotli -dc`), and the text vector decodes its literals then stops at the static
  dictionary reference, the boundary of phase D6. Single block type per category
  (NBLTYPES = 1); mid-data block-switch (sec 6, NBLTYPES >= 2) is a later refinement, no
  test vector exercises it.
- [x] D6: static dictionary (sec 8 + Appendix A/B). The 122,784-byte DICT is extracted
  from the vendored RFC hex to `rnd/0.5.x/brotli_dictionary.bin` (CRC-32 0x5136cb04,
  verified) and embedded with `@embedFile`. DOFFSET is derived at comptime from NDBITS,
  and the 121 word transforms (prefix + elementary + suffix) are transcribed and
  self-checked against the RFC's 648-byte serialization (CRC-32 0x3d965f81). Done in
  `rnd/0.5.x/brotli_dictionary_poc.zig` (imports D5 for the command machinery), 5 tests +
  transitive (25 total) pass. The text vector now decodes end to end to
  'the quick brown fox ' x12, and a Ferment-exercising vector
  ('The world will know the truth ...') decodes byte-exact, confirming the transform path.
- [x] D7: conformance. The consolidated decoder `rnd/0.5.x/brotli_conformance_poc.zig`
  (imports D2..D6) adds the cases the layered PoCs skipped: the multi-meta-block outer
  loop, metadata meta-blocks (MNIBBLES=0), uncompressed meta-blocks, and mid-data
  block-switch (NBLTYPES >= 2) for all three categories, with the cross-meta-block state
  (p1/p2, distance ring, output) persisted. Bug found and fixed: a distance resolving to a
  dictionary reference must not be pushed to the ring buffer (sec 4); the push is deferred
  to the confirmed back-reference branch (also back-ported to D5/D6). Driver
  `rnd/0.5.x/perf-conformance-brotli.sh` round-trips a 9-input corpus through `brotli -c`
  across q0/5/9/11 x w10/18/22/24 plus a >16 MiB input: 130/130 vectors decode byte-exact,
  coverage = 1223 meta-blocks, 96 uncompressed, 40 block-switch, 19 multi-meta-block files.
  Metadata is covered by a hand-crafted unit test (the CLI never emits metadata blocks).
  The full decoder (D1..D7) is complete.

## Encoder (compress, the harder half)

- [x] E1: uncompressed meta-blocks only. The LSB-first bit writer (inverse of the decoder's
  bit reader), the stream header WBITS (sec 9.1, full 10..24 range), and the uncompressed
  meta-block (ISLAST=0, MNIBBLES with minimal nibble count so the top nibble is non-zero,
  MLEN, ISUNCOMPRESSED=1, byte-align, literal copy), closed by an empty last meta-block
  (ISLAST=1, ISLASTEMPTY=1). Input over 2^24 bytes splits across meta-blocks. Done in
  `rnd/0.5.x/brotli_encoder_poc.zig`, 7 unit tests pass (empty == canonical 0x3f, single
  byte, multi-byte text, 250-block split, all window sizes, out-of-range rejected, 5-nibble
  >64 KiB path). Interop gate `rnd/0.5.x/verify-brotli-encoder.sh` (doc
  `verify-brotli-encoder.md`) encodes a 5-input corpus and decodes each byte-exact through
  `brotli -dc`: 5/5 pass. Store-only, so no compression yet (E2 is the first real ratio).
- [x] E2: literal-only compressed blocks. A full COMPRESSED meta-block: the LSB-first
  prefix-code writer (canonical codes, simple sec 3.4 and complex sec 3.5), the preamble
  (NBLTYPES=1, NPOSTFIX/NDIRECT=0, NTREES=1), three prefix codes (literal, single-symbol
  insert-and-copy, single-symbol distance), and one command that inserts every byte with the
  copy skipped at MLEN (sec 10). Literal code: simple for 1..4 distinct bytes, else a fixed
  balanced code (about log2(k) bits over k distinct values), no matching or optimal Huffman
  yet (those are E3 and E5). Key subtlety: the code-length-code description must stop the
  moment the code completes (space hits 0), exactly as the decoder stops reading. Done in
  `rnd/0.5.x/brotli_encoder_literal_poc.zig`, 10 unit tests pass (round-trip through the full
  decoder for k=1..4, full 256-symbol alphabet, binary, empty, low-cardinality shrink).
  Interop gate `rnd/0.5.x/verify-brotli-encoder-literal.sh` (doc
  `verify-brotli-encoder-literal.md`): 7/7 decode byte-exact through `brotli -dc`, real text
  (README-en.md) compresses to about 76 percent.
- [x] E3: LZ77 matching. A greedy hash-chain match finder (4-byte hash, chain walk capped at
  64, min match 4) turns repeated substrings into copy commands, runs of literals into
  inserts (sec 4, 5, 10). New machinery: the copy-length code and the distance code (the
  inverse of readDistance for NPOSTFIX=0 / NDIRECT=0, two interleaved series tiling distances
  1,2,3,...), the explicit-distance command-symbol cells, and multi-symbol HTREEI / HTREED
  prefix codes. Distances always use the explicit codes (>= 16); the last-distance ring reuse
  is E4. Done in `rnd/0.5.x/brotli_encoder_lz_poc.zig`, 11 unit tests pass (no-match degrade,
  repeated unit/phrase, match-ends-at-MLEN, 40 KB single-byte run, binary). Interop gate
  `rnd/0.5.x/verify-brotli-encoder-lz.sh` (doc `verify-brotli-encoder-lz.md`): 5/5 decode
  byte-exact through `brotli -dc`; README-en.md now 90756 -> 32117 (about 35 percent, down
  from E2's 69350), a 13.5 KB repeated phrase to 42 bytes.
- [x] E4: distances, the last-distance ring buffer. E3 always spelled out the full
  extra-bit distance code. E4 sends a reused distance as a short code 0..15 with zero extra
  bits (sec 4): 0..3 = the four recent distances, 4..9 = last distance +/- 1..3, 10..15 =
  second distance +/- 1..3. The encoder simulates the exact ring the decoder keeps (initial
  {4,11,15,16}, pushed after every real back-reference, NOT after short code 0). The matcher,
  commands, and prefix codes are reused unchanged from E3. Done in
  `rnd/0.5.x/brotli_encoder_dist_poc.zig`, 9 unit tests pass (ring-code mapping, fixed-width
  records, interleaved periods, run, binary). Interop gate
  `rnd/0.5.x/verify-brotli-encoder-dist.sh` (doc `verify-brotli-encoder-dist.md`): 4/4 decode
  byte-exact through `brotli -dc`. Ring win on structured data (csv 1025 -> 583, about 43
  percent). On high-distance-variety text it is a few bytes larger (the fixed balanced
  distance tree dilutes), which E5's optimal codes remove.
- [x] E5: dynamic prefix codes (optimal Huffman). All three trees (literal, command,
  distance) are now optimal length-limited Huffman codes built from the real symbol
  frequencies (sec 3.2): an exact merge for lengths, the 15-bit cap via the standard overflow
  redistribution, assigned shortest-to-most-frequent, emitted with E2's complex-code writer.
  The matcher, ring distances, and command machinery are reused from E3 / E4. Done in
  `rnd/0.5.x/brotli_encoder_huff_poc.zig`, 11 unit tests pass (kraft-sum completeness, 15-bit
  cap on a skewed alphabet, skewed literals, full alphabet, binary, run). Interop gate
  `rnd/0.5.x/verify-brotli-encoder-huff.sh` (doc `verify-brotli-encoder-huff.md`): 4/4 decode
  byte-exact through `brotli -dc`; README-en.md 32267 (E4) -> 28982 (E5), within about 4
  percent of `brotli -q 5` (27806); src/lib.zig and CSV similar.
  E5 sub-step literal CONTEXT MODELING (NTREESL > 1 with a context map, sec 7) is now
  PARTIALLY done in the integrated codec (`src/utils/compression/brotli.zig`): a UTF8
  context mode with per-context literal trees, assigned by populous-context clustering
  (a context with at least 256 literals earns its own tree, the rest share tree 0), with
  the encoder-side context-map writer. It is gated in `compressQualityAlloc` (q >= 5) to be
  kept only when smaller, so it never enlarges a body, and is interop-verified through
  `brotli -dc`. Measured gain is about 0.5 percent on multi-KB text (the coarse clustering
  folds most literals into the shared tree). The remaining follow-on is histogram-similarity
  context clustering (merge the 64 contexts into a few well-fit trees), the lever that gives
  brotli its larger text win.
- [x] E6: static dictionary references (identity transform). A copy can reference a word in
  the 122,784-byte Appendix A dictionary instead of earlier output (sec 8): the decoder reads
  word_id = distance - (max_allowed + 1), so for the identity transform distance = word_index
  + max_allowed + 1 with max_allowed = min(window, output position). It is sent with the
  ordinary distance code and is NOT pushed to the last-distance ring. The encoder builds a
  4-byte-prefix hash index over the identity words and, at each position, takes the longer of
  the local match and the dictionary word. Done in `rnd/0.5.x/brotli_encoder_dictref_poc.zig`,
  9 unit tests pass (index lookup against a real word, English texts, dict-then-self-ref,
  binary, full alphabet). Interop gate `rnd/0.5.x/verify-brotli-encoder-dictref.sh` (doc
  `verify-brotli-encoder-dictref.md`): 4/4 decode byte-exact through `brotli -dc`; short text
  wins (74-byte text 113 -> 53). Scope: IDENTITY transform only. The 120 case / prefix /
  suffix transforms are a later refinement.
- [x] E7: quality levels + never-expand fallback. The public front-end
  `compressBrotliAlloc(input, quality 0..11, wbits)`: quality maps to encoder effort (q0
  greedy no-dictionary, higher q widens the hash-chain walk and turns the dictionary on,
  bounded chain depth at the top since a response compressor wants a modest level). The
  encoder always also produces an E1 store-only stream and returns the smaller, so output
  never grows past the input plus the store header. With the dictionary on it also encodes a
  no-dictionary variant and keeps the smaller (a dictionary reference can cost more than
  literals when the word repeats locally). Done in `rnd/0.5.x/brotli_encoder_quality_poc.zig`,
  7 unit tests pass (ladder monotonic, round-trip at every quality, random never-expands,
  high q no worse than q0, binary, long repetitive). Interop gate
  `rnd/0.5.x/verify-brotli-encoder-quality.sh` (doc `verify-brotli-encoder-quality.md`): 20/20
  (4 inputs x 5 qualities) decode byte-exact through `brotli -dc` and never expand; README-en.md
  about 28 KB at q5, random stays at input size. Remaining E7 refinement (carried forward):
  block splitting (several meta-blocks with their own trees in one stream).

## Integration (into zix)

- [x] I1: `src/utils/compression/brotli.zig` consolidates the decoder (D1..D7) and the
  encoder (E1..E7) into one in-tree codec, with `compressBrotliAlloc` /
  `decompressBrotliAlloc` matching the gzip/deflate signatures in `flate.zig` (plus
  `compressQualityAlloc`, `compressBound`, and a shared `Level`). The 122,784-byte static
  dictionary rides alongside as `brotli_dictionary.bin` (`@embedFile`). Registered in
  `src/lib.zig` test discovery, in-code tests pass.
  - Caller-buffer parity (2026-06-28): `compressBrotli` / `decompressBrotli` added so the codec
    mirrors `flate.zig`'s full four-function shape (a buffer-into and an alloc variant in each
    direction). brotli's variants take an allocator for scratch, since its encoder and decoder are
    heap-backed, and report `error.BufferTooSmall` on overflow to match the gzip side. The one
    honest divergence: `decompressBrotli` needs an allocator where `decompressGzip` does not.
    `EncodeError` / `DecodeError` gained `BufferTooSmall`, and `flate.zig` gained matching named
    `EncodeError` / `DecodeError` so both modules read alike. `compressBound` documents the
    guarantee difference (brotli never expands, flate can). Edge, behaviour, and integration tests
    cover the new variants (boundary `BufferTooSmall`, binary-safe, buffer-vs-alloc equality,
    cross-variant interop).
- [x] I2: `compression.zig` `.BR` encode/decode arms now call the real codec, and `.BR`
  leads `supported_default` (preferred over gzip on text). The facade tests cover the BR
  round-trip and the new preference order. Both `writeNegotiated` (Http1) and
  `sendNegotiated` (Http) serve `Content-Encoding: br` end to end, verified with `curl`
  plus `brotli -dc`.
- [x] I3: gate-neutral. Compression stays opt-in (`compression = true`), so the 64c URING
  raw bench is untouched. Brotli pays off only on a real NIC (bandwidth-bound). The
  encoder builds its dictionary index per call on the heap (the static dictionary is
  `@embedFile` `.rodata`, not stack), so there is no per-worker stack bump like flate's
  230 KB `Compress`.
- [x] I4: interop both directions versus the `brotli` CLI. Encode: 20/20 (4 inputs x 5
  qualities) decode byte-exact through `brotli -dc` and never expand. Decode: 48/48
  (3 inputs x q0/5/9/11 x w10/18/22/24) of `brotli -c` streams round-trip byte-exact. The
  example test-runner (`http1_compression_runner.zig`, reused for both 9058 and 9059)
  adds a `br` case alongside gzip / deflate / identity.

## Order and effort

Decoder D1..D7 first (D1 done), then encoder E1..E7, then integration. The decoder is
the smaller, fully-specified half and de-risks the dictionary. The encoder quality work
(E5..E7) is the long pole. None of this is benchmark-gated, so it is do-now lane work
(the do-now Work lanes), it only meets the hard gate at integration (I3).
