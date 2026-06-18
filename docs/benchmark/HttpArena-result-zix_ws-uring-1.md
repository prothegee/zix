## Benchmark Results

**Framework:** `zix-ws` | **Test:** `all tests`

| Test | Conn | RPS | CPU | Mem | Δ RPS | Δ Mem |
|------|------|-----|-----|-----|-------|-------|
| echo-ws | 512 | 4,374,430 | 6414.1% | 190MiB | +2.2% | +0.5% |
| echo-ws | 4096 | 4,573,522 | 6418.6% | 246MiB | +1.3% | +1.2% |
| echo-ws | 16384 | 4,375,492 | 6402.6% | 418MiB | +3.4% | +0.5% |
| echo-ws-pipeline | 512 | 61,275,410 | 6291.8% | 195MiB | +1.9% | +0.5% |
| echo-ws-pipeline | 4096 | 66,861,180 | 6148.9% | 243MiB | +2.0% | -0.4% |
| echo-ws-pipeline | 16384 | 62,291,153 | 6412.5% | 416MiB | +16.2% | -5.9% |

<details><summary>Full log</summary>

```
  Thread Stats   Avg      p50      p90      p99    p99.9
    Latency    133us    126us    192us    298us    462us

  305242838 frames sent in 5.00s, 305358583 frames received
  Throughput: 61.05M req/s
  Bandwidth:  407.40MB/s
  WS upgrades: 512
  WS frames:   305358583
  Latency samples: 305335806 / 305358583 responses (100.0%)
[info] CPU 6446.0% | Mem 196MiB

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
    Latency    134us    127us    189us    315us    466us

  303288828 frames sent in 5.00s, 303288812 frames received
  Throughput: 60.64M req/s
  Bandwidth:  404.82MB/s
  WS upgrades: 512
  WS frames:   303288812
  Latency samples: 303287782 / 303288812 responses (100.0%)
[info] CPU 6313.4% | Mem 196MiB

=== Best: 61275410 req/s (CPU: 6291.8%, Mem: 195MiB) ===
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
    Latency    974us    929us   1.18ms   1.97ms   2.67ms

  334367344 frames sent in 5.00s, 334305904 frames received
  Throughput: 66.83M req/s
  Bandwidth:  446.26MB/s
  WS upgrades: 4096
  WS frames:   334305904
  Latency samples: 334305904 / 334305904 responses (100.0%)
[info] CPU 6148.9% | Mem 243MiB

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
    Latency    986us    959us   1.14ms   2.03ms   2.59ms

  332279092 frames sent in 5.00s, 332277908 frames received
  Throughput: 66.41M req/s
  Bandwidth:  443.32MB/s
  WS upgrades: 4096
  WS frames:   332277908
  Latency samples: 332301490 / 332277908 responses (100.0%)
[info] CPU 6430.2% | Mem 247MiB

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
    Latency    984us    963us   1.14ms   2.02ms   2.41ms

  332875692 frames sent in 5.00s, 332875229 frames received
  Throughput: 66.54M req/s
  Bandwidth:  444.22MB/s
  WS upgrades: 4096
  WS frames:   332875229
  Latency samples: 332873928 / 332875229 responses (100.0%)
[info] CPU 6239.7% | Mem 247MiB

=== Best: 66861180 req/s (CPU: 6148.9%, Mem: 243MiB) ===
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
    Latency   5.38ms   4.72ms   7.72ms   8.62ms   11.70ms

  234181984 frames sent in 5.00s, 233919840 frames received
  Throughput: 46.76M req/s
  Bandwidth:  312.58MB/s
  WS upgrades: 16384
  WS frames:   233919840
  Latency samples: 233919840 / 233919840 responses (100.0%)
[info] CPU 5821.4% | Mem 441MiB

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
    Latency   4.19ms   4.04ms   4.48ms   8.31ms   10.80ms

  311713815 frames sent in 5.00s, 311455767 frames received
  Throughput: 62.27M req/s
  Bandwidth:  416.08MB/s
  WS upgrades: 16384
  WS frames:   311455767
  Latency samples: 311455767 / 311455767 responses (100.0%)
[info] CPU 6412.5% | Mem 416MiB

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
    Latency   5.29ms   4.62ms   7.88ms   8.83ms   12.00ms

  246533281 frames sent in 5.00s, 246271137 frames received
  Throughput: 49.23M req/s
  Bandwidth:  329.05MB/s
  WS upgrades: 16384
  WS frames:   246271137
  Latency samples: 246271137 / 246271137 responses (100.0%)
[info] CPU 6130.6% | Mem 449MiB

=== Best: 62291153 req/s (CPU: 6412.5%, Mem: 416MiB) ===
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
