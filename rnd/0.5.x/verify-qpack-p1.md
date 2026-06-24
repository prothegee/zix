# Verify: QPACK static half (http3-plan.md phase P1)

QPACK is HTTP/3's header compression. P1 is the static half: the prefixed-integer codec every
representation rides on, the read-only static table, the two unidirectional stream types, and the
field line representations that reference only the static table. The dynamic table and its
synchronization arrive in P2 / P3.

## Oracle

RFC 9204 section 4.1.1 / 4.2 / 4.5 / Appendix A, plus RFC 7541 Appendix C.1:

- 4.1.1 reuses the HPACK prefixed integer (RFC 7541 5.1) unmodified. The C.1 vectors are checked:
  10 and 1337 on a 5-bit prefix, 42 on an 8-bit prefix, decode and encode, plus a 2^62-1 round trip
  (QPACK MUST decode up to 62 bits).
- Appendix A fixes the static table. The PoC carries the leading subset (indices 0..28, every
  pseudo-header) and checks :authority, :path, :method GET, :scheme https, :status 200. The engine
  carries all 99 entries.
- 4.2 fixes the two unidirectional stream types: encoder 0x02, decoder 0x03, at most one of each. A
  second instance is an H3_STREAM_CREATION_ERROR.
- 4.5 fixes the field line representations. With no dynamic table the Encoded Field Section Prefix is
  Required Insert Count 0 / Base 0 (two zero bytes). The PoC decodes Indexed Field Lines against the
  static table (0xc1 -> :path, 0xd1 -> :method GET, 0xd9 -> :status 200), round-trips the encode, and
  decodes a Literal Field Line with Name Reference (name :authority, literal value). Huffman string
  literals are detected by flag but decoded in a later phase.

No external tool is used at this layer. P4 is where the cross-implementation .qif interop begins.

## Run

```sh
bash rnd/0.5.x/verify-qpack-p1.sh
```

## Expect

The PoC checks 24 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| C.1 prefixed integers | decode + encode 10 / 1337 / 42, 2^62-1 round trip |
| Appendix A static table | five entry lookups including pseudo-headers |
| 4.2 streams | encoder 0x02, decoder 0x03, at most one each (second -> error) |
| 4.5 representations | static prefix RIC 0 / Base 0, indexed lines, literal name reference |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` and exits non-zero.
