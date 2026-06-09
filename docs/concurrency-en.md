# Concurrency Models: zix

Four dispatch models for HTTP and raw TCP. Select via `config.dispatch_model` (`DispatchModel` enum) in `HttpServerConfig` or `TcpServerConfig`. Default: `.ASYNC`.

---

## DispatchModel

```zig
pub const DispatchModel = enum(u8) {
    ASYNC = 0, // single accept, io.async() dispatch
    POOL  = 1, // work-queue thread pool
    MIXED = 2, // N accept threads, each dispatching via io.async()
    EPOLL = 3, // single epoll event loop, Linux-only
};
```

Defined once in `src/tcp/config.zig`. Re-exported by `src/tcp/http/config.zig` (for `zix.Http`) and imported by `src/tcp/http2/grpc/config.zig` (for `zix.Grpc`). All four values are present in every config.

`.EPOLL = 3` is Linux-only. `zix.Http` (HTTP/1), `zix.Grpc`, `zix.Fix`, and `zix.Tcp` implement it natively on Linux. `zix.Http2` and non-Linux builds fall back to `.POOL` automatically. See the Dispatch Model Comparison table below.

---

## .POOL: Work-Queue Thread Pool

N accept threads push accepted connections to a shared `ConnQueue`. M pool threads pop
connections and handle each one synchronously with blocking I/O. `SO_REUSEPORT` allows all
accept threads to listen on the same port in parallel.

```
Main thread:
  create ConnQueue + std.Io.Threaded backend
  spawn pool_size pool threads
  spawn worker_count accept threads
  join accept threads -> queue.close() -> join pool threads

Accept threads (worker_count, default cpu_count):
  bind/listen on same port with SO_REUSEPORT
  loop:
    stream = accept(io)
    queue.push(stream)   <- fast, never blocks on I/O

Pool threads (pool_size, default max(10, cpu_count * 2)):
  loop:
    stream = queue.pop()          <- blocks until a connection arrives
    handleConnection(stream, io)  <- synchronous blocking I/O, keep-alive loop
    (loop, next pop)
```

**When to use:**
- Best throughput under high connection counts.
- `dispatch_model = .POOL` (explicit).
- `workers = 0` (default) uses cpu_count accept threads.
- `workers = N` uses exactly N accept threads.
- `pool_size = 0` (default) sizes the pool at `max(10, cpu_count * 2)`.
- `pool_size = N` uses exactly N pool threads.

**OS requirement:** `SO_REUSEPORT` (Linux >= 3.9, macOS, BSD).

**Example** (`examples/http_basic.zig` with explicit POOL):
```zig
pub fn main(process: std.process.Init) !void {
    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/", .handler = homeHandler },
    }, .{
        .io             = process.io,
        .dispatch_model = .POOL,
        // workers   = 0  -> cpu_count accept threads
        // pool_size = 0  -> max(10, cpu_count * 2) pool threads
    });
    try server.run();
}
```

**Explicit thread counts:**
```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io        = process.io,
    .workers   = 4,   // 4 accept threads
    .pool_size = 32,  // 32 pool threads
});
```

---

## .ASYNC: Single Accept, io.async() Dispatch

One accept thread dispatches each accepted connection as a concurrent task via `io.async()`
(non-blocking). The caller owns the `std.Io` backend. Best for low-latency workloads and
long-lived connections (SSE, WebSocket) where pool threads must not be blocked.

```
Main thread:
  bind -> listen
  loop:
    stream = accept(io)
    io.async(handleConnection, stream)   <- suspends, OS event loop schedules task

Handler tasks (one per active connection):
  handleConnection(stream)  // keep-alive loop until client closes
  task exits when connection closes
```

**When to use:**
- SSE and WebSocket: long-lived connections occupy pool threads in `.POOL`. `.ASYNC` is preferred.
- You need an explicit `concurrent_limit` (resource-constrained deployments).
- `dispatch_model = .ASYNC` in `HttpServerConfig`.
- `workers` and `pool_size` are ignored.

**Example** (`examples/http_sse.zig`, `examples/http_websocket.zig`):
```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/events", .handler = eventsHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .ASYNC,
});
```

**Manual concurrency limit** (`examples/http_manual_concurrent.zig`):
```zig
var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{
    .concurrent_limit = std.Io.Limit.limited(4),
});
defer threaded.deinit();

var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = threaded.io(),
    .dispatch_model = .ASYNC,
});
```

---

