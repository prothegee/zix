# README

<h1 align="center">
    <b><i>ZIX</i></b>
</h1>
<p align="center" style="color: #333333;font-color: #333333;">
    <b><i>Zero sIX; 06;</i></b>
</p>

<div align="center">
    <img src="zix-logo.svg" alt="zix-logo" style="display: block; margin: auto;" align="center" width="243px">
</div>

<p align="center" style="color: #333333;font-color: #333333;">
    <i>A micro net-frame-work.</i>
</p>

<p align="center" style="color: #333333;font-color: #333333;">
    <i>Where the wire meets the will.</i>
</p>

<p align="center" style="color: #333333;font-color: #333333;">
    <i>Every byte owned, every thread deloberate, every route explicit.</i>
</p>

<p align="center" style="color: #333333;font-color: #333333;">
    <i>No hidden cost. Just clean metal and honest code - predictable by principle</i>
</p>

<br>

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
- [Github as Mirror #1](https://codeberg.org/prothegee/zix)

<br>

## Examples

For more examples see the `examples` directory.

### Minimal examples

Auto I/O (runtime-managed thread pool):
```zig
const std = @import("std");
const zix = @import("zix");

pub fn homeHandler(req: *zix.Request, res: *zix.Response, ctx: *zix.Context) !void {
    _ = req;
    _ = ctx;
    try res.send("hello from zix");
}

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var server = try zix.HttpServer.init(.{
        .io = process.io,
        .allocator = arena.allocator(),
        .ip = "0.0.0.0",
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

Manual I/O (explicit concurrency limit):
```zig
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{
        .concurrent_limit = std.Io.Limit.limited(4), // pin to 4 concurrent tasks
        // .concurrent_limit = .unlimited             // let runtime decide
    });
    defer threaded.deinit();

    var server = try zix.HttpServer.init(.{
        .io = threaded.io(),
        .allocator = arena.allocator(),
        .ip = "0.0.0.0",
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
// Intent: /secret/(.*)  →  only serve files with ?sec=abc123
server.registerPrefixHandler("/secret", secretHandler);

// Inside secretHandler — extract sub-path and apply custom logic
const sub = req.path()["/secret/".len..];          // e.g. "file.txt"
// check extension, depth, query params, headers, etc.
```

Any match logic expressible as string operations — extension checks, version parsing, depth limits — belongs in the handler body, not the route pattern.

<br>

### Concurrency Model

Two modes — the library accepts an opaque `std.Io`, so the caller owns the backend:

**Auto** — let the runtime manage threads (default for most cases):
```zig
pub fn main(process: std.process.Init) !void {
    var server = try zix.HttpServer.init(.{ .io = process.io, ... });
```

**Manual** — explicit concurrency cap (useful for resource-constrained deployments):
```zig
pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{
        .concurrent_limit = std.Io.Limit.limited(4), // cap at 4 concurrent tasks
    });
    defer threaded.deinit();
    var server = try zix.HttpServer.init(.{ .io = threaded.io(), ... });
```

Each accepted connection runs as a concurrent task via `io.concurrent()` — non-blocking, no busy-waiting.

<br>

### Middleware

Middleware is composed at comptime using wrapper functions. Each wrapper takes a `comptime next: zix.HandlerFn` and returns a new `HandlerFn` — no heap allocation, no runtime chain runner.

```zig
fn withOriginCheck(comptime next: zix.HandlerFn) zix.HandlerFn {
    return struct {
        fn handle(req: *zix.Request, res: *zix.Response, ctx: *zix.Context) anyerror!void {
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

fn withBasicAuth(comptime next: zix.HandlerFn) zix.HandlerFn {
    return struct {
        fn handle(req: *zix.Request, res: *zix.Response, ctx: *zix.Context) anyerror!void {
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

// origin check → basic auth → handler
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

For a full working example see `examples/server_middleware.zig`.

<br>

### WebSocket

Room-based broadcast over RFC 6455. A param handler upgrades the connection and enters a per-task frame loop — no separate thread needed.

```zig
var ws_rooms: zix.WebSocket.RoomMap = undefined;

pub fn wsHandler(req: *zix.Request, res: *zix.Response, ctx: *zix.Context) !void {
    const room_id = req.pathParam("room-id") orelse return;

    // Read query params BEFORE upgrade() — unavailable after the 101 handshake.
    const display_name = req.queryParam("name") orelse "anonymous";

    // extract Sec-WebSocket-Key from headers, then handshake
    var accept_buf: [64]u8 = undefined;
    const accept = try zix.WebSocket.acceptKey(ws_key, &accept_buf);
    try zix.WebSocket.upgrade(ctx.stream, ctx.io, accept); // writes 101 directly

    // heap-allocate conn, join room, both are cleaned up via defer (LIFO)
    const conn = try std.heap.smp_allocator.create(zix.WebSocket.Conn);
    conn.* = .{ .stream = ctx.stream, .io = ctx.io };
    defer std.heap.smp_allocator.destroy(conn);
    ws_rooms.join(room_id, conn, ctx.io);
    defer ws_rooms.leave(room_id, conn, ctx.io);  // runs before destroy

    // frame loop:
    //   text/binary → broadcast "[display_name] payload" to room
    //   ping        → pong
    //   close       → echo close frame + break
    //   EOF / error → best-effort close frame + break
    _ = display_name;
}

pub fn main(process: std.process.Init) !void {
    ws_rooms = zix.WebSocket.RoomMap.init(std.heap.smp_allocator);
    defer ws_rooms.deinit();
    // ...
    server.registerParamHandler("/ws/:room-id", wsHandler);
}
```

```
# Connect with wscat or websocat, ?name sets the broadcast display name
wscat    -c "ws://localhost:9007/ws/lobby?name=alice"
websocat    "ws://localhost:9007/ws/lobby?name=alice"

# ?name is optional — omit for "anonymous"
wscat    -c "ws://localhost:9007/ws/lobby"
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

### Static Files & Upload

Set `public_dir` in `HttpServerConfig` to enable static file serving. `server.run()` returns `error.PublicDirNotFound` if the directory does not exist. Use a `createInitDirs` helper to create all required directories before `HttpServer.init`:

```zig
fn createInitDirs(io: std.Io) void {
    std.Io.Dir.cwd().createDirPath(io, "./public") catch {};
    std.Io.Dir.cwd().createDirPath(io, "./public/u") catch {};
}

pub fn main(process: std.process.Init) !void {
    createInitDirs(process.io); // idempotent — safe on every start

    var server = try zix.HttpServer.init(.{
        // ...
        .public_dir        = "./public", // validated at run(); "" = disabled
        .public_dir_upload = "u",
    });
```

- Unmatched routes fall through to static serving from `public_dir`.
- Range requests (`Range: bytes=…`) → `206 Partial Content` (RFC 7233).
- Directory traversal (`..`) is rejected.

**Upload** — parse the multipart body in a handler, optionally rename before saving:

```zig
var parser = zix.MultipartParser.init(ctx.allocator, boundary);
defer parser.deinit();
try parser.parse(try req.body());

if (parser.getField("file")) |f| {
    // you can rename file first before save by replacing the filename string, e.g.:
    //   const filename = "custom_name.txt";
    // or build it dynamically:
    //   const filename = try std.fmt.allocPrint(ctx.allocator, "{s}_{s}", .{ sessionid, f.filename orelse "upload" });
    const filename = f.filename orelse "upload";
    const path = try zix.utils.file.saveFile(ctx.io, ctx.allocator, "./public/u", filename, f.data);
    _ = path; // arena-allocated; valid for this request
}
```

`saveFile` creates the destination directory if needed and returns a caller-owned path copy.

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
var server = try zix.HttpServer.init(.{
    // ...
    .max_response_headers = .LARGE,                // 64 headers
    // .max_response_headers = .{ .CUSTOM = 48 },  // explicit
});
```

`addHeader()` returns `error.TooManyHeaders` when the cap is reached and `error.InvalidHeaderName` / `error.InvalidHeaderValue` if the name or value contains CR or LF (header injection guard).

`.{ .CUSTOM = N }` allocates exactly N slots from the per-request arena — no ceiling, no clamping.

For security guidance and tier selection see [`docs/headers.md`](docs/headers.md). For a working demonstration see `examples/server_headers.zig`.

<br>

## Testing

```sh
zig build test
```

`zig build` alone does not run tests. See [`docs/tests.md`](docs/tests.md) for coverage details.

<br>

## Memory Model

| Scope | Allocator | Lifetime |
| :- | :- | :- |
| Router route list | `config.allocator` (caller-owned) | Process |
| Read / write I/O buffers | `smp_allocator` | Connection |
| Per-request allocations (`ctx.allocator`) | Per-connection `ArenaAllocator`, reset each request | Request |

Handlers receive `ctx.allocator` — an arena reset between requests. Any allocation made inside a handler is automatically reclaimed at the end of the request without any `free` call.

<br>

---

###### end of readme
