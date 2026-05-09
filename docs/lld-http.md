# LLD -- zix.Http

Internal implementation details for the HTTP layer. For design rationale see [`docs/hld-http.md`](hld-http.md).

---

## server.zig -- Server

### Public API

`Server` is a namespace struct with a single `pub fn init(comptime stack_threshold: usize, config: Config) !HttpServerImpl(stack_threshold)`. `HttpServerImpl` is the private generic; callers use `var server = try zix.Http.Server.init(4096, .{...})` without naming the generic type.

`HttpServerImpl.init(config)` stores the config and allocates the `Router` from `config.allocator`. Does not open any socket — socket is opened in `run()`.

### ConnQueue

Shared work queue between accept threads (producers) and pool threads (consumers). Backed by `std.Io.Mutex` + `std.Io.Condition` + `std.ArrayListUnmanaged(std.Io.net.Stream)`.

```
push(stream): lock → append → unlock → signal
pop():        lock → while empty: wait → orderedRemove(0) → unlock → return stream
close():      lock → closed = true → unlock → broadcast   (unblocks all waiting pop())
```

### run() -- Model 2 (default, workers = 0 or workers ≥ 2)

```
1. worker_count = if (workers == 0) 2 else workers
2. pool_size    = if (pool_size == 0) max(10, cpu_count * 2) else pool_size
3. std.Io.Threaded.init(smp_allocator, .{ .stack_size = 512 KB }) -> thread_io
4. ConnQueue{}
5. spawn pool_size pool threads  -> poolEntry(self, &queue, thread_io)
6. spawn worker_count accept threads -> workerEntry(self, &queue, thread_io)
7. join accept threads
8. queue.close(thread_io)
9. join pool threads
```

### run() -- Model 1 (workers = 1)

```
1. net.IpAddress.resolve(io, ip, port)
2. addr.listen(io, .{ .reuse_address = true, ... }) -> NetServer
3. accept loop:
      stream = net_server.accept(io)
      if (io.concurrent(handleConnection, .{ stream, io, self })) |_| {}
      else |_| { handleConnection(stream, io, self); }  -- fallback if pool exhausted
```

### workerEntry() (Model 2 accept thread)

```
1. resolve + listen with SO_REUSEPORT (reuse_address = true)
2. loop:
      stream = net_server.accept(io)
      queue.push(stream, io)        -- never blocks on I/O
```

### poolEntry() (Model 2 pool thread)

```
loop:
    stream = queue.pop(io)          -- blocks until connection arrives
    handleConnection(stream, io, self)
```

### handleConnection()

```
1. setsockopt TCP_NODELAY           -- disable Nagle, send each response immediately
2. stack_read / stack_write [stack_threshold]u8 on stack
   read_buf  = if max_client_request  <= stack_threshold: stack slice
               else smp_allocator.alloc(u8, max_client_request)
   write_buf = if max_client_response <= stack_threshold: stack slice
               else smp_allocator.alloc(u8, max_client_response)
3. defer: heap-free if heap-allocated; stream.close()
4. std.http.Server.init(&reader.interface, &writer.interface)
5. ArenaAllocator.init(smp_allocator); pre-warm with max_allocator_size; reset(.retain_capacity)
6. keep-alive loop:
      a. arena.reset(.retain_capacity)
      b. receiveHead() -- returns on close / reset / error
      c. build Request(inner, &reader, allocator)
         build Response(inner, io, allocator, max_response_headers.value())
         build Context(io, allocator, stream)  -- ctx.stream = stream (raw TCP, for WS/SSE)
      d. load global atomic date cache: idx = g_date_active.load(.acquire); res.date_cache = g_date_bufs[idx]
      e. router.dispatch(req, res, ctx)
      f. if res.streaming: break  -- SSE handler opened a stream; connection closes on handler return
      g. if public_dir and not dispatched: static.serve(...)
      h. if not served: 404
```

Stack buffers live on the pool-thread stack for the duration of the connection. Heap buffers are freed on connection close. The arena is reset between requests and deinited when `handleConnection` returns.

---

## router.zig -- Router

### Route storage

Three separate slices backed by `config.allocator`:

```
exact_routes:  []Route  -- registerHandler()
param_routes:  []Route  -- registerParamHandler()
prefix_routes: []Route  -- registerPrefixHandler()
```

Each `Route`:
```zig
const Route = struct {
    path:    []const u8,
    handler: HandlerFn,
};
```

Routes are appended at registration time. The `exact_routes` and `prefix_routes` arrays are scanned in full for each dispatch (O(N)). `param_routes` is scanned in registration order -- first match wins.

### dispatch()

