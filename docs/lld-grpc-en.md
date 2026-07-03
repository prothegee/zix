# LLD: zix.Grpc (h2c gRPC)

Internal implementation details. For design rationale see [`docs/hld-grpc-en.md`](hld-grpc-en.md) and ADR-031.

The blocking models (`.ASYNC`, `.POOL`, `.MIXED`) share one connection path (`serveGrpcConn` -> `serveGrpcLoop`). The `.EPOLL` model is a separate, multiplexed, non-blocking path (`grpcMuxOnReadable`) that owns the bulk of this document.

---

## core.zig

### GrpcContext

The per-stream handler context. Fields relevant to output:

```zig
fd: std.posix.fd_t,
stream_id: u31,
_hdr_sent: bool,
_write_mutex: ?*ConnMutex = null,   // streaming models only; null on the mux path
_out: ?*ReplyStage = null,          // set on the inline/mux path: stage instead of direct write
```

`sendMessage` / `sendHeaders` / `finish` branch on `_out`: when it is set they append the encoded frames to the cork (no per-call lock, no direct `write`). When it is null they write directly to the fd, taking `_write_mutex` if a concurrent streaming task may be writing. Unary inline dispatch and every mux dispatch use the staged path. Server-streaming under the blocking models uses the direct path.

### ReplyStage

A corked writer for one connection. Used by inline unary dispatch (blocking models) and by every dispatch on the mux path.

```zig
const ReplyStage = struct {
    fd: std.posix.fd_t,
    buf: []u8,                    // caller-owned backing, not an inline array
    len: usize,

    fn append(self, bytes) void   // flush first if it would overflow; pass a >buf payload straight through
    fn flush(self) void           // one fdWriteAll of buf[0..len]; len = 0
};
```

`buf` is a caller-supplied slice. The blocking inline path (`dispatchGrpcInline`) backs it with a 4096-byte stack array (unary replies are small). The mux path backs it with the connection's 64 KB `stage_buf` (see `GrpcMuxConn`). All response frames produced while handling one readable event accumulate here and leave in a single `write()`.

### ConnReader (blocking models)

Buffered frame reader used by `serveGrpcLoop`. `ensure(n)` blocks until `n` bytes are buffered (compacting when needed), `take(n)` returns and advances. Replaces a 9-byte header read plus a payload read per frame with batched reads.

### Stream

Per-stream parse state. `body` and `header_scratch` are slices into per-connection backing buffers sized to `opts.max_body` / `opts.max_header_scratch`, not inline arrays, so the stream table costs `max_streams * max_body` per connection rather than a fixed ~70 KB per slot.

```zig
const Stream = struct {
    id: u31,
    state: StreamState,
    headers: [h2.MAX_HEADERS]h2.Header,
    header_count: usize,
    body: []u8,
    body_len: usize,
    header_scratch: []u8,
    end_headers: bool,
    end_stream: bool,
};
```

`slotFor(stream_id, streams, used)` claims the first free slot, `findSlot(stream_id, ...)` locates an open stream by id. Both are linear scans over `max_streams`.

### Flow-control constants

```zig
const STREAM_WINDOW_SIZE: u32 = 16 * 1024 * 1024;  // advertised SETTINGS_INITIAL_WINDOW_SIZE
const CONN_WINDOW_BUMP: u31 = 1 << 30;             // one-time connection window bump after handshake
const CONN_REPLENISH_THRESHOLD: usize = 1 << 29;   // bulk connection-window replenish point
```

Stream windows are large enough that small request bodies never need a per-DATA stream `WINDOW_UPDATE`. The connection window is bumped once and only replenished in bulk past the threshold.

### GrpcMuxConn (multiplexed `.EPOLL`)

Heap-owned per-connection state for the multiplexed model. One worker thread owns a `GrpcMuxConn` for its whole lifetime.

```zig
pub const GrpcMuxConn = struct {
    fd: std.posix.fd_t,
    opts: GrpcServeOpts,

    rbuf: []u8,                 // read accumulator, persists across events, holds partial frames
    rstart: usize,
    rend: usize,

    hpack_dec: h2.HpackDecoder,
    streams: []Stream,
    slots: []bool,
    bodies: []u8,               // backing for stream bodies
    scratches: []u8,            // backing for stream header_scratch
    last_stream_id: u31,
    conn_window_consumed: usize,
    phase: MuxPhase,            // await_preface | await_upgrade | await_preface2 | h2
    settings_frame: [33]u8,     // precomputed server SETTINGS, built once in init
    stage_buf: [65536]u8,       // 64 KB backing for stage
    stage: ReplyStage,          // stage.buf = &stage_buf

    pub fn init(fd, opts) ?*GrpcMuxConn   // one allocation per buffer; null on OOM
    pub fn deinit(self) void
};
```

