# LLD: zix.Http1

Internal implementation details for the lean HTTP/1.x engine. For design rationale see [`docs/hld-http1-en.md`](hld-http1-en.md).

---

## Http1.zig: namespace

Pure re-export module. Pulls `Server` + `ServerConfig` + `DispatchModel`, the core types (`HandlerFn`, `RawFn`, `ParsedHead`, `ParseResult`, `Range`, `ServeOpts`, `ConnOutcome`, `WsFrameFn`), the router (`Route`, `RouteKind`, `Router`, `PathParam`, `pathParam`), the `WebSocket` namespace, and the core functions (deadline, parse, write helpers) into one public surface.

---

## config.zig: Http1ServerConfig

Plain struct with defaults, no allocations at construction. Runtime-read fields:

| Field | Read by |
| :- | :- |
| `io`, `ip`, `port`, `kernel_backlog` | all models (resolve + listen) |
| `dispatch_model` | `run()` switch |
| `workers` | .POOL accept count, .MIXED and .EPOLL worker count |
| `pool_size` | .POOL pool thread count |
| `handler_timeout_ms` | armed before every dispatch in all models |
| `max_recv_buf` | .EPOLL per-connection buffer size (`ConnTable.alloc`) |
| `large_body_rcvbuf` | `SO_RCVBUF` on the large-body (upload) path only, all models, 0 = kernel default |
| `ws_recv_buf` | WebSocket per-connection buffer size, 0 falls back to `max_recv_buf`. .EPOLL sizes the recv buffer, .URING sizes the frame-accumulation buffer (`conn.buf`) and the unmask scratch |
| `send_date_header` | managed write helpers: include or omit the `Date` header |
| `tls` | selects the TLS serve path when non-null (native https), else cleartext |
| `logger` | `logSystem` lifecycle lines |

`compression`, `compression_min_size`, and `compression_max_out` (the last renamed from `max_gzip_out`) are read at runtime under `.EPOLL` and `.URING`, where a handler opts in with `core.writeNegotiated`. The legacy `core.writeGzip` helper still uses the compile-time `core.GZIP_OUT_SIZE` (256 KB), and `max_headers` is not read at runtime: it is a no-op kept for source compatibility (the lazy engine has no header-count cap).

---

## core.zig: parsing, writing, connection loops

### Constants

```
BUF_SIZE      = 16 * 1024   // receive buffer (serveConn stack, EPOLL worker scratch)
GZIP_OUT_SIZE = 256 * 1024  // writeGzip output buffer
```

### parseHead()

```
1. indexOf "\r\n\r\n"            -> error.IncompleteHeader if absent
2. request line: split on first ' ' (method), last ' ' (version)
      version must be "HTTP/1.1" (minor 1) or "HTTP/1.0" (minor 0), else error.InvalidRequest
3. target split at '?'           -> path, query
4. raw_headers = slice from after the request-line CRLF through the final header CRLF
      (no count cap, looked up lazily by getHeader, empty when there are no headers)
5. framing scan folds recognized headers into flags while walking the block
      (only a line whose first letter is c, t, or e is tokenized, others skip):
      content-length    -> parseInt u64 (unparseable -> 0)
      connection        -> "close" clears keep_alive, "keep-alive" sets it
      transfer-encoding -> contains "chunked" sets chunked_request
      expect            -> "100-continue" sets expect_continue
6. keep_alive default: version_minor == 1
```

All slices in the returned `ParsedHead` point into `buf` (zero copy). Returns `.{ head, body_offset }` where `body_offset` is the first byte after the blank line. `getHeader(head, name)` does the case-insensitive on-demand lookup over `raw_headers`, so the per-header scan cost is paid only by a handler that actually reads a header.

`parseGetFastPath` (server.zig) is the keep-alive fast path for plain `GET` requests: it confirms the `"GET "` prefix and the `"HTTP/1.1"` version with single integer loads (`std.mem.readInt` of one `u32` and one `u64`, not `mem.eql`), extracts path and query by arithmetic, and only falls back to the full `parseHead` when `Connection: close` may be present. Same `ParsedHead` shape, no per-header scan.

