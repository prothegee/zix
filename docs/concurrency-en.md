# Concurrency Models: zix

Five dispatch models for HTTP and raw TCP. Select via `config.dispatch_model` (`DispatchModel` enum) in `HttpServerConfig` or `TcpServerConfig`. Required: set it explicitly (no default).

---

## DispatchModel

```zig
pub const DispatchModel = enum(u8) {
    ASYNC = 0, // single accept, io.async() dispatch
    POOL  = 1, // work-queue thread pool
    MIXED = 2, // N accept threads, each dispatching via io.async()
    EPOLL = 3, // shared-nothing epoll workers, Linux-only
    URING = 4, // shared-nothing io_uring workers, Linux-only
};
```

Defined once in `src/tcp/config.zig`. Re-exported by `src/tcp/http/config.zig` (for `zix.Http`) and imported by `src/tcp/http2/grpc/config.zig` (for `zix.Grpc`). All five values are present in every config.

`.EPOLL = 3` is Linux-only. `zix.Http` (HTTP/1), `zix.Http1`, `zix.Http2`, `zix.Grpc`, `zix.Fix`, and `zix.Tcp` implement it natively on Linux. Non-Linux builds fall back to `.POOL` automatically. `.URING = 4` is also Linux-only and native in `zix.Http1`, `zix.Http`, `zix.Http2`, `zix.Grpc`, and `zix.Fix`. The `zix.Tcp` per-connection handler folds to `.EPOLL` (the `zix.Tcp` framed callback runs the ring natively). See the Dispatch Model Comparison table below.

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

**Example** (`examples/http_basic_2_pool.zig` with explicit POOL):
```zig
pub fn main(process: std.process.Init) !void {
    var server = zix.Http.Server.init(&[_]zix.Http.Route{
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
var server = zix.Http.Server.init(&[_]zix.Http.Route{
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
var server = zix.Http.Server.init(&[_]zix.Http.Route{
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

var server = zix.Http.Server.init(&[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = threaded.io(),
    .dispatch_model = .ASYNC,
});
```

---

## .MIXED: N Accept Threads, io.async() Dispatch

N accept threads each dispatch connections via `io.async()` directly, no `ConnQueue`. Balanced
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
var server = zix.Http.Server.init(&[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .MIXED,
});
```

---

## .EPOLL: Shared-Nothing epoll Event Loop (Linux-only)

Each worker owns a private `SO_REUSEPORT` listener and its own `epoll` instance. The kernel
distributes new connections across per-worker listeners. No shared queue, no cross-thread fd
handoff. Each worker accepts, registers, reads, and responds on its own connections without
touching any other worker's state.

**Why it exists:** `.POOL` and `.ASYNC` both pay a cross-thread wakeup cost on every accepted
connection (either via `ConnQueue.pop()` or via the `io.async()` fiber scheduler). Under very
high connection counts where connections are fast but many overlap, queue contention accumulates.
With shared-nothing, a worker accepts directly on its own listener and handles all I/O inline:
no mutex, no condvar, no fd handoff.

```
Workers (workers, default cpu_count):
  resolve + listen on same port with SO_REUSEPORT
  epoll_create1
  epoll_ctl(ADD, listener_fd, EPOLLIN)        <- accept loop trigger

  event loop:
    epoll_wait(events, EPOLL_MAX_EVENTS)        <- Http: 1024, Http1: 4096
    for each event:
      if listener_fd:
        loop: fd = accept4(SOCK_CLOEXEC)
              setNoDelay(fd)
              epoll_ctl(ADD, fd, EPOLLIN | EPOLLRDHUP)
      else:   // connection fd
        if HUP or ERR or RDHUP:
          epoll_ctl(DEL, fd)
          close(fd)
        else:
          handleOneRequest(fd)   <- blocking read/write, no fiber
          if keep-alive: stay registered (level-triggered, re-fires on next data)
          if close: epoll_ctl(DEL, fd) + close(fd)
