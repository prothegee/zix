# HLD — zix

A micro net-framework to complement network library, built on Zig 0.16.x.

---

## Goals

- Keep-alive on by default.
- Reusable, modular, high-performance network library.
- Separation of concern: one file = one responsibility.
- Data Oriented Design — flat arrays, minimal indirection.
- Not framework-magic: explicit handler registration, no reflection.

---

## Runtime Model

```mermaid
flowchart TD
    A["main()"] --> B["std.Io.Threaded.init()\nM:N async I/O backend"]
    B --> C["HttpServer.run()"]
    C --> D["net_server.accept(io)\nsuspends until TCP connection"]
    D --> E["io.concurrent(handleConnection)"]
    E --> D
    E --> F["handleConnection()"]
    F --> G["alloc read_buf\nalloc write_buf"]
    G --> H["std.http.Server.init()"]
    H --> I["ArenaAllocator\nper-connection"]
    I --> J["keep-alive loop"]
    J --> K["receiveHead()"]
    K -->|close / reset| Z["stream.close()"]
    K --> L["build Request\nResponse\nContext"]
    L --> M["Router.dispatch()"]
    M -->|matched| N["HandlerFn"]
    M -->|no match| O{"public_dir set?"}
    O -->|yes| P["static.serve()"]
    O -->|no| Q["404 Not Found"]
    P -->|file not found| Q
    N --> J
    P --> J
    Q --> J
```

Concurrency is provided by `std.Io.Threaded` (hybrid async I/O using a kernel-backed thread pool). Each accepted connection is a concurrent task — non-blocking for the accept loop. Tasks suspend on I/O without busy-waiting.

---

## Source Layout

```mermaid
graph TD
    zix["src/zix.zig\n(public API root)"]

    zix --> Tcp["src/tcp/Tcp.zig"]
    Tcp --> Http["src/tcp/http/Http.zig"]

    Http --> config["config.zig\nHttpServerConfig"]
    Http --> server["server.zig\nHttpServer"]
    Http --> router["router.zig\nRouter + HandlerFn"]
    Http --> request["request.zig\nRequest"]
    Http --> response["response.zig\nResponse + HttpHeader"]
    Http --> context["context.zig\nContext"]
    Http --> middleware["middleware.zig\nMiddleware types"]
    Http --> static["static.zig\nstatic file serving"]
    Http --> upload["upload.zig\nMultipartParser + saveFile"]
    Http --> method["method.zig\nMethod.Code enum"]
    Http --> status["status.zig\nStatus.Code enum"]
    Http --> content["content.zig\nContent.Type enum"]

    zix --> utils["src/utils/file.zig\nextension()"]
```

---

## Module Dependencies

```mermaid
graph LR
    server --> config
    server --> router
    server --> request
    server --> response
    server --> context
    server --> static

    router --> request
    router --> response
    router --> context

    request --> method
    response --> status

    static --> utils["utils/file.zig"]
    upload --> upload_self["(self-contained)"]

    middleware --> request
    middleware --> response
    middleware --> context
```

---

## Public API  (`import("zix")`)

| Symbol | Type | Description |
|--------|------|-------------|
| `HttpServerConfig` | `struct` | Server configuration (see below) |
| `HttpServer` | `struct` | Server lifecycle: init / registerHandler / run |
| `Request` | `struct` | Per-request reader: method, path, query, header, body |
| `Response` | `struct` | Per-request writer: send, sendJson, noContent, addHeader |
| `Context` | `struct` | Per-request context: io, allocator, response_sent |
| `HandlerFn` | `type` | `*const fn(*Request, *Response, *Context) anyerror!void` |
| `HttpHeader` | `struct` | `{ name: []const u8, value: []const u8 }` |
| `Tcp.Http.Method.Code` | `enum` | GET HEAD POST PUT DELETE PATCH OPTIONS TRACE CONNECT |
| `Tcp.Http.Status.Code` | `enum` | Full HTTP 1xx–5xx status codes |
| `Tcp.Http.Content.Type` | `enum` | MIME type enum with `.asString()` |

---

## HttpServerConfig

```zig
pub const HttpServerConfig = struct {
    io:                   std.Io,           // external I/O backend (std.Io.Threaded or process.io)
    allocator:            std.mem.Allocator, // used for router's route list
    ip:                   []const u8,
    port:                 u16,
    max_kernel_backlog:   usize = 1024 * 4, // TCP listen() backlog
    max_client_request:   usize = 1024 * 4, // read buffer per connection  (heap)
    max_allocator_size:   usize = 1024 * 4, // per-connection arena backing size
    max_client_response:  usize = 1024 * 4, // write buffer per connection (heap)
    public_dir:           []const u8 = "",  // static file root; "" = disabled
    public_dir_upload:    []const u8 = "u", // upload subdir under public_dir
    response_timeout_ms:  u32 = 30_000,     // reserved for future timeout enforcement
};
```

The caller owns the `io` backend and `allocator` — `HttpServer` does not call `deinit` on either.

---

## Connection Lifecycle

```mermaid
sequenceDiagram
    participant Client
    participant Server as HttpServer.run()
    participant Task as handleConnection task
    participant Router
    participant Handler as HandlerFn
    participant Static as static.serve()

    Client->>Server: TCP connect
    Server->>Task: io.concurrent(handleConnection)
    Note over Server: accept loop continues

    Task->>Task: alloc read_buf + write_buf
    Task->>Task: ArenaAllocator init

    loop keep-alive
        Client->>Task: HTTP request
        Task->>Task: receiveHead()
        Task->>Task: build Request + Response + Context
        Task->>Router: dispatch(req, res, ctx)

        alt route matched
            Router->>Handler: handler(req, res, ctx)
            Handler->>Client: HTTP response
        else no route
            Router->>Static: serve(req_path, public_dir)
            alt file found
                Static->>Client: 200 / 206 response
            else file not found
                Static->>Client: 404 Not Found
            end
        end

        Task->>Task: arena.reset()
    end

    Client->>Task: connection close
    Task->>Task: free read_buf + write_buf\narena.deinit()
```

