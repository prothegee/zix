# gRPC Stream Bug Report — zix 0.2.0

## Bug 1: `sendGrpcError` missing `content-type` header

**Location:** `src/tcp/http2/grpc/frame.zig:81`

**Description:**

`sendGrpcError` sends a trailers-only error response with `:status: 200`,
`grpc-status`, and `grpc-message`, but omits `content-type`. The gRPC spec
requires `content-type: application/grpc[+format]` in every HEADERS frame,
including trailers-only error responses. Spec-compliant clients (ghz, grpc-go)
reject the response with:

```
rpc error: code = Unknown desc = malformed header: missing HTTP content-type
```

**Root cause:**

`sendGrpcHeaders` (the normal success path) includes `content-type`. `sendGrpcError`
(the error path) does not:

```zig
// sendGrpcHeaders — correct
try hpack_enc.writeHeader(":status", "200");
try hpack_enc.writeHeader("content-type", content_type);

// sendGrpcError — missing content-type
try hpack_enc.writeHeader(":status", "200");
try hpack_enc.writeHeader("grpc-status", status_s);
```

**Fix:**

Add `content-type: application/grpc+proto` after `:status` in `sendGrpcError`.

**Reproduce (Bug 1 in isolation):**

Build and start the server:

```sh
zig build bug-grpc_error_response_server
./zig-out/bin/bug-grpc_error_response_server
```

Send one request with ghz:

```sh
# run from the root project
ghz --insecure \
--proto rnd/bug-0.2.x/bug.proto \
--call bug.BugService.Trigger \
-d '{}' -c 1 -n 1 \
127.0.0.1:9091
```

**Expected output (unpatched):**

```
Summary:
  Count:    1
  Failed:   1

Error Distribution:
  [1]   rpc error: code = Unknown desc = malformed header: missing HTTP content-type
```

**Expected output (after fix):**

```
Summary:
  Count:    1
  Failed:   0

Status code distribution:
  [1]   OK
```

---

## Bug 2: Blocking dispatch freezes the h2 read loop under concurrent streams

**Location:** `src/tcp/http2/grpc/core.zig:541`

**Description:**

`dispatchGrpcStream` is called synchronously inside `serveGrpcLoop`. A handler
that writes many response frames (server-streaming RPC) holds the thread for the
entire duration. While the handler runs, no h2 frames can be read from the
connection.

Under concurrent load on the same connection, concurrent workers send HEADERS and
DATA frames that accumulate in the TCP receive buffer. The server's TCP send buffer
fills (flow control backpressure), writes stall, and neither side can make
progress — full deadlock.

When the connection degrades, subsequent streams are dispatched with `body_len = 0`
because their DATA frame either never arrived or the stream slot was in an
inconsistent state when the loop unblocked. `recvMessage()` returns null, the
handler calls `ctx.finish(.INVALID_ARGUMENT)`, which then triggers Bug 1.

**Root cause:**

```zig
// core.zig:541 — dispatch is synchronous, freezes the read loop
if (s.end_stream) {
    dispatchGrpcStream(routes, s, fd, opts);
    stream_slots[slot] = false;
}
```

**Fix:**

Dispatch each stream's handler on a separate thread so the read loop keeps
running while handlers write responses. Proper h2 per-stream and connection-level
flow control must also be maintained across concurrent writes.

**Reproduce:**

Build and start the server:

```sh
zig build bug-grpc_stream_concurrent_server
./zig-out/bin/bug-grpc_stream_concurrent_server
```

Send concurrent requests with ghz:

```sh
# run from the root project
ghz --insecure \
--proto rnd/bug-0.2.x/bug.proto \
--call bug.BugService.Stream \
-d '{}' \
--connections 2 -c 8 -z 5s \
127.0.0.1:9092
```

**Expected output (unpatched):**

```
Summary:
  Count:    ~200+
  Failed:   ~100%

Error Distribution:
  [~100%]   rpc error: code = Unknown desc = ...
```

Single-stream baseline to confirm server is reachable (should pass):

```sh
# run from the root project
ghz --insecure \
--proto rnd/bug-0.2.x/bug.proto \
--call bug.BugService.Stream \
-d '{}' -c 1 -n 5 \
127.0.0.1:9092
```

**Expected output (single-stream baseline):**

```
Summary:
  Count:    5
  Failed:   0

Status code distribution:
  [5]   OK
```

**Expected output (after fix):**

```
Summary:
  Count:    ~200+
  Failed:   0

Status code distribution:
  [~100%]   OK
```

---

## Relationship

Bug 2 produces the empty-body condition. The handler takes the early-exit path and
calls `ctx.finish(.INVALID_ARGUMENT)`. Because `_hdr_sent = false`, `finish` calls
`sendGrpcError`, which then triggers Bug 1. Bug 1 also surfaces independently on
any request that arrives with no body (HEADERS+END_STREAM, no DATA frame).

**Fix priority:** Bug 1 is a one-line fix with no architectural change. Bug 2
requires threaded or async per-stream dispatch and is the larger item.

---

## Test

See `bug/0.2.x/grpc_stream_test.zig` for unit-level reproduction of both paths.
Both tests are expected to fail on unpatched zix 0.2.0.