### recvHead()

Bulk-read into `buf` until `\r\n\r\n` is found. `pre_filled` bytes carried over from the previous keep-alive iteration are scanned first. On each read the scan restarts at `filled - 3` so a CRLFCRLF split across reads is still found. `error.HeaderTooLarge` when `buf` fills without a blank line, `error.Closed` on EOF or read failure.

### readChunkedBody()

Streaming chunked decoder (RFC 9112 7.1) for the blocking path. An inline 16 KB refill reader is seeded with the bytes already read past the header. Per chunk: read the size line (extensions after `;` ignored), copy `chunk_size` bytes into `out` (silently capped at `out.len`, excess consumed and discarded), expect CRLF. A zero chunk skips the trailer section to its final blank line. Returns decoded byte count.

### Thread-local handler deadline

```
threadlocal tl_deadline_ns: u64 = 0   // 0 = no deadline armed

setTimeout(ms): tl_deadline_ns = (ms == 0) ? 0 : wallClockNs() + ms * 1e6
isExpired():    tl_deadline_ns != 0 and wallClockNs() >= tl_deadline_ns
```

`wallClockNs()` is a raw `clock_gettime(REALTIME)`. The engine calls `setTimeout(opts.handler_timeout_ms)` before every dispatch, so a stale deadline can never leak into the next request.

### Thread-local WebSocket handoff

```
threadlocal tl_ws_pending: ?WsPending = null    // { fd, on_frame }

requestWebSocket(fd, cb): tl_ws_pending = .{ fd, cb }   // called by WebSocket.serve
takeWebSocket():          read + clear                  // called by the engine after every dispatch
```

`serveConn` / `serveConnOne` clear the handoff and close the connection (promotion is EPOLL-only). The EPOLL parse loop stores the callback into `conn.ws` and switches the connection to frame pumping.

### RespSink: per-event response coalescing

```zig
RespSink = { fd, buf, len, failed, grow_allocator, grow_cap }
threadlocal tl_resp_sink: ?*RespSink = null
```

While installed, `fdWriteAll(fd, ...)` for the matching fd appends to `buf` instead of hitting the socket:

```
append(bytes):
  bytes.len > buf.len        -> grow to fit when growable, else flush + write through directly
  len + bytes.len > buf.len  -> grow to fit when growable, else flush first
  else                       -> memcpy into buf
flush(): one fdWriteAllDirect(buf[0..len]), len = 0, failed sticky on error
grow(need): realloc buf (power-of-two) up to grow_cap, never shrinks, false when ungrowable
```

The EPOLL request loop (`serveEpollConn`) installs the sink with no `grow_allocator`, so a pipelined burst of N responses costs one `write()` and an oversized response flushes the batch then writes straight through. The URING loop installs the sink over the per-connection `send_buf` with `grow_allocator` set and `grow_cap = URING_SEND_BUF_MAX` (1 MiB): a response larger than the staged buffer grows it in place (power-of-two realloc) so the whole reply still leaves as one on-ring send, instead of stalling the worker on a blocking off-ring write (`fdWriteAllDirect`). The grown buffer never shrinks, so the recycled connection reuses it for later requests. `flushPending(fd)` lets a handler that bypasses the helpers (sendfile, raw send) flush staged bytes first so wire order matches request order.

### fdWriteAll() / fdWriteAllDirect()

`fdWriteAll` routes through the installed sink when the fd matches, otherwise calls the direct path. Direct path loop:

```
write(fd, rem)
  SUCCESS -> advance (0 bytes written = error.BrokenPipe)
  INTR    -> retry
  AGAIN   -> poll(POLLOUT, infinite) then retry   // non-blocking socket, full send buffer
  other   -> error.BrokenPipe
```

All write errors collapse to `error.BrokenPipe`: the caller's only remedy is closing the connection.

### buildSimpleHeader() and the date cache

Fixed headers are staged into a caller-provided 256-byte buffer with hand-rolled appends (no `std.fmt` on the hot path):

