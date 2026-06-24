# Verify: QPACK decoder feedback + error codes (http3-plan.md phase P3)

P1 / P2 built the tables. P3 is the feedback channel: the decoder-stream instructions that tell the
encoder what the decoder has processed, so both ends keep a consistent view of the dynamic table.

## Oracle

RFC 9204 section 4.4 + section 6:

- 4.4 fixes the three decoder instructions, told apart by their leading bits and each carrying a
  prefixed integer: Section Acknowledgment ('1', 7-bit stream id), Stream Cancellation ('01', 6-bit
  stream id), Insert Count Increment ('00', 6-bit increment). The PoC encodes and decodes each,
  including a stream id (200) that overflows the 7-bit prefix into a continuation byte, and confirms
  an Insert Count Increment of zero is a QPACK_DECODER_STREAM_ERROR (4.4.3).
- Section 6 fixes the three QPACK error codes in the HTTP/3 Error Codes registry:
  QPACK_DECOMPRESSION_FAILED (0x0200), QPACK_ENCODER_STREAM_ERROR (0x0201),
  QPACK_DECODER_STREAM_ERROR (0x0202).

No external tool is used at this layer. P4 is where the cross-implementation .qif interop begins.

## Run

```sh
bash rnd/0.5.x/verify-qpack-p3.sh
```

## Expect

The PoC checks 12 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| 4.4 encode | Section Ack (single + continuation), Stream Cancellation, Insert Count Increment |
| 4.4 decode | leading-bit discrimination of all three, zero-increment reject |
| section 6 error codes | 0x0200 / 0x0201 / 0x0202 |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` and exits non-zero.
