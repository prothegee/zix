# NOTE: HttpEngine Approach 1

Custom HTTP backend engine for `zix.Http.Server`. Replaces `std.http.Server` on the hot path with a pure-POSIX, zero-copy parser. Does not rely on `std.Io` for data I/O inside the engine — raw `posix.read`/`posix.write` (or `recv`/`send`) on blocking sockets.

---

## Motivation

`std.http.Server` is the remaining latency ceiling (ADR-015: ~3-5K req/s gap, ~4 µs latency gap vs comparable blocking-thread servers). The stdlib HTTP parser introduces overhead from its internal representation, allocation strategy, and abstraction over `std.Io`. The goal is a backend that is:

- Custom: parses HTTP/1.1 directly from a raw read buffer, no std.http dependency on the data path
- Pure POSIX: `posix.read`/`posix.write` on blocking sockets inside the engine; no `std.Io` dispatch on the hot path
- Zero-copy: parser works on byte offsets into the read buffer, no header data is copied during parsing
- Model 2 only: blocking OS threads (ConnQueue), no `io.concurrent()` in the engine

TLS is out of scope. Terminate at the proxy (nginx, HAProxy, Envoy). zix speaks plain HTTP behind the proxy.

---

## Boundary: Transport vs. Engine

Two distinct layers. The transport owns the socket lifecycle; the engine owns the HTTP lifecycle.

| Layer | Owns | Config fields |
| :- | :- | :- |
| Transport (`server.zig`) | accept threads, ConnQueue, pool threads, SO_REUSEPORT, Layer D eviction, date timer | `ip`, `port`, `workers`, `pool_size`, `max_kernel_backlog`, `conn_timeout_ms` |
| Engine (`engine.zig`) | read buffer, write buffer, parser, arena, Request/Response construction, router dispatch, Layer B timeout, static serving | `max_client_request`, `max_client_response`, `max_allocator_size`, `max_response_headers`, `handler_timeout_ms`, `public_dir`, `public_dir_upload` |

The transport hands a raw socket fd (or stream) to the engine. The engine never calls `accept()`. The engine never touches ConnQueue.

---

## Config Layout

```zig
pub const HttpEngineConfig = struct {
    max_client_request:   usize      = 1024 * 4,
    max_client_response:  usize      = 1024 * 4,
    max_allocator_size:   usize      = 1024 * 4,
    max_response_headers: HeaderSize = .COMMON,
    handler_timeout_ms:   u32        = 0,
    public_dir:           []const u8 = "",
    public_dir_upload:    []const u8 = "u",
};

pub const HttpServerConfig = struct {
    io:                 std.Io,
    allocator:          std.mem.Allocator,
    ip:                 []const u8,
    port:               u16,
    workers:            usize = 0,
    pool_size:          usize = 0,
    max_kernel_backlog: usize = 1024 * 4,
    conn_timeout_ms:    u32   = 0,
    engine:             HttpEngineConfig = .{},
};
```

Nesting `engine` keeps existing call sites compatible. Transport config and engine config are visually separated without forcing callers to construct two objects.

---

## Parser Design

### Rule 1: parser is a pure function

```
parse(buf: []const u8) ParseResult
```

No I/O. No allocation. No side effects. Takes a byte slice, returns either a complete parsed header block or `Incomplete` (caller must read more bytes and retry).

### Rule 2: offset-based output, not slices

The parser returns byte offsets (start + length pairs) into `buf`, not `[]const u8` slices. Slices into the read buffer are valid only while the buffer does not move. Offsets are always stable. `Request` fields index into the read buffer on the pool thread's stack.

```zig
const ParsedHead = struct {
    method_start:  u16,
    method_len:    u8,
    path_start:    u16,
    path_len:      u16,
    query_start:   u16,  // 0 if absent
    query_len:     u16,
    header_count:  u8,
    headers:       [MAX_REQUEST_HEADERS]HeaderEntry,
    body_offset:   u16,  // byte after \r\n\r\n
    keep_alive:    bool,
};

const HeaderEntry = struct {
    name_start:  u16,
    name_len:    u8,
    value_start: u16,
    value_len:   u16,
};
```

### Rule 3: read loop accumulates until header complete

The engine accumulates bytes into the read buffer (raw `posix.recv` on blocking socket) until `\r\n\r\n` is found. Only then does the parser run. This handles partial reads as the normal case, not an error.

```
read loop:
    recv(fd, buf[filled..], 0)   // blocking, POSIX
    filled += n
    if memchr/indexOf(buf[0..filled], "\r\n\r\n"):
        parse(buf[0..filled]) -> ParsedHead
        break
    if filled >= buf.len:
        -> 431 Request Header Fields Too Large
```

