# LLD: zix.Grpc (h2c gRPC)

Internal implementation details. For design rationale see [`docs/hld-grpc-en.md`](hld-grpc-en.md) and ADR-031.

The blocking model (`.ASYNC`) uses one connection path (`serve.serveConn` -> `serveLoop`). The `.EPOLL` model is a separate, multiplexed, non-blocking path (`grpcMuxOnReadable`) that owns the bulk of this document.

Every route-table-dependent internal function below still takes `comptime RouterType: type` (ADR-063), not a flattened runtime `handler: HandlerFn` like Http2's equivalents. This is deliberate: the engine reads `Route.is_server_streaming` off `RouterType.route_slice` before invoking the handler, to pick sync-inline vs task-spawn dispatch, and a bare `HandlerFn` pointer cannot carry that metadata. See `docs/hld-grpc-en.md`'s Handler Pattern section for the measured cost of losing it.

---

## Core files

| File | Role |
| :- | :- |
| `Context.zig` | per-call state: request messages, reply verbs, deadline, cache verbs |
| `Request.zig`, `Response.zig` | thin views over `Context` |
| `handler.zig` | `HandlerFn`, `invoke` (the one handler call site), `completeHandlerError`, `rpcStart` / `writeRpcRecord` |
| `router.zig` | `Route`, `Router`, `routeIsStreaming` |
| `serve.zig` | `serveConn`: preface or h2c upgrade, then `serveLoop` |
| `stream_dispatch.zig` | `dispatchWhole` (content-length check), `dispatchStream`, `dispatchInline` |
| `DispatchTask.zig` | one server-streaming call on its own task |
| `ReplyStage.zig`, `ConnReader.zig`, `ConnMutex.zig` | cork buffer, buffered frame reader, connection write lock |
| `Stream.zig`, `stream_slot.zig` | one request stream, stream table claim / find / in-flight |
| `deadline.zig`, `encoding.zig`, `cache.zig`, `path.zig`, `content_type.zig`, `window.zig` | deadline, gzip headers, response cache key, path split, content-type, window sizes |

### Context

The per-call handler state. `Request` (`header`, `recvMessage`) and `Response` (`sendHeaders` / `sendMessage` / `finish` / `serveCached` / `sendCached`) are thin wrappers holding a `*Context` pointer, one-line delegations to the methods below: the public trio (ADR-063) adds no new logic here. Fields relevant to output:

```zig
fd: std.posix.fd_t,
stream_id: u31,
deadline: ?std.Io.Clock.Timestamp = null,
_hdr_sent: bool = false,
_write_mutex: ?*ConnMutex = null,   // streaming task only, null on the inline and mux paths
_out: ?*ReplyStage = null,          // set on the inline and mux paths: stage instead of write
```

`sendMessage` / `sendHeaders` / `finish` branch on `_out`: when it is set they append the encoded frames to the cork (no per-call lock, no direct `write`). When it is null they write directly to the fd, taking `_write_mutex` when it is set. A streaming DATA frame of up to 4096 bytes (head plus payload) leaves in one write, a larger one in two.

Errors are `ZixHttp2_GrpcContext_*` (`BrokenPipe`, `UnexpectedEOF`, `Overflow`, `BufferFull`), translated to `ZixHttp2_GrpcResponse_*` by `Response`. A staged reply that already failed a write reports `BrokenPipe` on the next send. A content-type or grpc-message past the HPACK scratch is `BufferFull`.

`finishIfOpen` closes a call the handler left open, and leaves a finished call alone. `handler.invoke` calls it through `completeHandlerError` (INTERNAL, `handler error`) when the handler returns an error.

The per-worker unary response cache (ADR-036) lives in `cache.zig`: `tl_cache`, keyed by `requestKey(path, body)` (Wyhash over the gRPC path plus the raw request body). `Context.serveCached` looks up, replays via `sendMessage` and `finish(.OK, "")` on a hit, and returns false on a miss, no cache, or an empty path. `sendCached` sends then stores, skipping the store on the same conditions. The TTL clock is `nowMillis(ctx.io)`.

### Deadline

`deadline.computeDeadline(io, handler_timeout_ms, headers)` takes the tightest of the server budget and a valid `grpc-timeout` header. A `grpc-timeout` that does not parse is ignored. `Router.dispatch` then tightens it with `Route.timeout_ms` (`tightenMs`), so a route budget never loosens it.

### ReplyStage

A corked writer for one reply. Used by inline unary dispatch and by every dispatch on the mux path.

