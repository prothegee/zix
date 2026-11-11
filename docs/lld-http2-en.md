# LLD: zix.Http2 (h2c HTTP/2)

Internal implementation details. For design rationale see [`docs/hld-http2-en.md`](hld-http2-en.md), ADR-043 (the per-engine `dispatch/` split), and ADR-052 (multiplexed TLS).

The blocking model (`.ASYNC`) uses one connection path (`serve.serveConn` -> `serveLoop`). The `.EPOLL` and `.URING` models drive a separate, resumable, non-blocking state machine (`mux/`) that owns the bulk of this document. Both feed one comptime `Router`. The TLS path (`config.tls != null`) terminates in place, either multiplexed (`tls_mux.zig`, for `.EPOLL` / `.URING`) or thread-per-connection (`tls_serve.zig`, which also serves TLS 1.2).

---

## mux/

The resumable h2c state machine for `.EPOLL` / `.URING`, one file per concern:

| file | holds |
| :- | :- |
| `MuxStream.zig` | one pooled stream: headers, body, send window, parked body |
| `MuxConn.zig` | per-fd state: read buffer, HPACK decoder, slots, windows, `upgrade_slot` (stream 1 of an h2c upgrade, waiting for the preface). Slot claim, find, release |
| `stream_pool.zig` | per-worker threadlocal freelist of `MuxStream`: `acquire`, `release` |
| `conn_outcome.zig` | `ConnOutcome`: `keep_alive` or `close` |
| `mux_phase.zig` | `MuxPhase`: `await_preface`, `await_upgrade`, `await_preface2`, `h2` |
| `flow.zig` | send-side flow control: `pumpBody`, `resumeStream`, `resumeAll` |
| `send_stream.zig` | `active_conn` and `sendResponseStreamFD` |
| `mux_upgrade.zig` | `handleUpgrade`: the h2c upgrade on the mux path (opens stream 1, 101). `serveUpgradeStream`: answers stream 1 after the preface |
| `mux_dispatch.zig` | `dispatchWhole`, `hangupGoaway` |
| `frame_loop.zig` | `run`: one whole frame at a time, one `on*` function per frame type |
| `process.zig` | preface phases, `onReadable` (`.EPOLL`), `processRing` (`.URING`) |

One `MuxConn` per fd. The read accumulator `rbuf` persists across readable events and holds a partial frame until the rest arrives, so a single worker drives many connections. Connection frames and responses write straight to the fd through `writer` and `control` (which poll on EAGAIN for a non-blocking socket), and a handler runs inline on the worker, so like the gRPC mux it must stay bounded.

### MuxStream (MuxStream.zig)

One stream within a connection, borrowed from the per-worker pool while open.

```zig
id: u31 = 0,
state: StreamState = .IDLE,                     // IDLE | OPEN | HALF_CLOSED_REMOTE | CLOSED
headers: [frame.MAX_HEADERS]Header = undefined, // inline, MAX_HEADERS = 64
header_count: usize = 0,
header_scratch: []u8 = &.{},                    // pooled buffer, sized to opts.max_header_scratch
body: []u8 = &.{},                              // pooled buffer, sized to opts.max_body
body_len: usize = 0,
end_headers: bool = false,
end_stream: bool = false,
send_window: i64 = 65535,        // peer's remaining receive window for this stream (RFC 7540 6.9)
pending_body: []const u8 = &.{}, // unsent tail of a body capped by a window
pending_end: bool = false,
next_free: ?*Self = null,        // freelist link, valid only while idle in the pool
```

`reset` sets every field back to its default and keeps the two pooled buffers. `open(sid, send_window)` resets, then stamps the id, `OPEN`, and the starting send window. `appendBody` returns false and appends nothing when the data does not fit. `isParked` is true while `pending_body` is not empty. `pending_body` points into caller-owned memory that must outlive the stream (the static cache), so the slot stays borrowed until it drains.

### MuxConn (MuxConn.zig)

Heap-owned per-connection h2 state, one per fd, private to the owning worker.

```zig
fd: std.posix.fd_t,
opts: ServeOpts,
io: std.Io,                 // carried onto the Context of every handler call
rbuf: []u8,                 // read accumulator, unprocessed bytes are rbuf[rstart..rend]
rstart: usize,
rend: usize,
hpack_dec: HpackDecoder,
streams: []*MuxStream,      // pointer array: an idle conn reserves max_streams pointers, not buffers
slots: []bool,
last_stream_id: u31,
phase: MuxPhase,
send_window: i64,           // connection-level send window (all our DATA), starts at 65535
peer_init_window: i64,      // peer's SETTINGS_INITIAL_WINDOW_SIZE, a new stream's send window
peer_max_frame_size: u32,   // peer's SETTINGS_MAX_FRAME_SIZE, starts at 16384
```