### Rule 4: body is lazy, not parsed eagerly

The parser does not read or validate the body. The engine exposes a body reader to the handler that reads from the socket on demand, bounded by `Content-Length`. Body is not parsed at all for `GET`, `HEAD`, `DELETE`, `OPTIONS`.

---

## Engine Connection Loop

Replaces `handleConnection` in the current `server.zig`.

```
handleConnection(fd: posix.fd_t, io: std.Io):
    setsockopt(fd, TCP_NODELAY)
    stack read_buf[max_client_request] or heap if oversized
    stack write_buf[max_client_response] or heap if oversized
    ArenaAllocator per connection
    keep-alive loop:
        arena.reset(.retain_capacity)
        recv loop -> ParsedHead or 431
        build Request(buf, head, fd)
        build Response(write_buf, fd)
        build Context(io, arena.allocator(), fd)
        Layer B: if handler_timeout_ms > 0: ctx.deadline = ...
        load date cache
        router.dispatch(req, res, ctx)
        if res.streaming: break
        if public_dir and not dispatched: static.serve(...)
        if not served: 404
    close(fd)
```

Note: `io: std.Io` is still passed for arena and Layer B compatibility (`ctx.timedOut()` uses it). It is NOT used for `recv`/`send` — those are raw `posix` calls.

---

## Response Write Strategy

Current approach: multiple `writeAll` calls through `std.Io.Writer`. Engine approach:

- Fast path (no extra headers, body fits in write buffer): stage entire response (status line + fixed headers + body) into `write_buf`, then one `posix.write(fd, write_buf[0..total])`. Single syscall.
- Slow path (extra headers present or body too large for write buffer): `writev(fd, iov, n)` with iov slots for status+fixed-headers, each extra header, blank line, body. Eliminates multiple syscalls for the extra-headers case.

`writev` is POSIX. No std dependency.

---

## Planned File Structure

```
src/tcp/http/engine.zig        HttpEngine: handleConnection, keep-alive loop
src/tcp/http/parser.zig        parse(): pure function, ParsedHead, HeaderEntry
src/tcp/http/server.zig        transport: accept threads, ConnQueue, pool threads (unchanged shape)
src/tcp/http/config.zig        HttpEngineConfig + HttpServerConfig (split)
src/tcp/http/request.zig       Request: offset-based field access into read buffer
src/tcp/http/response.zig      Response: write_buf + writev path (update)
```

---

## Open Questions

These must be resolved before writing code.

| # | Question | Impact |
| :- | :- | :- |
| 1 | Does `posix.read`/`posix.write` replace `std.Io.net.Stream` entirely inside the engine, or does `std.Io` remain for the read/write path? | Determines whether `io: std.Io` is still passed to `handleConnection` for I/O or only for Layer B (arena, timeout) |
| 2 | Is `writev` in scope for the engine response path? | If yes, slow path becomes one syscall; if no, keep current buffered multi-write approach |
| 3 | Chunked request body (`Transfer-Encoding: chunked`): handle or reject with 411? | If reject, parser is simpler: only `Content-Length` bodies. If handle, chunked decode adds ~80 lines to the engine |
| 4 | How many request headers does the engine store: fixed comptime cap or configurable? | Comptime cap (e.g. 64) means `ParsedHead` is a fixed-size stack struct. Configurable means arena-allocated slice of `HeaderEntry` |
| 5 | Per-request allocator: keep `std.heap.ArenaAllocator` or replace with a custom bump allocator backed by a fixed stack buffer? | Custom bump removes the last std heap dependency on the per-request path; arena is simpler and already fast |

---

## PoC Benchmark: Dispatch Model Comparison

Three self-contained PoC files under `rnd/` isolate the dispatch model as the only variable. Parser, date cache, `fdWriteAll`, and `handleConnection` are identical across all three. Each responds with `Hello, World!` (keep-alive, HTTP/1.1).

### Models

| File | Port | Dispatch |
| :- | :- | :- |
| `rnd/http_poc_model_1_async.zig` | 9100 | Single accept thread, `io.async()` per connection (`std.Io.Threaded` internal pool) |
| `rnd/http_poc_model_2_pool.zig` | 9101 | N accept threads (SO_REUSEPORT) + ConnQueue + M blocking pool threads (`std.Thread.spawn`) |
| `rnd/http_poc_model_3_mixed.zig` | 9102 | N accept threads (SO_REUSEPORT), each calling `io.async()` directly (no ConnQueue) |

All run debug build (`zig run`, no `-O` flag). Machine: cpu_count available to auto-size workers and pool.

---

### Run 1: `wrk -c100 -t1 -d10s`

