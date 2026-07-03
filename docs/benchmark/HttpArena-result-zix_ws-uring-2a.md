## Benchmark Results

**Framework:** `zix-ws` | **Test:** `all tests`

| Test | Conn | RPS | CPU | Mem | Δ RPS | Δ Mem |
|------|------|-----|-----|-----|-------|-------|
| echo-ws | 512 | 4,182,045 | 6384.9% | 158MiB | -3.2% | -16.8% |
| echo-ws | 4096 | 4,445,718 | 6266.1% | 215MiB | -2.0% | -12.6% |
| echo-ws | 16384 | 4,266,069 | 6407.8% | 388MiB | -1.8% | -6.7% |
| echo-ws-pipeline | 512 | 59,724,259 | 6349.3% | 164MiB | -0.7% | -16.3% |
| echo-ws-pipeline | 4096 | 65,569,012 | 6421.9% | 216MiB | -0.9% | -10.4% |
| echo-ws-pipeline | 16384 | 50,446,362 | 5859.2% | 417MiB | +0.5% | -5.2% |

<details><summary>Full log</summary>

```
  Thread Stats   Avg      p50      p90      p99    p99.9
    Latency    139us    132us    205us    323us    514us

  292742792 frames sent in 5.00s, 292742776 frames received
  Throughput: 58.50M req/s
  Bandwidth:  390.53MB/s
  WS upgrades: 512
  WS frames:   292742776
  Latency samples: 292784335 / 292742776 responses (100.0%)
[info] CPU 6379.9% | Mem 165MiB

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
    Latency    136us    130us    192us    305us    466us

  298593260 frames sent in 5.00s, 298621297 frames received
  Throughput: 59.69M req/s
  Bandwidth:  398.43MB/s
  WS upgrades: 512
  WS frames:   298621297
  Latency samples: 298592124 / 298621297 responses (100.0%)
[info] CPU 6349.3% | Mem 164MiB

=== Best: 59724259 req/s (CPU: 6349.3%, Mem: 164MiB) ===
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
    Latency    996us    969us   1.18ms   2.04ms   2.57ms

  325230529 frames sent in 5.00s, 325166337 frames received
  Throughput: 65.01M req/s
  Bandwidth:  434.10MB/s
  WS upgrades: 4096
  WS frames:   325166337
  Latency samples: 325166337 / 325166337 responses (100.0%)
[info] CPU 6099.6% | Mem 212MiB

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
    Latency    999us    973us   1.18ms   2.08ms   2.43ms

  327849784 frames sent in 5.00s, 327845060 frames received
  Throughput: 65.54M req/s
  Bandwidth:  437.55MB/s
  WS upgrades: 4095
  WS frames:   327845060
  Latency samples: 327843812 / 327845060 responses (100.0%)
[info] CPU 6421.9% | Mem 216MiB

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
    Latency   1.00ms    977us   1.16ms   2.07ms   2.48ms

  327590252 frames sent in 5.00s, 327587164 frames received
  Throughput: 65.48M req/s
  Bandwidth:  437.14MB/s
  WS upgrades: 4096
  WS frames:   327587164
  Latency samples: 327586396 / 327587164 responses (100.0%)
[info] CPU 6271.7% | Mem 216MiB

=== Best: 65569012 req/s (CPU: 6421.9%, Mem: 216MiB) ===
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
    Latency   5.01ms   4.42ms   7.71ms   8.74ms   11.80ms

  252493734 frames sent in 5.00s, 252231814 frames received
  Throughput: 50.42M req/s
  Bandwidth:  337.02MB/s
  WS upgrades: 16384
  WS frames:   252231814
  Latency samples: 252231814 / 252231814 responses (100.0%)
[info] CPU 5859.2% | Mem 417MiB

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
    Latency   5.42ms   4.77ms   7.88ms   9.23ms   11.90ms

  240778694 frames sent in 5.00s, 240516550 frames received
  Throughput: 48.08M req/s
  Bandwidth:  321.35MB/s
  WS upgrades: 16384
  WS frames:   240516550
  Latency samples: 240516550 / 240516550 responses (100.0%)
[info] CPU 6403.9% | Mem 420MiB

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
    Latency   5.55ms   5.06ms   7.85ms   8.56ms   11.80ms

  235090520 frames sent in 5.00s, 234832472 frames received
  Throughput: 46.94M req/s
  Bandwidth:  313.79MB/s
  WS upgrades: 16384
  WS frames:   234832472
  Latency samples: 234832472 / 234832472 responses (100.0%)
[info] CPU 6151.6% | Mem 422MiB

=== Best: 50446362 req/s (CPU: 5859.2%, Mem: 417MiB) ===
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
