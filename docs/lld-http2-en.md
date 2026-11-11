# LLD: zix.Http2 (h2c HTTP/2)

Internal implementation details. For design rationale see [`docs/hld-http2-en.md`](hld-http2-en.md), ADR-043 (the per-engine `dispatch/` split), and ADR-052 (multiplexed TLS).

The blocking model (`.ASYNC`) uses one connection path (`serve.serveConn` -> `serveLoop`). The `.EPOLL` and `.URING` models drive a separate, resumable, non-blocking state machine (`mux.zig`) that owns the bulk of this document. Both feed one comptime `Router`. The TLS path (`config.tls != null`) terminates in place, either multiplexed (`tls_mux.zig`, for `.EPOLL` / `.URING`) or thread-per-connection (`tls_serve.zig`, which also serves TLS 1.2).

---

## mux.zig

The resumable h2c state machine for `.EPOLL` / `.URING`. One `MuxConn` per fd. The read accumulator `rbuf` persists across readable events and holds a partial frame until the rest arrives, so a single worker drives many connections. Connection frames and responses write straight to the fd via the `frame.*` helpers (which poll on EAGAIN for a non-blocking socket), and a handler runs inline on the worker, so like the gRPC mux it must stay bounded.

### MuxStream

One stream within a connection, borrowed from the per-worker pool while open.

```zig
const MuxStream = struct {
    id: u31 = 0,
    state: StreamState = .IDLE,                          // IDLE | OPEN | HALF_CLOSED_REMOTE | CLOSED
    headers: [frame.MAX_HEADERS]hpack.Header = undefined,// inline, MAX_HEADERS = 64
    header_count: usize = 0,
    header_scratch: []u8 = &.{},                         // pooled buffer, sized to opts.max_header_scratch
    body: []u8 = &.{},                                   // pooled buffer, sized to opts.max_body
    body_len: usize = 0,
    end_headers: bool = false,
    end_stream: bool = false,

    send_window: i64 = 65535,          // peer's remaining receive window for this stream (RFC 7540 6.9)
    pending_body: []const u8 = &.{},   // unsent tail of a body capped by a window, resumed by WINDOW_UPDATE
    pending_end: bool = false,

    next_free: ?*MuxStream = null,     // freelist link, valid only while idle in the pool
};
```

`headers` is an inline array. `body` and `header_scratch` are the pooled stream's own buffers, sized by the serve options and reused across borrows. `pending_body` points into caller-owned memory that must outlive the stream (the static cache), so the slot stays borrowed until it drains.

### MuxConn

Heap-owned per-connection h2 state, one per fd, private to the owning worker.

```zig
pub const MuxConn = struct {
    fd: std.posix.fd_t,
    opts: ServeOpts,

    rbuf: []u8,                 // read accumulator, persists across events, holds partial frames
    rstart: usize,
    rend: usize,

    hpack_dec: HpackDecoder,
    streams: []*MuxStream,      // pointer array: an idle conn reserves max_streams pointers, not buffers
    slots: []bool,

    last_stream_id: u31,
    phase: MuxPhase,            // await_preface | await_upgrade | await_preface2 | h2

    send_window: i64 = 65535,      // connection-level send window (all our DATA)
    peer_init_window: i64 = 65535, // peer's SETTINGS_INITIAL_WINDOW_SIZE, the starting per-stream window

    pub fn init(fd, opts) ?*MuxConn   // one alloc each for conn, rbuf, streams, slots; null on OOM
    pub fn deinit(self) void          // returns any still-open stream to the pool first
};
```

`rbuf` is sized `max(opts.conn_read_buf_min, opts.max_frame_size + frame.FRAME_PAYLOAD_SLACK + 9)`. Because `streams` holds pointers, the heavy per-stream state (inline header table plus body / scratch buffers) is not reserved at connection open, it is borrowed from the pool on stream open.

### Per-worker stream-slot pool

The key allocation strategy. A worker drives many connections from one thread, and each connection borrows a `MuxStream` only while a stream is open, returning it on close. The freelist is a threadlocal (shared-nothing per worker, no atomics), so resident stream memory tracks concurrent streams on the worker, not connections times `max_streams`. Buffers are allocated once per pooled stream and reused across borrows, so the steady state does zero per-stream allocation.

```zig
threadlocal var stream_pool: ?*MuxStream = null;

fn acquireStream(opts) ?*MuxStream  // pop the freelist (reset clean) or grow with a fresh stream + buffers
fn releaseStream(st) void           // reset scalars (st.* = .{}), keep body / header_scratch, LIFO push
fn releaseSlot(conn, slot) void     // mark the slot free and return its borrowed stream to the pool
```

