# Verify: QUIC frame parse + type rules (http3-plan.md phase Q2)

Q1 gave the base codec. Q2 reads frames out of a packet payload and enforces the two framing rules
an endpoint MUST apply: an unknown frame type is a FRAME_ENCODING_ERROR, and a known frame in a
packet type that does not permit it is a PROTOCOL_VIOLATION.

## Oracle

RFC 9000 section 12.4 / 12.5 + section 19:

- Section 19 fixes each frame's field layout. The PoC parses PADDING (coalesced run), PING, CRYPTO
  (offset + data), and STREAM, where the three low type bits (OFF 0x04, LEN 0x02, FIN 0x01) decide
  which fields are present. 0x08 carries data to the end of the packet at offset 0, 0x0f carries an
  explicit offset and length and marks the stream final.
- Section 12.4 fixes the type rules: an unknown type is a FRAME_ENCODING_ERROR, a frame type encoded
  on more than its shortest length is a PROTOCOL_VIOLATION, and an empty NEW_TOKEN is a
  FRAME_ENCODING_ERROR (19.7).
- Section 12.5 + the Table 3 "Pkts" column fix the number-space permission matrix (I / H / 0 / 1).
  The PoC checks the boundaries: ACK and CRYPTO are barred from 0-RTT, STREAM and MAX_DATA from
  Initial, NEW_TOKEN / HANDSHAKE_DONE / PATH_RESPONSE are 1-RTT only, and CONNECTION_CLOSE 0x1c is
  allowed in Initial while 0x1d is not.

No external tool is used at this layer, the same as Q1: crafted frames are parsed in process. From
phase T (handshake) onward the oracle becomes curl --http3 and the QUIC Interop Runner.

## Run

```sh
bash rnd/0.5.x/verify-quic-transport-q2.sh
```

## Expect

The PoC checks 32 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| 19 frame parse | PADDING, PING, CRYPTO, STREAM 0x08 + 0x0f field layouts |
| 12.4 type rules | unknown -> FRAME_ENCODING_ERROR, non-minimal -> PROTOCOL_VIOLATION, empty NEW_TOKEN |
| 12.5 / Table 3 | permission matrix boundaries across Initial / Handshake / 0-RTT / 1-RTT |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` and exits non-zero.
