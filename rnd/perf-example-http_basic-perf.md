# Perf: example-http_basic

Build: `zig build -Doptimize=ReleaseFast`
Binary: `zig-out/bin/example-http_basic`
Server config: 2 accept threads, 24 pool threads (auto on this machine)

---

## Post-engine wrk (zero-copy parser + raw posix fd writes)

Run after replacing `std.http.Server` + `std.Io.Writer` with the custom engine.

```
wrk -c100 -t1 -d10s http://127.0.0.1:9000/
```

```
Running 10s test @ http://127.0.0.1:9000/
  1 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    87.63us   27.33us   3.48ms   84.09%
    Req/Sec   148.32k     4.41k  154.73k    74.00%
  1475586 requests in 10.01s, 125.24MB read
Requests/sec: 147442.72
Transfer/sec:     12.51MB
```

Result: parity with baseline (within noise). Targets 1 and 2 from the priority table are implemented. The bottleneck at this load (100 c) is kernel TCP / syscall wait (60%+ of samples), not the HTTP machinery. Targets 1 and 2 have been neutralised: the remaining userspace overhead is in the pool thread and accept path.

---

## Baseline wrk (before engine work)

Baseline profiling run before custom HttpEngine / parser work.

---

## wrk

```
wrk -c100 -t1 -d10s http://127.0.0.1:9000/
```

```
Running 10s test @ http://127.0.0.1:9000/
  1 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    87.93us   28.50us   3.53ms   84.09%
    Req/Sec   147.87k     4.31k  155.83k    68.00%
  1471691 requests in 10.01s, 124.91MB read
Requests/sec: 147002.56
Transfer/sec:     12.48MB
```

---

## perf stat

```
perf stat -p <pid> -- sleep 10  (during wrk load)
```

```
                 0      context-switches:u
                 0      cpu-migrations:u
                 2      page-faults:u
         20,405.30 msec task-clock:u               #    2.0 CPUs utilized
        15,616,459      branch-misses:u             #    2.5 % branch miss rate     (49.69%)
       621,663,027      branches:u                  #   30.5 M/sec                  (49.10%)
     3,005,991,754      cpu-cycles:u                #    0.1 GHz                    (65.98%)
     2,823,611,469      instructions:u              #    0.9 insn per cycle          (50.31%)
     1,676,845,152      stalled-cycles-frontend:u   #   57% frontend cycles idle    (50.90%)
```

Notable: 57% frontend stall (instruction fetch / branch prediction). Not compute-bound — the bottleneck is latency (syscall wait, branch misprediction on header parsing paths).

---

## perf record (user-space symbols, flat self-time)

```
perf record -F 99 -p <pid> -g --call-graph dwarf
```

User-space symbols only (kernel addresses omitted):

| Self% | Symbol |
| :- | :- |
| 5.67% | `tcp.http.server.HttpServerImpl(4096).handleConnection` |
| 4.96% | `compiler_rt.memcpy.memcpyFast` |
| 3.22% | `Io.Threaded.netWritePosix` |
| 2.76% | `tcp.http.response.Response.send` |
| 1.26% | `Io.Writer.alignBufferOptions` |
| 0.93% | `Io.net.Stream.Writer.drain` |
| 0.57% | `Io.Writer.defaultFlush` |
| 0.47% | `mem.findScalarPos` |
| 0.29% | `mem.eql` |
| 0.07% | `http_basic.homeHandler` |
| 0.00% | `tcp.http.server.updateDateCache` |
| 0.00% | `heap.ArenaAllocator.reset` |
| 0.00% | `Io.Threaded.netReadPosix` |

Kernel calls account for ~60%+ of all samples (not shown above). Read/write syscalls are where the process actually waits.

---

## Analysis

### What is hot

**`handleConnection` (5.67%) + `memcpy` (4.96%):** Both driven by `std.http.Server`. The parser copies header data into its own representation on each request. A zero-copy custom parser (offset-based, no copies) eliminates both.

**`std.Io.Writer` chain (~6% combined):** `netWritePosix` + `alignBufferOptions` + `Writer.drain` + `defaultFlush` is the `std.Io.Writer` buffering abstraction. Raw `posix.write` / `writev` cuts this to zero.

**`mem.findScalarPos` (0.47%):** Byte scanning for header terminators inside `std.http.Server`. A custom parser owning the scan loop is faster and avoids repeated passes.

**`homeHandler` (0.07%):** Application code is essentially free. All overhead is in the HTTP machinery, not the handler.

### What is NOT hot

**`std.fmt`:** Not visible in the profile. In ReleaseFast the format string dispatch is comptime-resolved. The previous optimization batch (Tiers 1-3, `optimize_http_note.md`) already removed `std.fmt` from the true hot path. Not a target.

**`ArenaAllocator.reset` (0.00%):** Arena reset is free at this scale.

**`updateDateCache` (0.00%):** Atomic date cache is working as intended.

### Priority order for HttpEngine

| Priority | Target | Expected gain |
| :- | :- | :- |
| 1 | Custom parser (replaces `std.http.Server`) | Eliminates `handleConnection` 5.67% + `memcpy` 4.96% |
| 2 | Raw `posix.write` / `writev` (replaces `std.Io.Writer`) | Eliminates Writer chain ~6% combined |
| 3 | Reduce syscall count (larger reads, `writev` header+body) | Reduces kernel time share |

---

###### end of perf-example-http_basic-perf