| function | role |
| :- | :- |
| `init(fd, opts, io)` | one allocation each for conn, `rbuf`, `streams`, `slots`. Returns `Error!*Self` (`ZixHttp2_MuxConn_OutOfMemory`) |
| `deinit` | returns every still-open stream to the pool, then frees the arrays. The caller still owns and closes the fd |
| `buffered` / `compact` | the unprocessed bytes, and making room for the next read (reset an empty buffer, or move a partial frame to the front of a full one) |
| `claimSlot(sid)` | first free slot, borrows a stream via `stream_pool.acquire` and opens it with `peer_init_window`. Null at `max_streams` or when the pool can not grow, the caller then sends `RST_STREAM REFUSED_STREAM` |
| `findSlot(sid)` / `releaseSlot(slot)` | locate a live stream by id, free a slot and return its stream to the pool |
| `requestInFlight` | true while a live stream has not seen END_STREAM. A slot held only by a parked response does not count |
| `setPeerInitialWindow(value)` | RFC 7540 6.9.2: moves every open stream's send window by the difference |

`rbuf` is sized `max(opts.conn_read_buf_min, opts.max_frame_size + frame.FRAME_PAYLOAD_SLACK + 9)`. Because `streams` holds pointers, the heavy per-stream state is not reserved at connection open, it is borrowed from the pool on stream open. Slot lookups are linear scans over `max_streams`.

### Per-worker stream pool (stream_pool.zig)

The key allocation strategy. A worker drives many connections from one thread, and each connection borrows a `MuxStream` only while a stream is open, returning it on close. The freelist is a threadlocal (shared-nothing per worker, no atomics), so resident stream memory tracks concurrent streams on the worker, not connections times `max_streams`. Buffers are allocated once per pooled stream and reused across borrows, so the steady state does zero per-stream allocation.

- `acquire(opts) Error!*MuxStream`: pops the freelist and returns the stream when its buffers meet `opts.max_body` / `opts.max_header_scratch`. A smaller pooled stream (mixed serve options on one worker) is freed, and a fresh `MuxStream` plus its two buffers is allocated. Out of memory is `ZixHttp2_StreamPool_OutOfMemory`.
- `release(stream)`: `reset` (buffers kept), then LIFO push, so a hot stream is reused first.
- A pooled stream is never freed. It lives until its worker exits.

### process.zig

`process` is the handshake phase machine, then the frame loop:

- `await_preface`: need 3 bytes. If they are not `"PRI"`, set `await_upgrade`. Else need the 24-byte `PREFACE`, validate it (GOAWAY `PROTOCOL_ERROR` and close when it is wrong), send server SETTINGS (`peer_settings.sendServerSettings`), set `h2`.
- `await_upgrade`: `handleUpgrade` (accumulate to `\r\n\r\n`, reply `400` when `upgrade.isH2cUpgrade` is false). An h2c head is read with `upgrade.parseHead`, its `HTTP2-Settings` go through `peer_settings.apply`, and stream 1 is opened with `:method`, `:path`, `:scheme` copied into the stream scratch (the head bytes in `rbuf` are reused later). A request line past the scratch, or no free slot, replies `400` and closes. Then `101`, `last_stream_id = 1`, `upgrade_slot` set, `await_preface2`. A head that fills `rbuf` closes.
- `await_preface2`: after the `101`, validate the preface, send SETTINGS, set `h2`, then `serveUpgradeStream` answers stream 1 (`mux_dispatch.dispatchWhole`) before any frame that follows.
- The phases fall through, so an upgrade head, the preface, and frames read together are handled in one pass.
- `h2`: `frame_loop.run`.

`onReadable` (`.EPOLL`) loops: `compact`, close when `rbuf` is still full, `read` into `rbuf[rend..]` (WouldBlock -> `keep_alive`, an error -> `close`, 0 -> `hangupGoaway` then `close`), then `process`, repeating until EAGAIN. Level-triggered epoll re-fires if more arrives. `processRing` (`.URING`) is the same processing pass with no read loop: the ring owns the recv and re-arms it after this returns.

### frame_loop.zig

`run` works over the buffered bytes while a whole frame is present:

```
loop:
    if buffered < 9 -> return .keep_alive
    header = parseFrameHeader(rbuf[rstart..][0..9])
    if header.length > max_payload -> GOAWAY FRAME_SIZE_ERROR, return .close
    if buffered < 9 + header.length -> return .keep_alive
    advance past header + payload
    switch header.frame_type:
        SETTINGS      -> onSettings: skip ACK; peer_settings.apply (HEADER_TABLE_SIZE,
                         MAX_FRAME_SIZE), setPeerInitialWindow when INITIAL_WINDOW_SIZE came;
                         send ACK + one connection WINDOW_UPDATE
        WINDOW_UPDATE -> onWindowUpdate: payload not 4 bytes -> GOAWAY FRAME_SIZE_ERROR;
                         stream 0: send_window += inc, resumeAll; else findSlot,
                         stream.send_window += inc, resumeStream
        HEADERS       -> onHeaders: id guards; claimSlot; frame_payload.headerBlock;
                         hpack decode into header_scratch; on END_HEADERS + END_STREAM
                         -> dispatchWhole
        CONTINUATION  -> onContinuation: findSlot (unknown -> GOAWAY PROTOCOL_ERROR);
                         append-decode; dispatch on END
        DATA          -> onData: findSlot (unknown -> RST_STREAM STREAM_CLOSED);
                         frame_payload.dataBlock; appendBody, shed with 413 when it does
                         not fit; WINDOW_UPDATE(0) + WINDOW_UPDATE(sid); dispatch on END_STREAM
        RST_STREAM    -> onRstStream: findSlot -> releaseSlot
        PING          -> onPing: skip ACK; payload not 8 bytes -> GOAWAY FRAME_SIZE_ERROR;
                         sendPingAckFD
        GOAWAY        -> return .close
        other         -> ignore
```

A decode failure sends `RST_STREAM COMPRESSION_ERROR` and frees the slot. Server SETTINGS advertise `MAX_CONCURRENT_STREAMS`, `INITIAL_WINDOW_SIZE` 65535, `MAX_FRAME_SIZE`, and `ENABLE_PUSH` 0.

### mux_dispatch.zig

- `dispatchWhole(handler_fn, conn, slot)`: a stream whose body does not match its own content-length (`stream_body.isWhole`) is reset with `PROTOCOL_ERROR` and its slot freed. Otherwise it is dispatched.
- Dispatch builds the request with `stream_invoke.buildRequest(headers, body)`, records `cache.tl_req_path` / `tl_req_body` / `tl_req_io` only when a response cache is installed, sets `send_stream.active_conn = conn`, and calls `handler.invokeHandler` with `conn.peer_max_frame_size`. After the handler returns, the slot is freed unless the response body is parked on a window, in which case a later `WINDOW_UPDATE` resumes and frees it.
- `hangupGoaway(conn)`: GOAWAY `PROTOCOL_ERROR` when a request is still in flight, nothing on an idle connection. Returns whether it wrote.

### flow.zig and send_stream.zig

The send-side flow control. `active_conn` is the threadlocal that binds a running handler's send back to its connection windows.

- `pumpBody(conn, stream, body, end)`: writes DATA up to `min(conn.send_window, stream.send_window)` and the **peer's** `peer_max_frame_size`, decrements both windows per chunk, sets END_STREAM only on the final chunk once the whole body has gone out, and parks the remainder in `pending_body` / `pending_end`. A failed write stops the send and parks the rest.
- `resumeStream(conn, slot)`: after a window grew, `pumpBody`s the parked tail and frees the slot when it fully drains.
- `resumeAll(conn)`: after the connection window grew, resumes every parked stream.
- `sendResponseStreamFD(fd, sid, status, content_type, content_encoding, body)`: the flow-controlled response entry. With no `active_conn`, another fd, or no matching slot it falls back to `writer.sendResponseEncodedFD` (immediate, unmetered). Otherwise it writes HEADERS (`response_block.respHeaderBlock`, `content-length` always present, END_STREAM on HEADERS for an empty body) then `pumpBody(..., true)`. A header block that does not fit resets the stream with `INTERNAL_ERROR` and sends no DATA. The body is referenced, not copied, so it must outlive the stream (a process-lifetime cache).

Note: the frame batching hook (`writer.write_hook`) and the coalescing sink are not in `mux/`. The `.EPOLL` / `.URING` workers install the hook around each readable batch through `coalesce.zig`.

---

## hpack/

HPACK codec, one file per concern:

| File | Holds |
| :- | :- |
| `Header.zig` | `{ name, value }`, also the static and dynamic table entry |
| `HuffSym.zig` | `{ code: u32, bits: u5 }` |
| `huffman_table.zig` | `HUFF: [256]HuffSym` (RFC 7541 appendix B), joined at comptime from a code array and a bit-length array |
| `static_table.zig` | `HPACK_STATIC: [62]Header` (RFC 7541 appendix A), index 0 unused |
| `huffman.zig` | `huffEncode`, `huffDecode` |
| `integer.zig` | `encodeInt`, `decodeInt` (prefix integers, RFC 7541 section 5.1) |
| `DynamicTable.zig` | dynamic table entries, eviction, compaction |
| `HpackDecoder.zig` | `decode`, `evictTo`, `max_size` |
| `HpackEncoder.zig` | `writeHeader`, `encoded` |
| `RespPrefix.zig` | one cached response prefix |
| `response_block.zig` | `respHeaderBlock` plus the prefix cache |

