# Verify: QUIC flow control + ACK + path (http3-plan.md phase Q4)

Q3 gave the stream and connection-id state. Q4 adds the three control mechanisms that keep a
connection live and bounded: flow control (the receiver-advertised byte limits), acknowledgement
(the ACK frame and its relative range encoding), and path validation (the PATH_CHALLENGE /
PATH_RESPONSE echo).

## Oracle

RFC 9000 section 4 + section 19.3 + section 19.17 / 19.18:

- Section 4.1 fixes flow control at two levels (per stream and per connection). A sender MUST NOT
  exceed an advertised limit, a receiver MUST close with FLOW_CONTROL_ERROR when it does, and a
  MAX_DATA / MAX_STREAM_DATA advertisement only ever increases the limit (a smaller value is
  ignored).
- Section 19.3.1 fixes the ACK range arithmetic: the first range's smallest is largest minus First
  ACK Range, each later range's largest is the previous smallest minus Gap minus 2, and any negative
  computed packet number is a FRAME_ENCODING_ERROR. ACK Delay is decoded by shifting left by the
  peer's ack_delay_exponent, and ECN counts are present only for the 0x03 type.
- Section 19.17 / 19.18 fix the 8-byte path data: a PATH_RESPONSE MUST echo the PATH_CHALLENGE data,
  and a mismatch is grounds for a PROTOCOL_VIOLATION.

Crafted frames and byte counts are exercised in process, the same as the other Q phases. From phase
T (handshake) onward the oracle becomes curl --http3 and the QUIC Interop Runner.

## Run

```sh
bash rnd/0.5.x/verify-quic-transport-q4.sh
```

## Expect

The PoC checks 20 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| 4.1 flow control | within / past limit (stream + connection), raise + ignore-smaller advertisement |
| 19.3 ACK | single range, multi range with gap, ECN counts, delay decode, negative-range reject |
| 19.17 / 19.18 path | challenge parse, matching echo validates, mismatch fails, wrong-type reject |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` and exits non-zero.