## .MIXED: N Accept Threads, io.async() Dispatch

N accept threads each dispatch connections via `io.async()` directly — no `ConnQueue`. Balanced
throughput and latency, higher jitter than `.POOL` under saturation due to `io.async()` fallback
to inline execution.

```
Main thread:
  spawn worker_count accept threads

Accept threads (worker_count, default cpu_count):
  bind -> listen with SO_REUSEPORT
  loop:
    stream = accept(io)
    io.async(handleConnection, stream)
```

**When to use:**
- Multi-accept parallelism without a blocking pool.
- `dispatch_model = .MIXED` in `HttpServerConfig`.
- `pool_size` is ignored. `workers` controls accept thread count.

**Example:**
```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .MIXED,
});
```

---

## .EPOLL: Single epoll Event Loop (Linux-only)

One event-loop thread calls `epoll_wait` in a loop. When the kernel signals a socket as readable, the socket fd is pushed to an `FdQueue` and a pool worker handles it. No `io.async()` overhead, no condvar wakeup per connection — the kernel tracks readiness. Each `epoll_wait` drains up to `EPOLL_MAX_EVENTS` (512) ready events per call.

**Why it exists:** `.POOL` and `.ASYNC` both pay a condvar wakeup cost on every accepted connection (either via `ConnQueue.pop()` or via the `io.async()` fiber scheduler). Under very high connection counts where most connections are idle at any moment (slow clients, many open sessions), these wakeups accumulate. `epoll` lets the kernel batch readiness signals — the event loop thread only runs when bytes are actually available, with no per-connection thread overhead.

```
Event loop thread (1):
  epoll_create1
  accept4 in a nonblocking loop when EPOLLIN fires on the listener
  for each new conn_fd:
    epoll_ctl(ADD, conn_fd, EPOLLIN | EPOLLONESHOT | EPOLLRDHUP)

Pool workers (pool_size, default max(10, cpu_count * 2)):
  loop:
    fd = FdQueue.pop()           <- blocks until epoll signals a readable fd
    serve one request on fd      <- blocking read/write, no fiber
    epoll_ctl(MOD, fd, re-arm)   <- re-arm EPOLLONESHOT for next request
    (or epoll_ctl(DEL) + close if connection ended)
```

`EPOLLONESHOT` means each readable event fires exactly once. After a request is served, the worker explicitly re-arms the socket. Idle keep-alive connections hold no thread — they sit in the epoll set until the client sends the next request.

**When to use:**
- Linux production deployments of `zix.Http` (HTTP/1) or `zix.Grpc` under high connection counts with many idle connections.
- Slow or bursty clients where connections stay open between requests.
- You want to avoid `io.async()` fiber scheduler overhead entirely.
- `dispatch_model = .EPOLL` in `HttpServerConfig` or `GrpcServerConfig`.
- `pool_size` controls worker count. `workers` is ignored (single event loop thread).

**Example (`zix.Http`):**
```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .EPOLL,
    .pool_size      = 32, // worker threads; 0 = max(10, cpu_count * 2)
});
try server.run();
```

**Example (`zix.Grpc`):**
```zig
var server = try zix.Grpc.Server.init(
    &[_]zix.Grpc.Route{
        .{ .path = "/helloworld.Greeter/SayHello", .handler = sayHello },
    },
    .{
        .io             = process.io,
        .dispatch_model = .EPOLL,
    },
);
try server.run();
```

**Cost and considerations:**

| Item | Detail |
| :- | :- |
| Platform | Linux only (`epoll_create1`, `epoll_wait`, `epoll_ctl`). Non-Linux falls back to `.POOL` automatically (with a debug print) |
| Availability | `zix.Http` (HTTP/1), `zix.Grpc`, `zix.Fix`, and `zix.Tcp` implement natively on Linux. `zix.Http2` falls back to `.POOL` |
| Accept model | Single-threaded accept inside the event loop (no `SO_REUSEPORT`). High accept rates can become a bottleneck — prefer `.MIXED` if connection churn (not connection count) is the bottleneck |
| gRPC, FIX, and TCP difference | gRPC, FIX, and TCP EPOLL assign each connection to a pool worker for its full lifetime (all are long-lived stream protocols). `EPOLLONESHOT` is not used. The benefit is single-threaded accept vs N accept threads in `.POOL` |
| `pool_size` | Controls the number of request-handling worker threads. `workers` is ignored |
| Keep-alive idle cost | Near-zero: idle sockets sit in the epoll set without holding any thread |
| Debugging | `strace` or `perf` will show `epoll_wait` dominating idle time — this is expected and correct |