`acquireStream` pops the freelist when non-empty (the slot was already cleared on release) and returns it if its buffers meet `opts.max_body` / `opts.max_header_scratch`, otherwise it grows the pool with a fresh `MuxStream` plus a `max_body` body and a `max_header_scratch` scratch. `releaseStream` saves the two buffers, resets every scalar to defaults, restores the buffers, and pushes LIFO so a hot stream is reused first.

### slotFor / findSlot

`slotFor(conn, stream_id)` claims the first free slot, borrows a stream via `acquireStream`, stamps its id, and returns the index (null at `max_streams` or on a pool allocation failure, the caller then sends `RST_STREAM REFUSED_STREAM`). `findSlot(stream_id, streams, used)` locates an open stream by id. Both are linear scans over `max_streams`.

### muxProcess / muxFrameLoop

`muxProcess` is the handshake phase machine, then the frame loop:

- `await_preface`: need 3 bytes. If they are not `"PRI"`, set `await_upgrade` and call `muxHandleUpgrade`. Else need the 24-byte `PREFACE`, validate it, send server SETTINGS, set `h2`.
- `await_upgrade`: `muxHandleUpgrade` (accumulate to `\r\n\r\n`, reply `400` without `Upgrade: h2c`, `101` with it, then `await_preface2`, and the stream-1 request is not served).
- `await_preface2`: after the `101`, validate the preface, send SETTINGS, set `h2`.
- `h2`: `muxFrameLoop`.

`muxFrameLoop` runs over the buffered bytes while a whole frame is present:

```
loop:
    if buffered < 9 -> return .keep_alive
    fh = parseFrameHeader(rbuf[rstart..][0..9])
    if fh.length > max_payload -> GOAWAY FRAME_SIZE_ERROR, return .close
    if buffered < 9 + fh.length -> return .keep_alive
    advance past header + payload
    switch fh.frame_type:
        SETTINGS      -> skip ACK; apply HEADER_TABLE_SIZE (resize + evictTo) and
                         INITIAL_WINDOW_SIZE (shift every open stream's send_window by the
                         delta, RFC 7540 6.9.2); send ACK + one connection WINDOW_UPDATE
        WINDOW_UPDATE -> stream 0: send_window += inc, resumeAll; else findSlot,
                         stream.send_window += inc, resumeStream
        HEADERS       -> id guards; slotFor; reset stream; send_window = peer_init_window;
                         strip padding / priority; hpack decode into header_scratch;
                         on END_HEADERS + END_STREAM -> muxDispatch
        CONTINUATION  -> findSlot; append-decode; dispatch on END
        DATA          -> findSlot; strip padding; WINDOW_UPDATE(0) + WINDOW_UPDATE(sid) for
                         the data length; copy into body, shed with 413 past max_body;
                         dispatch on END_STREAM
        RST_STREAM    -> findSlot -> releaseSlot
        PING          -> skip ACK; sendPingAckFD
        GOAWAY        -> return .close
        PRIORITY      -> ignore
```

A decode failure sends `RST_STREAM COMPRESSION_ERROR` and frees the slot. `sendServerSettings` advertises `MAX_CONCURRENT_STREAMS`, `INITIAL_WINDOW_SIZE` 65535, `MAX_FRAME_SIZE`, and `ENABLE_PUSH` 0.

### muxDispatch

Extracts method / path from the decoded pseudo-headers (length-gated compares: `:path` is 5, `:method` is 7), sets `active_conn = conn`, records `tl_req_path` / `tl_req_body` only when a response cache is installed, and calls `router.Router(routes).dispatch`. After the handler returns, the slot is freed unless the response body is parked on a window (`pending_body.len > 0`), in which case a later `WINDOW_UPDATE` resumes and frees it.

### pumpBody / resumeStream / resumeAll / sendResponseStreamFD

