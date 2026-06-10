# LLD: zix.Http

Internal implementation details for the HTTP layer. For design rationale see [`docs/hld-http.md`](hld-http.md).

---

## server.zig: Server

### Public API

`Server` is a namespace struct with a single `pub fn init(comptime stack_threshold: usize, config: Config) !HttpServerImpl(stack_threshold)`. `HttpServerImpl` is the private generic. Callers use `var server = try zix.Http.Server.init(4096, .{...})` without naming the generic type.

`HttpServerImpl.init(config)` stores the config and allocates the `Router` from `config.allocator`. Does not open any socket — socket is opened in `run()`.

### ConnQueue

Shared work queue between accept threads (producers) and pool threads (consumers). Backed by `std.Io.Mutex` + `std.Io.Condition` + `std.ArrayListUnmanaged(std.Io.net.Stream)`.

```
push(stream): lock -> append -> unlock -> signal
pop():        lock -> while empty: wait -> orderedRemove(0) -> unlock -> return stream
close():      lock -> closed = true -> unlock -> broadcast   (unblocks all waiting pop())
```

### run(): .POOL (dispatch_model = .POOL)

```
1. worker_count = if (workers == 0) cpu_count else workers
2. pool_size    = if (pool_size == 0) max(10, cpu_count * 2) else pool_size
3. std.Io.Threaded.init(smp_allocator, .{ .stack_size = 512 KB }) -> thread_io
4. ConnQueue{}
5. spawn timer thread  -> timerLoop(thread_io, &self.registry)
      every 500ms: updateDateCache + registry.evict (Layer D connection guard)
6. spawn pool_size pool threads  -> poolEntry(self, &queue, thread_io)
7. spawn worker_count accept threads -> workerEntry(self, &queue, thread_io)
8. join accept threads
9. queue.close(thread_io)
10. join pool threads
```

### run(): .ASYNC (dispatch_model = .ASYNC)

```
1. net.IpAddress.resolve(io, ip, port)
2. addr.listen(io, .{ .reuse_address = true, ... }) -> NetServer
3. accept loop:
      stream = net_server.accept(io)
      if (io.async(handleConnection, .{ stream, io, self })) |_| {}
      else |_| { handleConnection(stream, io, self); }  // fallback if pool exhausted
```

### run(): .MIXED (dispatch_model = .MIXED)

```
1. worker_count = if (workers == 0) cpu_count else workers
2. spawn worker_count asyncWorkerEntry threads
3. each asyncWorkerEntry:
      resolve + listen with SO_REUSEPORT
      accept loop:
        stream = net_server.accept(io)
        if (io.async(handleConnection, .{ stream, io, self })) |_| {}
        else |_| { handleConnection(stream, io, self); }
```

### workerEntry() (.POOL accept thread)

```
1. resolve + listen with SO_REUSEPORT (reuse_address = true)
2. loop:
      stream = net_server.accept(io)
      queue.push(stream, io)        // never blocks on I/O
```

### poolEntry() (.POOL pool thread)

```
loop:
    stream = queue.pop(io)          // blocks until connection arrives
    handleConnection(stream, io, self)
```

### handleConnection()

```
1. setsockopt TCP_NODELAY           // disable Nagle, send each response immediately
2. Layer D: if conn_timeout_ms > 0:
      register ConnEntry{ stream, deadline = now + conn_timeout_ms } with self.registry
      defer deregister on return (marks done=true, removes from registry)
3. stack_read / stack_write [stack_threshold]u8 on stack
   read_buf  = if max_recv_buf  <= stack_threshold: stack slice
               else smp_allocator.alloc(u8, max_recv_buf)
   write_buf = if max_client_response <= stack_threshold: stack slice
               else smp_allocator.alloc(u8, max_client_response)
4. defer: heap-free if heap-allocated stream.close()
5. std.http.Server.init(&reader.interface, &writer.interface)
6. ArenaAllocator.init(smp_allocator), pre-warm with max_allocator_size, reset(.retain_capacity)
7. keep-alive loop:
      a. arena.reset(.retain_capacity)
      b. receiveHead() // breaks on HttpConnectionClosing / ConnectionResetByPeer / ReadFailed
            ReadFailed: Layer D timer thread called stream.shutdown(.both) -> connection expired
      c. build Request(inner, &reader, allocator)
         build Response(inner, io, allocator, max_response_headers.value())
         build Context(io, allocator, stream)  // ctx.stream = stream (raw TCP, for WS/SSE)
      d. Layer B: if handler_timeout_ms > 0: ctx = ctx.withTimeout(handler_timeout_ms)
            sets ctx.deadline, handler calls ctx.timedOut() between steps to check budget
      e. load global atomic date cache: idx = g_date_active.load(.acquire), res.date_cache = g_date_bufs[idx]
      f. router.dispatch(req, res, ctx)
      g. if res.streaming: break  // SSE handler opened a stream, connection closes on handler return
      h. if public_dir and not dispatched: static.serve(...)
      i. if not served: 404
      j. if cfg.logger: lg.access(method_str, req.path(), status_code, res.bytes_written, ua, origin)
            method_str: stringFromEnum(req.method())
            ua:     req.header("user-agent") orelse ""
            origin: req.header("origin") orelse ""
```

