# Verify: QUIC streams + connection IDs (http3-plan.md phase Q3)

Q1 / Q2 handled bytes and frames. Q3 is the first stateful layer: the stream id namespace, the
send / receive state machines a stream walks through, and the connection-id pool bounded by
active_connection_id_limit. These are the rules that decide whether an arriving frame is legal for
the stream it names.

## Oracle

RFC 9000 section 2.1 + section 3 + section 5.1.1 / 19.15:

- Section 2.1 Table 1 fixes the four stream types from the two low id bits: bit 0x01 is the
  initiator (client even, server odd), bit 0x02 the directionality (bidi 0, uni 1). The PoC checks
  ids 0..3, the maximum 62-bit id, and the varint carriage.
- Section 3 Figures 2 / 3 fix the send and receive state machines. The PoC walks the legal edges to
  the terminal states (Data Recvd / Reset Recvd for sending, Data Read / Reset Read for receiving)
  and confirms illegal events in a state produce no transition.
- Section 19.15 fixes NEW_CONNECTION_ID validation: connection ID length MUST be 1..20 and Retire
  Prior To MUST be <= Sequence Number, both FRAME_ENCODING_ERROR otherwise. Section 5.1.1 fixes the
  active-count rule: exceeding active_connection_id_limit is a CONNECTION_ID_LIMIT_ERROR, and a
  Retire Prior To only advances (a non-increasing value is ignored).

No external tool is used at this layer, the same as Q1 / Q2. From phase T (handshake) onward the
oracle becomes curl --http3 and the QUIC Interop Runner.

## Run

```sh
bash rnd/0.5.x/verify-quic-transport-q3.sh
```

## Expect

The PoC checks 29 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| 2.1 stream ids | four Table 1 types, max id, initiator / directionality bits, varint |
| 3.1 sending states | legal edges to terminal, terminal + illegal-event rejects |
| 3.2 receiving states | legal edges to terminal, terminal + illegal-event rejects |
| 19.15 / 5.1.1 conn ids | parse + length / retire validation, limit error, retire floor monotonic |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` and exits non-zero.