```
1. scan exact_routes: std.mem.eql(u8, req.path(), route.path) -> call handler
2. scan param_routes: matchParam(pattern, path) -> write captured params to req, call handler
3. scan prefix_routes: collect all where path starts with prefix (boundary-safe) -> pick longest
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

## request.zig -- Request

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

## response.zig -- Response

### Fields

`Response` carries `io: std.Io` (retained for potential future use; the `Date` header is now sourced from the global atomic date cache via `date_cache: ?[]const u8`, not from a clock call per request). `streaming: bool` is set to `true` by `stream()` so `handleConnection` breaks the keep-alive loop after the handler exits.

### extra_buf (arena-allocated header slice)

`extra_buf: []HttpHeader` is allocated from the per-request arena in `handleConnection` before building the `Response`. Its length equals `max_response_headers.value()`.

```
addHeader(name, value):
  1. CR/LF guard: scan name and value for \r or \n -- return error if found
  2. if header_count >= extra_buf.len -- return error.TooManyHeaders
  3. extra_buf[header_count] = .{ .name = name, .value = value }
  4. header_count += 1
```

### send() -- header write format

```
1. Stage fixed headers into a 320-byte stack buffer:
      "HTTP/1.1 {status_code} {status_text}\r\n"
      "Content-Type: {content_type}\r\n"
      "Content-Length: {body.len}\r\n"
      "Connection: {keep-alive|close}\r\n"
      "Date: {IMF-fixdate}\r\n"
2. Fast path (no extra headers AND body fits in remaining buffer space):
      append "\r\n" + body into the same 320-byte buffer
      one writeAll + flush -- single syscall for most responses
3. Slow path (extra headers present OR body too large for stack buffer):
      writeAll(fixed headers)
      for each extra header: print "{name}: {value}\r\n"
      writeAll("\r\n")
      writeAll(body)
      flush()
```

### stream() -- SSE header write format

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
keep-alive  iff  self.keep_alive == true  AND  req.head.keep_alive == true
close       otherwise (handler called setKeepAlive(false) OR client sent Connection: close)
```

`req.head.keep_alive` is parsed by `std.http` from the incoming request headers — no manual scanning.

### Date header logic

```
1. Iterate req.iterateHeaders() for "date" (case-insensitive)
      found -> use proxy-forwarded value verbatim
2. Not found: read from res.date_cache (set in handleConnection before dispatch)
      date_cache = g_date_bufs[g_date_active.load(.acquire)][0..g_date_lens[idx]]
      one atomic load, no clock syscall on the hot path
```

**Global date cache** (`server.zig` module-level):

```
g_date_bufs:   [2][40]u8      -- double-buffered IMF-fixdate strings
g_date_lens:   [2]usize       -- valid length of each buffer
g_date_active: atomic(usize)  -- index (0 or 1) of the current live buffer
g_date_secs:   atomic(u64)    -- last wall-clock second written

Model 2: timer thread calls updateDateCache every 500 ms (std.Io.sleep)
Model 1: accept loop calls updateDateCache before each accept()

updateDateCache():
  cur_secs = std.Io.Clock.real.now(io).toSeconds()
  if cur_secs == g_date_secs: return  (no-op within the same second)
  next_idx = 1 - g_date_active.load(.monotonic)
  formatHttpDate(cur_secs) -> g_date_bufs[next_idx]
  g_date_active.store(next_idx, .release)  -- publish atomically
  g_date_secs.store(cur_secs, .release)
```

`formatHttpDate` uses `std.time.epoch.EpochSeconds` for calendar decomposition. Day-of-week derived from `(epoch_day.day % 7 + 4) % 7` (Jan 1 1970 = Thursday = day 0).

---

## static.zig -- Static file serving

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

## websocket.zig -- WebSocket

### Frame format (RFC 6455)

```
Byte 0: FIN(1) + RSV(3) + Opcode(4)
Byte 1: MASK(1) + Payload length(7)
  if len == 126: next 2 bytes are 16-bit length
  if len == 127: next 8 bytes are 64-bit length
Mask key: 4 bytes (present if MASK bit set -- always set for client frames)
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
- `broadcast(room, msg, io)`: iterate list, build and write frame to each conn's stream; silently skip write failures (dead connections removed when their own handler's leave fires)

---

## upload.zig -- MultipartParser

### Parsing algorithm

```
1. Scan for boundary delimiter lines ("--{boundary}")
2. Between delimiters: parse header block (Content-Disposition, Content-Type)
3. Extract name, filename from Content-Disposition
4. Slice data between end-of-headers and next delimiter
5. Append MultipartField to fields slice
```

All slices reference the original body bytes -- no copy. `deinit()` frees only the fields slice.

---

## utils/file.zig -- saveFile

```
1. std.Io.Dir.cwd().makePath(io, dir) -- create directory tree if absent
2. dir.createFile(io, filename, .{}) -> file
3. file.writeAll(io, data)
4. file.close(io)
5. return allocator.dupe(u8, dir ++ "/" ++ filename)  -- caller-owned path
```

---

###### end of lld-http