```

Connections stay registered after each request. No explicit re-arm is needed: level-triggered
`EPOLLIN` re-fires whenever new data arrives. Idle keep-alive connections hold no thread and
occupy only one entry in the per-worker epoll set.

**When to use:**
- Linux production deployments of `zix.Http` or `zix.Http1` under high connection counts.
- Short-lived requests (REST, API) where `handleOneRequest` finishes quickly and returns the
  worker to `epoll_wait`.
- You want to avoid `io.async()` fiber scheduler overhead entirely.
- `dispatch_model = .EPOLL` in `HttpServerConfig` or `Http1ServerConfig`.
- `workers` controls worker count (0 = cpu_count). `pool_size` is ignored for `zix.Http`.

**Example (`zix.Http`):**
```zig
var server = zix.Http.Server.init(&[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .EPOLL,
    .workers        = 0, // 0 = cpu_count workers (default)
});
try server.run();
```

**Example (`zix.Grpc`):**
```zig
var server = zix.Grpc.Server.init(
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
| Availability | `zix.Http` (HTTP/1), `zix.Http1`, `zix.Http2`, `zix.Grpc`, `zix.Fix`, and `zix.Tcp` implement natively on Linux |
| Accept model (`zix.Http`) | Each worker binds its own `SO_REUSEPORT` listener. The kernel distributes connections across workers: no shared accept queue |
| gRPC difference | `zix.Grpc` uses a multiplexed shared-nothing model: one worker drives many non-blocking h2 connections via a resumable state machine. `pool_size` is the worker count. See ADR-031 |
| FIX and TCP difference | `zix.Fix` and `zix.Tcp` EPOLL use a centralized design: one accept loop pushes fds to a shared queue, pool workers pop and hold each connection for its full lifetime. `pool_size` is the worker count |
| `workers` field (`zix.Http`, `zix.Http1`) | Controls the number of shared-nothing worker threads (0 = cpu_count). `pool_size` is ignored |
| `pool_size` field (gRPC, FIX, TCP) | Controls the multiplexed or pool worker count. See per-protocol docs |
| Keep-alive idle cost | Near-zero: idle sockets sit in the epoll set without holding any thread |
| Debugging | `strace` or `perf` will show `epoll_wait` dominating idle time, this is expected and correct |

**When NOT to use:**
- SSE or WebSocket via `zix.Http`: connections stay active and data flows continuously, blocking reads will park the worker. Prefer `.ASYNC`.
- Non-Linux targets: use `.POOL` or `.ASYNC` explicitly to avoid the debug-print fallback.
- When connection count is low (< a few hundred): the simpler `.POOL` or `.ASYNC` models will perform the same or better with less complexity.

---

## .URING: Shared-Nothing io_uring Event Loop (Linux-only)

`.URING` is the completion-based sibling of `.EPOLL`: the same shared-nothing, thread-per-core topology (one `SO_REUSEPORT` listener and one ring per worker, no shared queue, no cross-thread fd handoff), but accepts, reads, and writes are submitted as io_uring SQEs and reaped as CQEs instead of waiting on `epoll_wait` readiness. Most syscall transitions are batched into the ring (ADR-037 Phase 4).

- Native engines: `zix.Http1`, `zix.Http`, `zix.Http2`, `zix.Grpc`, `zix.Fix`. The `zix.Tcp` per-connection handler has no native ring and folds to `.EPOLL` (the `zix.Tcp` framed callback does run the ring). Non-Linux builds fall back to `.POOL`.
- `workers` (Http/Http1) or `pool_size` (gRPC/FIX/TCP) sizes the worker count, exactly as `.EPOLL`.
- On loopback `.URING` matches `.EPOLL` on throughput and total CPU, winning mainly on per-request cache locality. On a many-core box the ring close (`prep_close`, ADR-041) keeps the worker reaping completions through connection churn instead of blocking in a synchronous `close`, so `.URING` reaches parity or better than `.EPOLL` on every measured workload at a fraction of the memory.
- Same "when NOT to use" as `.EPOLL`: SSE / WebSocket on `zix.Http`, low connection counts, non-Linux targets.

---

## Why Dispatch Loops Are Per-Engine

Each engine keeps its own dispatch loop (`.ASYNC` / `.POOL` / `.MIXED` / `.EPOLL` / `.URING`) in its own `server.zig` rather than behind one generic multiplexer. The split is deliberate and is itself the optimization: per-engine ownership lets each engine tune its hot path for its own connection shape.

The clearest example is the `.EPOLL` connection table, which looks like the most duplicated piece but is in fact specialized per engine:

| Engine | Connection table | Allocation | Why |
| :- | :- | :- | :- |
| `zix.Http1` | contiguous demand-paged slab | no per-accept heap call | buffers carved from one `MAX_FD * buf_size` slab, empty slot is `buf.len == 0` |
| `zix.Grpc` | per-connection heap pointer | one heap object per accept | the connection carries resumable h2 + HPACK state, too large and variable for one fixed slab cell |
| `zix.Fix` | per-connection heap pointer | one heap object per accept | the connection carries FIX session state (sequence numbers, heartbeat timing) |

A single generic loop would force one connection-table shape on every engine (erasing the `zix.Http1` slab win) and add a callback-per-event indirection on the accept / recv / send path, which is the hottest path in the library.

Only byte-identical primitives are shared, in `src/multiplexers/`. Today that is the `.URING` `user_data` codec (`ring.zig`): every io_uring engine must pack the same bits (an fd-keyed slot guarded by a generation in one layout), so the codec is hoisted out while the ring loop and slot table stay per-engine. The rule: share primitives that must match, keep dispatch loops per-engine. See ADR-042.

---

## Thread Count Reference

| Field | Default | Meaning |
| :- | :- | :- |
| `dispatch_model = .POOL` | work-queue thread pool | N accept threads + M pool threads |
| `dispatch_model = .ASYNC` | single accept, io.async() | 1 accept thread, io.async() per connection |
| `dispatch_model = .MIXED` | N accept, io.async() | N accept threads, each dispatching via io.async() |
| `workers = 0` | cpu_count threads | used by `.POOL`, `.MIXED`, and `.EPOLL` (for `zix.Http` and `zix.Http1`) |
| `workers = N` | N threads | explicit override for `.POOL`, `.MIXED`, and `.EPOLL` (for `zix.Http` and `zix.Http1`) |
| `pool_size = 0` | `max(10, cpu_count * 2)` | pool thread count for `.POOL`. Worker count for `.EPOLL` in `zix.Grpc`, `zix.Fix`, `zix.Tcp` |
| `pool_size = N` | N pool or mux workers | explicit size for `.POOL`. Explicit EPOLL worker count for `zix.Grpc`, `zix.Fix`, `zix.Tcp` |

---

## Dispatch Model Comparison

| | `.POOL` | `.ASYNC` | `.MIXED` | `.EPOLL` |
| :- | :- | :- | :- | :- |
| Accept threads | cpu_count (or N) | 1 | cpu_count (or N) | cpu_count (or N) |
| Connection dispatch | `queue.pop()` + sync I/O | `io.async()` task | `io.async()` task | per-worker epoll, level-triggered |
| Scheduler overhead | no (blocking pop, no fiber) | yes (condvar wakeup) | yes (condvar wakeup) | no (epoll, Linux only) |
| Pool threads | yes (`pool_size`) | no | no | no |
| `SO_REUSEPORT` | yes | no | yes | yes (per-worker listener, Http only) |
| `workers` field used | yes | no (ignored) | yes | yes (Http/Http1 only) |
| `pool_size` field used | yes | no (ignored) | no (ignored) | no (Http: ignored). Yes (gRPC/FIX/TCP) |
| Best for | throughput, high connection counts | SSE, WebSocket, low latency | balanced, multi-accept async | high-throughput HTTP/1 or gRPC on Linux |
| Available in | Http, Http2, Grpc, Tcp, Fix | Http, Http2, Grpc, Tcp, Fix | Http, Http2, Grpc, Tcp, Fix | Http, Http2, Grpc, Fix, Tcp (Linux-only) |

`.URING` (Linux-only) mirrors the `.EPOLL` column: a shared-nothing per-worker ring, completion-based, native in Http1, Http, Http2, Grpc, and Fix. The Tcp per-connection handler folds to `.EPOLL` (the Tcp framed callback runs the ring).

---

## Protocol Applicability

| Protocol | `.POOL` | `.ASYNC` | `.MIXED` | `.EPOLL` |
| :- | :- | :- | :- | :- |
| HTTP | yes | yes (default) | yes | yes, Linux-only |
| SSE | not recommended (exhausts pool threads) | yes, preferred | yes | n/a |
| WebSocket | not recommended (long-lived connections) | yes, preferred | yes | n/a |
| HTTP/2 (h2c) | yes | yes (default) | yes | yes, Linux-only |
| HTTP/3 (QUIC) | yes | yes (single worker) | yes | yes, Linux-only |
| gRPC (h2c) | yes | yes (default) | yes | yes, Linux-only |
| TCP (raw stream) | yes | yes (default) | yes | yes, Linux-only |
| FIX 4.x | yes | yes (default) | yes | yes, Linux-only |
| UDP | n/a | n/a | n/a | n/a |
| UDS (stream) | n/a | yes (io.concurrent() per connection) | n/a | n/a |

`.URING` (Linux-only) matches the `.EPOLL` column per protocol: native for HTTP, HTTP/2, gRPC, TCP, and FIX, n/a for SSE / WebSocket / UDP / UDS, and Http3 runs real per-core workers (cross-core CID steering for mid-connection migration is v2, ADR-049 phase 3).

---

## Cross-Platform Backends (planned)

Each model names two things at once: a concurrency shape (single or multi-core) and, for the per-core models, an I/O backend. The backend is OS-specific. The contract: the OS swaps the backend, never the single-or-multi nature of the model.

| Model | Core behavior | OS | Status |
| :- | :- | :- | :- |
| `.ASYNC` | single | all | now |
| `.POOL` | multi (thread pool) | all | now |
| `.MIXED` | multi (hybrid) | all | now |
| `.EPOLL` | multi (per-core) | Linux | now |
| `.URING` | multi (per-core) | Linux | now |
| `.KQUEUE` | multi (per-core) | macOS / BSD | planned |
| `.IOCP` | multi (per-core) | Windows | planned |

`.EPOLL`, `.KQUEUE`, and `.IOCP` are the same multi-core per-core idea, one per operating system. Each lives in its own `dispatch/<model>.zig` file, so the folder is self-documenting: open it, see every model, each header line states its core behavior and OS.

Like `.EPOLL` and `.URING` today, these backends are family-wide: every engine that selects a `DispatchModel` (`zix.Http`, `zix.Http1`, `zix.Http2`, `zix.Http3`, `zix.Grpc`, `zix.Tcp`, `zix.Fix`, `zix.Udp`) gets its platform's backend through the same enum.

There is no auto-select keyword. Portable code picks a portable shape (`.POOL` / `.MIXED`) or names the exact backend with a one-line comptime switch on `builtin.os.tag`. Two mismatches are handled differently:

- A backend that cannot exist on the target OS (for example `.IOCP` on Linux) is a compile-time error (a category error), caught at build.
- A backend that exists but the machine cannot use at runtime (for example `.URING` on an old kernel) folds to a working model with a logged notice (a capability gap).

Today, before the macOS and Windows backends land, `.EPOLL` on a non-Linux build folds to `.POOL` as an interim. `.KQUEUE` and `.IOCP` are reserved names only, not yet implemented and not present as source files. See ADR-050.

---

## Channel

`zix.Channel` is **not** a concurrency model. It is an in-process message-passing primitive
that works alongside all five dispatch models. A Channel connects producer and consumer tasks
(OS threads or `io.async()` fibers) within the same process. It does not cross a network or
process boundary.

```
Producer task --> [ Channel(T) ring buffer ] --> Consumer task
```

All five dispatch models can spawn `io.async()` tasks or OS threads that communicate through
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