| Model | Avg Latency | Stdev | Max Latency | Req/s | Transfer/s |
| :- | :- | :- | :- | :- | :- |
| 1 (io.async) | 49.88µs | 20.82µs | 3.37ms | 149,188 | 19.78MB |
| 2 (pool) | 342.81µs | 93.51µs | 3.89ms | 147,403 | 19.54MB |
| 3 (mixed) | 86.01µs | 29.87µs | 3.43ms | 148,596 | 19.70MB |

Observation: throughput is flat across all three (~149k req/s) — all hit the same ceiling at 100 connections, 1 wrk thread. Latency is the differentiator. Model 2's ConnQueue hand-off costs ~290µs per request over Model 1.

---

### Run 2: `wrk -c1000 -t4 -d10s`

| Model | Avg Latency | Stdev | Max Latency | Req/s | Transfer/s |
| :- | :- | :- | :- | :- | :- |
| 1 (io.async) | 35.72µs | 19.95µs | 3.84ms | 242,368 | 32.13MB |
| 2 (pool) | 367.25µs | 157.71µs | 5.20ms | 351,014 | 46.53MB |
| 3 (mixed) | 55.53µs | 96.11µs | 5.00ms | 312,713 | 41.45MB |

---

### Analysis

**Throughput scaling (c100 to c1000):**

| Model | c100 req/s | c1000 req/s | Scale factor |
| :- | :- | :- | :- |
| 1 (io.async) | 149,188 | 242,368 | 1.62x |
| 2 (pool) | 147,403 | 351,014 | 2.38x |
| 3 (mixed) | 148,596 | 312,713 | 2.10x |

Model 2 scales best under high connection counts. Pre-warmed pool threads absorb the connection burst without spawn cost. Model 1's single accept thread becomes the bottleneck as connection count grows — `io.async()` fallback to inline blocks the accept loop.

**Latency:**

Model 1 holds the lowest avg latency at both test points (50µs at c100, 36µs at c1000). The per-request latency actually drops under load because more connections amortize the io.async() dispatch.

Model 3 stdev at c1000 (96µs) exceeds its avg (55µs) — sign of bimodal distribution. Fast path when a pool thread is free, slow path (inline on accept thread) when `async_limit` is reached. This is the fallback behavior of `io.async()` under saturation.

Model 2 latency is stable but high: 342µs (c100) and 367µs (c1000). The ConnQueue mutex + condition variable wake is consistent overhead that does not compress under load.

**Summary:**

- Latency-first (low connection count, interactive): Model 1 or Model 3.
- Throughput-first (high connection count, I/O-bound pool): Model 2.
- Model 3 (mixed) sits between the two: better throughput than Model 1 at scale, lower avg latency than Model 2, but higher jitter than both due to `io.async()` fallback.

The existing `zix.Http.Server` uses Model 2 as default (`workers = 0` = cpu_count accept threads, `pool_size = 0` = cpu_count * 2 * 10 pool threads). This matches the throughput-scaling profile seen here.

---

## Dispatch Model Enum

The three models are selectable via a config field rather than hardcoded. Proposed addition to `HttpServerConfig`:

```zig
pub const DispatchModel = enum(u8) {
    POOL  = 0, // N accept threads + ConnQueue + M pool threads (throughput-first, default)
    ASYNC = 1, // single accept thread + io.async() per connection (latency-first)
    MIXED = 2, // N accept threads each calling io.async() directly (balanced)
};

// in HttpServerConfig:
dispatch_model: DispatchModel = .POOL,
```

`POOL = 0` is the zero-value so zero-init structs get the right default automatically.

### Config Field Interactions per Model

| Field | POOL | ASYNC | MIXED |
| :- | :- | :- | :- |
| `workers` | accept thread count (0 = cpu_count) | ignored, always 1 accept thread | accept thread count (0 = cpu_count) |
| `pool_size` | pool thread count (0 = cpu_count * 2 * 10) | ignored | ignored |
| `io` (when non-null) | used for ConnQueue sync primitives, ctx, arena, and any handler-level `io.async()` calls | controls connection dispatch pool (async_limit, stack_size) | controls connection dispatch pool (async_limit, stack_size) |

`io` is not ignored in POOL mode. What `io`'s `async_limit` and `stack_size` do not control in POOL mode is the connection dispatch itself: pool threads are spawned via `std.Thread.spawn` with their own `SpawnConfig.stack_size`, bypassing `io`'s pool for dispatch. `async_limit` still bounds any `io.async()` calls handlers make from inside pool threads.

In ASYNC and MIXED, `io`'s `async_limit` is the primary concurrency knob for connection dispatch. In POOL, `pool_size` is that knob.

---

## Real Server Benchmark: zix.Http.Server with DispatchModel