```zig
fd: std.posix.fd_t,
buf: []u8,                    // caller-owned backing, not an inline array
len: usize = 0,
failed: bool = false,         // set once a write failed, read by the next send

fn append(self, bytes) void   // flush first when it would overflow, a chunk past buf goes straight through
fn flush(self) void           // one writeAllFD of buf[0..len], len = 0
```

The inline path (`stream_dispatch.dispatchInline`) backs `buf` with a 4096-byte stack array (unary replies are small). The mux path backs it with the connection's 64 KB `stage_buf` (see `GrpcMuxConn`).

### ConnReader (blocking model)

Buffered frame reader used by `serveLoop`. `ensure(n)` blocks until `n` bytes are buffered (compacting when needed), `take(n)` returns and advances. `n` past the buffer is `TooLarge`, a peer that closes first is `Closed`.

### ConnMutex

Heap-allocated, ref-counted spinlock shared by the read loop and every streaming task of one connection. `active_streaming` counts the tasks writing now. The inline path takes the lock only while it is above 0. The last `release` frees it.

### DispatchTask

`spawn` deep-copies the stream's headers (rebased into its own 4 KiB scratch) and body (64 KiB, gunzipped first when the client sent `grpc-encoding: gzip`), so the read loop frees the slot at once. It runs on `opts.io` when set, on a detached thread otherwise. A call it cannot take is closed at once: INTERNAL when the task cannot be made or a header lies past the scratch, RESOURCE_EXHAUSTED when the body is past 64 KiB.

### Stream

Per-stream parse state. `body` and `header_scratch` are borrowed slices sized to `opts.max_body` / `opts.max_header_scratch`. On the multiplexed (`.EPOLL` / `.URING`) path a `Stream` is borrowed from a per-worker pool while open (`next_free` links it into the freelist while idle). On the blocking path each table entry points into per-connection backing.

```zig
id: u31 = 0,
state: StreamState = .IDLE,
headers: [frame.MAX_HEADERS]Header = undefined,
header_count: usize = 0,
body: []u8 = &.{},
body_len: usize = 0,
header_scratch: []u8 = &.{},
end_headers: bool = false,
end_stream: bool = false,
next_free: ?*Self = null,     // freelist link while idle in the per-worker pool
```

`open(sid)` resets it for a new stream, `appendBody` refuses a chunk past the body (nothing copied). The blocking path claims and finds entries with `stream_slot.claim` / `find`, both linear scans over `max_streams`.

### Flow-control constants (`window.zig`)

```zig
pub const STREAM_WINDOW_SIZE: u32 = 16 * 1024 * 1024;  // advertised SETTINGS_INITIAL_WINDOW_SIZE
pub const CONN_WINDOW_BUMP: u31 = 1 << 30;             // one-time connection window bump after handshake
pub const CONN_REPLENISH_THRESHOLD: usize = 1 << 29;   // bulk connection-window replenish point
```

Stream windows are large enough that small request bodies never need a per-DATA stream `WINDOW_UPDATE`. The connection window is bumped once and only replenished in bulk past the threshold.

### GrpcMuxConn (multiplexed `.EPOLL`)

Heap-owned per-connection state for the multiplexed model. One worker thread owns a `GrpcMuxConn` for its whole lifetime.

```zig
pub const GrpcMuxConn = struct {
    fd: std.posix.fd_t,
    opts: GrpcServeOpts,
    io: std.Io,                 // carried for the Context built at each muxDispatch, worker-wide

    rbuf: []u8,                 // read accumulator, persists across events, holds partial frames
    rstart: usize,
    rend: usize,

    hpack_dec: h2.HpackDecoder,
    streams: []*Stream,         // max_streams-wide pointer table, slots borrowed from the per-worker pool
    slots: []bool,
    last_stream_id: u31,
    conn_window_consumed: usize,
    phase: MuxPhase,            // await_preface | await_upgrade | await_preface2 | h2
    settings_frame: [33]u8,     // precomputed server SETTINGS, built once in init
    stage_buf: [65536]u8,       // 64 KB backing for stage
    stage: ReplyStage,          // stage.buf = &stage_buf

    pub fn init(fd, opts, io) ?*GrpcMuxConn   // one allocation per buffer; null on OOM
    pub fn deinit(self) void
};
```

`rbuf` is sized `max(32 KB, max_frame_size + 256 + 9)`.