```
"HTTP/1.1 " + 3-digit status + ' ' + statusPhrase
["Content-Type: {s}\r\n" when content_type.len > 0]
"Content-Length: " + appendDec
"\r\nDate: " + cachedDate() + "\r\n\r\n"
```

For a known status the whole `"HTTP/1.1 <code> <phrase>\r\n"` line is emitted in one `memcpy` from a comptime-baked `statusLine` table, instead of assembling it from five pieces (`"HTTP/1.1 "` + `appendStatusCode` + `' '` + `statusPhrase` + `"\r\n"`) per response. `statusLine` returns `""` for an unknown code, where the build falls back to the piecewise path above, byte-identical to the baked line. `statusPhrase` covers the same common codes (anything else prints `Unknown`); `appendStatusCode` and `appendDec` are the manual digit writers for that fallback.

**Per-thread date cache:**

```
threadlocal tl_date: { secs, buf[40], len }
threadlocal tl_date_tick: u8

cachedDate():
  tick +%= 1
  only on tick wrap (every 256 calls) or first use:
      clock_gettime(REALTIME)
      reformat only when the second changed
```

The IMF-fixdate string is reformatted at most once per second per thread, and the clock syscall itself is amortized across 256 responses. `formatHttpDate` uses `std.time.epoch` decomposition, day-of-week from `(epoch_day % 7 + 4) % 7`.

### writeSimple()

```
1. buildSimpleHeader into 256-byte stack buffer
2. body.len <= 3840:
      memcpy header + body into one 4096-byte stack buffer
      single fdWriteAll                       // one syscall for most responses
3. larger body: writev loop with 2 iovecs (header remainder, body)
      tracks sent across partial writes, INTR retries, AGAIN polls POLLOUT
```

### Other write helpers

| Helper | Wire behaviour |
| :- | :- |
| `writeSimpleNoBody` | `buildSimpleHeader` only, Content-Length set to the would-be body size (HEAD) |
| `writeJson` | `writeSimple` with `application/json` |
| `write100Continue` | literal `HTTP/1.1 100 Continue\r\n\r\n` |
| `writeGzip` | heap-allocates 256 KB out + flate window + compressor (stack safety), compresses with `std.compress.flate` `.gzip`, then header (`Content-Encoding: gzip`) + compressed bytes |
| `writeChunkedStart` | status line + `Transfer-Encoding: chunked`, no Content-Length |
| `writeChunk` | `{x}\r\n` + data + `\r\n`, zero-length data is a no-op (would terminate the body) |
| `writeChunkedEnd` | `0\r\n\r\n` |
| `writeRange` | `parseRange` against `full_body.len`: valid gives `206` + `Content-Range` + slice, invalid gives `416` with `Content-Range: bytes */{total}` |

### serveConn(): blocking keep-alive loop

Used by .ASYNC, .POOL, and .MIXED. Stack state: `recv_buf[16 KB]`, `body_buf[8 KB]`, `leftover: usize`.

```
0. TCP_NODELAY (opts.nodelay, skipped on Windows)
loop:
  1. recvHead(fd, recv_buf, leftover)
        HeaderTooLarge -> write 431, return
  2. parseHead -> failure: write 400, return
  3. expect_continue and body present -> write100Continue
  4. body:
        chunked        -> readChunkedBody(peeked, body_buf)
        content_length -> copy peeked bytes, read until min(content_length, 8192)
  5. setTimeout(handler_timeout_ms), handler(head, body, fd)
  6. takeWebSocket() != null -> return   // promotion not honored here
  7. !keep_alive -> return
  8. pipelining: bytes past request_end shifted to recv_buf front, leftover updated
        chunked requests reset leftover to 0
```

The caller (connEntry / poolEntry) owns closing the fd. A Content-Length body above `body_buf` (8 KB) hands the handler the first 8 KB, then `serveConn` drains the remainder off the socket (and widens the receive window via `large_body_rcvbuf` / SO_RCVBUF) so the keep-alive connection stays usable. Large-body handlers read `head.content_length`, not the bytes.

### serveConnOne(): EPOLL one-shot fallback