`rbuf` is sized `max(32 KB, max_frame_size + 256 + 9)`.

`init` calls `buildSettingsFrame(&settings_frame, opts)` once to encode the 33-byte server SETTINGS blob (9-byte header + 4 params), and points `stage.buf` at the 64 KB `stage_buf`. The handshake appends `settings_frame` as-is (no per-connection encode loop). The 64 KB stage coalesces ~100 concurrent unary replies (~6 KB) into one write, and a server-streaming reply packs its messages into fewer, larger DATA frames (see `muxDispatch`), so even a ~5000-message reply stays well under the stage and leaves in one write.

### grpcMuxOnReadable(comptime routes, conn) -> GrpcConnOutcome

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
     e. if muxProcess(routes, conn) == .close -> flush, return .close
```

Reads a chunk, processes complete frames, repeats until `EAGAIN`. Level-triggered epoll re-fires if more arrives.

### muxProcess(comptime routes, conn) -> GrpcConnOutcome

Handshake phase machine, then the frame loop.

- `await_preface`: need 3 bytes. If they are not `"PRI"`, set `await_upgrade` and call `muxHandleUpgrade`. Else need 24 bytes, validate the connection preface, stage server SETTINGS, set `h2`.
- `await_upgrade`: `muxHandleUpgrade`.
- `await_preface2`: after a `101`, validate the preface, stage SETTINGS, set `h2`.
- `h2`: `muxFrameLoop`.

### muxHandleUpgrade(conn)

Accumulate to `\r\n\r\n`. Without an `Upgrade: h2c` header, stage `400` and return `.close` (the validate probe path). With it, stage `101`, consume the request headers, set `await_preface2`, return `.keep_alive`. An initial request on stream 1 of the upgrade is not served (prior-knowledge clients do not use this path).

### muxFrameLoop(comptime routes, conn) -> GrpcConnOutcome

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

### muxDispatch(comptime routes, conn, stream)

Builds a `GrpcContext` with `_out = &conn.stage` and `_write_mutex = null` (the worker owns the connection, so there is no concurrent writer), then `Router(routes).dispatch`. Every route, unary and streaming, runs inline. Optional `logger.rpc` timing wraps the call.

Server-streaming replies coalesce at the gRPC layer. `muxDispatch` gives a streaming route a per-call coalesce buffer (`ctx._coal`), and `sendMessage` packs consecutive gRPC-framed messages into it, emitting one HTTP/2 DATA frame per `grpc_stream_coalesce_cap` (16 KiB, the HTTP/2 default max frame size) instead of one DATA frame per message. A `count = 5000` reply drops from 5000 tiny DATA frames to about 3, cutting the frame-header bytes on the wire and the client's per-frame parse cost. Unary keeps one frame per message (`_coal` is null), so it is byte-for-byte unchanged.

For a streaming route (detected by `routeIsStreaming(routes, path)`), the dispatch is wrapped in `setTcpCork(conn.fd, true)` / `setTcpCork(conn.fd, false)`: the kernel holds output until the MSS is full or cork clears, coalescing the multiple intermediate stage flushes a streaming handler produces into fewer TCP segments. Unary routes are not corked (they already leave in one write). `setTcpCork` is a no-op on non-Linux targets.

### Blocking path (serveGrpcConn / serveGrpcLoop)

Unchanged for `.ASYNC`, `.POOL`, `.MIXED`. `serveGrpcConn` sets `TCP_NODELAY` and calls `serveGrpcConnInner`, which handles the h2c-direct preface or the h2c upgrade, then `serveGrpcLoop`. The loop uses a blocking `ConnReader` and the same frame switch, dispatching via `dispatchStream`: unary inline (`dispatchGrpcInline`, staged via a stack `ReplyStage`), server-streaming via `spawnGrpcStream` (one detached thread, deep-copies headers and body, writes under a shared `ConnMutex`).

---

## frame.zig

### build* / send*

`build*` functions encode a frame into a caller buffer and return the byte count, `send*` wrap them with `fdWriteAll`.

```zig
pub fn buildGrpcHeaders(out, stream_id, content_type) usize     // initial HEADERS, no END_STREAM
pub fn buildGrpcDataHeader(out, stream_id, msg_len) usize       // 9-byte DATA header + 5-byte gRPC prefix (caller appends payload)
pub fn buildGrpcTrailer(out, stream_id, grpc_status, msg) usize // trailer HEADERS, END_STREAM
pub fn buildGrpcError(out, stream_id, grpc_status, msg) usize   // trailers-only HEADERS, END_STREAM
```

### Cached reply blocks

The two constant hot-path header blocks are HPACK-encoded once at comptime:

```zig
pub const GRPC_CONTENT_TYPE = "application/grpc+proto";
const HEADERS_PROTO_BLOCK = ...;  // :status 200 + content-type application/grpc+proto
const TRAILER_OK_BLOCK = ...;     // grpc-status 0
```

`buildGrpcHeaders` takes `HEADERS_PROTO_BLOCK` when `content_type == GRPC_CONTENT_TYPE`, and `buildGrpcTrailer` takes `TRAILER_OK_BLOCK` when `grpc_status == 0` and the message is empty. Both go through `emitCachedHeaders`, which stamps the 9-byte frame header (with the stream id and flags) and `memcpy`s the cached block - no HPACK encoder run. Any other content-type or status falls back to the dynamic encoder.

The blocks are produced by running the real `HpackEncoder` at comptime, so they are byte-identical to the dynamic output. This requires `HpackEncoder.writeString` to type the Huffman result as `?usize` (otherwise comptime collapses the optional when the error branch is statically unreachable).

---

## server.zig and dispatch/

### Dispatch (run)

`server.zig` holds the public `GrpcServer` type and a thin `run()` switch on `dispatch_model`. The per-model implementations live in `dispatch/` (`async.zig`, `pool.zig`, `mixed.zig`, `epoll.zig`, `uring.zig`). `.ASYNC` / `.POOL` / `.MIXED` keep the accept-thread + `io.async` / `ConnQueue` pool structure and call `serveGrpcConn`. `.EPOLL` calls `epoll.runEpoll`. `.URING` calls `uring.runUring` (the io_uring completion-based shape of `.EPOLL`). When `cfg.tls != null`, `run()` instead branches to `tls_mux.runTlsMux` (multiplexed) or `tls_serve.runTls` (blocking per-connection).

The `GrpcConnTable`, `acceptAll`, `epollMuxWorkerFn`, and `runEpoll` symbols below all live in `dispatch/epoll.zig`.

### GrpcConnTable

Private per-worker fd to `*GrpcMuxConn` map, indexed directly by fd (sparse, `MAX_FD = 1 << 16`). `alloc` builds a `GrpcMuxConn`, `free`/`deinit` release it. Not shared between workers.

### acceptAll(table, epfd, listener_fd, opts)

Drains `accept4(SOCK.NONBLOCK | SOCK.CLOEXEC)` to `EAGAIN` (level-triggered). Each accepted fd gets `TCP_NODELAY`, a `GrpcMuxConn`, and an `EPOLL.IN | RDHUP` registration. On allocation or registration failure the fd is closed.

### epollMuxWorkerFn(routes)(ctx)

`epollMuxWorkerFn(comptime routes)` returns the worker entry function. One worker thread:

```
1. private SO_REUSEPORT listener on ip:port; setNonBlock
2. epoll_create1; add listener (EPOLL.IN)
3. GrpcConnTable.init
4. loop epoll_wait (up to EPOLL_MAX_EVENTS = 512 events per call):
     for each event:
       listener fd  -> acceptAll
       conn fd      -> outcome = (HUP|ERR) ? .close : grpcMuxOnReadable(routes, conn)
                       if .close -> epoll_ctl DEL, table.free, close
```

### runEpoll(comptime routes, cfg)

`worker_count = pool_size` (0 = cpu count). Spawns `worker_count` `epollMuxWorkerFn(routes)` threads (512 KB stacks) and joins them. The kernel balances connections across the per-worker `SO_REUSEPORT` listeners.

---

###### end of lld-grpc
