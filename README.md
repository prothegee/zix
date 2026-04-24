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

<br>

## Motivation, Idea, Principal

__*1. Explicit Over Implicit.*__

__*2. Modular & Maintanable.*__

__*3. Performance-First Architecture.*__

__*4. Practical Features, Ready to Use.*__

__*5. Modern  Efficient Concurrency Model.*__

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

__*Minimal examples*__

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

For more examples see the `examples` directory.

<br>

## Routing

Three explicit functions, each with a distinct purpose:

```zig
server.registerHandler("/about", aboutHandler);
// exact — matches only /about

server.registerPrefixHandler("/api", apiHandler);
// prefix — matches /api, /api/foo, /api/foo/bar; NOT /apiv2

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

<br>

## Concurrency Model

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
