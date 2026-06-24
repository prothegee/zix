# Verify: HTTP/3 GOAWAY + direction + error codes (http3-plan.md phase H3)

H1 framed the streams, H2 validated the messages. H3 closes the deterministic HTTP/3 layer with
connection lifecycle and the error vocabulary: GOAWAY ordering, the client-only / server-only frame
rules, and the full set of error codes.

## Oracle

RFC 9114 section 5.2 + 7.2.7 / 7.2.5 + 8.1:

- 5.2 fixes GOAWAY monotonicity: each received identifier MUST NOT be greater than any previous one,
  and a larger one is H3_ID_ERROR. The PoC walks a decreasing sequence and rejects an increase.
- 7.2.7 fixes that MAX_PUSH_ID is sent only by clients and its value only increases (a decrease is
  H3_ID_ERROR); a server MUST NOT send it. 7.2.5 fixes that PUSH_PROMISE is server-only. A
  wrong-direction frame is H3_FRAME_UNEXPECTED at the receiver.
- 8.1 fixes the seventeen error code values (H3_NO_ERROR 0x0100 through H3_VERSION_FALLBACK 0x0110)
  and the reserved grease range (0x1f * N + 0x21) that a receiver MUST treat as H3_NO_ERROR.

No external tool is used at this layer. The live curl --http3 round trip comes with Layer I.

## Run

```sh
bash rnd/0.5.x/verify-http3-h3.sh
```

## Expect

The PoC checks 30 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| 5.2 GOAWAY | first / lower / equal accepted, larger rejected |
| 7.2.7 / 7.2.5 direction | MAX_PUSH_ID client-only, PUSH_PROMISE server-only |
| 7.2.7 MAX_PUSH_ID | increase accepted, decrease rejected |
| 8.1 error codes | all seventeen values, grease range maps to H3_NO_ERROR |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` and exits non-zero.