**When NOT to use:**
- SSE or WebSocket: connections stay active and data flows continuously — `EPOLLONESHOT` re-arm overhead adds up with no benefit. Prefer `.ASYNC`.
- Non-Linux targets: use `.POOL` or `.ASYNC` explicitly to avoid the debug-print fallback.
- When connection count is low (< a few hundred): the simpler `.POOL` or `.ASYNC` models will perform the same or better with less complexity.

---

## Thread Count Reference

| Field | Default | Meaning |
| :- | :- | :- |
| `dispatch_model = .POOL` | work-queue thread pool | N accept threads + M pool threads |
| `dispatch_model = .ASYNC` | single accept, io.async() | 1 accept thread, io.async() per connection |
| `dispatch_model = .MIXED` | N accept, io.async() | N accept threads, each dispatching via io.async() |
| `workers = 0` | cpu_count accept threads | used by `.POOL` and `.MIXED` |
| `workers = N` | N accept threads | explicit override for `.POOL` and `.MIXED` |
| `pool_size = 0` | `max(10, cpu_count * 2)` | pool thread count for `.POOL` only |
| `pool_size = N` | N pool threads | explicit pool size for `.POOL` only |

---

## Dispatch Model Comparison

| | `.POOL` | `.ASYNC` | `.MIXED` | `.EPOLL` |
| :- | :- | :- | :- | :- |
| Accept threads | cpu_count (or N) | 1 | cpu_count (or N) | 1 |
| Connection dispatch | `queue.pop()` + sync I/O | `io.async()` task | `io.async()` task | epoll event loop |
| Scheduler overhead | no (blocking pop, no fiber) | yes (condvar wakeup) | yes (condvar wakeup) | no (epoll, Linux only) |
| Pool threads | yes (`pool_size`) | no | no | no |
| `SO_REUSEPORT` | yes | no | yes | no |
| `pool_size` field used | yes | no (ignored) | no (ignored) | no (ignored) |
| Best for | throughput, high connection counts | SSE, WebSocket, low latency | balanced, multi-accept async | high-throughput HTTP/1 or gRPC on Linux |
| Available in | Http, Http2, Grpc, Tcp, Fix | Http, Http2, Grpc, Tcp, Fix | Http, Http2, Grpc, Tcp, Fix | Http, Grpc, Fix, Tcp (Linux-only: Http2 falls back to .POOL) |

---

## Protocol Applicability

| Protocol | `.POOL` | `.ASYNC` | `.MIXED` | `.EPOLL` |
| :- | :- | :- | :- | :- |
| HTTP | yes | yes (default) | yes | yes, Linux-only |
| SSE | not recommended (exhausts pool threads) | yes, preferred | yes | n/a |
| WebSocket | not recommended (long-lived connections) | yes, preferred | yes | n/a |
| HTTP/2 (h2c) | yes | yes (default) | yes | n/a |
| gRPC (h2c) | yes | yes (default) | yes | yes, Linux-only |
| TCP (raw stream) | yes | yes (default) | yes | yes, Linux-only |
| FIX 4.x | yes | yes (default) | yes | yes, Linux-only |
| UDP | n/a | n/a | n/a | n/a |
| UDS (stream) | n/a | yes (io.concurrent() per connection) | n/a | n/a |

---

## Channel

`zix.Channel` is **not** a concurrency model. It is an in-process message-passing primitive
that works alongside all four dispatch models. A Channel connects producer and consumer tasks
(OS threads or `io.async()` fibers) within the same process. It does not cross a network or
process boundary.

```
Producer task --> [ Channel(T) ring buffer ] --> Consumer task
```

All four dispatch models can spawn `io.async()` tasks or OS threads that communicate through
a Channel. The Channel itself is independent of which dispatch model is in use.

| Property | Channel |
| :- | :- |
| Crossing process/network boundary | no (in-process only) |
| Works with `io.async()` tasks | yes, uses `std.Io.Mutex` + `std.Io.Condition` (fiber-aware) |
| Works with OS threads | yes: each thread needs its own `std.Io` from `std.Io.Threaded` |
| Replaces dispatch model | no (orthogonal) |

Status: Implemented. See ADR-017 and [`docs/hld-channel.md`](hld-channel.md).

---

###### end of concurrency
