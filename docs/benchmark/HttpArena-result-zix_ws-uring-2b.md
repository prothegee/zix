## Benchmark Results

**Framework:** `zix-ws` | **Test:** `all tests`

| Test | Conn | RPS | CPU | Mem | Δ RPS | Δ Mem |
|------|------|-----|-----|-----|-------|-------|
| echo-ws | 512 | 4,357,290 | 6414.3% | 158MiB | +0.8% | -16.8% |
| echo-ws | 4096 | 4,494,247 | 6421.4% | 214MiB | -0.9% | -13.0% |
| echo-ws | 16384 | 4,330,765 | 6398.5% | 391MiB | -0.3% | -6.0% |
| echo-ws-pipeline | 512 | 60,806,628 | 6342.2% | 163MiB | +1.1% | -16.8% |
| echo-ws-pipeline | 4096 | 66,085,776 | 6416.8% | 216MiB | -0.1% | -10.4% |
| echo-ws-pipeline | 16384 | 47,531,733 | 6154.1% | 425MiB | -5.3% | -3.4% |

<details><summary>Full log</summary>

```
  Thread Stats   Avg      p50      p90      p99    p99.9
    Latency    137us    128us    206us    334us    587us

  295659938 frames sent in 5.00s, 295659906 frames received
  Throughput: 59.11M req/s
  Bandwidth:  394.62MB/s
  WS upgrades: 512
  WS frames:   295659906
  Latency samples: 295755378 / 295659906 responses (100.0%)
[info] CPU 6396.6% | Mem 165MiB

[run 3/3]
gcannon v0.5.3 [WS]
  Target:    localhost:8080/ws
  Threads:   64
  Conns:     512 (8/thread)
  Pipeline:  16
  Req/conn:  unlimited (keep-alive)
  Expected:  200
  Duration:  5s


  Thread Stats   Avg      p50      p90      p99    p99.9
    Latency    137us    129us    199us    337us    495us

  297212508 frames sent in 5.00s, 297212491 frames received
  Throughput: 59.42M req/s
  Bandwidth:  396.68MB/s
  WS upgrades: 512
  WS frames:   297212491
  Latency samples: 297211182 / 297212491 responses (100.0%)
[info] CPU 6293.1% | Mem 166MiB

=== Best: 60806628 req/s (CPU: 6342.2%, Mem: 163MiB) ===
[info] saved results/echo-ws-pipeline/512/zix-ws.json
httparena-bench-zix-ws
httparena-bench-zix-ws

==============================================
=== zix-ws / echo-ws-pipeline / 4096c (tool=gcannon) ===
==============================================
[info] ws-only framework — skipping HTTP probe (sleep 2s for startup)

[run 1/3]
gcannon v0.5.3 [WS]
  Target:    localhost:8080/ws
  Threads:   64
  Conns:     4096 (64/thread)
  Pipeline:  16
  Req/conn:  unlimited (keep-alive)
  Expected:  200
  Duration:  5s


  Thread Stats   Avg      p50      p90      p99    p99.9
    Latency    992us    962us   1.15ms   2.02ms   3.29ms

  325442126 frames sent in 5.00s, 325379662 frames received
  Throughput: 65.05M req/s
  Bandwidth:  434.36MB/s
  WS upgrades: 4096
  WS frames:   325379662
  Latency samples: 325379662 / 325379662 responses (100.0%)
[info] CPU 6075.8% | Mem 214MiB

[run 2/3]
gcannon v0.5.3 [WS]
  Target:    localhost:8080/ws
  Threads:   64
  Conns:     4096 (64/thread)
  Pipeline:  16
  Req/conn:  unlimited (keep-alive)
  Expected:  200
  Duration:  5s


  Thread Stats   Avg      p50      p90      p99    p99.9
    Latency    991us    963us   1.17ms   2.03ms   2.52ms

  330421693 frames sent in 5.00s, 330428882 frames received
  Throughput: 66.06M req/s
  Bandwidth:  440.96MB/s
  WS upgrades: 4096
  WS frames:   330428882
  Latency samples: 330443057 / 330428882 responses (100.0%)
[info] CPU 6416.8% | Mem 216MiB

[run 3/3]
gcannon v0.5.3 [WS]
  Target:    localhost:8080/ws
  Threads:   64
  Conns:     4096 (64/thread)
  Pipeline:  16
  Req/conn:  unlimited (keep-alive)
  Expected:  200
  Duration:  5s


  Thread Stats   Avg      p50      p90      p99    p99.9
    Latency    993us    959us   1.14ms   2.02ms   2.40ms

  329651984 frames sent in 5.00s, 329648752 frames received
  Throughput: 65.90M req/s
  Bandwidth:  439.92MB/s
  WS upgrades: 4096
  WS frames:   329648752
  Latency samples: 329647960 / 329648752 responses (100.0%)
[info] CPU 6255.1% | Mem 216MiB

=== Best: 66085776 req/s (CPU: 6416.8%, Mem: 216MiB) ===
[info] saved results/echo-ws-pipeline/4096/zix-ws.json
httparena-bench-zix-ws
httparena-bench-zix-ws

==============================================
=== zix-ws / echo-ws-pipeline / 16384c (tool=gcannon) ===
==============================================
[info] ws-only framework — skipping HTTP probe (sleep 2s for startup)

[run 1/3]
gcannon v0.5.3 [WS]
  Target:    localhost:8080/ws
  Threads:   64
  Conns:     16384 (256/thread)
  Pipeline:  16
  Req/conn:  unlimited (keep-alive)
  Expected:  200
  Duration:  5s


  Thread Stats   Avg      p50      p90      p99    p99.9
    Latency   5.53ms   4.80ms   7.99ms   8.81ms   12.10ms

  222059372 frames sent in 5.00s, 221797228 frames received
  Throughput: 44.34M req/s
  Bandwidth:  296.40MB/s
  WS upgrades: 16384
  WS frames:   221797228
  Latency samples: 221797228 / 221797228 responses (100.0%)
[info] CPU 5581.4% | Mem 420MiB

[run 2/3]
gcannon v0.5.3 [WS]
  Target:    localhost:8080/ws
  Threads:   64
  Conns:     16384 (256/thread)
  Pipeline:  16
  Req/conn:  unlimited (keep-alive)
  Expected:  200
  Duration:  5s


  Thread Stats   Avg      p50      p90      p99    p99.9
    Latency   5.75ms   4.92ms   8.14ms   9.75ms   12.40ms

  226890676 frames sent in 5.00s, 226628532 frames received
  Throughput: 45.31M req/s
  Bandwidth:  302.88MB/s
  WS upgrades: 16384
  WS frames:   226628532
  Latency samples: 226628532 / 226628532 responses (100.0%)
[info] CPU 6401.2% | Mem 426MiB

[run 3/3]
gcannon v0.5.3 [WS]
  Target:    localhost:8080/ws
  Threads:   64
  Conns:     16384 (256/thread)
  Pipeline:  16
  Req/conn:  unlimited (keep-alive)
  Expected:  200
  Duration:  5s


  Thread Stats   Avg      p50      p90      p99    p99.9
    Latency   5.48ms   4.75ms   8.01ms   8.65ms   12.00ms

  237920813 frames sent in 5.00s, 237658669 frames received
  Throughput: 47.51M req/s
  Bandwidth:  317.56MB/s
  WS upgrades: 16384
  WS frames:   237658669
  Latency samples: 237658669 / 237658669 responses (100.0%)
[info] CPU 6154.1% | Mem 425MiB

=== Best: 47531733 req/s (CPU: 6154.1%, Mem: 425MiB) ===
[info] saved results/echo-ws-pipeline/16384/zix-ws.json
httparena-bench-zix-ws
httparena-bench-zix-ws
[info] rebuilding site/data/*.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/frameworks.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/echo-ws-16384.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/echo-ws-4096.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/echo-ws-512.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/echo-ws-pipeline-16384.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/echo-ws-pipeline-4096.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/echo-ws-pipeline-512.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/current.json
[info] done
[info] restoring loopback MTU to 65536
```
</details>