---

## Request

Wraps `*std.http.Server.Request` + a `*std.Io.Reader` for body reading.

| Method | Returns | Notes |
|--------|---------|-------|
| `method()` | `Method.Code` | Mapped from `std.http.Method` |
| `path()` | `[]const u8` | Target stripped of query string |
| `query()` | `[]const u8` | Raw query string after `?` |
| `queryParam(key)` | `?[]const u8` | Single key from query string |
| `header(name)` | `?[]const u8` | Case-insensitive header lookup |
| `body()` | `![]const u8` | Reads `Content-Length` bytes; cached after first call |

---

## Response

Buffers response state; writes on `send()` or equivalent.

| Method | Notes |
|--------|-------|
| `setStatus(Status.Code)` | Default: `.OK` |
| `setContentType([]const u8)` | Default: `"text/plain"` |
| `setKeepAlive(bool)` | Default: `true` |
| `addHeader(name, value)` | Up to 32 extra headers |
| `send(body)` | Writes full HTTP/1.1 response + flushes |
| `sendJson(body)` | Sets `content_type = "application/json"`, then `send` |
| `noContent()` | Sets status `.NO_CONTENT`, sends empty body |

Response is written to `req.server.out` (the underlying `std.Io.Writer`). The 4 KB header buffer limits combined header size; `error.BufferTooSmall` is returned if exceeded.

---

## Router Dispatch

```mermaid
flowchart TD
    A["Router.dispatch(req, res, ctx)"] --> B["i = 0"]
    B --> C{"i < routes.len?"}
    C -->|no| D["return false\n(no match)"]
    C -->|yes| E{"routes[i].path\n== req.path()?"}
    E -->|no| F["i += 1"]
    F --> C
    E -->|yes| G["handler(req, res, ctx)"]
    G --> H["return true"]
```

Registration order is preserved; first match wins. Routes are added via `registerHandler()` before `run()`.

---

## Static File Serving  (`static.zig`)

```mermaid
flowchart TD
    A["static.serve(req, path, public_dir, io)"] --> B{"path contains '..'?"}
    B -->|yes| Z["return false\n(traversal rejected)"]
    B -->|no| C["build full_path =\npublic_dir/path"]
    C --> D{"file exists?"}
    D -->|no| Z2["return false"]
    D -->|yes| E{"Range header\npresent?"}
    E -->|yes| F["parse Range\n→ 206 Partial Content\nor 416 Range Not Satisfiable"]
    E -->|no| G["200 OK\nstream full file\nin 8 KB chunks"]
    F --> H["return true"]
    G --> H
```

- Directory traversal (`..`) rejected.
- MIME type resolved from file extension.
- `Range` header supported → `206 Partial Content` (RFC 7233).

---

## Upload  (`upload.zig`)

`MultipartParser` — parses `multipart/form-data` body into `[]MultipartField`.  
`saveFile(io, dir, filename, data)` — writes a field's data to `dir/filename`.

Not wired into the server automatically; handlers call these directly.

---

## Middleware  (`middleware.zig`)

Types defined, chain runner not yet implemented.

```zig
pub const NextFn    = *const fn (*Request, *Response, *Context) anyerror!void;
pub const Middleware = struct {
    name:   []const u8,
    handle: *const fn (*Request, *Response, *Context, NextFn) anyerror!void,
};
```

---

## Memory Model

```mermaid
graph TD
    PA["config.allocator\n(caller-owned)"] -->|route list| RL["Router.routes\nprocess lifetime"]

    SMP["std.heap.smp_allocator\n(global, lock-free per-CPU)"] -->|per connection| RB["read_buf\nwrite_buf\nfreed on close"]
    SMP -->|per connection| Arena["ArenaAllocator\nreset per request\ndeinit on close"]

    Arena -->|per request| REQ["Request.body_cache\nResponse buffers\ntemp allocations"]
```

| Scope | Allocator | Lifetime |
|-------|-----------|----------|
| Router route list | `config.allocator` | Process lifetime |
| Read/write I/O buffers | `smp_allocator` | Connection lifetime |
| Per-request allocations | Per-connection `ArenaAllocator` (reset each request) | Request lifetime |
| WebSocket rooms (future) | `smp_allocator` | Connection lifetime |

---

## Not Yet Implemented

| Feature | Location |
|---------|----------|
| Middleware chain runner | `middleware.zig` |
| WebSocket upgrade + room broadcast | `websocket.zig` (planned) |
| Response timeout enforcement | `config.response_timeout_ms` reserved |
| UDP support | `src/udp/` (reserved) |
| HTTP/2 / TLS | out of scope |

---

## Performance Reference  (from `rnd/`)

| Mode | Benchmark | req/s |
|------|-----------|-------|
| `io.concurrent` async (server_implementation.zig) | wrk -c100 -t6 -d10s | ~349 k |
| `std.Thread.spawn` detached (server_configuration.zig) | wrk -c100 -t2 -d10s | ~254 k |

Current `HttpServer` uses the `io.concurrent` pattern.

---

###### end of HLD
