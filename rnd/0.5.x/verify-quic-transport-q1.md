# Verify: QUIC transport base codec (http3-plan.md phase Q1)

Layer C proved the crypto is byte-exact. Layer Q builds the wire format on top, and Q1 is the base
codec everything above reads through: the variable-length integer (every QUIC length / id / offset),
the truncated packet number, and the header parse that splits a datagram into its fields.

## Oracle

RFC 9000 section 16 / 17 + Appendix A:

- A.1 publishes four variable-length integer decodings (8 / 4 / 2 / 1 byte) plus a non-minimal
  two-byte form of 37. Decode matches all five, encode reproduces the minimal bytes, and the Table 4
  length boundaries (63 / 64, 16383 / 16384, 2^30-1 / 2^30) are checked.
- A.2 publishes two packet-number encoding-length examples (0xac5c02 needs 2 bytes, 0xace8fe needs
  3, both against largest-acked 0xabe8b3). A.3 publishes a decode (largest 0xa82f30ea, 16-bit
  truncated 0x9b32 recovers 0xa82f9b32).
- The header cases are crafted from the section 17 field diagrams and check the version-1
  invariants: Fixed Bit MUST be 1 (else discard), and a long-header connection ID length MUST NOT
  exceed 20 (else drop the packet). Long and short headers are split into their fields and the
  rejection paths are exercised.

No external tool is used at this layer, the same as Layer C: crafted packets are parsed in process.
From phase T (handshake) onward the oracle becomes curl --http3 and the QUIC Interop Runner.

## Run

```sh
bash rnd/0.5.x/verify-quic-transport-q1.sh
```

## Expect

The PoC checks 34 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| A.1 varint decode | 8 / 4 / 2 / 1 byte values, non-minimal form + length |
| 16 varint encode | minimal bytes for the four values, six Table 4 length boundaries |
| A.2 / A.3 packet number | two encode lengths, one decode |
| 17.2 long header | type / version / DCID / SCID / payload, fixed-bit-zero + 21-byte-CID rejects |
| 17.3 short header | spin / key phase / pn length / DCID / payload, fixed-bit-zero reject |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` with want / got and exits
non-zero.