### respHeaderBlock + response-header cache

`respHeaderBlock(dst, status, content_type, content_encoding, content_length)` encodes a full response header block. The `[:status, content-type, content-encoding]` prefix is served from a process-global append-only cache, only `content_length` (which varies) is encoded per call. A null `content_length` omits the field (a bodyless END_STREAM response). A `dst` too small for the block returns `ZixHttp2_ResponseBlock_BufferFull`.

The cache is `prefix_cache: [32]RespPrefix` with a release-published count and a spinlock (`prefix_lock`). Readers scan `0..count` lock-free, the spinlock serializes only the rare insert (one per distinct triple). It is byte-identical on every connection because `HpackEncoder` is stateless: static table plus literal-without-indexing, never the dynamic table or a size update, so the cached bytes plus a per-call content-length are valid HPACK. A too-long triple or a full cache falls back to a direct encode, so correctness never depends on a hit. A test asserts `respHeaderBlock` matches the `writeHeader` calls byte-for-byte.

### DynamicTable

```zig
entries: [128]Header = undefined, // newest first, entries[0] is dynamic index 1
count: usize = 0,
size: usize = 0,                  // name.len + value.len + 32 per entry
buf: [8192]u8 = undefined,        // entries always slice into here, never per-call scratch
buf_pos: usize = 0,
```

`add(name, value, max_size)` copies the entry into `buf` (connection-lifetime), so an indexed lookup stays valid after a stream slot's scratch is reused. `evictTo(target)` drops the oldest entries until the table fits. When `buf` runs out, `compact` repacks the live entries at the front with a forward copy (source and destination can overlap). An entry larger than `max_size` empties the table and is not stored.

### HpackDecoder

```zig
table: DynamicTable = .{},
max_size: usize = 4096,
```

`decode(block, out, scratch)` handles indexed, literal-with-incremental-indexing, dynamic-table-size-update, and literal-without-indexing representations. Every decoded slice points into the caller's `scratch`, also for table lookups. `evictTo(target)` forwards to the table, so callers that apply SETTINGS_HEADER_TABLE_SIZE keep using `max_size` and `evictTo`. Huffman literals go through `huffDecode`.

### HpackEncoder

`init(buf)` over a caller buffer, `writeHeader(name, value)`: a static-table exact match encodes as indexed, a static name-only match as a name-indexed literal (never added to the dynamic table), otherwise a full literal. `writeString` picks Huffman when it is shorter and types the Huffman result as `?usize` so comptime evaluation (cached blocks) keeps the optional even when the error branch is statically unreachable. Stateless: no dynamic table, no size update.

---

## frame.zig, writer.zig, reader.zig, control.zig

`frame.zig` holds the constants (`FRAME_TYPE_*`, `FLAG_*`, `ERR_*`, `SETTINGS_*`, `PREFACE`, `FRAME_HEADER_LEN` 9, `DEFAULT_MAX_FRAME_SIZE` 16384, `HPACK_ENCODE_SCRATCH` 512, `SEND_STAGE_BODY_MAX` 4096) and the header codec. `FrameHeader.zig` is `{ length: u24, frame_type: u8, flags: u8, stream_id: u31 }`. `parseFrameHeader` / `encodeFrameHeader` do no I/O (for buffered or staged writes).

`writer.zig` is the write side. `writeAllFD` marks the stream answered (`tl_responded`) and calls `writeAllDirectFD`, the blocking write-all that polls on `POLL.OUT` for a non-blocking socket's EAGAIN and retries on INTR. When the threadlocal `write_hook` and `write_hook_ctx` are both set (the coalescing sink today, the TLS seal path later), `writeAllFD` and the vectored pair write hand the bytes to the hook instead. `writeAllDirectFD` never consults the hook, so it is the hook's own flush path and a flush does not re-enter the hook. `writeFrameHeaderFD` encodes and writes one header.

`sendResponseFD` -> `sendResponseEncodedFD` (also in `writer.zig`) is the immediate, unmetered response (no flow control): HEADERS via `respHeaderBlock`, then the body framed in `<= DEFAULT_MAX_FRAME_SIZE` DATA chunks with END_STREAM on the last (or on HEADERS when the body is empty). A body at or under `SEND_STAGE_BODY_MAX` (4 KiB) leaves as one staged write, a larger one as one vectored write per DATA chunk (the HEADERS block rides the first chunk, a write hook receives each pair as two appends). Large bodies that may exceed the peer window use `mux/send_stream.sendResponseStreamFD` instead.

`reader.zig` is the read side: `readOnceFD`, `recvExact` (fills the buffer or returns `Closed`), and `readFrameHeader`.

