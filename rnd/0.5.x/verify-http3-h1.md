# Verify: HTTP/3 stream mapping + frames (http3-plan.md phase H1)

QPACK (Layer P) compresses the headers; HTTP/3 (Layer H) is the framing that carries them. H1 is the
stream and frame structure: the control stream, the SETTINGS-first rule, the frame type values, the
frame-per-stream permission matrix, and the legal frame order within a request.

## Oracle

RFC 9114 section 6.2 + section 7.2:

- 6.2 fixes the unidirectional stream types: control 0x00, push 0x01 (QPACK adds encoder 0x02,
  decoder 0x03). 6.2.1 fixes the control-stream invariants: exactly one control stream (a second is
  H3_STREAM_CREATION_ERROR) and SETTINGS as its first frame (any other first frame is
  H3_MISSING_SETTINGS).
- 7.2 fixes the seven frame type values (DATA 0x00, HEADERS 0x01, CANCEL_PUSH 0x03, SETTINGS 0x04,
  PUSH_PROMISE 0x05, GOAWAY 0x07, MAX_PUSH_ID 0x0d) and which frames are legal on which stream.
  SETTINGS / GOAWAY / MAX_PUSH_ID / CANCEL_PUSH belong on the control stream, HEADERS / DATA /
  PUSH_PROMISE on a request stream. A frame on the wrong stream is H3_FRAME_UNEXPECTED.
- 4.1 fixes the request frame order: a HEADERS, then optional DATA, then an optional trailing
  HEADERS. DATA before any HEADERS, or any frame after the trailing HEADERS, is H3_FRAME_UNEXPECTED.

No external tool is used at this layer. The live curl --http3 round trip comes with Layer I.

## Run

```sh
bash rnd/0.5.x/verify-http3-h1.sh
```

## Expect

The PoC checks 24 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| 7.2 frame values | seven frame type values |
| 6.2 stream types | control / push / QPACK encoder + decoder |
| 6.2.1 control stream | SETTINGS first, second-stream + missing-settings rejects |
| 7.2 frame matrix | control vs request permission for SETTINGS / HEADERS / DATA / GOAWAY / MAX_PUSH_ID |
| 4.1 request sequence | HEADERS -> DATA -> trailer, DATA-before-HEADERS + after-trailer rejects |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` and exits non-zero.