Same parse + body + dispatch sequence as one `serveConn` iteration over caller-owned buffers, returns `ConnOutcome` instead of looping. Kept for one-shot dispatch uses, the EPOLL engine itself uses the buffered `serveEpollConn` path in server.zig.

---

## router.zig: comptime Router

### Comptime partition

`Router(routes)` counts each kind in comptime blocks, then builds:

```
exact_pairs   [exact_count]{ path, handler }  -> StaticStringMap.initComptime
prefix_routes [prefix_count]Route             -> inline for at dispatch
param_routes  [param_count]Route              -> inline for at dispatch
```

The returned type has a single decl, `dispatch`, with the exact `HandlerFn` signature, so a router plugs in anywhere a bare handler does.

### dispatch()

```
1. tl_param_count = 0
2. exact_map.get(path)                 -> call handler, return
3. inline for param_routes: matchParam -> call handler, return  (first match wins)
4. inline for prefix_routes: startsWith + boundary check (next char '/' or end)
       track longest match             -> call best handler
5. nothing matched                     -> writeSimple 404 text/plain
```

### matchParam() and the param store

```
threadlocal tl_params: [8]PathParam
threadlocal tl_param_count: usize
```

Splits pattern and path on `/` in lockstep. `:name` segments capture (empty path segment rejected, more than 8 captures rejected), literal segments must match exactly, segment counts must be equal. Captures are written into `tl_params` as they match but `tl_param_count` is committed only on full success, so a failed candidate never corrupts a later match. `pathParam(name)` is a linear scan over the committed entries. Values are slices into the request path and die with the dispatch call.

---

## server.zig: dispatch models

### logSystem()

Lifecycle lines route through `config.logger.system(.INFO, "http1", ...)` when present. Without a logger they fall back to `std.debug.print` with a `zix: ` prefix only in Debug builds (`builtin.mode == .Debug`), and are silent in release. Every zix server uses this same gated `logSystem` shape (http, http2, grpc, fix, tcp, udp, uds), so a release build with no logger emits no init noise.

### connEntry() (.ASYNC / .MIXED task body)

```
defer stream.close(io)
core.serveConn(stream.socket.handle, handler, .{ .handler_timeout_ms })
```

### runAsync()

```
1. resolve + listen (reuse_address = true, kernel_backlog)
2. accept loop: srv.accept(io) catch continue
      io.async(connEntry, ...)        // discard handle, task owns the stream
```

### ConnQueue (.POOL)

Growable ring buffer guarded by `std.Io.Mutex` + `std.Io.Condition`:

```
push: lock -> grow x2 when full (alloc failure closes the stream instead of pushing)
      -> buf[(head + len) % cap] = stream -> unlock -> signal
pop:  lock -> while empty: closed ? return null : waitUncancelable
      -> take buf[head], head advances modulo cap -> unlock
close: lock -> closed = true -> unlock -> broadcast
```

Backing storage uses `std.heap.smp_allocator`. Existing entries are re-packed to index 0 on growth.

### runPool()

```
1. worker_count = workers == 0 ? cpu_count : workers
2. pool_count   = pool_size == 0 ? max(10, cpu_count * 2) : pool_size
3. spawn pool_count poolEntry threads (512 KB stacks): pop -> serveConn -> close
4. spawn worker_count acceptEntry threads (256 KB stacks): own SO_REUSEPORT listener -> accept -> push
5. join accept threads, queue.close(), join pool threads
```

### runMixed()

`worker_count` accept threads, each with its own `SO_REUSEPORT` listener, dispatching `connEntry` via `io.async()`. Threads are spawned with the default stack size on purpose: an explicit 256 KB stack overflows when `io.async` falls back to inline dispatch (serveConn needs ~128 KB of stack).

### EPOLL engine

Linux only (`run()` falls back to `runPool` elsewhere, with a logged notice). Shared-nothing: each worker owns a private `SO_REUSEPORT` listener, a private epoll instance, and a private `ConnTable`, so no fd or slot is ever touched by two threads.

#### Conn and ConnTable

