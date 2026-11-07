# LLD: zix.Http

Internal implementation details for the HTTP layer. For design rationale see [`docs/hld-http-en.md`](hld-http-en.md).

---

## server.zig: Server

### Public API

`Server` is one concrete struct (`{ handler: HandlerFn, config: Config, registry: ConnRegistry }`), not a comptime generic (ADR-063). `pub fn init(handler: HandlerFn, config: Config) Self` just stores both fields. Callers build `handler` via `zix.Http.Router(&[_]zix.Http.Route{...}).dispatch` and pass it in: `var server = zix.Http.Server.init(router.dispatch, .{...})`.

`init(handler, config)` stores the handler and config, nothing else: no socket is opened. The socket is opened in `run()`. `Router(routes).dispatch` itself absorbs the static-file-fallback and 404 (mirrors Http1's router), so `dispatch/common.zig` no longer owns that logic externally.

### run(): .ASYNC (dispatch_model = .ASYNC)

```
1. net.IpAddress.resolve(io, ip, port)
2. addr.listen(io, .{ .reuse_address = true, ... }) -> NetServer
3. accept loop:
      stream = net_server.accept(io)
      if (io.async(handleConnection, .{ stream, io, self })) |_| {}
      else |_| { handleConnection(stream, io, self); }  // fallback if pool exhausted
```

### run(): .EPOLL (dispatch_model = .EPOLL, Linux-only)

```
1. worker_count = if (workers == 0) cpu_count else workers
2. spawn worker_count threads -> epollWorker(self, io)
3. join all threads

epollWorker():
  1. resolve + listen with SO_REUSEPORT (reuse_address = true)
  2. setNonBlock(listener_fd)
  3. epoll_create1
  4. epoll_ctl(ADD, listener_fd, EPOLLIN)
  5. per-worker read buf + ArenaAllocator
  6. event loop (epoll_wait EPOLL_MAX_EVENTS = 1024):
       listener fd:
         loop: conn_fd = accept4(SOCK_CLOEXEC)  <- drain all pending
               break on EAGAIN / EWOULDBLOCK
               tcp_nodelay(conn_fd)
               epoll_ctl(ADD, conn_fd, EPOLLIN | EPOLLRDHUP)
       conn fd (HUP | ERR | RDHUP):
               epoll_ctl(DEL, conn_fd)
               linux.close(conn_fd)
       conn fd (readable):
               read to EAGAIN into the connection buffer
               result = processRequest(conn_fd, buf, arena, self)
               .keep_alive -> stay registered (level-triggered, no re-arm)
               .close      -> epoll_ctl(DEL, conn_fd) + linux.close(conn_fd)
```

No shared state between workers. The worker thread calls `processRequest` (dispatch/common.zig) directly: a synchronous parse/dispatch/send over the delivered bytes. The same pipeline serves every dispatch model, so body behaviour is identical on all three:

- `Expect: 100-continue` with a declared body is answered before the handler runs.
- A body past `max_request_body` is refused inside `body()` and answered `413`, a chunk framing that cannot be parsed is `error.ZixInvalidChunkedBody` and answered `400` (both only when the handler wrote nothing yet).
- After the handler, the connection closes when a declared body was not fully consumed: the handler never called `body()`, the peer stopped early, or a chunked body fell short. Leftover body bytes would otherwise be parsed as the next request.

The arena is reset between requests.

### handleConnection()

The `.ASYNC` per-connection entry (dispatch/common.zig). One call owns the whole keep-alive lifetime:

```
1. defer stream.close, setsockopt TCP_NODELAY   // disable Nagle, send each response immediately
2. install the per-connection thread-locals: compression settings, response cache
      (the multiplexed models install these once per worker, .ASYNC has no worker:
      io.async hands each connection to whichever pool thread is free)
3. Layer D: if conn_timeout_ms > 0:
      register ConnEntry{ stream, deadline = now + conn_timeout_ms } with self.registry
      defer deregister on return
4. stack_read [stack_read_buf_max]u8 on stack (stack_read_buf_max = 4096, dispatch/common)
   read_buf  = if max_recv_buf <= stack_read_buf_max: stack slice
               else smp_allocator.alloc(u8, max_recv_buf), freed when the connection closes
5. ArenaAllocator.init(smp_allocator), pre-warm with max_allocator_size, reset(.retain_capacity)
6. keep-alive loop: handleOneRequest until it returns .close
```

`handleOneRequest` resets the arena, then recv-loops until the header terminator is found (each scan resumes 3 bytes back, so a CRLFCRLF split across reads is still caught): a full buffer with no terminator answers `431` and closes, EOF or a read error closes silently. The buffered request then goes through `processRequest`, the same pipeline the event-driven models call, so body behaviour (100-continue, the `413` / `400` mapping, the close-on-unconsumed-body rule) is identical: see the `.EPOLL` section above.

Inside `processRequest`: `Request` / `Response` / `Context` are built over the buffered bytes (`ctx.stream` carries the raw TCP stream for WS/SSE), Layer B (`ctx.withTimeout`) arms the handler budget when `handler_timeout_ms` > 0, the Date header is one atomic load from the global double-buffered cache, the router dispatch owns the static-file fallback and the 404 (`ctx.public_dir`), a streaming response (`res.streaming`) closes the connection after the handler returns, and the access log line is written when a logger is configured.

Stack buffers live on the pool-thread stack for the duration of the connection. Heap buffers are freed on connection close. The arena is reset between requests and deinited when `handleConnection` returns.

Layer D (ConnRegistry) is active under `.ASYNC` only: the timer thread that calls `registry.evict()` exists only there. Layer B (`ctx.withTimeout`) is active on every dispatch model.

---

## router.zig: Router

### Route storage

One `routes: MultiArrayList(Route)` backed by `config.allocator`, plus a dedicated O(1) hash map for exact-match paths:

```
routes:    MultiArrayList(Route)             // SoA: separate kind[], path[], handler[] arrays
exact_map: StringHashMapUnmanaged(HandlerFn) // exact-path keys only, O(1) dispatch
```

`MultiArrayList` stores each field in its own contiguous array. Dispatch Pass 2 iterates only the `kind[]` slice until a PARAM match is found, then indexes into `path[]` and `handler[]`. Pass 3 zips `kind[]` and `path[]` without touching `handler[]` until a candidate is confirmed.

Each `Route`:
```zig
const RouteKind = enum { EXACT, PREFIX, PARAM };

const Route = struct {
    path:    []const u8,
    handler: HandlerFn,
    kind:    RouteKind = .EXACT,
};
```

`register()` inserts into both `routes` and `exact_map`. `deinit()` frees both. `routes` is scanned for param and prefix kinds during dispatch exact lookups bypass the scan entirely via `exact_map.get()`.

### dispatch()

```
1. exact_map.get(req.path()) -> call handler  (O(1))
2. scan routes for kind == .PARAM: matchParam(pattern, path) -> write captured params to req, call handler
3. scan routes for kind == .PREFIX: collect all where path starts with prefix (boundary-safe) -> pick longest
```

### matchParam()

Splits pattern and path by `/`. For each segment pair:
- Pattern segment starts with `:` -> capture: store name+value in `req.path_params`
- Otherwise: must equal exactly, else no match
- Segment counts must be equal

Captures are written into `req.path_params` (arena-allocated slice of `PathParam { name, value }`).

### Prefix boundary check

A prefix `/api` matches `/api`, `/api/foo`, `/api/foo/bar` but NOT `/apiv2`. The check:
```
path starts with prefix AND (path.len == prefix.len OR path[prefix.len] == '/')
```

---

## request.zig: Request

### Body caching

```zig
body_cache: ?[]const u8 = null,
```

`body()` is lazy: the first call pulls the body off the socket and stores it in `body_cache`, later calls return the cache directly.

For a Content-Length body, a declared length past `max_request_body` is refused with `error.ZixRequestBodyTooLarge` before the allocation is even reserved (the engine answers `413`), so a client cannot make the server allocate by claiming a size it never sends. The read loop then pulls until the declared length, waiting out `body_read_timeout_ms` between segments on a non-blocking fd. A peer that stops early leaves the returned slice short and `bodyComplete()` false.

A chunked body is framed by walking the chunk framing (`parser.chunkedEnd`) and decoded in place over its own read buffer: a size line that is not hex is `error.ZixInvalidChunkedBody` (the engine answers `400`), and a body that outgrows the limit is `error.ZixRequestBodyTooLarge` (`413`). Chunked declares no length up front, so the buffer grows toward the limit only as bytes actually arrive.

`bodyReceived()` counts what the reads consumed (not what the header claimed), and `bodyComplete()` whether the declared or framed end was reached.

### Path params

```zig
path_params: []PathParam = &.{},
```

Written by `Router.matchParam()` during dispatch. `pathParam(name)` does a linear scan over `path_params`.

---

## response.zig: Response

### Fields

`Response` carries `io: std.Io` (retained for potential future use, the `Date` header is now sourced from the global atomic date cache via `date_cache: ?[]const u8`, not from a clock call per request). `streaming: bool` is set to `true` by `sendStream()` so `handleConnection` breaks the keep-alive loop after the handler exits. `bytes_written: usize` is set to `body_data.len` at the start of `send()` so `handleConnection` can read the response body size for access logging without introspecting the write buffer.

### extra_buf (lazily-grown arena slice)

`extra_buf: ?[]HttpHeader` starts null allocated lazily on the first `addHeader()` call. Requests that add no custom headers pay zero allocation cost.

```
addHeader(name, value):
  1. CR/LF guard: scan name and value for \r or \n (return error if found)
  2. if extra_buf == null:
       initial = min(4, max_response_headers); if 0 -> return error.ZixTooManyHeaders
       extra_buf = allocator.alloc(HttpHeader, initial)
  3. else if extra_len >= extra_buf.len:
       if extra_buf.len >= max_response_headers -> return error.ZixTooManyHeaders
       new_cap = min(extra_buf.len * 2, max_response_headers)
       new_buf = allocator.alloc(HttpHeader, new_cap)
       @memcpy(new_buf[0..extra_len], extra_buf[0..extra_len])
       extra_buf = new_buf
  4. extra_buf[extra_len] = .{ .name = name, .value = value }
  5. extra_len += 1
```

Starts at 4 slots, doubles on each overflow, capped at `max_response_headers` (from `HeaderSize.value()`, ADR-062). `TooManyHeaders` is only returned when the cap is reached.

### send(): header write format

```
1. Stage fixed headers into a 512-byte stack buffer:
      status line: Status.statusLine(code) -> @memcpy pre-built string for common codes
                   uncommon codes: bufPrint "HTTP/1.1 {d} {s}\r\n"
      if status != 204 No Content:
          if content_type set: "Content-Type: {ct}\r\n"  // @memcpy prefix + value, no std.fmt
          "Content-Length: {N}\r\n"  // hand-rolled writeDecimal, no std.fmt
      if keep_alive set: "Connection: keep-alive\r\n" or "Connection: close\r\n"
      "Date: {date_cache}\r\n"  // @memcpy prefix + value, no std.fmt
2. Fast path (no extra headers AND body fits in remaining buffer space):
      append "\r\n" + body into the same 512-byte buffer
      one writeAll + flush // single syscall for most responses
3. Slow path (extra headers present OR body too large for stack buffer):
      writeAll(fixed headers)
      for each extra header: print "{name}: {value}\r\n"
      writeAll("\r\n")
      writeAll(body)
      flush()
```

Content-Type and Date are written with `@memcpy` of the literal prefix plus the value (not `bufPrint`), so a per-response `send()` no longer enters the `std.Io.Writer` formatting path. `buildResponse` (the zero-copy serializer the `.EPOLL` / `.URING` sink uses) produces byte-identical output the same way.

### sendStream(): SSE header write format

```
1. Stage into a 256-byte stack buffer:
      "HTTP/1.1 200 OK\r\n"
      "Content-Type: text/event-stream\r\n"
      "Cache-Control: no-cache\r\n"
      "Connection: keep-alive\r\n"
      "Date: {IMF-fixdate}\r\n"  (if date_cache non-empty)
2. writeAll(fixed headers)
3. for each extra header: print "{name}: {value}\r\n"
4. writeAll("\r\n")
5. flush()
6. set res.streaming = true
7. return SseWriter{ .fd = fd }
```

`SseWriter` holds the connection fd. Each write method calls `writeAllFD` so events reach the client without buffering. Over TLS (ADR-054) the per-connection stream sink is armed: step 1 detaches the buffered capture sink instead of flushing it (its bytes are replaced by the stream), and `writeAllFD` routes each header and event through the stream sink, encrypting one TLS record per write. In cleartext the writes go straight to the socket.

```
writeEvent(data):      writeAll("data: ") + writeAll(data) + writeAll("\n\n") + flush
writeNamedEvent(e, d): print("event: {e}\ndata: {d}\n\n") + flush
comment(text):         writeAll(": ") + writeAll(text) + writeAll("\n") + flush
```

### Connection header logic

```
omitted     if keep_alive == null (setKeepAlive() was never called)
keep-alive  if keep_alive == true  AND  req.head.keep_alive == true
close       if keep_alive == false OR   req.head.keep_alive == false
```

`keep_alive: ?bool = null` by default. `req.head.keep_alive` is set by the engine's own head parse (`parser.zig`) from the incoming request headers. Connection header is only written when the handler opts in via `setKeepAlive()`.

### Date header logic

```
1. handleConnection sets res.date_cache from the global atomic date cache (one atomic load)
2. handleConnection then scans req.iterateHeaders() once for a proxy-forwarded "date" header
      found -> overwrite res.date_cache with the proxy value
3. send() reads res.date_cache directly // no header scan at send time
      date_cache = g_date_bufs[g_date_active.load(.acquire)][0..g_date_lens[idx]]
```

**Global date cache** (`server.zig` module-level):

```
g_date_bufs:   [2][40]u8      // double-buffered IMF-fixdate strings
g_date_lens:   [2]usize       // valid length of each buffer
g_date_active: atomic(usize)  // index (0 or 1) of the current live buffer
g_date_secs:   atomic(u64)    // last wall-clock second written

.ASYNC: a background timer thread calls updateDateCache every 500 ms (std.Io.sleep), and the
        accept loop also calls it before each accept()

updateDateCache():
  cur_secs = std.Io.Clock.real.now(io).toSeconds()
  if cur_secs == g_date_secs: return  (no-op within the same second)
  next_idx = 1 - g_date_active.load(.monotonic)
  formatHttpDate(cur_secs) -> g_date_bufs[next_idx]
  g_date_active.store(next_idx, .release)  // publish atomically
  g_date_secs.store(cur_secs, .release)
```

`formatHttpDate` uses `std.time.epoch.EpochSeconds` for calendar decomposition. Day-of-week derived from `(epoch_day.day % 7 + 4) % 7` (Jan 1 1970 = Thursday = day 0).

---

## static.zig: Static file serving

Two paths behind one entry point (ADR-064): a cached path that is tried first, and the original
uncached path kept as the fallback. The cached path is inert unless `public_dir_cache_ttl_ms` is
set, so the shipped default runs everything below unchanged.

### Cached path

`static_cache.instance()` returns the process-wide table when a server installed one. A hit carries
an already-open file, its size, the content type, and a prerendered 200 header, so a repeat request
costs a hash lookup instead of an open plus a stat.

- The 200 header is replayed as bytes. A Range request cannot replay it (it is a 200 with a fixed
  `Content-Length`), so its 206 header is rendered per request from the same hit.
- The body goes out through `static_send.sendBody`: `sendfile` on Linux in cleartext, a positional
  read plus the engine's own write everywhere else. Zero copy is refused when the fd is the TLS
  capture sentinel or a TLS stream sink is installed, since a direct write would bypass encryption.
- Precompressed `.br` and `.gz` siblings are resolved once when the entry is built, and
  `compression.negotiate` picks among the variants that exist. Every variant header carries
  `Vary: Accept-Encoding`.
- A miss, an unsafe path, or a full table returns false, and the uncached path below runs.

### Traversal guard

```
if std.mem.indexOf(u8, path, "..") != null -> return false
```

### Range header parsing

Parses `Range: bytes=start-end`. Validates `start <= end < file_size`. Returns:
- `206 Partial Content` with `Content-Range: bytes start-end/total`
- `416 Range Not Satisfiable` for invalid ranges

### Chunk streaming

File is read and written in 8 KB stack-allocated chunks. No full-file buffering.

```
var chunk_buf: [8192]u8 = undefined;
var reader = file.reader(io, &chunk_buf);
loop: read chunk -> writer.writeAll(chunk) -> flush
```

### MIME resolution

`Content.typeFromExtension(ext)` maps file extension strings to `Content.Type` enum values. Falls back to `.APPLICATION_OCTET_STREAM` for unknown extensions. Case-insensitive comparison.

---

## websocket.zig: WebSocket

### Frame format (RFC 6455)

```
Byte 0: FIN(1) + RSV(3) + Opcode(4)
Byte 1: MASK(1) + Payload length(7)
  if len == 126: next 2 bytes are 16-bit length
  if len == 127: next 8 bytes are 64-bit length
Mask key: 4 bytes (present if MASK bit set, always set for client frames)
Payload: XOR each byte with mask_key[i % 4]
```

### parseFrame()

```
1. Check minimum 2 bytes available
2. Read FIN, opcode from byte 0
3. Read MASK bit, base length from byte 1
4. Read extended length if needed (2 or 8 bytes)
5. Read mask key if MASK bit set
6. Unmask payload into caller-provided payload_buf
7. Return ParseResult { frame, consumed } or null if not enough bytes
```

### RoomMap internals

```zig
rooms: std.StringHashMap(std.array_list.Managed(*Conn))
```

- `join(room, conn, io)`: `getOrPut(room)` -> append `conn` to the list
- `leave(room, conn, io)`: find `conn` in the list by pointer, `swapRemove`, then send a close frame to the removed conn
- `broadcast(room, msg, io)`: iterate list, build and write frame to each conn's stream, silently skip write failures (dead connections removed when their own handler's leave fires)

