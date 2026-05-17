# README

<h1 align="center">
    <b><i>ZIX</i></b>
</h1>

<p align="center" style="color: #C3C3C3;font-color: #C3C3C3;">
    <b><i>Zero sIX; 06;</i></b>
</p>


<p align="center" style="color: #C3C3C3;font-color: #C3C3C3;">
    <i>A network backend library written in zig.</i>
</p>

<div align="center">
    <img src="zix-logo.svg" alt="zix-logo" style="display: block; margin: auto;" align="center" width="243px">
</div>

<p align="center" style="color: #C3C3C3;font-color: #C3C3C3;">
    <i>Where the wire meets the will.</i>
</p>

<p align="center" style="color: #C3C3C3;font-color: #C3C3C3;">
    <i>Every byte owned, every thread deliberate, every route explicit.</i>
</p>

<p align="center" style="color: #C3C3C3;font-color: #C3C3C3;">
    <i>No hidden cost. Just clean metal and honest code - predictable by principle</i>
</p>

---

<p align="center" style="color: #C3C3C3;font-color: #C3C3C3;">
    <i>You are the thinker. Tinker.. Assembler... The builder, Not just as user/coder....</i>
</p>

---

## A Reason.. A Motivation...

__*1. Explicit Over Implicit.*__

__*2. Modular & Maintanable.*__

__*3. Performance-First Architecture.*__

__*4. Practical Features, Ready to Use.*__

__*5. Modern Efficient Concurrency Model.*__

__*6. Predictable, Transparent Memory Management.*__

<!-- > Valued performance, clarity, and control. -->

<br>

## Requirements

- Zig 0.16.x

<br>

## Repositories

