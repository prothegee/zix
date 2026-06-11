# gRPC Benchmark Results: origin-0.2.x

See `grpc_stream_bug.md` for full root cause analysis.

---

## Post-fix benchmark (debug build, 2026-06-06)

After applying Phase 1 performance fix: `Route.is_server_streaming = false` (default) triggers
synchronous dispatch on the connection thread (no Task alloc, no 4KB header copy, no mutex per call).
Stream slot init replaced from `std.mem.zeroes(Stream)` (zeroes 72KB) to explicit field init.

| Test | Tool | Connections | req/s | vs pre-fix | Errors |
| :- | :- | :- | :- | :- | :- |
| 1 | h2load | 256c | 110,923 | +304% | 0 |
| 2 | h2load | 512c | 105,338 | +284% | 0 |
| 3 | h2load | 1024c | 106,435 | +276% | 0 |
| 4 | ghz | 64c | ~33,000 | +74% | 13 teardown |

All handlers in these tests are unary (`is_server_streaming = false` default).
Target for ReleaseFast HttpArena run: >= 85k req/s at 256c (0.2.0 baseline was 87k).

---

## Pre-fix benchmark (debug build + perf, 2026-06-06)

Benchmarks run against `origin-0.2.x` after the second-pass fixes
(HPACK dyn_buf + io.async dispatch) but before the Phase 1 performance fix.

---

## Local benchmark (debug build + perf)

### Setup

- Server 1 (h2load): `example-grpc_server_4_epoll` (port 8083, helloworld unary)
- Server 2 (ghz): `example-grpc_location_server_4_epoll` (port 10101, location unary)
- Duration: 10s for all tests
- Build: debug (no -Doptimize)
- Profiling: `perf record -F 99` on each server process

Note: h2load does not validate protobuf bodies, it measures raw HTTP/2 throughput.
The `example-grpc_server_4_epoll` handler returns a raw string, not valid protobuf,
so only h2load (not ghz) was used against it. The location server returns valid protobuf.

### Results

| Test | Tool | Connections | req/s | Errors |
| :- | :- | :- | :- | :- |
| 1 | h2load | 512c | 27,400 | 0 |
| 2 | h2load | 1024c | 28,283 | 0 |
| 3 | ghz | 64c | 18,987 | ~0.03% (59 on teardown) |

Test 3 detail: 189,812 OK / 189,871 total. 59 Unavailable/Canceled = connection
teardown noise from SIGINT. p50: 3.18ms. p99: 5.34ms.

### perf data files

| File | Test |
| :- | :- |
| `grpc_server_4_epoll_h2load_c512.perf.data` | Test 1 |
| `grpc_server_4_epoll_h2load_c1024.perf.data` | Test 2 |
| `grpc_location_server_4_epoll_ghz_c64.perf.data` | Test 3 |

### perf analysis

Samples are from a debug build. Absolute overhead percentages are inflated vs
ReleaseFast (no SIMD, no inlining, bounds checks, Dwarf stack unwinding active).
The RANKING of hot spots is directionally correct and maps to real costs in
production builds.

| Symbol | c512 | c1024 | ghz c64 | Notes |
| :- | :- | :- | :- | :- |
| `mem.zeroes` (Stream slot) | 28.44% | 29.39% | 33.54% | `stream.* = std.mem.zeroes(Stream)`: resets the 4KB `header_scratch` on every slot reuse |
| `huffDecode` | 19.13% | 19.06% | n/a | HPACK Huffman decode on every request headers frame |
| `mem.zeroes` (DispatchTask) | 12.87% | 12.03% | 9.77% | `task.header_scratch = s.header_scratch` deep copy, 4KB copy added in 0.2.x that 0.2.0 never had |
| `serveGrpcLoop` | 3.80% | 4.70% | 2.94% | Frame read and dispatch loop |
| `ConnMutex.lock` | 2.57% | 1.56% | **13.79%** | Spinlock per write. Jumps sharply with real protobuf I/O (ghz). For stream-grpc at count=5000 this becomes dominant |
| `spawnGrpcStream` | 1.07% | 0.80% | 0.72% | Task alloc + io.async enqueue |
| Dwarf unwinding | ~4.4% | ~4.4% | ~2.7% | Debug-only: `SelfUnwinder`, `dwarfRegisterBytes`, `applyOffset`. Absent in ReleaseFast |