---

## multipart.zig: Parser

The parser lives in `src/utils/multipart.zig` (`zix.utils.multipart`), shared by `zix.Http` and `zix.Http1`. `zix.Http.Multipart` remains as a thin alias.

### Parsing algorithm

```
1. Scan for boundary delimiter lines ("--{boundary}")
2. Between delimiters: parse header block (Content-Disposition, Content-Type)
3. Extract name, filename from Content-Disposition
4. Slice data between end-of-headers and next delimiter
5. Append a multipart.Field to fields slice
```

All slices reference the original body bytes (no copy). `deinit()` frees only the fields slice.

---

## client_config.zig: HttpClientConfig

Plain struct with defaults. All fields visible to the caller. No internal allocations at config construction time. `io` is stored and used throughout the client's lifetime (init, request calls, deinit). `allocator` is used for response body and head copies.

Default values:

| Field | Default | Enforced in v1? |
| :- | :- | :- |
| `connect_timeout_ms` | 0 | Yes, via `connectTcpOptions` |
| `response_timeout_ms` | 0 | Yes, a readiness poll before `receiveHead` yields `error.ZixResponseTimeout` |
| `read_timeout_ms` | 0 | Yes, a readiness poll inside the body read loop yields `error.ZixReadTimeout` (Content-Length bodies only) |
| `max_response_body` | 4 MB | Yes, via `allocRemaining` |
| `follow_redirects` | true | Yes |
| `max_redirects` | 3 | Yes |
| `h2_max_read_rounds` | 4096 | Yes, bounds the HTTP/2 client read-loop |
| `user_agent` | "zix/1" | Yes, via `Request.Headers.user_agent` |
| `version` | `.HTTP_1` | Yes. `.HTTP_2` routes through the native h2-over-TLS path (`requestHttp2` / `h2_client.zig`) |
| `tls_ca_path` | null | Yes, on the https path (extra CA PEM, null = system roots) |
| `tls_verify` | true | Yes, on the `.HTTP_2` native path |