`control.zig` holds `sendSettingsFD` / `sendSettingsAckFD` / `sendPingAckFD` / `sendGoawayFD` / `sendRstStreamFD` / `sendWindowUpdateFD`, each encoding one control frame. A fixed-size control frame leaves as one write.

---

## Blocking core (serve.zig and its parts)

Shared request processing and the blocking connection path, split by responsibility. `send_best_effort`, `frame_payload`, `peer_settings`, `buildRequest`, and the upgrade helpers are shared with `mux/`:

| file | holds |
| :- | :- |
| `ServeOpts.zig` | per-connection serving knobs |
| `serve.zig` | `serveConn`: preface or upgrade, then one frame at a time |
| `upgrade.zig` + `UpgradeHead.zig` | HTTP/1.1 half of the h2c upgrade (`accept`, answers 101). `isH2cUpgrade`, `parseHead`, `HEAD_END`, `BAD_REQUEST`, `SWITCHING_PROTOCOLS` are public, the mux upgrade reuses them |
| `Stream.zig` | one request stream: decoded headers and body |
| `stream_state.zig` | `StreamState` (RFC 7540 section 5.1) |
| `stream_slot.zig` | stream table `claim`, `find`, `requestInFlight` |
| `declared.zig` + `stream_body.zig` | content-length against DATA bytes (`declared`, `isWhole`) |
| `stream_invoke.zig` | `invokeWhole`: finished stream to `Request`, then the handler. `buildRequest(headers, body)` is public, the mux reuses it |
| `send_best_effort.zig` | `goaway`, `rstStream`, `windowUpdate`, `sendTooLarge`: a failed write is dropped, the next read sees the broken socket |
| `frame_payload.zig` | `headerBlock`, `dataBlock`: strip padding and priority, null when the padding runs past the payload |
| `peer_settings.zig` | `apply` (HEADER_TABLE_SIZE, MAX_FRAME_SIZE in 16384..16777215, returns the last INITIAL_WINDOW_SIZE or null), `sendServerSettings` |
| `handler.zig` | `HandlerFn`, `invokeHandler`, `setAccessLogger` |
| `cache.zig` | per-worker response cache |

### ServeOpts

`ServeOpts` holds the per-connection tuning with these defaults:

| field | default |
| :- | :- |
| `max_streams` | 128 |
| `max_frame_size` | 16384 (`DEFAULT_MAX_FRAME_SIZE`) |
| `max_header_scratch` | 4096 |
| `max_body` | 16384 |
| `logger` | null (logs nothing) |
| `conn_read_buf_min` | 32 * 1024 |
| `tls_write_buf_initial` | 16 * 1024 |
| `response_cache` | false |
| `cache_max_entries` | 256 |
| `cache_max_value_bytes` | 16 * 1024 |
| `cache_ttl_ms` | 1000 |
| `cache_max_total_bytes` | 0 (no ceiling) |
| `handler_timeout_ms` | 0 (no deadline) |
| `public_dir` | "" (empty disables the static fallback) |

### handler.zig

`HandlerFn` is `fn(req: *Request, res: *Response, ctx: *Context) anyerror!void` (ADR-063 trio, built at dispatch by `handler.invokeHandler`). `invokeHandler` is the one place a handler is called, so every dispatch model builds the trio the same way. On a handler error it sends one 500, but only when nothing was written yet: neither `Response.sent` nor `writer.respondedFD()`. Then it writes the access record when `setAccessLogger` installed a logger.

`invokeHandler` takes `peer_max_frame_size: u32` as an explicit parameter and copies it onto `Context.max_frame_size`, which the static fallback uses to size DATA frames. It is separate from `ServeOpts.max_frame_size` on purpose: that field is this server's receive-side advertisement, and using it as the outbound cap is what a conforming peer answers with `FRAME_SIZE_ERROR`. Three call sites supply the correct value:

| call site | source of the peer value |
| :- | :- |
| `mux/mux_dispatch.zig` (`.EPOLL` / `.URING`) | `conn.peer_max_frame_size`, which the mux already tracks for `pumpBody` |
| `serve.serveLoop` (blocking models) | a running local, updated from every SETTINGS frame by `peer_settings.apply` with the 16384..16777215 check (`MAX_FRAME_SIZE_LIMIT`), since a peer may raise it mid-connection |
| `serve.serveUpgrade` | decoded from the base64 `HTTP2-Settings` header, so the carried stream-1 response is correct before any frame is exchanged |

`Context.public_dir` is filled from `ServeOpts.public_dir` at the same point, so the router reaches the static root without a threadlocal (unlike `zix.Http1`, which keeps `tl_static_dir`).

### Router / Route (router.zig)

