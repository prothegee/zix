# LLD: zix.Grpc (h2c gRPC)

Internal implementation details. For design rationale see [`docs/hld-grpc-en.md`](hld-grpc-en.md) and ADR-031.

The blocking model (`.ASYNC`) uses one connection path (`serve.serveConn` -> `serveLoop`). The multiplexed models (`.EPOLL`, `.URING`) use a separate, non-blocking path under `mux/` (`process.onReadable`, `process.processRing`). `dispatch/epoll.zig` and `dispatch/uring.zig` drive it.

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

The inline path (`stream_dispatch.dispatchInline`) backs `buf` with a 4096-byte stack array (unary replies are small). The mux path backs it with the connection's 64 KB `stage_buf` (see `MuxConn`).

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

### Mux files (`mux/`)

| File | Role |
| :- | :- |
| `MuxConn.zig` | per-fd state: read buffer, slots, reply stage, server SETTINGS |
| `stream_pool.zig` | per-worker freelist of `Stream` |
| `settings_frame.zig` | `build`: the 33-byte server SETTINGS frame |
| `stage_frame.zig` | `append`, `windowUpdate`, `goaway`, `rstStream` into the reply stage |
| `tcp_cork.zig` | `set`: TCP_CORK on or off, best effort |
| `mux_dispatch.zig` | `dispatch`, `dispatchWhole`, `hangupGoaway` |
| `mux_upgrade.zig` | `handleUpgrade`: 101 or 400 |
| `frame_loop.zig` | `run`: one frame at a time |
| `process.zig` | `onReadable`, `processRing` |

`ConnOutcome` (`keep_alive`, `close`) and `MuxPhase` (`await_preface`, `await_upgrade`, `await_preface2`, `h2`) are reused from the http2 mux.

### MuxConn

Heap-owned per-connection state. One worker thread owns a `MuxConn` for its whole life, so there is no write lock.

```zig
fd: std.posix.fd_t,
opts: ServeOpts,
io: std.Io,                      // carried onto the Context of every call
rbuf: []u8,                      // read accumulator, holds a partial frame across events
rstart: usize,
rend: usize,
hpack_dec: HpackDecoder,
streams: []*Stream,              // borrowed from the pool, valid only where slots is true
slots: []bool,
last_stream_id: u31,
conn_window_consumed: usize,
phase: MuxPhase,
settings: [SETTINGS_FRAME_LEN]u8,    // server SETTINGS, built once in init
stage_buf: [STAGE_BUF_LEN]u8,        // 64 KiB
stage: ReplyStage,                   // stage.buf = &stage_buf

pub fn init(fd, opts, io) Error!*Self      // ZixHttp2_GrpcMuxConn_OutOfMemory
pub fn deinit(self) void                   // returns open streams to the pool
pub fn buffered(self) []u8
pub fn compact(self) void
pub fn claimSlot(self, sid) ?usize
pub fn findSlot(self, sid) ?usize
pub fn releaseSlot(self, slot) void
pub fn requestInFlight(self) bool
```

`rbuf` is sized `max(opts.conn_read_buf_min, max_frame_size + 256 + 9)`. `stage` points into the struct, so a `MuxConn` is heap-only and never moved.

The 64 KiB stage holds about 100 concurrent unary replies in one write, and a server-streaming reply packs its messages into fewer, larger DATA frames (see `mux_dispatch.dispatch`).

### stream_pool

`acquire(opts)` takes the most recently released stream, or allocates one with `max_body` and `max_header_scratch` buffers. `release(stream)` resets the stream and keeps its buffers. The freelist is threadlocal, so resident stream memory follows the concurrent streams of a worker, not connections times `max_streams`. A pooled stream smaller than `opts` asks for is dropped and replaced.

### process.onReadable(comptime RouterType, conn) -> ConnOutcome

One readable event.

```
1. conn.stage.len = 0, flush the stage on every return
2. loop:
     a. compact rbuf
     b. rbuf still full -> return .close (a frame larger than the buffer)
     c. got = read(fd, rbuf[rend..])
          WouldBlock -> return .keep_alive
          other error -> return .close
          0 -> hangupGoaway, return .close
     d. rend += got
     e. process(RouterType, conn) == .close -> return .close
```

