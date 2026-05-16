# Concurrency Models: zix

Three dispatch models for HTTP. Select via `config.dispatch_model` (`DispatchModel` enum) in `HttpServerConfig`. Default: `.POOL`.

---

## DispatchModel

```zig
pub const DispatchModel = enum(u8) {
    POOL  = 0, // work-queue thread pool (default)
    ASYNC = 1, // single accept, io.async() dispatch
    MIXED = 2, // N accept threads, each dispatching via io.async()
};
```

---

## .POOL: Work-Queue Thread Pool (default)

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
- Default for production workloads.
- Best throughput under high connection counts.
- `dispatch_model = .POOL` (default, can be omitted).
- `workers = 0` (default) uses cpu_count accept threads.
- `workers = N` uses exactly N accept threads.
- `pool_size = 0` (default) sizes the pool at `max(10, cpu_count * 2)`.
- `pool_size = N` uses exactly N pool threads.

**OS requirement:** `SO_REUSEPORT` (Linux >= 3.9, macOS, BSD).

**Example** (default, `examples/http_basic.zig` and others):
```zig
pub fn main(process: std.process.Init) !void {
    var server = try zix.Http.Server.init(4096, .{
        .io = process.io,
        // dispatch_model = .POOL  (default, can be omitted)
        // workers        = 0  -> cpu_count accept threads
        // pool_size      = 0  -> max(10, cpu_count * 2) pool threads
        ...
    });
    try server.run();
}
```

**Explicit thread counts:**
```zig
var server = try zix.Http.Server.init(4096, .{
    .io        = process.io,
    .workers   = 4,   // 4 accept threads
    .pool_size = 32,  // 32 pool threads
    ...
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
var server = try zix.Http.Server.init(4096, .{
    .io             = process.io,
    .dispatch_model = .ASYNC,
    ...
});
```

**Manual concurrency limit** (`examples/http_manual_concurrent.zig`):
```zig
var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{
    .concurrent_limit = std.Io.Limit.limited(4),
});
defer threaded.deinit();

var server = try zix.Http.Server.init(4096, .{
    .io             = threaded.io(),
    .dispatch_model = .ASYNC, // .ASYNC uses the caller's io directly
    ...
});
```

---

## .MIXED: N Accept Threads, io.async() Dispatch

N accept threads each dispatch connections via `io.async()` directly — no `ConnQueue`. Balanced
throughput and latency; higher jitter than `.POOL` under saturation due to `io.async()` fallback
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
var server = try zix.Http.Server.init(4096, .{
    .io             = process.io,
    .dispatch_model = .MIXED,
    ...
});
```

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

| | `.POOL` | `.ASYNC` | `.MIXED` |
| :- | :- | :- | :- |
| Accept threads | cpu_count (or N) | 1 | cpu_count (or N) |
| Connection dispatch | `queue.pop()` + sync I/O | `io.async()` task | `io.async()` task |
| Scheduler overhead | no (blocking pop, no fiber) | yes (condvar wakeup) | yes (condvar wakeup) |
| Pool threads | yes (`pool_size`) | no | no |
| `SO_REUSEPORT` | yes | no | yes |
| `pool_size` field used | yes | no (ignored) | no (ignored) |
| Best for | throughput, high connection counts | SSE, WebSocket, low latency | balanced, multi-accept async |

---

## Protocol Applicability

| Protocol | `.POOL` | `.ASYNC` | `.MIXED` |
| :- | :- | :- | :- |
| HTTP | yes (default) | yes | yes |
| SSE | not recommended (exhausts pool threads) | yes, preferred | yes |
| WebSocket | not recommended (long-lived connections) | yes, preferred | yes |
| UDP | n/a | n/a | n/a |
| UDS (stream) | n/a | yes (io.async() per connection) | n/a |

---

## Channel

`zix.Channel` is **not** a concurrency model. It is an in-process message-passing primitive
that works alongside all three dispatch models. A Channel connects producer and consumer tasks
(OS threads or `io.async()` fibers) within the same process. It does not cross a network or
process boundary.

```
Producer task --> [ Channel(T) ring buffer ] --> Consumer task
```

All three dispatch models can spawn `io.async()` tasks or OS threads that communicate through
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