`init` calls `buildSettingsFrame(&settings_frame, opts)` once to encode the 33-byte server SETTINGS blob (9-byte header + 4 params), and points `stage.buf` at the 64 KB `stage_buf`. The handshake appends `settings_frame` as-is (no per-connection encode loop). The 64 KB stage coalesces ~100 concurrent unary replies (~6 KB) into one write, and a server-streaming reply packs its messages into fewer, larger DATA frames (see `muxDispatch`), so even a ~5000-message reply stays well under the stage and leaves in one write.

### grpcMuxOnReadable(comptime RouterType, conn) -> GrpcConnOutcome

One readable event. Returns `.close` (peer closed, protocol error, or rejected handshake) or `.keep_alive`.

```
1. conn.stage.len = 0                  // reset the cork for this event
2. loop:
     a. compact rbuf if full / reset if empty
     b. if rbuf full and still no progress -> flush, return .close (frame larger than buffer)
     c. got = read(fd, rbuf[rend..])
          WouldBlock -> flush, return .keep_alive
          other error or 0 -> flush, return .close
     d. rend += got
     e. if muxProcess(RouterType, conn) == .close -> flush, return .close
```

Reads a chunk, processes complete frames, repeats until `EAGAIN`. Level-triggered epoll re-fires if more arrives.

### muxProcess(comptime RouterType, conn) -> GrpcConnOutcome

Handshake phase machine, then the frame loop.

- `await_preface`: need 3 bytes. If they are not `"PRI"`, set `await_upgrade` and call `muxHandleUpgrade`. Else need 24 bytes, validate the connection preface, stage server SETTINGS, set `h2`.
- `await_upgrade`: `muxHandleUpgrade`.
- `await_preface2`: after a `101`, validate the preface, stage SETTINGS, set `h2`.
- `h2`: `muxFrameLoop`.

### muxHandleUpgrade(conn)

Accumulate to `\r\n\r\n`. Without an `Upgrade: h2c` header, stage `400` and return `.close` (the validate probe path). With it, stage `101`, consume the request headers, set `await_preface2`, return `.keep_alive`. An initial request on stream 1 of the upgrade is not served (prior-knowledge clients do not use this path).

### muxFrameLoop(comptime RouterType, conn) -> GrpcConnOutcome

```
loop:
    if buffered < 9 -> return .keep_alive
    fh = parseFrameHeader(rbuf[rstart..][0..9])
    if fh.length > max_payload -> stage GOAWAY, return .close
    if buffered < 9 + fh.length -> return .keep_alive
    advance past header + payload
    switch fh.frame_type:
        SETTINGS  -> apply table size; stage SETTINGS ack + one CONN_WINDOW_BUMP
        PING      -> stage PING ack
        HEADERS   -> slotFor, hpack decode into stream.header_scratch; if END_HEADERS+END_STREAM -> muxDispatch, free slot
        CONTINUATION -> append decode; dispatch on END
        DATA      -> findSlot; bulk-replenish connection window past threshold; copy into stream.body; if END_STREAM -> muxDispatch, free slot
        RST_STREAM-> free slot
        GOAWAY    -> return .close
```

Control frames are staged via `muxStageFrame` / `muxStageWindowUpdate` / `muxStageGoaway` / `muxStageRst` / `muxStageServerSettings`, so they leave in the same coalesced write as the replies. `muxStageServerSettings` appends the precomputed `conn.settings_frame` (built once in `init` by `buildSettingsFrame`), not a fresh parameter encode.

### muxDispatch(comptime RouterType, conn, stream)

Builds a `Context` with `_out = &conn.stage` and `_write_mutex = null` (the worker owns the connection, so there is no concurrent writer), wraps it in a `Request` / `Response` pair (thin delegating views, zero extra logic), then calls `RouterType.dispatch(&req, &res, &ctx)`. Every route, unary and streaming, runs inline. Optional `logger.rpc` timing wraps the call.

Server-streaming replies coalesce at the gRPC layer. `muxDispatch` gives a streaming route a per-call coalesce buffer (`ctx._coal`), and `sendMessage` packs consecutive gRPC-framed messages into it, emitting one HTTP/2 DATA frame per `Context.STREAM_COALESCE_CAP` (16 KiB, the HTTP/2 default max frame size) instead of one DATA frame per message. A `count = 5000` reply drops from 5000 tiny DATA frames to about 3, cutting the frame-header bytes on the wire and the client's per-frame parse cost. Unary keeps one frame per message (`_coal` is null), so it is byte-for-byte unchanged.

