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

<br>

# Table of Contents

- [Reason & Motivation](./README-en.md#A-Reason-A-Motivation)
- [Requirements](./README-en.md#Requirements)
- [Repositories](./README-en.md#Repositories)
- [Important Contribution Notes](./README-en.md#Important-Contribution-Notes)
- [Documentation](./README-en.md#Documentation)
- [Getting Started](./README-en.md#Getting-Started)
- [Examples](./README-en.md#Examples)
- [Examples: Minimal](./README-en.md#Minimal-Examples)
- [Examples: Routing](./README-en.md#Routing)
- [Examples: Concurrency Model](./README-en.md#Concurrency-Model)
- [Examples: Timeouts](./README-en.md#Timeouts)
- [Examples: Middleware](./README-en.md#Middleware)
- [Examples: WebSocket](./README-en.md#WebSocket)
- [Examples: SSE](./README-en.md#SSE-Server-Sent-Events)
- [Examples: HTTP Client](./README-en.md#HTTP-Client)
- [Examples: Static Files & Upload](./README-en.md#Static-Files--Upload)
- [Examples: Response Header Capacity](./README-en.md#Response-Header-Cap-Headersize)
- [Examples: Response Header Capacity](./README-en.md#Response-Header-Cap-Headersize)
<!-- - [Examples: HTTP/2 h2c](./README-en.md#HTTP2-h2c) -->
- [Examples: gRPC h2c](./README-en.md#gRPC-h2c)
- [Examples: Raw TCP](./README-en.md#Raw-TCP)
- [Examples: FIX 4.x](./README-en.md#FIX-4x)
- [Examples: UDS (Unix DOmain Sockets)](./README-en.md#UDS-Unix-Domain-Sockets)
- [Examples: Channel](./README-en.md#Channel)
- [Examples: UDP](./README-en.md#UDP)
- [Examples: Logger](./README-en.md#Logger)
- [Examples: Testing](./README-en.md#Testing)
- [Examples: Memory Model](./README-en.md#Memory-Model)

<br>

## A Reason.. A Motivation...

<details close>
<summary>Frame of Mind:</summary>

```
The way we think, is how system start.
A time to read and think from existing lines,
made "us" re-think, arguing, and approaching for the flow of the program.

When "our" next generation doesn't want to learn the past and present. What will happen?
If they don't want to use/learn/be eager about the language and the build system, they'll ..?

To be modern with less hassle, "magic" should less or more?

Zig (also another programming language) could complement existing program
and able to create a good program, but when critical-performance our options is less/hard.

My work mostly 80% backend nad 20% frontend.
So network/communication system is essential in my end.
From monolith, micro-service, and modular micro-service.

At early Zig (before 0.16.x), I enjoyed the language.
Zig is flexible and yet most of the logic
But "variant of colors" made me go back to Go & C++ again.
So in mid 2025 the plan is only idea and some architectural design.

So when Zig 0.16.x release, and in 2026 early March. I started the march.
```

<!--
Why not rust:
- Too many "just use tokio/smol" made me think again.
- My code in rust as professional is still 70% sync, less async.
- Rust in my case to complement existing system, QR & Barcode reader/writer replacing C++.
-->

</details>

<br>

<details open>

<summary>Principles for the motivations:</summary>

__*1. Explicit Over Implicit.*__

__*2. Modular & Maintanable.*__

__*3. Performance-First Architecture.*__

__*4. Practical Features, Ready to Use.*__

__*5. Modern Efficient Concurrency Model.*__

__*6. Predictable, Transparent Memory Management.*__

> We valued clarity, control, and performance.

</details>

<br>

## Requirements

- Zig >= 0.16.x

<br>

## Repositories

- [Codeberg as Main](https://codeberg.org/prothegee/zix)
- [Github as Mirror #1](https://github.com/prothegee/zix)

<br>

## Important Contribution Notes

- Zig should be the ecosystem.
- Single file, single responsibility.
- Always use and push Zig and their std.
- Any significant change/s required RnD/PoC.
- Cover for the un-cover test/s is good contribution.
- Narrowing down the system thinking then be explicit.
- A "nice to have" and "maybe we need this" is tertiary.
- Always fix from our side first rather than Zig feature/s side.
- If bias/ambigue, try to discuss it. At least involved with other 1-2 entities.
- You and your people (Junior/Mid/Senior) use another language beside english, you can contribute that.

<br>

[Open an issue.](https://codeberg.org/prothegee/zix/issues/new)

[Open a discussion.](https://github.com/prothegee/zix/discussions)

<br>

## Documentation

| Document | Description |
| :- | :- |
| [`docs/hld-http.md`](docs/hld-http.md) | HTTP: goals, runtime model, API, router, WebSocket, SSE, memory model |
| [`docs/hld-tcp.md`](docs/hld-tcp.md) | TCP raw stream: goals, API, frame format, dispatch models |
| [`docs/hld-udp.md`](docs/hld-udp.md) | UDP: goals, runtime model, API, packet model, endianness, disconnect |
| [`docs/hld-uds.md`](docs/hld-uds.md) | UDS: goals, API, frame format, server/client lifecycle |
| [`docs/hld-channel.md`](docs/hld-channel.md) | Channel: goals, model, API, concurrency requirement, examples |
| [`docs/hld-fix.md`](docs/hld-fix.md) | FIX 4.x: goals, protocol overview, session layer, dispatch models, config |
| [`docs/hld-grpc.md`](docs/hld-grpc.md) | gRPC h2c: goals, architecture, API, all 4 RPC types, codec, dispatch models |
| [`docs/hld-grpc-proxy.md`](docs/hld-grpc-proxy.md) | gRPC TLS termination via nginx and haproxy |
| [`docs/hld-logger.md`](docs/hld-logger.md) | Logger: goals, API, log methods, formats, file rotation, protocol wiring |
| [`docs/lld-http.md`](docs/lld-http.md) | HTTP: internal data structures and algorithms |
| [`docs/lld-tcp.md`](docs/lld-tcp.md) | TCP: internal data structures and algorithms |
| [`docs/lld-udp.md`](docs/lld-udp.md) | UDP: internal data structures and algorithms |
| [`docs/lld-uds.md`](docs/lld-uds.md) | UDS: internal server/client structure and frame handling |
| [`docs/lld-fix.md`](docs/lld-fix.md) | FIX: internal data structures and serveConn algorithm |
| [`docs/lld-channel.md`](docs/lld-channel.md) | Channel: ring buffer internals, locking, send/recv algorithms |
| [`docs/lld-logger.md`](docs/lld-logger.md) | Logger: internal write buffer, spinlock, rotation algorithm |
| [`docs/concurrency.md`](docs/concurrency.md) | Dispatch models: POOL, ASYNC, MIXED, EPOLL. Thread counts, protocol applicability. |
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
zig fetch --save "git+https://codeberg.org/prothegee/zix#0.2.x" # upstream v0.2.x
```

> You can change to mirror too as `github.com/prothegee/zix`
>
> For a specific version, use `MAJOR.MINOR.x`, i.e. `#0.2.x` and replace `#main`

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

### Minimal Examples

Auto I/O (work-queue thread pool, default):
```zig
const std = @import("std");
const zix = @import("zix");

pub fn homeHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req; _ = ctx;
    try res.send("hello from zix");
}

pub fn main(process: std.process.Init) !void {
    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/", .handler = homeHandler },
    }, .{
        .io   = process.io,
        .ip   = "127.0.0.1",
        .port = 9000,
    });
    defer server.deinit();
    try server.run();
}
```

Manual I/O (explicit concurrency limit via `concurrent_limit`, `.ASYNC` dispatch):
```zig
pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{
        .concurrent_limit = std.Io.Limit.limited(4), // pin to 4 concurrent tasks
        // .concurrent_limit = .unlimited             // let runtime decide
    });
    defer threaded.deinit();

    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/", .handler = homeHandler },
    }, .{
        .io             = threaded.io(),
        .ip             = "127.0.0.1",
        .port           = 9000,
        .dispatch_model = .ASYNC, // .ASYNC uses the caller's io directly
    });
    defer server.deinit();
    try server.run();
}
```

<br>

### Routing

Routes are registered at compile time via the route table passed to `Server.init`. Each `Route` entry has a `path`, a `handler`, and an optional `kind` (`.EXACT` by default):

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/about",           .handler = aboutHandler },
    // exact (default) — matches only /about

    .{ .path = "/api",             .handler = apiHandler,    .kind = .PREFIX },
    // prefix — matches /api, /api/foo, /api/foo/bar, NOT /apiv2

    .{ .path = "/users/:id",       .handler = userHandler,   .kind = .PARAM },
    // param — matches /users/alice, captures id="alice"
    // read inside handler: req.pathParam("id")

    .{ .path = "/:tenant/:branch", .handler = branchHandler, .kind = .PARAM },
    // multi-param — req.pathParam("tenant"), req.pathParam("branch")
}, .{ .ip = "127.0.0.1", .port = 9000 });
```

**Priority:**

```
exact  >  param  >  prefix (longer prefix beats shorter)
```

Exact and prefix priority is independent of registration order. **Param routes are the exception** — when two patterns have the same segment count and both match, the first entry in the route table wins. Register more-literal patterns before all-param patterns of the same depth:

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    // Correct order — /path/user/:id wins for /path/user/alice
    .{ .path = "/path/user/:id",        .handler = userHandler,   .kind = .PARAM },
    .{ .path = "/path/:tenant/:branch", .handler = tenantHandler, .kind = .PARAM },
}, .{ ... });
```

| Registered | Request | Winner | Reason |
| :- | :- | :- | :- |
| `/path/info` (exact) + `/path/:id` (param) | `/path/info` | `/path/info` | exact beats param |
| `/path/:id` (param) + `/path` (prefix) | `/path/alice` | `/path/:id` | param beats prefix |
| `/api/v2` + `/api` (both prefix) | `/api/v2/foo` | `/api/v2` | longer prefix wins |
| `/path/user/:id` (1st) + `/path/:a/:b` (2nd) | `/path/user/alice` | `/path/user/:id` | more literals registered first |

**Regex-like matching** — zix has no regex engine. A prefix route (`.kind = .PREFIX`) covers the registered path and any sub-path below it. Additional filtering is done inside the handler with plain string operations on `req.path()`:

```zig
// In the route table:
.{ .path = "/secret", .handler = secretHandler, .kind = .PREFIX },

// Inside secretHandler — extract sub-path and apply custom logic
const sub = req.path()["/secret/".len..];  // e.g. "file.txt"
// check extension, depth, query params, headers, etc.
```

<br>

### Concurrency Model

Four dispatch models, selected via `config.dispatch_model` (`DispatchModel` enum, default `.POOL`):

**`.POOL` — work-queue thread pool (default):**

N accept threads push connections to a shared `ConnQueue`. M pool threads pop and handle each connection synchronously with blocking I/O — no scheduler overhead. Best throughput under high connection counts. `SO_REUSEPORT` lets all accept threads listen on the same port.

```zig
pub fn main(process: std.process.Init) !void {
    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/", .handler = homeHandler },
    }, .{
        .io = process.io,
        // dispatch_model = .POOL (default, can be omitted)
        // workers        = 0  -> cpu_count accept threads (auto)
        // pool_size      = 0  -> max(10, cpu_count * 2) pool threads (auto)
    });
```

**`.ASYNC` — single accept, `io.async()` dispatch:**

One accept thread dispatches each connection via `io.async()`. `workers` and `pool_size` are ignored. Preferred for SSE and WebSocket (long-lived connections do not hold pool threads). Also suitable for explicit `concurrent_limit`.

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .ASYNC,
});
```

**`.MIXED` — N accept threads, `io.async()` dispatch:**

N accept threads each dispatch connections via `io.async()` directly — no `ConnQueue`. Balanced throughput and latency. `pool_size` is ignored.

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .MIXED,
});
```

**`.EPOLL` — single epoll event loop + worker pool (Linux-only):**

One event-loop thread uses `epoll_wait` to detect readable sockets. Workers pop ready fds from a queue and serve one request each, then re-arm the socket (`EPOLLONESHOT`). Idle keep-alive connections hold no thread. Best for high connection counts with many idle or slow clients. Non-Linux builds fall back to `.POOL` automatically.

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .EPOLL,
    .pool_size      = 32, // worker threads; workers field is ignored
});
```

See [`docs/concurrency.md`](docs/concurrency.md) for architecture details, thread counts, and when to prefer each model.

<br>

### Timeouts

Two independent timeout layers, both disabled by default (`0`):

**`conn_timeout_ms`**: network-level connection guard (Layer D). The timer thread shuts down connections that have been open longer than this without completing. Protects pool threads from clients that stall before or during header send. Effective in `.POOL` only.

**`handler_timeout_ms`**: per-handler execution budget (Layer B). Sets `ctx.deadline` before each dispatch. Handlers opt in by calling `ctx.isExpired()` between expensive steps.

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/slow", .handler = slowHandler },
}, .{
    .io                 = process.io,
    .ip                 = "127.0.0.1",
    .port               = 9000,
    .conn_timeout_ms    = 30_000, // close stalled connections after 30s
    .handler_timeout_ms = 5_000,  // handler budget: 5s
});
```

Handler using the budget:

```zig
pub fn slowHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;

    doStep1(ctx.io);
    if (ctx.isExpired()) {
        res.setStatus(.REQUEST_TIMEOUT);
        return res.sendJson("{\"error\":\"timeout\"}");
    }

    doStep2(ctx.io);
    if (ctx.isExpired()) {
        res.setStatus(.REQUEST_TIMEOUT);
        return res.sendJson("{\"error\":\"timeout\"}");
    }

    try res.sendJson("{\"result\":\"ok\"}");
}
```

To override the deadline inside a handler (shorter or longer window than the global budget):

```zig
ctx.setTimeout(2_000); // override to 2s from now regardless of global cap
```

`ctx.isExpired()` is a no-op (always returns `false`) when `handler_timeout_ms == 0`. `ctx.timedOut()` is an alias for `ctx.isExpired()`. `conn_timeout_ms` should be >= `handler_timeout_ms` to avoid the connection being cut before the handler can send a 408. See `examples/http_timeout_resp.zig` and `docs/adr.md` (ADR-018) for design rationale.

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
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    // origin check only
    .{ .path = "/public",  .handler = withOriginCheck(publicHandler) },
    // origin check -> basic auth -> handler
    .{ .path = "/private", .handler = withOriginCheck(withBasicAuth(privateHandler)) },
}, .{ .io = process.io, .ip = "127.0.0.1", .port = 9008 });
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

    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/ws/:room-id", .handler = wsHandler, .kind = .PARAM },
    }, .{ .io = process.io, .ip = "127.0.0.1", .port = 9008 });
    defer server.deinit();
    try server.run();
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
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/",          .handler = homeHandler },
    .{ .path = "/api",       .handler = apiHandler,  .kind = .PREFIX },
    .{ .path = "/ws/:room-id", .handler = wsHandler, .kind = .PARAM },
}, .{
    .io         = process.io,
    .ip         = "127.0.0.1",
    .port       = 9008,
    .public_dir = "./public", // static files for unmatched routes
});
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
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/events", .handler = eventsHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .ASYNC, // preferred for SSE: long-lived connections do not hold pool threads
});
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

    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/upload", .handler = uploadHandler },
    }, .{
        .io                = process.io,
        .ip                = "127.0.0.1",
        .port              = 9005,
        .public_dir        = "./public", // validated at run(); "" = disabled
        .public_dir_upload = "u",
    });
```

- Unmatched routes fall through to static serving from `public_dir`.
- Range requests (`Range: bytes=...`) -> `206 Partial Content` (RFC 7233).
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
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
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
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .max_request_headers = .COMMON,                // 32 headers
    // .max_request_headers = .{ .CUSTOM = 24 },   // explicit
});
```

The parser storage limit is 64 — `CUSTOM` values above 64 are silently capped. See `zix.Http.RequestHeaderSize`.

<br>

<!-- ## HTTP/2 h2c -->
<!---->
<!-- `zix.Http2` is a standalone HTTP/2 server over cleartext TCP (h2c). Routes are registered at compile time. -->
<!---->
<!-- ```zig -->
<!-- const std = @import("std"); -->
<!-- const zix = @import("zix"); -->
<!---->
<!-- fn homeHandler( -->
<!--     method:  []const u8, -->
<!--     headers: []const zix.Http2.Header, -->
<!--     body:    []const u8, -->
<!--     fd:      std.posix.fd_t, -->
<!--     sid:     u31, -->
<!-- ) void { -->
<!--     _ = method; _ = headers; _ = body; -->
<!--     zix.Http2.sendResponse(fd, sid, 200, "text/plain", "Hello from Http2") catch {}; -->
<!-- } -->
<!---->
<!-- pub fn main(process: std.process.Init) !void { -->
<!--     var server = try zix.Http2.Server.init( -->
<!--         &[_]zix.Http2.Route{ -->
<!--             .{ .path = "/", .handler = homeHandler }, -->
<!--         }, -->
<!--         .{ -->
<!--             .io   = process.io, -->
<!--             .ip   = "127.0.0.1", -->
<!--             .port = 8082, -->
<!--         }, -->
<!--     ); -->
<!--     defer server.deinit(); -->
<!--     try server.run(); -->
<!-- } -->
<!-- ``` -->
<!---->
<!-- ```sh -->
<!-- curl --http2-prior-knowledge http://127.0.0.1:8082/ -->
<!-- ``` -->
<!---->
<!-- `HandlerFn`: `fn(method, headers, body, fd, sid) void` — the handler writes response frames directly via `zix.Http2.sendResponse` or the raw frame helpers. Routes are exact-path matches baked in at compile time. -->
<!---->
<!-- **Config fields:** -->
<!---->
<!-- | Field | Default | Description | -->
<!-- | :- | :- | :- | -->
<!-- | `io` | required | caller-provided `std.Io` backend | -->
<!-- | `ip` | required | bind address | -->
<!-- | `port` | required | listen port; 0 → `error.PortNotConfigured` | -->
<!-- | `dispatch_model` | `.ASYNC` | `.ASYNC`, `.POOL`, or `.MIXED` | -->
<!-- | `kernel_backlog` | 1024 | TCP listen backlog | -->
<!-- | `workers` | 0 (cpu count) | accept thread count; ignored by `.ASYNC` | -->
<!-- | `pool_size` | 0 (auto) | pool thread count; only used by `.POOL` | -->
<!-- | `max_streams` | 16 | max concurrent HTTP/2 streams per connection | -->
<!-- | `max_frame_size` | 16384 | advertised MAX_FRAME_SIZE in SETTINGS | -->
<!-- | `max_header_scratch` | 4096 | HPACK scratch buffer size per connection | -->
<!-- | `max_body` | 65536 | max total body buffered per stream | -->
<!---->
<!-- See [`docs/hld-grpc.md`](docs/hld-grpc.md) for gRPC on top of Http2. -->
<!---->
<!-- <br> -->

## gRPC h2c

`zix.Grpc` is a gRPC server and client over h2c. Routes are registered at compile time. All 4 RPC types are supported (unary, server streaming, client streaming, bidirectional).

```zig
const std = @import("std");
const zix = @import("zix");

fn sayHelloHandler(
    headers: []const zix.Http2.Header,
    ctx:     *zix.Grpc.Context,
) void {
    _ = headers;
    const req = ctx.recvMessage() orelse {
        ctx.finish(.INVALID_ARGUMENT, "no message");
        return;
    };
    // decode req (proto3), encode reply
    var reply: [256]u8 = undefined;
    const n = zix.Grpc.encodeString(1, "Hello!", &reply);
    ctx.sendMessage("application/grpc+proto", reply[0..n]);
    ctx.finish(.OK, "");
}

pub fn main(process: std.process.Init) !void {
    var server = try zix.Grpc.Server.init(
        &[_]zix.Grpc.Route{
            .{ .path = "/helloworld.Greeter/SayHello", .handler = sayHelloHandler },
        },
        .{
            .io   = process.io,
            .ip   = "127.0.0.1",
            .port = 8083,
        },
    );
    defer server.deinit();
    try server.run();
}
```

```sh
# Test with grpcurl
grpcurl -plaintext -d '{"name":"world"}' 127.0.0.1:8083 helloworld.Greeter/SayHello
```

**HandlerFn:** `fn(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void`

- Path is resolved by the route table before the handler is called.
- `ctx.recvMessage()` returns each buffered client message or `null` when done.
- `ctx.sendMessage(content_type, data)` sends a response DATA frame (first call also sends HEADERS).
- `ctx.finish(status, message)` sends the grpc-status trailer. Must be called exactly once.

**GrpcClient:**

```zig
var client = try zix.Grpc.Client.connect(.{
    .ip   = "127.0.0.1",
    .port = 8083,
}, process.io);
defer client.deinit();

// Unary convenience
var buf: [4096]u8 = undefined;
const resp = try client.unary(
    "/helloworld.Greeter/SayHello",
    "application/grpc+proto",
    request_bytes,
    &buf,
);
```

**Minimal protobuf codec** (no codegen required for simple schemas):

```zig
var out: [256]u8 = undefined;
var pos: usize = 0;
pos += zix.Grpc.encodeString(1, "world",  out[pos..]); // field 1: string
pos += zix.Grpc.encodeInt32( 2, 42,       out[pos..]); // field 2: int32
pos += zix.Grpc.encodeDouble(3, 1.5,      out[pos..]); // field 3: double
// send out[0..pos] as the gRPC message payload
```

**Dispatch models:** `.ASYNC` (default), `.POOL`, `.MIXED`, `.EPOLL` (Linux-only). The gRPC EPOLL model uses a single epoll event loop for accept and assigns each connection to a pool worker for its full lifetime (gRPC is streaming — `EPOLLONESHOT` does not apply). Non-Linux falls back to `.POOL` automatically. See [`docs/concurrency.md`](docs/concurrency.md) for details.

**Context timeout:** Three inputs, tightest wins:

```zig
var server = try zix.Grpc.Server.init(
    &[_]zix.Grpc.Route{
        // per-route 3s cap, tightens the 5s global cap
        .{ .path = "/helloworld.Greeter/SayHello", .handler = sayHelloHandler, .timeout_ms = 3_000 },
        // per-route 10s cap, global 5s cap still wins
        .{ .path = "/helloworld.Greeter/Echo",     .handler = echoHandler,     .timeout_ms = 10_000 },
    },
    .{
        .io                = process.io,
        .ip                = "127.0.0.1",
        .port              = 8083,
        .handler_timeout_ms = 5_000, // global cap; also combined with Route.timeout_ms and grpc-timeout header
    },
);
```

Handlers check `ctx.isExpired()` between steps. Override `ctx.deadline_ns` directly for per-call extension: `ctx.deadline_ns = zix.Grpc.wallClockNs() + 30 * std.time.ns_per_s`. See `examples/grpc_timeout.zig` for the full demo.

See [`docs/hld-grpc.md`](docs/hld-grpc.md) for full documentation including all 4 RPC type patterns and TLS proxy setup.

<br>

## Raw TCP

`zix.Tcp` is a raw TCP stream server and client. User-defined handler owns the stream. Three dispatch models. Default frame format: 4-byte big-endian length prefix.

```zig
const std = @import("std");
const zix = @import("zix");

fn myHandler(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);
    var rbuf: [4100]u8 = undefined;
    var rdr = stream.reader(io, &rbuf);
    var buf: [4096]u8 = undefined;
    while (true) {
        const len = rdr.interface.takeVarInt(u32, .big, 4) catch return;
        if (len == 0 or len > buf.len) return;
        rdr.interface.readSliceAll(buf[0..len]) catch return;
        const msg = buf[0..len];
        _ = msg; // process msg
        // write response with stream.writer()
    }
}

pub fn main(process: std.process.Init) !void {
    var server = try zix.Tcp.Server.init(.{
        .ip   = "127.0.0.1",
        .port = 9300,
        .dispatch_model = .ASYNC,
    });
    defer server.deinit();
    try server.runWith(process.io, myHandler);
    // or: try server.run(process.io);  // uses built-in echoHandler
}
```

**Frame format:** `[u32 big-endian payload_len][payload bytes]`. Both the built-in `echoHandler` and `TcpClient.sendMsg`/`recvMsg` use this format.

**TcpClient:**

```zig
var client = try zix.Tcp.Client.connect(.{
    .ip   = "127.0.0.1",
    .port = 9300,
}, io);
defer client.deinit(io);

try client.sendMsg(io, "hello");
var buf: [4096]u8 = undefined;
const reply = try client.recvMsg(io, &buf);
```

**CLI arg override** (no rebuild needed):

```zig
var server = try zix.Tcp.Server.initArgs(.{ .ip = "127.0.0.1", .port = 9300 }, process.minimal.args);
var client = try zix.Tcp.Client.connectArgs(.{ .ip = "127.0.0.1", .port = 9300 }, io, process.minimal.args);
```

See `examples/tcp_server_1_async.zig`, `examples/tcp_client.zig`, and [`docs/hld-tcp.md`](docs/hld-tcp.md) for details.

<br>

## FIX 4.x

`zix.Fix` is a FIX 4.x session layer server and client. SOH-delimited (0x01) framing. Session handling (Logon/Logout/Heartbeat) is built in — no handler callback needed.

```zig
const std = @import("std");
const zix = @import("zix");

pub fn main(process: std.process.Init) !void {
    var server = try zix.Fix.Server.init(.{
        .io                   = process.io,
        .ip                   = "127.0.0.1",
        .port                 = 9500,
        .comp_id              = "SERVER",
        .dispatch_model       = .ASYNC,
        .heartbeat_timeout_ms = 30_000, // 0 = disabled (default)
    });
    defer server.deinit();
    try server.run();
}
```

`FixClient`:

```zig
var client = try zix.Fix.Client.connect(.{
    .ip             = "127.0.0.1",
    .port           = 9500,
    .comp_id        = "CLIENT",
    .target_comp_id = "SERVER",
}, io);
defer client.deinit(io);

try client.logon(io, 30);                                       // Logon with HeartBtInt=30
try client.sendMessage(io, "D", &[_]zix.Fix.BuildField{       // NewOrderSingle
    .{ .tag = .ClOrdID,  .value = "order-001" },
    .{ .tag = .Symbol,   .value = "AAPL" },
    .{ .tag = .Side,     .value = "1" },
    .{ .tag = .OrderQty, .value = "100" },
});
const msg = try client.recvMessage(io);                         // receive echo
_ = msg;
try client.logout(io);
```

**Session messages handled automatically:**

| MsgType (tag 35) | Server action |
| :- | :- |
| `A` (Logon) | Reply with Logon, CompIDs swapped |
| `5` (Logout) | Reply with Logout, then close |
| `0` (Heartbeat) | Reply with Heartbeat |
| `1` (TestRequest) | Reply with Heartbeat |
| any other | Echo unchanged |

Default dispatch model is `.ASYNC` (FIX sessions are long-lived).

See `examples/fix_server_1_async.zig`, `examples/fix_client.zig`, and [`docs/hld-fix.md`](docs/hld-fix.md) for details.

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

Structured file logger with automatic per-protocol event logging. Thread-safe — safe to call from background OS threads.

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

    var logger = try zix.Logger.init(arena.allocator(), .{
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
    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/", .handler = homeHandler },
    }, .{
        .io     = process.io,
        .ip     = "127.0.0.1",
        .port   = 9000,
        .logger = &logger,
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

# gRPC stream close:
2026-05-25 10:15:33.201 INFO   [grpc:rpc] 127.0.0.1:56789 /helloworld.Greeter/SayHello status=0 recv=16 sent=22 dur=1ms
```

| Config field | Default | Description |
| :- | :- | :- |
| `console` | `.OFF` | Console mode: `.OFF`, `.DEBUG_ONLY` (debug builds only), `.ALWAYS` |
| `console_min_level` | `.INFO` | Minimum level for console output |
| `save_path` | `""` | Directory root for log files. Must already exist. `""` disables file logging |
| `save_file` | `"log"` | Base filename. `"log"` writes `log-000000.log`, `log-000001.log`, ... |
| `save_min_level` | `.INFO` | Minimum level for file output |
| `max_lines` | 1,000,000 | Lines per file before rotating to the next sequence number |

**Per-protocol log methods:**

| Method | Auto-called by | Line format |
| :- | :- | :- |
| `system(level, component, fmt, args)` | all servers (lifecycle) | `DATE TIME LEVEL  [component] message` |
| `access(method, path, status, bytes, ua, origin)` | HTTP server | `DATE TIME LEVEL  METHOD PATH STATUS BYTES "UA" "ORIGIN"` |
| `conn(peer, dur_ms, err)` | TCP server | `DATE TIME LEVEL  [tcp:conn] PEER dur=NNNms ERR` |
| `packet(dir, peer, size, err)` | UDP server | `DATE TIME LEVEL  [udp:pkt] DIRECTION PEER size=N ERR` |
| `frame(dir, sock_path, size, err)` | UDS (manual) | `DATE TIME LEVEL  [uds:frame] DIRECTION SOCKPATH size=N ERR` |
| `session(msg_type, sender, target, seq, state)` | FIX server | `DATE TIME LEVEL  [fix:sess] 35=TYPE sender=S target=T seq=N STATE` |
| `rpc(peer, path, grpc_status, recv, sent, dur_ms)` | gRPC server | `DATE TIME LEVEL  [grpc:rpc] PEER PATH status=N recv=N sent=N dur=Nms` |

Levels: `.DEBUG`(0) `.INFO`(1) `.WARN`(2) `.ERROR`(3). The file backend uses a 64 KB write buffer flushed on date rollover, sequence rotation, explicit `logger.flush()`, or `logger.deinit()`.

Wire a logger into any server by setting `logger: &logger` in its config. See [`docs/hld-logger.md`](docs/hld-logger.md) for full documentation.

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
| Route table | comptime (zero heap cost) | N/A |
| Read / write I/O buffers | `smp_allocator` | Connection |
| Per-request allocations (`ctx.allocator`) | Per-connection `ArenaAllocator`, reset each request | Request |

Handlers receive `ctx.allocator`, an arena reset between requests. Any allocation made inside a handler is automatically reclaimed at the end of the request without any `free` call.

Routes are baked into the server type at compile time — no allocator is needed for route storage.

### UDP

| Scope | Allocator | Lifetime |
| :- | :- | :- |
| Client record list | `config.allocator` (caller-owned) | Server process lifetime |
| Peer snapshot (broadcast) | `config.allocator` | Single packet dispatch |
| Receive buffer | Stack | Single receive loop iteration |

`config.allocator` must be a general-purpose allocator (e.g. `std.heap.smp_allocator`). `ArenaAllocator` is not suitable: the broadcast peer snapshot is allocated and freed per packet — `ArenaAllocator.free()` is a no-op, so snapshots accumulate unboundedly until the server stops. See [`docs/hld-udp.md`](docs/hld-udp.md) for the full explanation and PoC.

### HTTP/2 and gRPC

Both use heap-allocated per-connection stream arrays (stack allocation of `max_streams` `Stream` structs would overflow the thread stack). No per-request allocator is exposed — handlers receive raw frame I/O via `GrpcContext` (gRPC) or `fd`/`sid` (HTTP/2).

For full memory details see [`docs/hld-http.md`](docs/hld-http.md) and [`docs/hld-udp.md`](docs/hld-udp.md). For threading models see [`docs/concurrency.md`](docs/concurrency.md).

<br>

---

<!--
perf record -F 99 -o my_custom_output.perf.data ./myprogram;
-->

###### end of readme
