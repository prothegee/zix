# Concurrency Models -- zix

Two threading models are available for all server protocols (TCP, UDP, UDS, Channel).
Both are PoC-verified on TCP/HTTP. Choose based on workload shape.

---

## Model 1 -- Single Accept, Per-Connection Dispatch

One main thread binds the socket and calls `accept()` / `receive()` in a loop. Each accepted
connection or packet is dispatched to a worker via `io.concurrent()` (or `std.Thread.spawn`).

```
Main thread:
  bind → listen / bind → receive
  loop:
    conn/pkt = accept() / receive()
    io.concurrent(handler, conn/pkt)    ← yields to OS event loop; no busy-wait

Handler tasks (one per active connection/packet):
  process to completion
  task exits when connection closes or packet is handled
```

**When to use:**
- Default for most workloads.
- Connection or packet arrival rate is not the bottleneck.
- Simplest code path.

**Reference PoC:** `rnd/server_model_1.zig` — raw `std.Thread.spawn` per connection (no io.concurrent).

**Current src/ implementation:** `src/tcp/http/server.zig` uses `io.concurrent()` — same single-accept pattern.

**Benchmark** (wrk, 100 connections, 2 threads, 10 s, HTTP): ~254,072 req/s

---

## Model 2 -- Multiple Workers, Each With Own Accept Loop

N worker threads are pre-spawned. Each worker independently binds to the same address using
`SO_REUSEPORT`. Each worker runs its own accept/receive loop and submits handlers to a shared
`io.concurrent()` pool.

```
Main thread:
  create shared std.Io.Threaded backend
  spawn N worker threads
  join (wait for all workers)

Worker threads (N workers, each independent):
  bind/listen with SO_REUSEPORT
  loop:
    conn/pkt = accept() / receive()
    threaded.io().concurrent(handler, conn/pkt)

Shared io.concurrent pool:
  bounded by .concurrent_limit
  handlers from all workers run on any available pool thread
```

**When to use:**
- Accept/receive rate is the bottleneck (very high connection volume, short-lived connections).
- Distribute accept load across all CPU cores.
- `WORKERS = 0` auto-detects CPU count (`std.Thread.getCpuCount()`).

**OS requirement:** `SO_REUSEPORT` -- Linux ≥ 3.9, macOS, BSD.

**Reference PoC:** `rnd/server_model_2.zig`

**Benchmark** (wrk, 100 connections, 2 threads, 10 s, HTTP): ~248,160 req/s
(Throughput is similar to Model 1; the advantage appears in latency distribution under extreme load.)

---

## Protocol Applicability

| Protocol | Model 1 | Model 2 |
| :- | :- | :- |
| TCP (HTTP) | yes -- current src/ | yes -- via server_model_2 pattern |
| UDP | yes -- current src/ | yes -- SO_REUSEPORT on UDP socket |
| UDS | yes -- planned | yes -- planned (SO_REUSEPORT on UDS, Linux only) |
| Channel | n/a -- in-process | n/a -- in-process |

---

## Concurrency Limit (Model 1 and Model 2)

Both models use `std.Io.Threaded` for the handler pool. The caller sets the cap:

```zig
// unlimited (runtime auto from CPU count)
var threaded = std.Io.Threaded.init(allocator, .{});

// explicit cap
var threaded = std.Io.Threaded.init(allocator, .{
    .concurrent_limit = std.Io.Limit.limited(4),
});
```

See `examples/http_manual_concurrent.zig` for explicit limit usage.

---

###### end of concurrency
