# Concurrency Models: zix

Two threading models are available. Select via `config.workers` in `HttpServerConfig`.

---

## Model 1: Single Accept, io.concurrent Dispatch (`workers = 1`)

One thread binds the socket and calls `accept()` in a loop. Each accepted connection is
dispatched as a concurrent task via `io.concurrent()` (non-blocking, no busy-waiting).
The caller owns and creates the `std.Io` backend. This model is suitable when you need
explicit control over the concurrency limit.

```
Main thread:
  bind -> listen
  loop:
    stream = accept(io)
    io.concurrent(handleConnection, stream)   ← suspends, OS event loop schedules task

Handler tasks (one per active connection):
  handleConnection(stream)  // keep-alive loop until client closes
  task exits when connection closes
```

**When to use:**
- You need an explicit `concurrent_limit` (e.g. resource-constrained deployment).
- Single-threaded testing or embedding.
- `workers = 1` in `HttpServerConfig`.

**Example** (`examples/http_manual_concurrent.zig`):
```zig
var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{
    .concurrent_limit = std.Io.Limit.limited(4),
});
defer threaded.deinit();

var server = try zix.Http.Server.init(4096, .{
    .io = threaded.io(),
    .workers = 1, // stay on model 1, use the caller's io directly
    ...
});
```

---

## Model 2: Work-Queue Thread Pool (`workers = 0` or `workers = N`, default)

Dedicated accept threads push accepted connections to a shared `ConnQueue`. Pool threads
pop connections and handle each one synchronously with blocking I/O (no scheduler,
no `io.concurrent()` overhead). `SO_REUSEPORT` allows all accept threads to listen on
the same port in parallel.

```
Main thread:
  create ConnQueue + std.Io.Threaded backend
  spawn pool_size pool threads
  spawn worker_count accept threads
  join accept threads -> queue.close() -> join pool threads

Accept threads (worker_count, default 2):
  bind/listen on same port with SO_REUSEPORT
  loop:
    stream = accept(io)
    queue.push(stream)   ← fast, never blocks on I/O

Pool threads (pool_size, default max(10, cpu_count * 2)):
  loop:
    stream = queue.pop()          ← blocks until a connection arrives
    handleConnection(stream, io)  ← synchronous blocking I/O, keep-alive loop
    (loop, next pop)
```

**When to use:**
- Default for production workloads.
- `workers = 0` (default) uses 2 accept threads.
- `workers = N` (N ≥ 2) uses exactly N accept threads.
- `pool_size = 0` (default) sizes the pool at `max(10, cpu_count * 2)`.
- `pool_size = N` uses exactly N pool threads.

**OS requirement:** `SO_REUSEPORT` (Linux ≥ 3.9, macOS, BSD).

**Example** (default, `examples/http_basic.zig` and others):
```zig
pub fn main(process: std.process.Init) !void {
    var server = try zix.Http.Server.init(4096, .{
        .io = process.io,
        // workers   = 0  -> 2 accept threads
        // pool_size = 0  -> max(10, cpu_count * 2) pool threads
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

## Thread Count Reference

| Field | Default | Meaning |
| :- | :- | :- |
| `workers = 0` | 2 accept threads | Enough to saturate the kernel accept queue |
| `workers = 1` | model 1 (no pool) | Single accept + `io.concurrent` dispatch |
| `workers = N` | N accept threads | Explicit accept parallelism |
| `pool_size = 0` | `max(10, cpu_count * 2)` | Standard blocking-thread pool sizing |
| `pool_size = N` | N pool threads | Explicit pool size |

---

## Model Comparison

| | Model 1 | Model 2 |
| :- | :- | :- |
| Accept threads | 1 | 2 (or N) |
| Connection dispatch | `io.concurrent()` task | `queue.pop()` + synchronous I/O |
| Scheduler overhead | yes (condvar wakeup per connection) | no (blocking pop, no fiber) |
| Concurrency cap | `concurrent_limit` on `std.Io.Threaded` | `pool_size` (OS threads) |
| `SO_REUSEPORT` | no | yes |
| Use case | explicit limit, single-threaded embed | production default |

---

## Protocol Applicability

| Protocol | Model 1 | Model 2 |
| :- | :- | :- |
| TCP (HTTP) | yes (`workers = 1`) | yes (default) |
| TCP (SSE) | yes, required (long-lived connections fit the async task model) | not recommended (exhausts blocking pool threads) |
| UDP | yes (current src/) | planned |
| UDS (stream) | yes, implemented (`io.concurrent()` per connection) | not applicable (no pool in UDS server) |
| UDS (datagram) | not via `std.Io.net` (would need raw `std.posix`). Deferred. | defer |

---

## Channel

`zix.Channel` is **not** a concurrency model. It is an in-process message-passing primitive that works alongside the server models. A Channel connects two or more `io.concurrent()` tasks (or OS threads) within the same process. It does not cross a network or process boundary.

```
Producer task --> [ Channel(T) ring buffer ] --> Consumer task
```

Both Model 1 and Model 2 servers can spawn `io.concurrent()` tasks or OS threads that communicate through a Channel. The Channel itself is independent of which server model is in use.

| Property | Channel |
| :- | :- |
| Crossing process/network boundary | no (in-process only) |
| Works with `io.concurrent()` tasks | yes, uses `std.Io.Mutex` + `std.Io.Condition` (fiber-aware) |
| Works with OS threads | yes: each thread needs its own `std.Io` from `std.Io.Threaded` |
| Replaces Model 1 / Model 2 | no (orthogonal) |

Status: Implemented. See ADR-017 and [`docs/hld-channel.md`](hld-channel.md).

---

###### end of concurrency