Stack buffers live on the pool-thread stack for the duration of the connection. Heap buffers are freed on connection close. The arena is reset between requests and deinited when `handleConnection` returns.

Layer D (ConnRegistry) is active in model 2 only: the timer thread that calls `registry.evict()` exists only in model 2. Layer B (`ctx.withTimeout`) is active in both models.

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

`body()` reads `Content-Length` bytes on the first call and stores in `body_cache`. Subsequent calls return `body_cache` directly. Reading happens via `*std.Io.Reader` which holds the underlying stream reference.

### Path params

```zig
path_params: []PathParam = &.{},
```

Written by `Router.matchParam()` during dispatch. `pathParam(name)` does a linear scan over `path_params`.

---

## response.zig: Response

### Fields

`Response` carries `io: std.Io` (retained for potential future use, the `Date` header is now sourced from the global atomic date cache via `date_cache: ?[]const u8`, not from a clock call per request). `streaming: bool` is set to `true` by `stream()` so `handleConnection` breaks the keep-alive loop after the handler exits. `bytes_written: usize` is set to `body_data.len` at the start of `send()` so `handleConnection` can read the response body size for access logging without introspecting the write buffer.

### extra_buf (lazily-grown arena slice)

`extra_buf: ?[]HttpHeader` starts null allocated lazily on the first `addHeader()` call. Requests that add no custom headers pay zero allocation cost.

```
addHeader(name, value):
  1. CR/LF guard: scan name and value for \r or \n (return error if found)
  2. if extra_buf == null:
       initial = min(4, max_headers); if 0 -> return error.TooManyHeaders
       extra_buf = allocator.alloc(HttpHeader, initial)
  3. else if extra_len >= extra_buf.len:
       if extra_buf.len >= max_headers -> return error.TooManyHeaders
       new_cap = min(extra_buf.len * 2, max_headers)
       new_buf = allocator.alloc(HttpHeader, new_cap)
       @memcpy(new_buf[0..extra_len], extra_buf[0..extra_len])
       extra_buf = new_buf
  4. extra_buf[extra_len] = .{ .name = name, .value = value }
  5. extra_len += 1
```

Starts at 4 slots, doubles on each overflow, capped at `max_headers` (from `HeaderSize.value()`). `TooManyHeaders` is only returned when the cap is reached.

### send(): header write format

```
1. Stage fixed headers into a 512-byte stack buffer:
      status line: Status.statusLine(code) -> @memcpy pre-built string for common codes
                   uncommon codes: bufPrint "HTTP/1.1 {d} {s}\r\n"
      if status != 204 No Content:
          if content_type set: "Content-Type: {ct}\r\n"
          "Content-Length: {N}\r\n"  // hand-rolled writeDecimal, no std.fmt
      if keep_alive set: "Connection: keep-alive\r\n" or "Connection: close\r\n"
      "Date: {date_cache}\r\n"
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

### stream(): SSE header write format

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
7. return SseWriter{ .out = req.server.out }
```

`SseWriter` holds a `*std.Io.Writer` pointer to the connection's write buffer. Each write method flushes immediately so events reach the client without buffering.

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

`keep_alive: ?bool = null` by default. `req.head.keep_alive` is parsed by `std.http` from the incoming request headers (no manual scanning). Connection header is only written when the handler opts in via `setKeepAlive()`.

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

.POOL: timer thread calls updateDateCache every 500 ms (std.Io.sleep)
.ASYNC: accept loop calls updateDateCache before each accept()

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
- `leave(room, conn, io)`: find `conn` in the list by pointer, `swapRemove`; sends close frame to removed conn
- `broadcast(room, msg, io)`: iterate list, build and write frame to each conn's stream, silently skip write failures (dead connections removed when their own handler's leave fires)

---

## upload.zig: MultipartParser

### Parsing algorithm

```
1. Scan for boundary delimiter lines ("--{boundary}")
2. Between delimiters: parse header block (Content-Disposition, Content-Type)
3. Extract name, filename from Content-Disposition
4. Slice data between end-of-headers and next delimiter
5. Append MultipartField to fields slice
```

All slices reference the original body bytes (no copy). `deinit()` frees only the fields slice.

---

## client_config.zig: HttpClientConfig

Plain struct with defaults. All fields visible to the caller. No internal allocations at config construction time. `io` is stored and used throughout the client's lifetime (init, request calls, deinit). `allocator` is used for response body and head copies.

Default values:

| Field | Default | Enforced in v1? |
| :- | :- | :- |
| `connect_timeout_ms` | 0 | Yes, via `connectTcpOptions` |
| `response_timeout_ms` | 0 | No, stored only |
| `read_timeout_ms` | 0 | No, stored only |
| `max_response_body` | 4 MB | Yes, via `allocRemaining` |
| `follow_redirects` | true | Yes |
| `max_redirects` | 3 | Yes |
| `user_agent` | "zix/1" | Yes, via `Request.Headers.user_agent` |

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
1. Uri.parse(url)               -> error.InvalidUrl on failure
2. Protocol.fromUri(uri)        -> error.InvalidUrl if scheme is not http or https
3. uri.getHost(&host_buf)       -> error.InvalidUrl if host component is absent
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
      error.StreamTooLong -> return error.BodyTooLarge
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