The send-side flow control (`active_conn` is the threadlocal that binds a running handler's send back to its connection windows).

- `pumpBody(conn, stream, body, end)`: writes DATA up to `min(conn.send_window, stream.send_window)` and `max_frame_size`, decrements both windows per chunk, sets END_STREAM only on the final chunk once the whole body has gone out, and parks the remainder in `pending_body` / `pending_end`.
- `resumeStream(conn, slot)`: after a stream window grew, `pumpBody`s the parked tail and frees the slot when it fully drains.
- `resumeAll(conn)`: after the connection window grew, resumes every parked stream.
- `sendResponseStreamFD(fd, sid, status, content_type, content_encoding, body)`: the flow-controlled response entry. With no `active_conn` or no matching slot it falls back to `writer.sendResponseEncodedFD` (immediate, unmetered). Otherwise it writes HEADERS (`sendRespHeadersFD` -> `response_block.respHeaderBlock`) then `pumpBody(..., true)`. The body is referenced, not copied, so it must outlive the stream (a process-lifetime cache).

### onReadable / processRing

`onReadable` (`.EPOLL`) loops: compact `rbuf`, `read` into `rbuf[rend..]` (WouldBlock -> `keep_alive`, 0 or error -> `close`), then `muxProcess`, repeating until EAGAIN. Level-triggered epoll re-fires if more arrives. `processRing` (`.URING`) is the same processing pass with no read loop and no trailing flush: the ring owns the recv and re-arms it after this returns.

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

`writer.zig` is the write side. `writeAllFD` marks the stream answered (`tl_responded`) and checks a threadlocal `write_hook`: when set (the TLS seal path, or the coalescing sink) it hands the plaintext to the hook, otherwise it calls `writeAllDirectFD`, the blocking write-all that polls on `POLL.OUT` for a non-blocking socket's EAGAIN and retries on INTR. `writeAllDirectFD` is also the hook's own flush path, so a coalescing flush does not re-enter the hook. `writeFrameHeaderFD` encodes and writes one header.

`sendResponseFD` -> `sendResponseEncodedFD` (also in `writer.zig`) is the immediate, unmetered response (no flow control): HEADERS via `respHeaderBlock`, then the body framed in `<= DEFAULT_MAX_FRAME_SIZE` DATA chunks with END_STREAM on the last (or on HEADERS when the body is empty). A body at or under `SEND_STAGE_BODY_MAX` (4 KiB) leaves as one staged write, a larger one as one vectored write per DATA chunk (the HEADERS block rides the first chunk, a write hook receives each pair as two appends). Large bodies that may exceed the peer window use `mux.sendResponseStreamFD` instead.

`reader.zig` is the read side: `readOnceFD`, `recvExact` (fills the buffer or returns `Closed`), and `readFrameHeader`.

`control.zig` holds `sendSettingsFD` / `sendSettingsAckFD` / `sendPingAckFD` / `sendGoawayFD` / `sendRstStreamFD` / `sendWindowUpdateFD`, each encoding one control frame. A fixed-size control frame leaves as one write.

---

## Blocking core (serve.zig and its parts)

Shared request processing and the blocking connection path, split by responsibility:

| file | holds |
| :- | :- |
| `ServeOpts.zig` | per-connection serving knobs |
| `serve.zig` | `serveConn`: preface or upgrade, then one frame at a time |
| `upgrade.zig` + `UpgradeHead.zig` | HTTP/1.1 half of the h2c upgrade (`accept`, answers 101) |
| `Stream.zig` | one request stream: decoded headers and body |
| `stream_state.zig` | `StreamState` (RFC 7540 section 5.1) |
| `stream_slot.zig` | stream table `claim`, `find`, `requestInFlight` |
| `declared.zig` + `stream_body.zig` | content-length against DATA bytes (`declared`, `isWhole`) |
| `stream_invoke.zig` | `invokeWhole`: finished stream to `Request`, then the handler |
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
| `mux.zig` (`.EPOLL` / `.URING`) | `conn.peer_max_frame_size`, which the mux already tracked for `pumpBody` |
| `serve.serveLoop` (blocking models) | a running local, updated from every SETTINGS frame with the 16384..16777215 check (`MAX_FRAME_SIZE_LIMIT`), since a peer may raise it mid-connection |
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
| `zeroCopyAllowed` | true on Linux for a real fd (`fd >= 0`), false everywhere else. Frames are written straight to the socket today, so `sendfile` cannot overtake its own HEADERS frame |

`Source` carries `{ file, size, content_type, content_encoding, bytes }` and `Segment` carries `{ offset, length, status, content_range }`, so a cached and an uncached file, and a 200 and a 206, share one framing path. `Content-Length` carries the segment length, not the file size, or a client waits for bytes that never arrive. An empty file closes the stream on HEADERS with no DATA frame at all.

Note: when `mux.zig` lands, its frame batching hook stages frames in a buffer. `zeroCopyAllowed` must then refuse while the hook is set, or the body overtakes frames already staged.

Range parsing is shared with the other engines: `utils/http/range_header.zig`. `parseSpec` (read the header) and `resolve` (clamp against a known length) are separate calls on purpose, because one nullable result cannot tell "ignore the header" apart from "answer 416".

---

## dispatch/ and tls_mux.zig

`server.zig` holds the public `Http2Server` type and a thin `run()` switch: `.ASYNC` keeps the accept-thread structure (`common.ConnTask` plus `common.dispatchConn`) and calls `serve.serveConn`, `.EPOLL` calls `epoll.runEpoll`, `.URING` calls `uring.runUring`, and `config.tls != null` routes `.EPOLL` / `.URING` to `tls_mux.runTlsMux`, everything else to `tls_serve.runTls`. Before any of that, `run()` rejects `.EPOLL` / `.URING` off Linux with `error.ZixDispatchModelUnsupported` (ADR-065).

### dispatch/epoll.zig

`ConnTable` is a private per-worker fd -> `*MuxConn` map, indexed by fd over `slab.mapZeroedSlots(MAX_FD = 1 << 16)` (kernel-zeroed, demand-paged), not shared between workers. `acceptAll` drains `accept4(NONBLOCK | CLOEXEC)` to EAGAIN, sets `TCP_NODELAY` and the optional busy-poll, builds a `MuxConn`, and registers `EPOLL.IN | RDHUP`. `epollMuxWorkerFn(routes)` pins to a CPU, opens a private `SO_REUSEPORT` listener plus its own epoll instance and optional response cache, and runs `epoll_wait` (up to 512 events): the listener drives `acceptAll`, a connection fd runs `beginCoalesce` -> `mux.onReadable` -> `endCoalesce` (close on a batch write failure). `runEpoll` spawns `worker_count = workers` (0 = available CPU count) threads and joins them.

### dispatch/uring.zig

The io_uring shape of the same loop (ADR-037 Phase 4). `initUringRing` requests `SINGLE_ISSUER | DEFER_TASKRUN | CQSIZE | CLAMP` and falls back to a flagless ring. A worker arms a multishot accept, keeps an fd-indexed `[]?*UringConn` slot table, and tags each `user_data` with a `gen: u24` so a stale recv CQE for a reused fd is dropped (`lookup`). `armRecv` compacts the accumulator then posts one `prep_recv` into `rbuf[rend..]` (one recv in flight per connection), and `handleRecv` advances `rend`, runs `beginCoalesce` -> `mux.processRing` -> `endCoalesce`, then re-arms. Responses go direct-to-fd on the non-blocking socket (no reply cork is ring-sent). `runUring` probes the ring at startup and falls back to `runEpoll` when io_uring is unavailable.

### dispatch/common.zig

`serveOpts(cfg)` maps `Config` (`Config.zig`) to `ServeOpts` (`max_recv_buf` -> `conn_read_buf_min`, `tls_write_buf_initial_bytes` -> `tls_write_buf_initial`, plus the cache fields and `public_dir`). It also holds `setNoDelay`, `setBusyPoll`, `pinToCpu` and `getAvailableCpuCount` (both cgroup-mask aware), and `effectiveCacheEntries` (honors `cache_max_total_bytes`).

The write-coalescing sink is the batching primitive for the cleartext mux: `MuxCoalesceSink` (a 64 KiB threadlocal, one per worker) is installed as `writer.write_hook` by `beginCoalesce(fd)` and torn down by `endCoalesce()`. While installed, every frame the mux writes in one readable batch (HEADERS, DATA, SETTINGS, WINDOW_UPDATE) stages into one buffer and leaves as a single write, so a many-stream batch is one segment rather than one tiny segment per frame under `TCP_NODELAY`. It flushes when full and writes an oversized frame straight through, so correctness never depends on the buffer size. `endCoalesce` returns whether a write failed during the batch.

### tls_mux.zig

Multiplexed h2 over TLS 1.3 (ADR-052): one `SO_REUSEPORT` listener plus one epoll instance per worker, each connection terminating TLS in place via a resumable `tls_session.Session` (no socketpair, no thread per connection). A `TlsConn` holds the session, the `?*MuxConn` h2 state (allocated once the handshake establishes and ALPN selects h2), an outbound-ciphertext backpressure buffer (`wbuf` / `woff` / `wlen`, flushed on EPOLLOUT), and a `plain` staging buffer. The pass is: recv ciphertext -> `session.feed` decrypts -> `feedMux` appends plaintext to `h2.rbuf` and runs `mux.processRing` -> the mux's reply frames route through `writer.write_hook = hookWrite` -> sealed into TLS records -> `sendRaw`.

`hookWrite` is a seal-in-place gather. It accumulates plaintext into `plain`, and whenever the staged prefix plus the new write completes a full record it seals that record straight from source with `sealGather` -> `conn.tls.encrypt2(prefix, tail, sealed)` (which threads down to `connection.writeAppData2` and `record.protect2`), gathering the staged prefix with a slice of the source. This avoids copying a large DATA payload into `plain` first, only the sub-record remainder is staged. The `seal_in_place` toggle is a comptime `const` so the gather path can be A/B'd against the accumulate-then-seal fallback (`flushPlain` -> `encrypt`) without changing any other behavior. `sendRaw` preserves record order (the AEAD nonce is the record sequence number): if ciphertext is already staged it appends rather than writing directly, so a later record never overtakes a staged one on the wire.

---

###### end of lld-http2