`Route` is `{ path, handler, kind = .EXACT }` with `RouteKind` `EXACT | PREFIX`. `Router(comptime routes)` builds a comptime table: `EXACT` routes resolve through a `StaticStringMap` (O(1)), `PREFIX` routes match the longest registered prefix on a path-segment boundary, the query string is stripped first, an unmatched path tries `static.fallback`, and a path still unmatched sends `404 text/plain`. `Router(routes).dispatch` itself matches `HandlerFn` exactly, so `Server.init` takes `router.dispatch` as a plain runtime value, not the route table.

### cache.zig

The per-worker response cache (ADR-036): `tl_cache`, `setCache`, `cacheTtl`, `serveCached` / `sendCachedFD`, and `requestKey` (Wyhash over path + body). The cache stores the unframed body, so a hit is framed again for the stream that asked and one entry serves any stream id. The handler does not pass its request, so the dispatcher records `tl_req_path` / `tl_req_body` / `tl_req_io` around each handler call. An empty path or a null io turns every call into a plain send.

### Blocking path (serveConn / serveLoop)

`serveConn` sets `TCP_NODELAY` and calls `serveInner`, which reads 3 bytes: `"PRI"` runs the h2c-direct preface (validate, send SETTINGS, `serveLoop`), anything else runs `serveUpgrade` (`upgrade.accept` for the HTTP/1.1 `Upgrade: h2c` handshake, which serves the initial stream-1 request then `serveLoop`). `serveLoop` allocates a payload buffer (`max_frame_size + FRAME_PAYLOAD_SLACK`) plus a `[]Stream` table and a `[]bool` used flag, both `max_streams` deep, then reads with blocking `readFrameHeader` + `recvExact`. A finished stream goes through `stream_invoke.invokeWhole`.

- A `Stream` is about 70 KiB (`body: [BODY_BUF_SIZE]u8` 64 KiB, `header_scratch: [4096]u8`, up to `MAX_HEADERS` 64 headers), so the table is allocated once per connection on the heap and each entry is reused, in contrast to the mux's pooled buffers sized to the serve options.
- A body past what a stream can hold is shed with 413, never truncated, so a handler never receives a partial body.
- A stream short of (or past) its own content-length is reset with PROTOCOL_ERROR and never reaches the handler (RFC 9113 section 8.1.1).
- A peer that hangs up with a request unfinished gets GOAWAY PROTOCOL_ERROR. A peer that hangs up idle gets nothing, that is an ordinary close.

---

## static.zig

The `public_dir` fallback (ADR-064). `Router.dispatch` calls `fallback(req, ctx)` after every route misses and before the 404. `fallback` returns false when `ctx.public_dir` is empty or the path is `/`, otherwise it strips the leading slash and calls `serve(req, ctx, req_path, max_frame_size)`. `serve` returns false for a traversal attempt, an absolute path, a path past `PUBLIC_PATH_MAX`, a directory, or an absent file, and the router then sends its 404. When `fallback` returns true, the router sets `res.sent`, so a handler error path never answers the stream a second time.

`serve` tries `serveCached` first and falls back to `serveUncached` (open, stat, send) when no static cache is installed or the cache declines the path. Both end at `answer`, so `public_dir` behaves the same whether or not `public_dir_cache_ttl_ms` is set.

| function | role |
| :- | :- |
| `fallback` | the router entry: empty `public_dir` or root path is false, otherwise strips the leading `/` and calls `serve` with `ctx.max_frame_size` |
| `acquireHit` | reads `accept-encoding`, then asks the cache. When `zeroCopyAllowed` refuses, it asks `acquireMapped` first (a resident snapshot) and falls back to the plain descriptor hit past `SNAPSHOT_MAX_BYTES`, so a large file keeps its cached descriptor |
| `rangeAsk` | turns the `Range` header into `FULL` (absent or malformed, RFC 7233 section 3.1 says ignore it), `PARTIAL` (a satisfiable range), or `UNSATISFIABLE` (well-formed but past the end, answered with 416) |
| `encodeHead` | encodes the HEADERS block: status, content type, content encoding, `content-length`, plus `content-range` and `accept-ranges` for a 206. Returns null when it does not fit |
| `encodeUnsatisfiable` | encodes the 416 block with `Content-Range: bytes */length` |
| `answer` | picks the segment, encodes the block, then calls `sendFramed`. A 206 block that does not fit falls back to the whole file as 200. When even the 200 block does not fit, the stream is closed with RST_STREAM `INTERNAL_ERROR` (`resetStream`) |
| `sendFramed` | one HEADERS frame, then DATA frames each capped at `max_frame_size`, the last one flagged END_STREAM. A resident body is cut from its own bytes, otherwise `utils/static/static.sendBody` sends the range |
| `zeroCopyAllowed` | true on Linux for a real fd (`fd >= 0`) while no `writer.write_hook` is set, false everywhere else. A set hook stages frames, so `sendfile` would overtake them |