- [Codeberg as Main](https://codeberg.org/prothegee/zix)
- [Github as Mirror #1](https://github.com/prothegee/zix)

<br>

## Important Contribution Notes

- Always push Zig and their std.
- Single file, single responsibility.
- Significant change/s required RnD/PoC.
- Narrowing down the system thinking then be explicit.
- A "nice to have" and "maybe we need this" is tertiary.
- Always fix from our side first rather than Zig feature/s side.

<br>

## Documentation

| Document | Description |
| :- | :- |
| [`docs/hld-http.md`](docs/hld-http.md) | HTTP: goals, runtime model, API, router, WebSocket, SSE, memory model |
| [`docs/hld-udp.md`](docs/hld-udp.md) | UDP: goals, runtime model, API, packet model, endianness, disconnect |
| [`docs/hld-uds.md`](docs/hld-uds.md) | UDS: goals, API, frame format, server/client lifecycle |
| [`docs/hld-channel.md`](docs/hld-channel.md) | Channel: goals, model, API, concurrency requirement, examples |
| [`docs/lld-http.md`](docs/lld-http.md) | HTTP: internal data structures and algorithms |
| [`docs/lld-udp.md`](docs/lld-udp.md) | UDP: internal data structures and algorithms |
| [`docs/lld-uds.md`](docs/lld-uds.md) | UDS: internal server/client structure and frame handling |
| [`docs/lld-channel.md`](docs/lld-channel.md) | Channel: ring buffer internals, locking, send/recv algorithms |
| [`docs/concurrency.md`](docs/concurrency.md) | Dispatch models: POOL, ASYNC, MIXED. Thread counts, protocol applicability, Channel note. |
| [`docs/adr.md`](docs/adr.md) | Architecture Decision Records |
| [`docs/headers.md`](docs/headers.md) | Response header cap: tiers, security, error handling |
| [`docs/tests.md`](docs/tests.md) | Test tiers (unit / integration / behaviour / edge) and how to run |

<br>

## Getting Started

Fetch zix to your project:

```sh
zig fetch --save "git+https://codeberg.org/prothegee/zix#main" # upstream
```

or 

```sh
zig fetch --save "git+https://codeberg.org/prothegee/zix#0.1.x" # upstream v0.1.x
```

> You can change to mirror too as `github.com/prothegee/zix`
>
> For specifc version, use `MAJOR.MINOR.x`, i.e. `#0.1.x` and replace `#main`

<br>

Add to your project (`build.zig` file):

```sh
const zix = b.dependency("zix", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zix", zix.module("zix"));
```

<br>

## Examples

For more examples see the `examples` directory.

### Minimal examples

Auto I/O (work-queue thread pool, default):
```zig
const std = @import("std");
const zix = @import("zix");

pub fn homeHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    try res.send("hello from zix");
}

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var server = try zix.Http.Server.init(4096, .{
        .io = process.io,
        .allocator = arena.allocator(),
        .ip = "127.0.0.1",
        .port = 9000,
        .max_kernel_backlog = 1024 * 4,
        .max_client_request = 1024 * 4,
        .max_allocator_size = 1024 * 4,
        .max_client_response = 1024 * 4,
    });
    defer server.deinit();

    server.registerHandler("/", homeHandler);

    try server.run();
}
```

Manual I/O (explicit concurrency limit via `concurrent_limit`, `.ASYNC` dispatch):
```zig
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{
        .concurrent_limit = std.Io.Limit.limited(4), // pin to 4 concurrent tasks
        // .concurrent_limit = .unlimited             // let runtime decide
    });
    defer threaded.deinit();

    var server = try zix.Http.Server.init(4096, .{
        .io = threaded.io(),
        .allocator = arena.allocator(),
        .ip = "127.0.0.1",
        .port = 9000,
        .max_kernel_backlog = 1024 * 4,
        .max_client_request = 1024 * 4,
        .max_allocator_size = 1024 * 4,
        .max_client_response = 1024 * 4,
        .dispatch_model = .ASYNC, // .ASYNC uses the caller's io directly
    });
    defer server.deinit();

    server.registerHandler("/", homeHandler);

    try server.run();
}
```

<br>

### Routing

Three explicit functions, each with a distinct purpose:

```zig
server.registerHandler("/about", aboutHandler);
// exact — matches only /about

server.registerPrefixHandler("/api", apiHandler);
// prefix — matches /api, /api/foo, /api/foo/bar, NOT /apiv2

server.registerParamHandler("/users/:id", userHandler);
// param — matches /users/alice, captures id="alice"
// read inside handler: req.pathParam("id")

server.registerParamHandler("/:tenant/:branch", branchHandler);
// multi-param — req.pathParam("tenant"), req.pathParam("branch")
```

**Priority:**

```
exact  >  param  >  prefix (longer prefix beats shorter)
```

Exact and prefix priority is independent of registration order. **Param routes are the exception** — when two patterns have the same segment count and both match, the first-registered wins. Register more-literal patterns before all-param patterns of the same depth:

```zig
// Correct order — /path/user/:id wins for /path/user/alice
server.registerParamHandler("/path/user/:id", userHandler);       // more literals first
server.registerParamHandler("/path/:tenant-id/:branch", tenantHandler); // all-param second
```

| Registered | Request | Winner | Reason |
| :- | :- | :- | :- |
| `/path/info` (exact) + `/path/:id` (param) | `/path/info` | `/path/info` | exact beats param |
| `/path/:id` (param) + `/path` (prefix) | `/path/alice` | `/path/:id` | param beats prefix |
| `/api/v2` + `/api` (both prefix) | `/api/v2/foo` | `/api/v2` | longer prefix wins |
| `/path/user/:id` (1st) + `/path/:a/:b` (2nd) | `/path/user/alice` | `/path/user/:id` | more literals registered first |

**Regex-like matching** — zix has no regex engine. `registerPrefixHandler` is the equivalent of `/prefix/(.*)`: it covers the prefix and any sub-path below it. Additional filtering is done inside the handler with plain string operations on `req.path()`:

```zig
// Intent: /secret/(.*)  ->  only serve files with ?sec=abc123
server.registerPrefixHandler("/secret", secretHandler);

// Inside secretHandler — extract sub-path and apply custom logic
const sub = req.path()["/secret/".len..];          // e.g. "file.txt"
// check extension, depth, query params, headers, etc.
```

Any match logic expressible as string operations — extension checks, version parsing, depth limits — belongs in the handler body, not the route pattern.

<br>

### Concurrency Model

Three dispatch models, selected via `config.dispatch_model` (`DispatchModel` enum, default `.POOL`):

**`.POOL` — work-queue thread pool (default):**

N accept threads push connections to a shared `ConnQueue`. M pool threads pop and handle each connection synchronously with blocking I/O — no scheduler overhead. Best throughput under high connection counts. `SO_REUSEPORT` lets all accept threads listen on the same port.

```zig
pub fn main(process: std.process.Init) !void {
    var server = try zix.Http.Server.init(4096, .{
        .io = process.io,
        // dispatch_model = .POOL (default, can be omitted)
        // workers        = 0  -> cpu_count accept threads (auto)
        // pool_size      = 0  -> max(10, cpu_count * 2) pool threads (auto)
        ...
    });
```

**`.ASYNC` — single accept, `io.async()` dispatch:**

One accept thread dispatches each connection via `io.async()`. `workers` and `pool_size` are ignored. Preferred for SSE and WebSocket (long-lived connections do not hold pool threads). Also suitable for explicit `concurrent_limit`.

```zig
var server = try zix.Http.Server.init(4096, .{
    .io             = process.io,
    .dispatch_model = .ASYNC,
    ...
});
```

**`.MIXED` — N accept threads, `io.async()` dispatch:**

N accept threads each dispatch connections via `io.async()` directly — no `ConnQueue`. Balanced throughput and latency. `pool_size` is ignored.

```zig
var server = try zix.Http.Server.init(4096, .{
    .io             = process.io,
    .dispatch_model = .MIXED,
    ...
});
```

See [`docs/concurrency.md`](docs/concurrency.md) for architecture details and thread counts.

<br>

### Timeouts

Two independent timeout layers, both disabled by default (`0`):

**`conn_timeout_ms`**: network-level connection guard (Layer D). The timer thread shuts down connections that have been open longer than this without completing. Protects pool threads from clients that stall before or during header send. Effective in model 2 only.

**`handler_timeout_ms`**: per-handler execution budget (Layer B). Sets `ctx.deadline` before each dispatch. Handlers opt in by calling `ctx.timedOut()` between expensive steps.

```zig
var server = try zix.Http.Server.init(4096, .{
    .io = process.io,
    .allocator = arena.allocator(),
    .ip = "127.0.0.1",
    .port = 9000,
    .conn_timeout_ms    = 30_000, // close stalled connections after 30s
    .handler_timeout_ms = 5_000,  // handler budget: 5s
});
```

Handler using the budget:

```zig
pub fn slowHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;

    doStep1(ctx.io);
    if (ctx.timedOut()) {
        res.setStatus(.REQUEST_TIMEOUT);
        return res.sendJson("{\"error\":\"timeout\"}");
    }

    doStep2(ctx.io);
    if (ctx.timedOut()) {
        res.setStatus(.REQUEST_TIMEOUT);
        return res.sendJson("{\"error\":\"timeout\"}");
    }

    try res.sendJson("{\"result\":\"ok\"}");
}
```

`ctx.timedOut()` is a no-op (always returns `false`) when `handler_timeout_ms == 0`. `conn_timeout_ms` should be >= `handler_timeout_ms` to avoid the connection being cut before the handler can send a 408. See `examples/http_timeout_resp.zig` and `docs/adr.md` (ADR-018) for design rationale.

<br>

### Middleware

Middleware is composed at comptime using wrapper functions. Each wrapper takes a `comptime next: zix.Http.HandlerFn` and returns a new `HandlerFn` — no heap allocation, no runtime chain runner.

```zig
fn withOriginCheck(comptime next: zix.Http.HandlerFn) zix.Http.HandlerFn {
    return struct {
        fn handle(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) anyerror!void {
            const origin = req.header("origin") orelse "";
            if (!isAllowedOrigin(origin)) {
                res.setStatus(.FORBIDDEN);
                try res.sendJson("{\"error\":\"forbidden origin\"}");
                return;
            }
            return next(req, res, ctx);
        }
    }.handle;
}

fn withBasicAuth(comptime next: zix.Http.HandlerFn) zix.Http.HandlerFn {
    return struct {
        fn handle(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) anyerror!void {
            // validate Authorization: Basic <base64(user:pass)>
            // ...
            return next(req, res, ctx);
        }
    }.handle;
}
```

Compose left-to-right — the outermost wrapper runs first:

```zig
// origin check only
server.registerHandler("/public",  withOriginCheck(publicHandler));

// origin check -> basic auth -> handler
server.registerHandler("/private", withOriginCheck(withBasicAuth(privateHandler)));
```

```
# curl examples
curl -H "Origin: http://localhost" "http://localhost:9008/public"                         # 200
curl "http://localhost:9008/public"                                                       # 403

curl -H "Origin: http://localhost" -u "admin:secret" "http://localhost:9008/private"      # 200
curl -H "Origin: http://localhost" "http://localhost:9008/private"                        # 401
curl "http://localhost:9008/private"                                                      # 403
```

For a full working example see `examples/http_middleware.zig`.

<br>

### WebSocket

Room-based broadcast over RFC 6455. A param handler upgrades the connection and enters a per-task frame loop — no separate thread needed.

```zig
var ws_rooms: zix.Http.WebSocket.RoomMap = undefined;

pub fn wsHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    const room_id = req.pathParam("room-id") orelse return;

    // Read query params BEFORE upgrade() — unavailable after the 101 handshake.
    const display_name = req.queryParam("name") orelse "anonymous";

    // extract Sec-WebSocket-Key from headers, then handshake
    var accept_buf: [64]u8 = undefined;
    const accept = try zix.Http.WebSocket.acceptKey(ws_key, &accept_buf);
    try zix.Http.WebSocket.upgrade(ctx.stream, ctx.io, accept); // writes 101 directly

    // heap-allocate conn, join room, both are cleaned up via defer (LIFO)
    const conn = try std.heap.smp_allocator.create(zix.Http.WebSocket.Conn);
    conn.* = .{ .stream = ctx.stream, .io = ctx.io };
    defer std.heap.smp_allocator.destroy(conn);
    ws_rooms.join(room_id, conn, ctx.io);
    defer ws_rooms.leave(room_id, conn, ctx.io);  // runs before destroy

    // frame loop:
    //   text/binary -> broadcast "[display_name] payload" to room
    //   ping        -> pong
    //   close       -> echo close frame + break
    //   EOF / error -> best-effort close frame + break
    _ = display_name;
}

pub fn main(process: std.process.Init) !void {
    ws_rooms = zix.Http.WebSocket.RoomMap.init(std.heap.smp_allocator);
    defer ws_rooms.deinit();
    // ...
    server.registerParamHandler("/ws/:room-id", wsHandler);
}
```

```
# Connect with wscat or websocat, ?name sets the broadcast display name
wscat    -c "ws://localhost:9008/ws/lobby?name=alice"
websocat    "ws://localhost:9008/ws/lobby?name=alice"

# ?name is optional — omit for "anonymous"
wscat    -c "ws://localhost:9008/ws/lobby"
```

**Priority:** exact > param > prefix — `/ws/:room-id` is a param route, so `/ws/lobby` captures `room-id = "lobby"`.

`ctx.stream` is the raw TCP stream exposed via `Context`. The server sets it for **every** connection before calling any handler — HTTP handlers ignore it, WebSocket handlers use it after the 101 upgrade.

**Combining HTTP, static, and WebSocket in one server** — register all handler types together, routing handles dispatch. Unmatched routes fall through to static serving:

```zig
server.registerHandler("/", homeHandler);
server.registerPrefixHandler("/api", apiHandler);
server.registerParamHandler("/ws/:room-id", wsHandler);
// + set public_dir in HttpServerConfig for static files
```

<br>

### SSE (Server-Sent Events)

One-way server push over HTTP/1.1 — no WebSocket handshake, browser-native `EventSource` reconnect.

```zig
// GET /events — streams "tick N" once per second
pub fn eventsHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    const sse = try res.stream(); // sends SSE headers, returns SseWriter
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "tick {d}", .{i}) catch break;
        sse.writeEvent(msg) catch break;                                       // data: tick N\n\n
        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(1000), .awake) catch break;
    }
    // handler returns -> connection closes -> EventSource auto-reconnects
}
```

| `SseWriter` method | Wire format |
| :- | :- |
| `writeEvent(data)` | `data: <data>\n\n` |
| `writeNamedEvent(event, data)` | `event: <event>\ndata: <data>\n\n` |
| `comment(text)` | `: <text>\n` (keepalive) |

**Dispatch model:** use `.ASYNC`. SSE connections are long-lived — they would exhaust a blocking pool (`.POOL`) one thread per open stream. `.ASYNC` dispatches each connection via `io.async()`, keeping pool threads free.

```zig
var server = try zix.Http.Server.init(4096, .{
    .io             = process.io,
    .dispatch_model = .ASYNC, // preferred for SSE: long-lived connections do not hold pool threads
    ...
});
server.registerHandler("/events", eventsHandler);
```

```sh
curl -N http://localhost:9010/events
```

See `examples/http_sse.zig` for a full example with a browser-compatible HTML page.

<br>

### HTTP Client

`zix.Http.Client` makes outbound HTTP requests. Each call returns a `ClientResponse` the caller owns and must release with `deinit()`.

```zig
var client = zix.Http.Client.init(.{
    .allocator         = arena.allocator(),
    .io                = process.io,
    .connect_timeout_ms = 5000,       // error.Timeout if TCP connect takes > 5s
    .max_response_body  = 64 * 1024,  // error.BodyTooLarge if body exceeds 64 KB
});
defer client.deinit();

// GET
var resp = try client.get("http://127.0.0.1:9000/", .{});
defer resp.deinit();
std.debug.print("{d}: {s}\n", .{ resp.status(), resp.body() });

// GET with header inspection
if (resp.header("content-type")) |ct| {
    std.debug.print("content-type: {s}\n", .{ct});
}

// POST with body and custom headers
const extra = [_]std.http.Header{
    .{ .name = "X-Trace-Id", .value = "abc-123" },
};
var post_resp = try client.post("http://127.0.0.1:9000/api/items", .{
    .headers = &extra,
    .body    = "{\"name\":\"widget\"}",
});
defer post_resp.deinit();

// Per-request connect timeout override
var fast = try client.get("http://127.0.0.1:9000/health", .{
    .connect_timeout_ms = 500,
});
defer fast.deinit();
```

| Method shorthand | Sends body? |
| :- | :- |
| `client.get(url, opts)` | no |
| `client.head(url, opts)` | no |
| `client.post(url, opts)` | yes (Content-Length: 0 if opts.body is null) |
| `client.put(url, opts)` | yes |
| `client.patch(url, opts)` | yes |
| `client.delete(url, opts)` | no |
| `client.request(method, url, opts)` | depends on method |

| Error | Condition |
| :- | :- |
| `error.InvalidUrl` | malformed URL, unsupported scheme, or missing host |
| `error.BodyTooLarge` | response body exceeded `max_response_body` |
| `error.Timeout` | TCP connect exceeded `connect_timeout_ms` |

Redirects are followed automatically up to `max_redirects` (default 3). Set `follow_redirects = false` to receive the 3xx response directly.

See `examples/http_client.zig` and [`docs/hld-http.md`](docs/hld-http.md) for details.

<br>

### Static Files & Upload

Set `public_dir` in `HttpServerConfig` to enable static file serving. `server.run()` returns `error.PublicDirNotFound` if the directory does not exist. Use a `createInitDirs` helper to create all required directories before `Server.init`:

```zig
fn createInitDirs(io: std.Io) void {
    std.Io.Dir.cwd().createDirPath(io, "./public") catch {};
    std.Io.Dir.cwd().createDirPath(io, "./public/u") catch {};
}

pub fn main(process: std.process.Init) !void {
    createInitDirs(process.io); // idempotent — safe on every start

    var server = try zix.Http.Server.init(.{
        // ...
        .public_dir        = "./public", // validated at run(); "" = disabled
        .public_dir_upload = "u",
    });
```

- Unmatched routes fall through to static serving from `public_dir`.
- Range requests (`Range: bytes=…`) -> `206 Partial Content` (RFC 7233).
- Directory traversal (`..`) is rejected.

**Upload** — parse the multipart body in a handler, optionally rename before saving:

```zig
var parser = zix.Http.Multipart.init(ctx.allocator, boundary);
defer parser.deinit();
try parser.parse(try req.body());

if (parser.getField("file")) |f| {
    // you can rename file first before save by replacing the filename string, e.g.:
    //   const filename = "custom_name.txt"
    // or build it dynamically:
    //   const filename = try std.fmt.allocPrint(ctx.allocator, "{s}_{s}", .{ sessionid, f.filename orelse "upload" });
    const filename = f.filename orelse "upload";
    const path = try zix.utils.file.save(ctx.io, ctx.allocator, "./public/u", filename, f.data);
    _ = path; // arena-allocated, valid for this request
}
```

`zix.utils.file.save` creates the destination directory if needed and returns a caller-owned path copy.

```
# curl example: upload a file with JSON metadata
curl -X POST "http://localhost:9005/upload" \
  -F "file=@/path/to/file.txt" \
  -F 'data={"userid":0,"sessionid":"01944f5a-0000-7000-8000-000000000000"}'
```

**Access-controlled serving** — use a prefix handler to gate files behind a required query param. Check file existence before the param so the auth requirement is not revealed for non-existent paths:

```zig
// GET /secret/<file>?sec=abc123
// 404 if file not found, 403 if sec param missing or wrong, 200 if both pass
server.registerPrefixHandler("/secret", secretHandler);
```

```
curl "http://localhost:9005/secret/file.txt?sec=abc123"    # 200
curl "http://localhost:9005/secret/file.txt"               # 403 (file exists, no param)
curl "http://localhost:9005/secret/missing.txt?sec=abc123" # 404
```

<br>

## Response Header Cap (`HeaderSize`)

`HttpServerConfig.max_response_headers` controls how many custom headers `res.addHeader()` will accept per response. Pick the tier that matches your deployment:

| Variant | Cap | Typical use |
| :- | :- | :- |
| `.MINIMAL` | 16 | Simple internal APIs, controlled environments |
| `.COMMON` | 32 | **Default.** Most web apps, single proxy |
| `.LARGE` | 64 | CDN + proxy, load balancers, CORS-heavy APIs |
| `.EXTRA_LARGE` | 128 | k8s, service mesh, heavy forwarding stacks |
| `.{ .CUSTOM = N }` | N | Explicit cap, arena-allocated to exactly N slots per request |

```zig
var server = try zix.Http.Server.init(.{
    // ...
    .max_response_headers = .LARGE,                // 64 headers
    // .max_response_headers = .{ .CUSTOM = 48 },  // explicit
});
```

`addHeader()` returns `error.TooManyHeaders` when the cap is reached and `error.InvalidHeaderName` / `error.InvalidHeaderValue` if the name or value contains CR or LF (header injection guard).

`.{ .CUSTOM = N }` allocates exactly N slots from the per-request arena — no ceiling, no clamping.

For security guidance and tier selection see [`docs/headers.md`](docs/headers.md). For a working demonstration see `examples/http_xtra_headers.zig`.

<br>

## Request Header Cap (`RequestHeaderSize`)

`HttpServerConfig.max_request_headers` controls how many headers the server accepts per request. Requests exceeding the cap are rejected with `431 Request Header Fields Too Large`.

| Variant | Cap | Note |
| :- | :- | :- |
| `.MINIMAL` | 16 | Strict APIs, internal services |
| `.COMMON` | 32 | Most web applications |
| `.LARGE` | 64 | **Default.** Parser storage limit. CDN, proxy, CORS-heavy APIs |
| `.{ .CUSTOM = N }` | N (capped at 64) | Explicit cap; values above 64 silently capped at the parser limit |

```zig
var server = try zix.Http.Server.init(4096, .{
    // ...
    .max_request_headers = .COMMON,                // 32 headers
    // .max_request_headers = .{ .CUSTOM = 24 },   // explicit
});
```

The parser storage limit is 64 — `CUSTOM` values above 64 are silently capped. See `zix.Http.RequestHeaderSize`.

<br>

## UDS (Unix Domain Sockets)

Same-host IPC over a Unix stream socket. The server accepts connections and dispatches each as a concurrent task. Both sides use a 4-byte length-prefixed frame format.

```zig
// Process A: UDS server (data provider)
pub fn main(process: std.process.Init) !void {
    var server = try zix.Uds.Server.init(.{
        .path      = "/tmp/app.sock",
        .allocator = std.heap.smp_allocator,
    });
    defer server.deinit();
    try server.run(process.io);        // built-in echo handler
    // try server.runWith(process.io, myHandler); // custom handler
}
```

```zig
// Process B: UDS client (consumer)
var client = try zix.Uds.Client.connect(.{ .path = "/tmp/app.sock" }, io);
defer client.deinit(io);

try client.sendMsg(io, "get");              // sends [u32 len][payload]
var buf: [4096]u8 = undefined;
const reply = try client.recvMsg(io, &buf); // reads [u32 len][payload]
```

Custom handler: receives the raw stream directly:

```zig
fn myHandler(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);
    // read/write frames using stream.reader() and stream.writer()
}

try server.runWith(process.io, myHandler);
```

**Frame format:** `[u32 payload_len, native LE, 4 bytes][payload bytes]`. Frames with payload > `max_msg_len` (default 4096) close the connection.

See `examples/uds_server.zig` and `examples/uds_http.zig` for full working examples. For design details see [`docs/hld-uds.md`](docs/hld-uds.md).

<br>

## Channel

Typed, fiber-safe in-process message passing. A buffered ring queue that connects producer and consumer tasks (OS threads or `io.concurrent` fibers) within the same process.

```zig
const MyChan = zix.Channel(u32);

// capacity 8: send blocks when full, recv blocks when empty
var ch = try MyChan.init(std.heap.smp_allocator, 8);
defer ch.deinit();

// producer (runs in its own thread / task)
try ch.send(io, 42);
ch.close(io); // signal done: receivers drain, then get error.Closed

// consumer (runs in its own thread / task)
while (true) {
    const v = ch.recv(io) catch break; // error.Closed when channel is drained and closed
    // process v
}
```

`send` and `recv` require an `io` valid on the calling thread. Each OS thread needs its own `std.Io` (e.g. from `std.Io.Threaded`):

```zig
var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
defer threaded.deinit();
const io = threaded.io();

const t = try std.Thread.spawn(.{}, workerFn, .{ &ch, io });
t.join();
```

| Example | Pattern |
| :- | :- |
| `examples/channel_basic.zig` | Producer/consumer: two OS threads, Channel(u32) |
| `examples/channel_worker_pool.zig` | Fan-out: one producer, many consumer workers |
| `examples/channel_pipeline.zig` | Multi-stage pipeline: backpressure flows upstream |
| `examples/channel_ipc_a.zig` + `ipc_b.zig` | Inter-process coordination pair |
| `examples/uds_http.zig` | HTTP + UDS + Channel: full integration pattern |

For design details see [`docs/hld-channel.md`](docs/hld-channel.md).

<br>

## UDP

Type-safe UDP server and client. The user defines their own `extern struct` packet. Zix handles endianness, size validation, and concurrency.

```zig
const std = @import("std");
const zix = @import("zix");

const Packet = extern struct {
    id:       [16]u8,
    kind:     i32,
    register: u32,
    position: [3]f64,
};

const MyServer = zix.Udp.Server(Packet);

pub fn main(process: std.process.Init) !void {
    var server = try MyServer.init(.{
        .allocator  = std.heap.smp_allocator,
        .ip         = "127.0.0.1",
        .port       = 9100,
        .port_mode  = .REQUIRED,
        .endianness = .LITTLE,
        .broadcast  = true,   // relay each packet to all connected clients
        .auto_ack   = false,
        .disconnect_timeout_ms = 5000,
        .poll_timeout_ms       = 2000,
    });
    defer server.deinit();
    try server.run(process.io);
}
```

Client (concurrent send + receive):

```zig
const MyClient = zix.Udp.Client(Packet);

pub fn main(process: std.process.Init) !void {
    const io = process.io;
    var client = try MyClient.init(.{
        .server_ip   = "127.0.0.1",
        .server_port = 9100,
        .bind_port   = 9101,
        .port_mode   = .REQUIRED,
        .endianness  = .LITTLE,
        .send_every  = 1000,
    }, io);
    defer client.deinit();

    // spawn receive task alongside send loop
    _ = io.concurrent(receiveLoop, .{&client}) catch {};

    const p = Packet{ .id = [_]u8{0} ** 16, .kind = 1, .register = 0, .position = .{ 0.0, 0.0, 0.0 } };
    while (true) {
        client.send(p) catch {};
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .awake);
    }
}
```

See `examples/udp_server.zig` and `examples/udp_client.zig` for a full working example with broadcast and configurable ports. For design details see [`docs/hld-udp.md`](docs/hld-udp.md).

<br>

## Logger

Structured file logger with automatic HTTP access logging and system event logging.

```zig
const std = @import("std");
const zix = @import("zix");

// Logger does not create save_path automatically — caller's responsibility.
// Silently ignores "already exists" — safe to call on every start.
fn createLogDir(io: std.Io) void {
    std.Io.Dir.cwd().createDirPath(io, "./logs") catch {};
}

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    createLogDir(process.io);

    var logger = try zix.Logger.Logger.init(arena.allocator(), .{
        .save_path      = "./logs",
        .save_file      = "app",
        .save_min_level = .INFO,
        .console        = .ALWAYS,
    });
    defer logger.deinit();

    // System event: any component, any level
    logger.system(.INFO,  "startup", "listening on {d}", .{9000});
    logger.system(.ERROR, "db",      "connect failed: {}", .{error.ConnectionRefused});

    // Wire into HTTP server for automatic per-request access logging
    var server = try zix.Http.Server.init(4096, .{
        .io        = process.io,
        .allocator = arena.allocator(),
        .ip        = "127.0.0.1",
        .port      = 9000,
        .logger    = &logger,
    });
    defer server.deinit();
    try server.run();
}
```

Log files are written to `save_path/YYYY-MM-DD/save_file-NNNNNN.log`. Each line is a newline-terminated record:

```
# System event format:
2026-05-16 12:34:56.789 INFO   [startup] listening on 9000
2026-05-16 12:34:56.789 ERROR  [db] connect failed: ConnectionRefused

# HTTP access format (2xx/3xx=INFO, 4xx=WARN, 5xx=ERROR, other=DEBUG):
2026-05-16 12:34:56.789 INFO   GET /api/users 200 512 "MyBot/2.0" "http://example.com"
2026-05-16 12:34:56.789 WARN   GET /missing 404 0 "-" "-"
2026-05-16 12:34:56.789 ERROR  POST /crash 500 0 "-" "-"
```

| Config field | Default | Description |
| :- | :- | :- |
| `console` | `.OFF` | Console mode: `.OFF`, `.DEBUG_ONLY` (debug builds only), `.ALWAYS` |
| `console_min_level` | `.INFO` | Minimum level for console output |
| `save_path` | `""` | Directory root for log files. Must already exist — logger does not create it. `""` disables file logging |
| `save_file` | `"log"` | Base filename. `"log"` writes `log-000000.log`, `log-000001.log`, ... |
| `save_min_level` | `.INFO` | Minimum level for file output |
| `max_lines` | 1,000,000 | Lines per file before rotating to the next sequence number |

Levels: `.DEBUG`(0) `.INFO`(1) `.WARN`(2) `.ERROR`(3). The file backend uses a 64 KB write buffer flushed on date rollover, sequence rotation, explicit `logger.flush()`, or `logger.deinit()`.

<br>

## Testing

```sh
zig build unit-test        # unit tests (src/ inline tests)
zig build integration-test # integration tests (components wired together)
zig build behaviour-test   # behaviour tests (observable API contracts)
zig build edge-test        # edge tests (boundary conditions and error paths)
zig build test-all         # all of the above
```

`zig build` alone does not run tests. See [`docs/tests.md`](docs/tests.md) for full coverage details.

<br>

## Memory Model

### HTTP

| Scope | Allocator | Lifetime |
| :- | :- | :- |
| Router route list | `config.allocator` (caller-owned) | Process |
| Read / write I/O buffers | `smp_allocator` | Connection |
| Per-request allocations (`ctx.allocator`) | Per-connection `ArenaAllocator`, reset each request | Request |

Handlers receive `ctx.allocator`, an arena reset between requests. Any allocation made inside a handler is automatically reclaimed at the end of the request without any `free` call.

`config.allocator` (router storage) is append-only — `ArenaAllocator` is the recommended choice. All route allocations are freed together when `server.deinit()` is called.

### UDP

| Scope | Allocator | Lifetime |
| :- | :- | :- |
| Client record list | `config.allocator` (caller-owned) | Server process lifetime |
| Peer snapshot (broadcast) | `config.allocator` | Single packet dispatch |
| Receive buffer | Stack | Single receive loop iteration |

`config.allocator` must be a general-purpose allocator (e.g. `std.heap.smp_allocator`). `ArenaAllocator` is not suitable: the broadcast peer snapshot is allocated and freed per packet — `ArenaAllocator.free()` is a no-op, so snapshots accumulate unboundedly until the server stops. See [`docs/hld-udp.md`](docs/hld-udp.md) for the full explanation and PoC.

For full memory details see [`docs/hld-http.md`](docs/hld-http.md) and [`docs/hld-udp.md`](docs/hld-udp.md). For threading models see [`docs/concurrency.md`](docs/concurrency.md).

<br>

---

###### end of readme