### process.processRing(comptime RouterType, conn) -> ConnOutcome

Same as one pass of `process`, with no read and no flush. The `.URING` worker fills `rbuf` and sends `conn.stage.buf[0..conn.stage.len]` after it returns. A reply past the stage already went straight to the fd.

### process (handshake phases)

The phases fall through, so bytes read together are handled in one pass.

- `await_preface`: need 3 bytes. Not `"PRI"` -> `await_upgrade`. Else accept the preface (24 bytes): stage `conn.settings`, set `h2`. A wrong preface stages GOAWAY PROTOCOL_ERROR and closes.
- `await_upgrade`: `mux_upgrade.handleUpgrade`.
- `await_preface2`: after a `101`, accept the preface the same way.
- `h2`: `frame_loop.run`.

### mux_upgrade.handleUpgrade(conn)

Accumulate to `\r\n\r\n`. A head that fills `rbuf` closes. Without `Upgrade: h2c`, stage `400` and close. With it, stage `101`, consume the head, set `await_preface2`. The request on stream 1 of the upgrade is not served (gRPC clients use prior knowledge).

### frame_loop.run(comptime RouterType, conn) -> ConnOutcome

```
loop:
    buffered < 9 -> return .keep_alive
    header = parseFrameHeader
    header.length > max_frame_size + 256 -> stage GOAWAY FRAME_SIZE_ERROR, return .close
    buffered < 9 + length -> return .keep_alive
    advance past header + payload
    switch frame_type:
        SETTINGS     -> peer_settings.apply, stage SETTINGS ACK + WINDOW_UPDATE(0, CONN_WINDOW_BUMP)
        PING         -> stage PING ACK (a payload not 8 bytes: GOAWAY FRAME_SIZE_ERROR, close)
        HEADERS      -> stream 0: GOAWAY, close. Reused odd id: RST STREAM_CLOSED.
                        claimSlot (none: RST REFUSED_STREAM), hpack decode (fail: RST COMPRESSION_ERROR)
        CONTINUATION -> unknown stream: GOAWAY, close. Else decode more headers
        DATA         -> stream 0: GOAWAY, close. Unknown stream: RST STREAM_CLOSED.
                        replenish the connection window past CONN_REPLENISH_THRESHOLD.
                        body past opts.max_body: stage RESOURCE_EXHAUSTED trailers, free the slot
        RST_STREAM   -> free the slot
        GOAWAY       -> return .close
    END_HEADERS and END_STREAM both set -> mux_dispatch.dispatchWhole, free the slot
```

Every control frame is staged (`stage_frame`), so it leaves in the same write as the replies.

The body cap is `opts.max_body`, not the pooled buffer length, since a pooled buffer can be larger.

### mux_dispatch

- `dispatchWhole(RouterType, conn, stream)`: a body short of (or past) its content-length stages RST_STREAM PROTOCOL_ERROR (RFC 9113 section 8.1.1), else `dispatch`.
- `dispatch(RouterType, conn, stream)`: builds a `Context` with `_out = &conn.stage` and no write lock, then calls the handler through `handler.invoke`. Every route, unary and streaming, runs inline on the worker. An attached logger gets one `rpc` line.
- `hangupGoaway(conn)`: stages GOAWAY PROTOCOL_ERROR only when a request is still in flight.

A server-streaming route gets a per-call coalesce buffer (`ctx._coal`, `Context.STREAM_COALESCE_CAP`, 16 KiB), so its messages share DATA frames instead of one frame per message. Unary keeps one frame per message. A streaming route also runs under `tcp_cork.set(fd, true)` / `set(fd, false)`, so the stage flushes it produces leave in fewer TCP segments. `tcp_cork.set` is a no-op off Linux and on a socket without TCP_CORK.

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

### builder.zig / send.zig

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

### server.zig

Functions only. `init(comptime RouterType, config)` returns `GrpcServer(RouterType)`, a struct that holds the config. `deinit` is a no-op.

`run` checks, in order:

1. `config.port == 0` -> `ZixHttp2_GrpcServer_PortNotConfigured`.
2. the dispatch model: `.ASYNC` runs everywhere, `.EPOLL` and `.URING` run on Linux. `.EPOLL` / `.URING` off Linux, `.IOCP`, and `.KQUEUE` -> `ZixHttp2_GrpcServer_DispatchModel_NotSupported`.
3. the model's `run(RouterType, config)`. Its errors are translated into the server set:
   - `dispatchError` (`.ASYNC`): `ResolveFailed`, `ListenFailed`, `AcceptFailed` keep their names.
   - `dispatchEpollError` / `dispatchUringError`: `ResolveFailed` and `ListenFailed` keep their names. `OutOfMemory`, `SpawnFailed`, `SetupFailed`, `Unsupported` (and `WaitFailed` for `.URING`) -> `ZixHttp2_GrpcServer_EpollSetupFailed` / `UringSetupFailed`.

### dispatch/async.zig

`run(comptime RouterType, config) Error!void` resolves `config.ip`, listens with `reuse_address` and `config.kernel_backlog`, logs one `listening on` line through `log.logSystem`, then accepts forever. Each connection goes to `io.async(ConnEntry(RouterType).serveOne, ...)`. `ConnEntry` binds the comptime Router, since `io.async` takes a plain function.

`serveOne` installs this pool thread's response cache (`installCache`, sized by `effectiveCacheEntries` from the http2 cache), runs `serve.serveConn`, then closes the stream and releases the cache. `ConnectionAborted` is skipped, any other accept failure ends the loop with `AcceptFailed`.

### log.zig

`logSystem(config, level, fmt, args)`: to `config.logger.system` with the tag `grpc`, or to `std.log` without a logger.

### dispatch/epoll.zig and dispatch/uring.zig

Same structure as the http2 `dispatch/epoll.zig` / `uring.zig`. Both `run(comptime RouterType, config)`:

1. resolve `config.ip`, then bind one `reuse_address` listener per worker on the calling thread, in worker order (`workers`, 0 = available CPU count). A bind failure returns before anything serves.
2. attach the `reuseport_cbpf` CPU steering to the group when asked. A kernel that refuses it logs a warning and keeps the default hash.
3. spawn one worker per listener with `worker_stack_size_bytes`. The Router is bound by `WorkerEntry(RouterType)` (epoll) or `Worker(RouterType)` (uring), since `std.Thread.spawn` takes a plain function.
4. join every worker. A worker that could not start its loop sets `failed` and `stop`, so the whole group stops and `run` returns `SetupFailed`.

Each worker pins itself to a CPU (`cpu_affinity.pinToCpu`), installs its own response cache (`cache.installWorker`, freed on return), and keeps an fd-indexed slot table (`slab.mapZeroedSlots`, `MAX_FD` = 65536). A fd past the table is closed. Accepted fds get TCP_NODELAY and, when `busy_poll_us` is set, SO_BUSY_POLL. The loop waits at most 1 s at a time, so it sees `stop`.

`.EPOLL` (level-triggered):

- the listener event runs `acceptAll`: `accept4` until EAGAIN, a `MuxConn` per fd, registered for `EPOLLIN | EPOLLRDHUP`.
- a connection event runs `serveEvent`: `EPOLLHUP` / `EPOLLERR` close it, otherwise `process.onReadable` reads, processes, and flushes the stage in one write. `.close` unregisters, frees, and closes the fd.

`.URING`:

- one ring per worker (single issuer, deferred task run, 16 Ki CQ entries, falls back to a plain ring). No fallback to `.EPOLL`.
- multishot accept. A re-arm lost to a full SQ is retried on the next pass (`accept_pending`).
- `user_data` packs the op (`accept`, `recv`, `send`), a 24-bit generation, and the fd, so a completion for an earlier connection on a reused fd is dropped.
- a recv completion runs `process.processRing`, then sends `conn.stage` on the ring. Only one recv or one send is in flight per connection, so the read buffer and the stage are never touched while the kernel holds them. A partial send resends the rest.
- a hang-up part way through a request stages a GOAWAY (`mux_dispatch.hangupGoaway`) and the connection closes after that send lands (`closing`). A send error closes at once.
- on stop, the ring is torn down before the connections, so no send still reads a freed stage.

---

###### end of lld-grpc