`Source` carries `{ file, size, content_type, content_encoding, bytes }` and `Segment` carries `{ offset, length, status, content_range }`, so a cached and an uncached file, and a 200 and a 206, share one framing path. `Content-Length` carries the segment length, not the file size, or a client waits for bytes that never arrive. An empty file closes the stream on HEADERS with no DATA frame at all.

Range parsing is shared with the other engines: `utils/http/range_header.zig`. `parseSpec` (read the header) and `resolve` (clamp against a known length) are separate calls on purpose, because one nullable result cannot tell "ignore the header" apart from "answer 416".

---

## dispatch/ and tls_mux.zig

`Server.zig` is the public `zix.Http2.Server` (fields `config` and `handler` at file scope). `run()` runs three gates, then the model switch:

1. `gatePort`: port 0 returns `ZixHttp2_Server_PortNotConfigured`.
2. `gateDispatchModel`: `.IOCP` and `.KQUEUE` always, `.EPOLL` and `.URING` off Linux, return `ZixHttp2_Server_DispatchModel_NotSupported` (ADR-065). It runs before anything is set up, so a rejected config leaves nothing behind.
3. `gatePublicDir`: a set `public_dir` that cannot be opened returns `ZixHttp2_Server_PublicDirNotFound`, `PublicDirNotADirectory`, or `PublicDirUnreadable`.

Then `installStaticCache` installs the process static cache when `public_dir` and a TTL are set (a failed install is only a warning). Only the server that built the table shuts it down when `run()` returns.

The model switch maps `.ASYNC` to `dispatch/async.zig` (then `serve.serveConn`), `.EPOLL` to `dispatch/epoll.zig`, and `.URING` to `dispatch/uring.zig`. Each model's errors are translated by its own function: `dispatchError` (`ZixHttp2_Async_*` -> `ZixHttp2_Server_ResolveFailed`, `ListenFailed`, `AcceptFailed`), `dispatchEpollError` and `dispatchUringError` (`ResolveFailed` and `ListenFailed` keep their names, every other member -> `ZixHttp2_Server_EpollSetupFailed` or `UringSetupFailed`). The `config.tls != null` branch (`tls_mux.runTlsMux` for `.EPOLL` / `.URING`, `tls_serve.runTls` otherwise) is not in `Server.zig` yet either.

`Http2.zig` is the `zix.Http2` namespace. It re-exports the public types and functions from their own files and keeps the old names `HpackEntry` (the same type as `Header`), `DEFAULT_WINDOW_SIZE`, and `MAX_PAYLOAD`.

### dispatch/async.zig

`run(config, handler)` resolves `config.ip`, listens with `reuse_address` and `kernel_backlog`, logs the listening line through `log.logSystem`, and hands every accepted stream to `io.async(connEntry, ...)`. A peer that drops before accept (`ConnectionAborted`) is skipped, any other accept failure returns `ZixHttp2_Async_AcceptFailed`. `Config.serveOpts()` maps `Config` to `ServeOpts`. `connEntry` sets the access logger, holds the pool thread's response cache (`utils/cache/async.zig`, sized by `cache.effectiveCacheEntries`), runs `serve.serveConn`, then closes the stream and releases the cache. `async_cache.reclaim()` frees the per-thread caches when the accept loop ends.

### dispatch/epoll.zig

`run(config, handler)` resolves `config.ip`, then binds `workers` listeners (0 = `cpu_affinity.availableCpuCount()`) on the calling thread with `reuse_address`, in worker order, so a bind failure returns `ZixHttp2_Epoll_ListenFailed` before anything serves and listener i is index i of the `SO_REUSEPORT` group. With `reuseport_cbpf` it calls `reuseport.attachCpuSteering` once on the first listener, a refusal is a WARN line. It then spawns one thread per listener with `worker_stack_size_bytes`, logs the listening line, and joins. Shared `stop` and `failed` flags let a worker that cannot set up end the run with `ZixHttp2_Epoll_SetupFailed`.

`workerMain` pins to its CPU slot (`cpu_affinity.pinToCpu`), sets the access logger, installs the worker response cache (`cache.installWorker`), makes the listener non-blocking, opens its epoll instance, and maps an fd-indexed `[]?*MuxConn` slot table over `slab.mapZeroedSlots(MAX_FD = 1 << 16)` (kernel-zeroed, demand-paged). `epoll_wait` drains up to 512 events with a 1 s timeout so the loop sees `stop`, and polls once more without sleeping after a busy pass. The listener drives `acceptAll`, which drains `accept4(NONBLOCK | CLOEXEC)` to EAGAIN, sets `TCP_NODELAY` and `SO_BUSY_POLL` (`busy_poll_us`), builds a `MuxConn`, and registers `EPOLL.IN | RDHUP`. A connection fd runs `serveEvent`: HUP or ERR closes, otherwise `beginCoalesce` -> `process.onReadable` -> `endCoalesce` (a failed batch write closes). On exit every remaining connection is freed and closed.

