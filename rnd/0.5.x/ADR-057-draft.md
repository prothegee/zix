# ADR-057 (accepted record)

Records the gRPC server-streaming DATA-frame coalescing: consecutive messages pack into fewer,
larger HTTP/2 DATA frames on the mux cork path, capped at 16 KiB per frame. Folded into the public
ADR docs (en and id) as the accepted ADR-057, kept here as the record.

## Status

Accepted. Landed in the shared `muxDispatch`, so `.URING`, `.EPOLL`, and both TLS mux paths inherit
it in one change. The thread path (`.ASYNC` / `.POOL` / `.MIXED`) still emits one frame per message
(no cork to pack into), deferred as an open item.

## Context

Server-streaming emitted one DATA frame per message: a 9-byte frame header plus a 5-byte gRPC
prefix per payload, so a `count = 5000` reply was 5000 tiny frames, about 45 KiB of headers, and
5000 frame parses on the peer. The streaming cells left the server at 5 to 10 percent CPU, idle:
the wall was the peer's per-frame parse cost, not the server's send. A first attempt (growing the
reply cork to avoid a mid-handler blocking flush) did not move throughput and was reverted, the
worker was never parked on that flush.

## Decision

`GrpcContext` gains an optional coalesce buffer (`_coal`), installed by `muxDispatch` for a
server-streaming route. `sendMessage` packs each gRPC-framed message into the buffer and emits one
DATA frame per `grpc_stream_coalesce_cap` (16 KiB, the HTTP/2 default `SETTINGS_MAX_FRAME_SIZE`),
flushing the remainder at `finish()`. The frame length is known before the frame is written (pack,
then emit), so no back-patch and the cork may flush freely between frames. Unary keeps one frame
per message (`_coal` null), byte-for-byte unchanged.

## Consequences

- Streaming throughput rose about 44 to 50 percent (roughly 2.3M to 3.4M messages per second) with
  the server still at roughly 6 to 9 percent CPU: the peer parses about 1600x fewer frames.
- The 16 KiB cap keeps every emitted frame inside a client's default max frame size, and the
  message stream inside the DATA payload is unchanged (a conformant client reassembles
  length-prefixed messages regardless of frame boundaries).
- The bundled `zix.Grpc.Client` drains multiple messages from one DATA frame to match.
- Open: the thread path needs its own per-context accumulator to coalesce.