---

## client.zig: HttpClient

### init()

```
HttpClient{
    config: HttpClientConfig,                         // stored as-is
    inner:  std.http.Client{ allocator, io },         // no connections opened
}
```

No allocations. Socket is not opened until the first `request()` call.

### deinit()

```
inner.deinit()
    connection_pool.deinit(io)   // close all free + used connections
    ca_bundle.deinit(allocator)  // TLS cert bundle (no-op when TLS disabled)
```

Asserts all requests are complete (used pool is empty) before closing.

### request()

```
1. Uri.parse(url)               -> error.ZixUrlMalformed on failure
2. Protocol.fromUri(uri)        -> error.ZixUrlSchemeUnsupported if scheme is not http or https
3. uri.getHost(&host_buf)       -> error.ZixUrlHostMissing if host component is absent
4. uri.port orelse default port (80 for plain, 443 for tls)
5. Build Io.Timeout:
      connect_ms = opts.connect_timeout_ms orelse config.connect_timeout_ms
      if connect_ms > 0: .{ .duration = .{ .raw = Duration.fromMilliseconds(connect_ms), .clock = .real } }
      else .none
6. inner.connectTcpOptions(.{ host, port, protocol, timeout })
      reuses a pooled connection if one matches, opens a new TCP connection otherwise
7. Build RedirectBehavior:
      follow_redirects = false -> .unhandled  (caller receives 3xx as-is)
      max_redirects = 0        -> .not_allowed (error.TooManyHttpRedirects on any redirect)
      else                     -> @enumFromInt(max_redirects) (auto-follow up to N hops)
8. inner.request(std_method, uri, .{ connection, redirect_behavior, extra_headers, headers.user_agent })
9. Send:
      if std_method.requestHasBody():
          req.transfer_encoding = .{ .content_length = body.len }
          sendBodyUnflushed(&write_buf[8192]) -> BodyWriter
          bw.writer.writeAll(body)
          bw.end()  // flushes body writer + connection
      else:
          req.sendBodiless()  // writes head + flushes
10. receiveHead(&redirect_buf[8192])
      handles redirects internally if redirect_behavior != .unhandled
11. gpa.dupe(response.head.bytes)
      copies raw head bytes (status line + headers) to owned memory
      MUST happen before response.reader() which calls invalidateStrings()
12. @intFromEnum(response.head.status) -> status_code: u16
13. response.reader(&transfer_buf[4096]) -> *Io.Reader
14. body_reader.allocRemaining(gpa, .limited(max_response_body))
      reads body into gpa-owned []u8
      error.StreamTooLong -> return error.ZixBodyTooLarge
15. return ClientResponse{ status_code, body_data, head_bytes, allocator }
    defer req.deinit() releases connection back to pool
```

### ClientResponse.header()

```
std.http.HeaderIterator.init(head_bytes)
    index starts after first \r\n (skips status line)
    iterates name: value pairs
    linear scan until case-insensitive name match or exhausted
```

### ClientResponse.deinit()

```
if body_data.len > 0: allocator.free(body_data)
if head_bytes.len > 0: allocator.free(head_bytes)
```

Both slices are owned by `config.allocator`. Zero-length body (e.g., 204 No Content) is not freed (allocRemaining may return a non-allocated empty slice from an empty ArrayList).

---

## utils/file.zig: save

```
1. std.Io.Dir.cwd().makePath(io, dir) // create directory tree if absent
2. dir.createFile(io, filename, .{}) -> file
3. file.writeAll(io, data)
4. file.close(io)
5. return allocator.dupe(u8, dir ++ "/" ++ filename)  // caller-owned path
```

---

###### end of lld-http