### dispatch/uring.zig

The io_uring shape of the same worker, with the same `run` (bind in order, optional CBPF, stack size, `stop` / `failed` flags). `initRing` requests `SINGLE_ISSUER | DEFER_TASKRUN | CQSIZE | CLAMP` and falls back to a flagless ring. There is no fallback to `.EPOLL`: a worker that cannot build its ring ends the run with `ZixHttp2_Uring_SetupFailed`. `waitOnce` waits with a 1 s bound (`IORING_ENTER_EXT_ARG`) when the kernel supports it, so the loop sees `stop`.

A worker arms a multishot accept (re-armed on the next pass when the SQ was full), keeps an fd-indexed `[]?*RingConn` slot table, and tags each `user_data` with `op`, a `gen: u24`, and the fd, so a stale recv CQE for a reused fd is dropped (`lookup`). `handleAccept` sets `TCP_NODELAY`, `SO_BUSY_POLL`, and `O_NONBLOCK` (a direct reply then waits for `POLL.OUT` instead of blocking the worker), builds a `MuxConn`, and arms one recv. `armRecv` compacts the accumulator and posts one `prep_recv` into `rbuf[rend..]` (one recv in flight per connection). `handleRecv` closes on 0 (after `hangupGoaway`) or an error, otherwise advances `rend`, runs `beginCoalesce` -> `process.processRing` -> `endCoalesce`, then re-arms.

### coalesce.zig and CoalesceSink.zig

`CoalesceSink` is the write buffer of one readable batch: `fd`, `len`, `failed`, and a 64 KiB `buf`. `append` stages bytes, flushing first when they do not fit, and writes a chunk larger than the whole buffer straight through after that flush, so wire order is kept and no size is too large. `flush` writes the staged bytes. Both write through `writer.writeAllDirectFD`, and a failed write sets `failed`.

`coalesce.zig` owns one threadlocal sink per worker. `beginCoalesce(fd)` resets it and installs it as `writer.write_hook`, so every frame the mux writes in that batch (HEADERS, DATA, SETTINGS, WINDOW_UPDATE) stages into one buffer and leaves as one write instead of one small segment per frame under `TCP_NODELAY`. `endCoalesce()` removes the hook, flushes, and returns whether a write failed.

### multiplexers/

Linux helpers shared by the `.EPOLL` / `.URING` models of every engine:

| File | Role |
| :- | :- |
| `slab.zig` | kernel-zeroed, demand-paged slot tables (`mapZeroedSlots` / `unmapSlots`) |
| `reuseport.zig` | `attachCpuSteering(fd, group_size)`: the classic BPF program `ld cpu, mod N, ret A` through `SO_ATTACH_REUSEPORT_CBPF`. Returns false when the kernel refuses it |
| `cpu_affinity.zig` | `availableCpuCount()` (the affinity mask, cgroup and taskset aware) and `pinToCpu(worker_id)`, which lists each physical core once before any SMT sibling (sysfs topology) and keeps the mask order without it |

### tls_mux.zig

Multiplexed h2 over TLS 1.3 (ADR-052): one `SO_REUSEPORT` listener plus one epoll instance per worker, each connection terminating TLS in place via a resumable `tls_session.Session` (no socketpair, no thread per connection). A `TlsConn` holds the session, the `?*MuxConn` h2 state (allocated once the handshake establishes and ALPN selects h2), an outbound-ciphertext backpressure buffer (`wbuf` / `woff` / `wlen`, flushed on EPOLLOUT), and a `plain` staging buffer. The pass is: recv ciphertext -> `session.feed` decrypts -> `feedMux` appends plaintext to `h2.rbuf` and runs `process.processRing` -> the mux's reply frames route through `writer.write_hook = hookWrite` -> sealed into TLS records -> `sendRaw`.

`hookWrite` is a seal-in-place gather. It accumulates plaintext into `plain`, and whenever the staged prefix plus the new write completes a full record it seals that record straight from source with `sealGather` -> `conn.tls.encrypt2(prefix, tail, sealed)` (which threads down to `connection.writeAppData2` and `record.protect2`), gathering the staged prefix with a slice of the source. This avoids copying a large DATA payload into `plain` first, only the sub-record remainder is staged. The `seal_in_place` toggle is a comptime `const` so the gather path can be A/B'd against the accumulate-then-seal fallback (`flushPlain` -> `encrypt`) without changing any other behavior. `sendRaw` preserves record order (the AEAD nonce is the record sequence number): if ciphertext is already staged it appends rather than writing directly, so a later record never overtakes a staged one on the wire.

---

###### end of lld-http2