Key findings:

- `mem.zeroes` (Stream + Task) accounts for ~41% of all cycles. The Stream zeroing
  clears `header_scratch[4096]` on every slot reuse. The Task zeroing is the 4KB
  copy that `spawnGrpcStream` adds in 0.2.x, 0.2.0 dispatched synchronously and
  never copied the scratch buffer.

- `ConnMutex.lock` at 13.79% (ghz) vs 1.56-2.57% (h2load unary) shows the mutex
  cost scales with actual write I/O per request. For stream-grpc (count=5000, 5000
  `sendMessage` calls per stream at 64c), this is the dominant bottleneck.

- `huffDecode` at ~19% is consistent across all unary runs. In ReleaseFast with
  SIMD this drops significantly but remains a real hot path.

- `ConnMutex.lock` drop from 2.57% (c512) to 1.56% (c1024) at higher concurrency:
  the connection thread spends proportionally more time in `serveGrpcLoop` managing
  more connections, diluting the mutex sample share, not an improvement.

---

## HttpArena benchmark (ReleaseFast, containerised)

### Setup

- Framework: `frameworks/zix-grpc` from `../HttpArena`
- Command: `./scripts/benchmark.sh zix-grpc`
- Build: `--release=fast`, target `x86_64-linux-musl`, inside Docker (host network)
- zix source: pulled from `github.com/prothegee/zix` `0.2.x` branch at run time
- Profiles: `unary-grpc` (h2load, 256c + 1024c, 5s × 3 runs) and `stream-grpc` (ghz, 64c, 5s × 3 runs)
- Handlers: `GetSum` (unary, add two i32s), `StreamSum` (server-streaming, send count=5000 replies)

### Results: unary-grpc

| Connections | Run | req/s | Failed | p50 | p99 |
| :- | :- | :- | :- | :- | :- |
| 256c | 1 | 40,599 | 4,260 (2.1%) | 58ms | 92ms |
| 256c | 2 | 40,788 | 4,828 (2.3%) | 58ms | 99ms |
| 256c | 3 | 41,551 | 5,705 (2.7%) | 56ms | 96ms |
| 256c | **best** | **41,221** | | | |
| 1024c | 1 | 41,955 | 9,160 (4.2%) | 56ms | 94ms |
| 1024c | 2 | 41,991 | 8,095 (3.7%) | 56ms | 95ms |
| 1024c | 3 | 41,508 | 6,845 (3.2%) | 56ms | 95ms |
| 1024c | **best** | **41,213** | | | |

Failures are h2load 5s per-request timeouts, requests queueing too long under
high concurrency. TTFB p95/p99 hits 5s at 1024c. 0.2.0 baseline was ~87k req/s
at 0% error rate.

### Results: stream-grpc

ghz sends `count=5000` per call. The script reports
`rps = ok_count × 5000 / duration` (normalised messages/sec).

| Run | Completions (OK) | Canceled | Unavailable | msg/s |
| :- | :- | :- | :- | :- |
| 1 | 695 | 242 | 11 | ~695,000 |
| 2 | 581 | 232 | 23 | ~581,000 |
| 3 | 550 | 246 | 0 | ~550,000 |
| **best** | | | | **~695,000** |

Canceled = in-flight streams cut by the 5s window. Not real failures. Unavailable
= connection teardown on test end. p50 latency: 557ms per stream call (each call
sends 5000 DATA frames under ConnMutex contention at 64c).

### Regression summary vs 0.2.0

| Metric | 0.2.0 | 0.2.x (current) | Gap |
| :- | :- | :- | :- |
| Unary 256c req/s | ~87k | ~41k | ~2x regression |
| Unary 1024c errors | 0% | 3-4% | new failures |
| Streaming msg/s | unknown | ~695k | no baseline |

Root cause of unary regression: `spawnGrpcStream` adds a 4KB `header_scratch`
copy + Task heap alloc + io.async enqueue + ConnMutex acquire/release per request.
0.2.0 dispatched synchronously with none of these costs.