```zig
Conn = {
    fd, buf, filled,                  // buf: max_recv_buf bytes, filled: live byte count
    ws: ?WsFrameFn = null,            // set on WebSocket promotion
    drain: usize = 0,                 // oversize-body bytes still to discard
    drain_close: bool = false,        // close once the drain finishes
}
```

`ConnTable` is a flat `[]?*Conn` indexed by fd, `MAX_FD = 1 << 16` slots. Linux hands out the lowest free fd so the table stays dense at the bottom. `alloc` creates the Conn + buffer (failure closes the fd), `free` releases both and nulls the slot. Connections with fd >= MAX_FD are refused.

#### epollWorker()

```
1. private listener (reuse_address) -> setNonBlock(listener_fd)
2. epoll_create1(CLOEXEC), CTL_ADD listener (EPOLLIN)
3. per-worker scratch: body_buf[16 KB] + out_buf[16 KB] (smp_allocator)
4. event loop, EPOLL_MAX_EVENTS = 4096 per epoll_wait:
      listener event       -> acceptAll
      HUP/ERR              -> close
      conn.drain > 0       -> serveEpollDrain
      conn.ws != null      -> serveEpollWs
      else                 -> serveEpollConn
      outcome == .close    -> CTL_DEL + table.free + close(fd)
```

#### acceptAll()

`accept4(NONBLOCK | CLOEXEC)` drained to EAGAIN (level-triggered listener, so nothing is missed). Each accepted fd: TCP_NODELAY, `table.alloc(fd, max_recv_buf)`, `CTL_ADD` with `EPOLLIN | EPOLLRDHUP`. Registration failure closes the fd.

#### serveEpollConn() / serveEpollConnInner()

Outer function installs the `RespSink` over `out_buf` around the parse pass, flushes it after, and hands a just-promoted connection to `serveEpollWs` immediately (a client can pipeline its first frame with the handshake request, and the flush guarantees the 101 precedes the first echo).

Inner pass:

```
1. read into conn.buf[filled..]:
      SUCCESS n=0 -> .close, AGAIN -> proceed with what is buffered, INTR -> retry
      filled == buf.len before read -> 431, .close
2. parse loop over conn.buf[consumed..filled]:
      no "\r\n\r\n" -> break (partial head, wait for more)
      parseHead failure -> 400, .close
      body:
        chunked        -> decodeChunkedInBuf (whole body must be buffered, else break)
        fits in rem    -> body = slice, request_len = need
        need > buf.len -> oversize: dispatch with empty body, set conn.drain to the
                          unread remainder, conn.drain_close = !keep_alive,
                          reset filled, return .keep_alive
        else           -> break (body still arriving)
      setTimeout + handler(head, body, fd)
      takeWebSocket() -> conn.ws = callback, break  // bytes after this are frames
      !keep_alive -> break
3. shift unconsumed bytes to buffer front (pipelined partial request preserved)
```

One readable event therefore serves every complete pipelined request it delivered, with all responses leaving in one coalesced write.

#### decodeChunkedInBuf()