Run against the actual `zix.Http.Server` on branch `new-http_engine_model` (debug build).
Unlike the PoC, this includes router dispatch, Request/Response construction, and arena allocation.
Examples used: `examples/http_basic_1_async.zig`, `examples/http_basic_2_pool.zig`, `examples/http_basic_3_mixed.zig`.

### Run 1: `wrk -c100 -t1 -d10s`

| Model | Avg Latency | Stdev | Max Latency | Req/s | Transfer/s |
| :- | :- | :- | :- | :- | :- |
| 1 (ASYNC) | 52.41µs | 21.53µs | 3.77ms | 146,305 | 12.42MB |
| 2 (POOL) | 91.47µs | 31.14µs | 3.39ms | 145,289 | 12.33MB |
| 3 (MIXED) | 88.72µs | 31.30µs | 3.39ms | 144,357 | 12.25MB |

### Run 2: `wrk -c1000 -t4 -d10s`

| Model | Avg Latency | Stdev | Max Latency | Req/s | Transfer/s |
| :- | :- | :- | :- | :- | :- |
| 1 (ASYNC) | 37.71µs | 21.44µs | 3.37ms | 234,600 | 19.91MB |
| 2 (POOL) | 76.52µs | 91.95µs | 6.03ms | 245,918 | 20.87MB |
| 3 (MIXED) | 56.53µs | 34.22µs | 4.54ms | 290,201 | 24.63MB |

### Throughput Scaling (c100 to c1000)

| Model | c100 req/s | c1000 req/s | Scale |
| :- | :- | :- | :- |
| 1 (ASYNC) | 146,305 | 234,600 | 1.60x |
| 2 (POOL) | 145,289 | 245,918 | 1.69x |
| 3 (MIXED) | 144,357 | 290,201 | 2.01x |

### Analysis

At c100 all three models are throughput-equivalent (~144-146k req/s). ASYNC holds the lowest latency (52µs). POOL and MIXED are similar at ~88-91µs — the router and arena overhead narrows the latency gap vs the PoC.

At c1000, MIXED wins throughput (290k req/s, 2.01x scale). POOL stdev blows out (91.95µs > avg 76.52µs — sign of bimodal distribution from ConnQueue contention under load). ASYNC has the lowest and most stable latency at both concurrency levels.

Notable difference from PoC: MIXED now beats POOL at c1000 in the real server (290k vs 245k). In the PoC, POOL won (351k vs 312k). The real server's router and arena overhead changes the balance — MIXED's no-queue path benefits more from reduced per-request overhead than POOL's pre-warmed thread advantage.

---

## POOL: File Descriptor Budget (RLIMIT_NOFILE)

POOL mode opens file descriptors at startup before any connection arrives:

```
startup_fds ≈ pool_size + workers + io_async_limit
            = (cpu * 20) + cpu + (cpu - 1)
            = cpu * 22 - 1
```

The Linux default soft `RLIMIT_NOFILE` is 1024. With the current default formula `pool_size = cpu * 2 * 10`:

| cpu_count | pool_size | est. startup fds | safe `ulimit -n` |
| :- | :- | :- | :- |
| 4 | 80 | ~87 | 4096 |
| 8 | 160 | ~175 | 8192 |
| 16 | 320 | ~351 | 16384 |
| 32 | 640 | ~703 | 32768 |
| 48 | 960 | ~1055 | 65536 (required) |
| 64 | 1280 | ~1407 | 65536 (required) |

On machines with 48+ cores, startup fds alone exceed the default limit. The server accept loop will log `error.ProcessFdQuotaExceeded` repeatedly until the limit is raised.

Rule of thumb: `ulimit -n ≥ pool_size * 4` (covers startup fds plus concurrent connection headroom).
With current default: `ulimit -n ≥ cpu * 80`.

### Raising RLIMIT_NOFILE on Linux/Unix

**Session (temporary, current shell only):**
```sh
ulimit -n 65536
```

**Check current limits:**
```sh
ulimit -n        # soft limit
ulimit -Hn       # hard limit
cat /proc/sys/fs/file-max   # system-wide kernel fd limit
```

**Persistent per-user (PAM):**

`/etc/security/limits.conf`:
```
*    soft    nofile    65536
*    hard    nofile    65536
```
Requires re-login to take effect.

**Persistent for a systemd service:**

In the `.service` unit file:
```ini
[Service]
LimitNOFILE=65536
```

**Persistent system-wide (kernel limit):**
```sh
sysctl -w fs.file-max=2097152
```
To persist across reboots, add to `/etc/sysctl.conf`:
```
fs.file-max = 2097152
```
Then apply with `sysctl -p`.

---

###### end of NOTE-HTTP_ENGINE-APPROACH-1