For a streaming route (detected by `routeIsStreaming(RouterType.route_slice, path)`), the dispatch is wrapped in `setTcpCork(conn.fd, true)` / `setTcpCork(conn.fd, false)`: the kernel holds output until the MSS is full or cork clears, coalescing the multiple intermediate stage flushes a streaming handler produces into fewer TCP segments. Unary routes are not corked (they already leave in one write). `setTcpCork` is a no-op on non-Linux targets.

### Blocking path (serveConn / serveLoop)

Used by `.ASYNC`. `serveConn` sets `TCP_NODELAY`, then handles the h2c-direct preface or the h2c upgrade (`upgrade.accept` from Http2, stream 1 is answered inline before the loop), then `serveLoop`. The loop uses a blocking `ConnReader` and one frame switch. Every write goes through the connection `ConnMutex`. A finished stream goes to `stream_dispatch.dispatchWhole`: a body short of (or past) its content-length is reset with PROTOCOL_ERROR, a unary route runs inline (`dispatchInline`, staged in a stack `ReplyStage`), a server-streaming route runs on a `DispatchTask`. A body past `max_body` is closed with RESOURCE_EXHAUSTED. A peer that hangs up with a request in flight gets GOAWAY PROTOCOL_ERROR, an idle hang-up gets nothing.

---

## proto/

### varint.zig

7 value bits per byte, low bits first, top bit set while more bytes follow. A u64 takes at most `MAX_LEN` (10) bytes.

- `decodeVarint`: the 10th byte may only carry bit 0. More than that, or an 11th byte, is `Overflow`. Input that ends mid-varint is `UnexpectedEOF`.
- `encodeVarint`: checks room before each byte. On `BufferFull`, buf may hold a partial varint.

### field.zig

Tag = `(field_number << 3) | wire_type`. Each encoder writes the tag, then the value, and checks room before the payload. A negative int32 is sign-extended to 64 bits, so it encodes as a 10-byte varint (same as protobuf). Varint errors are translated to `ZixHttp2_GrpcField_*` at each public function.

### MessageReader.zig

`{ buf, pos }`. `next` reads one tag, then the value for its wire type, and moves `pos` past it. Every `payload` is a slice of `buf`, nothing is copied.

- A LEN length is checked against `buf.len - pos`, so a huge length is `UnexpectedEOF`, never an overflow of `pos + len`.
- A field number past u32 is `FieldNumberTooLarge`.
- Wire types 3, 4 (deprecated groups), 6, and 7 are `UnknownWireType`.

---

## frame/

### prefix.zig

`[compress: 1 byte][msg_len: 4 bytes, big-endian]`, `PREFIX_LEN` = 5. Any non-zero compress byte reads as compressed. A body shorter than 5 bytes is `TooShort`.

### build.zig / send.zig

`build*` encode a frame into a caller buffer and return the byte count. `send*` build into a stack buffer and write it with `writeAllFD`.

```zig
pub fn buildGrpcHeaders(out, stream_id, content_type) Error!usize            // initial HEADERS, no END_STREAM
pub fn buildGrpcHeadersGzip(out, stream_id, content_type) Error!usize        // same, plus grpc-encoding: gzip
pub fn buildGrpcDataHeader(out, stream_id, msg_len, compress) Error!usize    // DATA_HEAD_LEN: 9-byte DATA header + 5-byte prefix (caller appends payload)
pub fn buildGrpcTrailer(out, stream_id, grpc_status, msg) Error!usize        // trailer HEADERS, END_STREAM
pub fn buildGrpcError(out, stream_id, grpc_status, msg) Error!usize          // trailers-only HEADERS, END_STREAM
```

- `HEADERS_FRAME_SCRATCH` (frame header + `HPACK_ENCODE_SCRATCH`) always fits a HEADERS frame built here.
- A block past the HPACK scratch, or an `out` too small, is `BufferFull`. A `msg_len` past `MAX_DATA_MSG_LEN` (u24 max minus the prefix) is `Overflow`.
- `send*` errors are translated to `ZixHttp2_GrpcSend_*` at each public function.

### reply_block.zig

The two constant hot-path header blocks are HPACK-encoded once at comptime:

```zig
pub const GRPC_CONTENT_TYPE = "application/grpc+proto";
pub const HEADERS_PROTO_BLOCK: []const u8 = ...;  // :status 200 + content-type application/grpc+proto
pub const TRAILER_OK_BLOCK: []const u8 = ...;     // grpc-status 0
```

`buildGrpcHeaders` takes `HEADERS_PROTO_BLOCK` when `content_type == GRPC_CONTENT_TYPE`, and `buildGrpcTrailer` takes `TRAILER_OK_BLOCK` when `grpc_status == 0` and the message is empty. Both stamp the 9-byte frame header and copy the cached block, with no HPACK encoder run. Any other content-type or status runs the encoder.