Non-streaming variant of the chunked decoder for the buffered path: requires the full chunked body (through the trailer's final CRLF) to be present in `src`, returns `{ decoded len, consumed }` or null to wait for more bytes. Out-of-space also returns null (treated as incomplete, the connection eventually 431s or closes).

#### serveEpollWs()

One read (level-triggered, remaining bytes re-fire the event), then `ws.pump` over the buffered bytes, then the standard shift of unconsumed bytes. Closes on peer EOF, close frame, write failure, or a frame wider than the whole buffer (can never complete, would spin otherwise).

#### serveEpollDrain()

Discards `conn.drain` bytes with `recvfrom(MSG_TRUNC)`: the kernel drops the bytes in place, no copy into `conn.buf`, chunk size not capped by the buffer (capped at 1 GB per call). Reads to EAGAIN, never past `conn.drain`, so the next pipelined request's bytes are untouched. When the drain hits zero: `.close` if `drain_close`, else back to normal HTTP parsing.

### URING engine

Linux only (`run()` falls back to `runPool` elsewhere). The completion-based twin of the EPOLL engine: the same shared-nothing topology (one `SO_REUSEPORT` listener and one `io_uring` ring per worker, no shared queue, no fd handoff), but driven by completions instead of readiness, so most syscall transitions are batched into the ring (ADR-037).

#### UringConn and the slot table

```zig
UringConn = {
    fd, gen, buf, filled,             // gen: u24 generation tag against fd reuse
    send_buf, staged, inflight,       // send_buf[0..inflight] held by the kernel while a send is in flight
    closing,                          // free once the last send lands
    drain: usize = 0,                 // oversize-body bytes still to discard (mirrors Conn.drain)
    drain_close: bool = false,
    ws: ?WsFrameFn = null,
}
```

`slots` is a flat `[]?*UringConn` indexed by fd (`MAX_FD` entries). Every completion's `user_data` packs `{ op, gen, fd }`, and `lookup` rejects a CQE whose `gen` no longer matches the slot, which closes the close-versus-recv race on a reused fd. A connection is half-duplex (at most one recv or one send in flight), so a blocking sink flush can never interleave with an in-flight send.

#### initUringRing()

`IoUring.init_params` with `SINGLE_ISSUER | DEFER_TASKRUN | CQSIZE | CLAMP` (single-issuer fast path on a one-thread-per-ring loop, plus an enlarged completion queue), falling back to a flagless `IoUring.init` on a kernel that lacks them. SQ `URING_ENTRIES = 4096`, CQ `URING_CQ_ENTRIES = 16 K`.

#### run() loop

```
1. armAccept (multishot)
2. submit_and_wait(1), copy_cqes into a 512-entry stack array
3. per CQE, switch on user_data.op:
      accept -> handleAccept   // re-arm on !IORING_CQE_F_MORE, alloc conn, armRecv
      recv   -> handleRecv
      send   -> handleSend
      close  -> no-op          // teardown completion, slot already recycled
```

#### armRecv() / handleRecv() / dispatch()

`armRecv` posts a plain `recv` SQE into `conn.buf[filled..]`, so data lands in place with no copy. `handleRecv` adds `cqe.res` bytes, then `dispatch` runs the parse loop, mirroring `serveEpollConnInner` without the read. A chunked body fully present in `conn.buf` decodes in place via `decodeChunkedInBuf` into the per-worker `body_buf`. A body larger than `conn.buf` is answered with an empty body, `conn.drain` is set to the unread remainder, and the drain (below) takes over. Responses stage into `conn.send_buf` through the `RespSink`, so a pipelined burst coalesces into one `submitSend`.

#### armDrainRecv()

The ring twin of `serveEpollDrain`. Posts a `recv` SQE with `MSG_TRUNC` and `sqe.len` overridden to `min(conn.drain, 1 GB)`: the kernel discards the body bytes in place (no copy into `conn.buf`, the request is not capped by the buffer length), so one recv drains the whole remaining body instead of one round-trip per `max_recv_buf`. `handleRecv` counts the drained bytes down and re-arms until `conn.drain` reaches zero, then resumes normal reads (or closes when `drain_close`). Capping the request at `conn.drain` leaves any pipelined bytes after the body untouched. Covered by the `test-runner-http1-drain-{epoll,uring}` runners, which pipeline an over-large POST then a follow-up GET on one keep-alive connection.

#### WebSocket on the ring

A per-worker `IoUring.BufferGroup` (provided-buffer ring) serves WebSocket recvs (Phase 4b): the kernel hands a buffer over only when a frame arrives, so an idle connection ties up no recv buffer, the memory-scaling win at high connection counts. `wsHandleBuf` parses a whole-frame batch in place out of the selected buffer (zero copy) and copies only a trailing partial frame into `conn.buf`. A kernel without buffer-ring support leaves `ws_bufs` null, and WebSocket falls back to the plain recv-into-`conn.buf` path.

#### finishClose(): ring teardown (ADR-041)

Teardown closes the fd on the ring, not synchronously. `finishClose` reads the fd, recycles the connection slot first (`destroyConn`, which clears the slot and returns the connection to the free list), then submits a `prep_close` SQE tagged with `OpKind.close`. It falls back to a synchronous `linux.close` only when the SQ is momentarily full. The half-duplex per-connection state guarantees no in-flight op targets the closing fd, and recycling the slot before the close completes is safe because the generation tag rejects any late CQE against the reused fd. The `close` completion is a no-op (the slot is already free). This matters under connection churn: a synchronous `close` per teardown blocks the worker between connections, so on the 64-core box the ring barely engaged its cores under reconnect storms (limited-conn, json). Keeping the close on the ring lets the worker keep reaping completions across teardowns, so the cores fill. See ADR-041 for the 64-core measurement.

The shared `OpKind` (with the `close` variant) lives in `src/multiplexers/ring.zig` (relocated from `src/tcp/io_uring`), so every io_uring engine carries a `.close => {}` arm. Only `zix.Http1` arms it for now.

### Http1ServerImpl / Server

```zig
fn Http1ServerImpl(comptime handler: HandlerFn) type
    init(config) -> .{ .config = config }   // no socket opened, no allocation
    deinit()     -> no-op
    run()        -> switch on dispatch_model (.EPOLL gated on Linux at comptime)

Server.init(comptime handler, config) -> Http1ServerImpl(handler).init(config)
```

The handler is baked into the type so `run()` takes no argument and dispatch is a direct call, not a function pointer load from config.

---

## websocket.zig: RFC 6455 codec + engine pump

### Frame format constants

```
7-bit len max 125, 126 = 16-bit extended, 127 = 64-bit extended
mask key 4 bytes (client frames always masked)
max server frame header 10 bytes
```

### parseFrame()

```
1. need 2 bytes minimum
2. byte 0: FIN + opcode, byte 1: MASK + 7-bit length
3. extended length (2 or 8 bytes) when marked
4. mask key when MASK set
5. payload capped at payload_buf.len:
      masked   -> XOR-unmask into payload_buf
      unmasked -> zero-copy slice into buf
6. return { frame, consumed } or null when bytes are still missing
```

The masked path unmasks with a 16-wide `@Vector(16, u8)` XOR against the 4-byte mask replicated four times, processing 16 bytes per iteration, with a scalar `i % 4` tail for the remaining bytes. This replaces the per-byte loop and matches it bit-for-bit (covered by 32-byte and 17-byte unmask tests).

### buildHeader() / buildFrame()

`buildHeader` writes FIN | opcode then the 7-bit / 16-bit / 64-bit length form into a >= 10 byte buffer, returns header length. `buildFrame` appends the payload after the header (buffer must hold payload + 10). Server frames are unmasked per RFC 6455 5.1.

### acceptKey() / upgrade()

`acceptKey` concatenates the client key with the RFC 6455 GUID, SHA-1, base64 into a caller `[64]u8` (`error.KeyTooLong` past 128 input bytes). `upgrade` writes the full `101 Switching Protocols` block through `core.fdWriteAll` (sink-aware, so under EPOLL it stages with the other responses).

### send() and SendSink

`SendSink` is the WebSocket twin of core's `RespSink` (same append / flush / write-through rules), installed thread-locally by `pump` for the duration of one pass.

```
send(fd, opcode, payload):
  sink active -> stage header then payload         (error.BrokenPipe if sink failed)
  payload + header <= 4096 -> build one buffer, one fdWriteAll
  larger -> write header then payload separately   (avoids a big stack copy)
```

### serve()

`acceptKey` + `upgrade` + `core.requestWebSocket(fd, on_frame)`. Called from inside an http1 handler. The engine honors the promotion under `.EPOLL` only.

### pump()

```
install SendSink(out_buf)
loop over data:
  parseFrame orelse break        // trailing partial frame left for the next read
  text/binary -> on_frame(fd, opcode, payload)
  ping        -> send pong (payload echoed)
  close       -> send close, consume, stop with close = true
  pong/continuation/other -> ignored
flush sink
return { consumed, close: close or sink.failed }
```

`consumed` counts whole frames only, so the engine's buffer shift keeps partial frames intact.

---

###### end of lld-http1
