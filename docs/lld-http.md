# LLD -- zix.Http

Internal implementation details for the HTTP layer. For design rationale see [`docs/hld-http.md`](hld-http.md).

---

## server.zig -- HttpServer

### Initialization

`HttpServer.init(config)` stores the config and allocates the `Router` from `config.allocator`. Does not open any socket. Socket is opened in `run()`.

### run()

```
1. net.IpAddress.parse(ip, port)
2. net_addr.listen(io, .{ .kernel_backlog = max_kernel_backlog }) -> NetServer
3. accept loop:
      conn = net_server.accept(io)   -- suspends until TCP connect
      io.concurrent(handleConnection, .{ conn, ... })
```

### handleConnection()

```
1. alloc read_buf  [max_client_request]u8  from smp_allocator
2. alloc write_buf [max_client_response]u8 from smp_allocator
3. defer: free both buffers, arena.deinit()
4. std.http.Server.init(conn.stream, read_buf)
5. ArenaAllocator.init(smp_allocator)
6. keep-alive loop:
      a. receiveHead() -- suspends until request arrives, or returns on close/reset
      b. arena.reset(.retain_capacity)
      c. extra_buf = arena.alloc(HttpHeader, max_response_headers.value())
      d. build Request(inner, &reader)
         build Response(req.server, io, extra_buf)   -- io stored for Date header clock
         build Context(io, arena.allocator(), stream)
      e. router.dispatch(req, res, ctx) -- calls matched handler or static.serve
      f. if public_dir and not dispatched: static.serve(...)
      g. if not served: send 404
```

Buffer lifetimes are explicit: `read_buf` and `write_buf` are freed in the `defer` at the top of `handleConnection`. The arena is reset between requests and deinited when the connection closes.

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

`Response` carries `io: std.Io` (set during `init`) used exclusively by `send()` to obtain wall-clock time for the `Date` header via `std.Io.Clock.real`. This keeps the clock call cross-platform — `std.Io` abstracts Linux `CLOCK_REALTIME`, macOS, and Windows epoch translation behind a vtable.

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
1. Stage into 4096-byte stack buffer:
      "HTTP/1.1 {status_code} {status_text}\r\n"
      "Content-Type: {content_type}\r\n"
      "Content-Length: {body.len}\r\n"
      "Connection: {keep-alive|close}\r\n"
      "Date: {IMF-fixdate}\r\n"
      for each extra header: "{name}: {value}\r\n"
      "\r\n"
2. error.BufferTooSmall if buffer overflows
3. writer.writeAll(header_buf[0..header_len])
4. writer.writeAll(body)
5. writer.flush()
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
2. Not found:
      ts = std.Io.Clock.real.now(self.io)       -- wall-clock UTC, cross-platform
      secs = ts.toSeconds()                      -- i64, Unix epoch
      formatHttpDate(secs) -> "Day, DD Mon YYYY HH:MM:SS GMT"
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