The blocks come from the real `HpackEncoder` run at comptime, so they are byte-identical to the dynamic output.

### gzip.zig

- `decompressGrpcBody`: walks every prefix + message. A message with flag 1 is gunzipped in full (`streamRemaining`), flag 0 is copied. Every output prefix has flag 0. Fewer than 5 bytes left after the last message are ignored.
- `compressGrpcMessage`: gzip at `level_1`. The window and the compressor state come from `std.heap.smp_allocator`. `out_buf` of `data.len + GZIP_FRAMING_HEADROOM` always fits.

---

## timeout.zig

`parseTimeout` reads `<digits><unit>` and returns nanoseconds. Units: `H`, `M`, `S`, `m`, `u`, `n` (case-sensitive).

- Fewer than 2 bytes is `InvalidFormat`. More than `MAX_DIGITS` (8) digits is `TooManyDigits` (gRPC over HTTP/2 spec).
- Digits are ASCII 0-9 only, so `+5S`, `-5S`, and `1_0S` are `InvalidNumber`. Zero is `NotPositive` (the spec asks for a positive integer). An unknown unit is `InvalidUnit`.
- The multiply is checked, so `99999999H` is `Overflow`, never a panic.

---

## Config.zig

Server config record. `io`, `ip`, `port`, and `dispatch_model` are required, every other field has a default (see the hld field table).

- `max_recv_buf` defaults to 64 KiB (Http2 uses 32 KiB).
- `compress` and `handler_timeout_ms` are gRPC only. Http2 has no `compress`.
- `serveOpts()` builds the `ServeOpts` for one connection. `io` becomes the pool that runs server-streaming calls.
- `tls` and `tls_port` are not ported yet.

---

## server.zig and dispatch/

### Dispatch (run)

`server.zig` holds the public `GrpcServer` type and a thin `run()` switch on `dispatch_model`. The per-model implementations live in `dispatch/` (`async.zig`, `epoll.zig`, `uring.zig`). `.ASYNC` keeps the accept-thread + `io.async` structure and calls `serve.serveConn`. `.EPOLL` calls `epoll.runEpoll`. `.URING` calls `uring.runUring` (the io_uring completion-based shape of `.EPOLL`). When `cfg.tls != null`, `run()` instead branches to `tls_mux.runTlsMux` (multiplexed) or `tls_serve.runTls` (blocking per-connection). Before any of that, `run()` rejects `.EPOLL` / `.URING` off Linux with `error.ZixDispatchModelUnsupported` (ADR-065).

The `GrpcConnTable`, `acceptAll`, `epollMuxWorkerFn`, and `runEpoll` symbols below all live in `dispatch/epoll.zig`.

### GrpcConnTable

Private per-worker fd to `*GrpcMuxConn` map, indexed directly by fd (sparse, `MAX_FD = 1 << 16`). `alloc` builds a `GrpcMuxConn`, `free`/`deinit` release it. Not shared between workers.

### acceptAll(table, epfd, listener_fd, opts, io)

Drains `accept4(SOCK.NONBLOCK | SOCK.CLOEXEC)` to `EAGAIN` (level-triggered). Each accepted fd gets `TCP_NODELAY`, a `GrpcMuxConn` (built with `io`, carried on `Context` for the trio), and an `EPOLL.IN | RDHUP` registration. On allocation or registration failure the fd is closed.

### epollMuxWorkerFn(RouterType)(ctx)

`epollMuxWorkerFn(comptime RouterType: type)` returns the worker entry function. One worker thread:

```
1. private SO_REUSEPORT listener on ip:port; setNonBlock
2. epoll_create1; add listener (EPOLL.IN)
3. GrpcConnTable.init
4. loop epoll_wait (up to EPOLL_MAX_EVENTS = 512 events per call):
     for each event:
       listener fd  -> acceptAll
       conn fd      -> outcome = (HUP|ERR) ? .close : grpcMuxOnReadable(RouterType, conn)
                       if .close -> epoll_ctl DEL, table.free, close
```

### runEpoll(comptime RouterType: type, cfg)

`worker_count = workers` (0 = cpu count). Spawns `worker_count` `epollMuxWorkerFn(RouterType)` threads (512 KB stacks) and joins them. The kernel balances connections across the per-worker `SO_REUSEPORT` listeners.

---

###### end of lld-grpc
