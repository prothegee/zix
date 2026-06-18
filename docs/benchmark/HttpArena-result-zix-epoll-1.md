## Benchmark Results

**Framework:** `zix` | **Test:** `all tests`

| Test | Conn | RPS | CPU | Mem | Δ RPS | Δ Mem |
|------|------|-----|-----|-----|-------|-------|
| baseline | 512 | 3,705,081 | 6463.8% | 342MiB | +0.9% | ~0% |
| baseline | 4096 | 3,729,529 | 6609.9% | 395MiB | +2.0% | ~0% |
| pipelined | 512 | 49,978,406 | 6479.7% | 341MiB | +0.9% | ~0% |
| pipelined | 4096 | 50,275,436 | 6568.3% | 396MiB | +1.5% | ~0% |
| limited-conn | 512 | 2,576,612 | 5753.9% | 485MiB | +1.6% | +0.6% |
| limited-conn | 4096 | 2,778,183 | 6215.1% | 1.5GiB | +1.1% | ~0% |
| json | 4096 | 2,419,331 | 6228.2% | 1.3GiB | +1.0% | +8.3% |
| upload | 32 | 8,411 | 1063.2% | 341MiB | +0.3% | +1.2% |
| upload | 256 | 6,531 | 914.4% | 367MiB | -2.5% | -3.4% |
| static | 1024 | 2,037,278 | 5586.6% | 354MiB | ~0% | +0.9% |
| static | 4096 | 2,048,629 | 5608.1% | 415MiB | +0.6% | -0.5% |
| static | 6800 | 1,994,802 | 5381.4% | 500MiB | +0.5% | +0.8% |

<details><summary>Full log</summary>

```

[run 3/3]
gcannon v0.5.3
  Target:    localhost:8080/
  Threads:   64
  Conns:     256 (4/thread)
  Pipeline:  1
  Req/conn:  5
  Templates: 4
  Expected:  200
  Duration:  5s


  Thread Stats   Avg      p50      p90      p99    p99.9
    Latency   39.01ms   39.50ms   43.00ms   45.30ms   47.00ms

  32565 requests in 5.02s, 32571 responses
  Throughput: 6.49K req/s
  Bandwidth:  451.24KB/s
  Status codes: 2xx=32571, 3xx=0, 4xx=0, 5xx=0
  Latency samples: 32571 / 32571 responses (100.0%)
  Reconnects: 6536
  Per-template: 8141,8142,8144,8144
  Per-template-ok: 8141,8142,8144,8144
[info] CPU 882.1% | Mem 380MiB

=== Best: 6531 req/s (CPU: 914.4%, Mem: 367MiB) ===
[info] input BW: 51.80GB/s (avg template: 8516680 bytes)
[info] saved results/upload/256/zix.json
httparena-bench-zix
httparena-bench-zix
[info] skip: zix does not subscribe to api-4
[info] skip: zix does not subscribe to api-16

==============================================
=== zix / static / 1024c (tool=wrk) ===
==============================================
[info] waiting for server...
[info] server ready

[run 1/3]
Running 5s test @ http://localhost:8080
  64 threads and 1024 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   373.16us    1.15ms  32.74ms   99.41%
    Req/Sec    31.98k     1.21k   39.86k    97.12%
  10386513 requests in 5.10s, 158.23GB read
Requests/sec: 2036400.28
Transfer/sec:     31.02GB
[info] CPU 5538.9% | Mem 347MiB

[run 2/3]
Running 5s test @ http://localhost:8080
  64 threads and 1024 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   301.15us  114.66us   4.16ms   71.60%
    Req/Sec    31.91k   666.05    38.77k    97.70%
  10363968 requests in 5.10s, 157.88GB read
Requests/sec: 2031954.56
Transfer/sec:     30.95GB
[info] CPU 5591.1% | Mem 351MiB

[run 3/3]
Running 5s test @ http://localhost:8080
  64 threads and 1024 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   301.97us  114.43us   3.63ms   70.25%
    Req/Sec    32.00k   572.85    37.82k    96.75%
  10390970 requests in 5.10s, 158.29GB read
Requests/sec: 2037278.12
Transfer/sec:     31.04GB
[info] CPU 5586.6% | Mem 354MiB

=== Best: 2037278 req/s (CPU: 5586.6%, Mem: 354MiB) ===
[info] saved results/static/1024/zix.json
httparena-bench-zix
httparena-bench-zix

==============================================
=== zix / static / 4096c (tool=wrk) ===
==============================================
[info] waiting for server...
[info] server ready

[run 1/3]
Running 5s test @ http://localhost:8080
  64 threads and 4096 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.13ms    0.95ms  40.55ms   98.08%
    Req/Sec    31.18k     1.56k   41.83k    96.44%
  10113387 requests in 5.10s, 154.06GB read
Requests/sec: 1982697.11
Transfer/sec:     30.20GB
[info] CPU 5397.3% | Mem 401MiB

[run 2/3]
Running 5s test @ http://localhost:8080
  64 threads and 4096 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.06ms  284.65us   9.96ms   90.17%
    Req/Sec    32.21k     1.07k   46.76k    96.87%
  10448044 requests in 5.10s, 159.16GB read
Requests/sec: 2048629.65
Transfer/sec:     31.21GB
[info] CPU 5608.1% | Mem 415MiB

[run 3/3]
Running 5s test @ http://localhost:8080
  64 threads and 4096 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.05ms  254.21us   5.14ms   92.20%
    Req/Sec    32.00k     0.96k   46.03k    95.64%
  10367607 requests in 5.10s, 157.94GB read
Requests/sec: 2033263.59
Transfer/sec:     30.97GB
[info] CPU 5505.7% | Mem 433MiB

=== Best: 2048629 req/s (CPU: 5608.1%, Mem: 415MiB) ===
[info] saved results/static/4096/zix.json
httparena-bench-zix
httparena-bench-zix

==============================================
=== zix / static / 6800c (tool=wrk) ===
==============================================
[info] waiting for server...
[info] server ready

[run 1/3]
Running 5s test @ http://localhost:8080
  64 threads and 6800 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.80ms    0.95ms  44.38ms   94.91%
    Req/Sec    31.19k   713.15    43.69k    96.11%
  10086446 requests in 5.10s, 153.65GB read
Requests/sec: 1977539.47
Transfer/sec:     30.13GB
[info] CPU 5280.6% | Mem 447MiB

[run 2/3]
Running 5s test @ http://localhost:8080
  64 threads and 6800 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.77ms  415.76us   7.67ms   92.59%
    Req/Sec    31.29k     1.07k   45.58k    97.07%
  10122662 requests in 5.10s, 154.21GB read
Requests/sec: 1985362.39
Transfer/sec:     30.24GB
[info] CPU 5398.7% | Mem 475MiB

[run 3/3]
Running 5s test @ http://localhost:8080
  64 threads and 6800 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.74ms  354.21us   5.15ms   94.31%
    Req/Sec    31.46k     0.97k   46.76k    97.25%
  10175355 requests in 5.10s, 155.01GB read
Requests/sec: 1994802.32
Transfer/sec:     30.39GB
[info] CPU 5381.4% | Mem 500MiB

=== Best: 1994802 req/s (CPU: 5381.4%, Mem: 500MiB) ===
[info] saved results/static/6800/zix.json
httparena-bench-zix
httparena-bench-zix
[info] skip: zix does not subscribe to async-db
[info] skip: zix does not subscribe to crud
[info] skip: zix does not subscribe to fortunes
[info] skip: zix does not subscribe to baseline-h2
[info] skip: zix does not subscribe to static-h2
[info] skip: zix does not subscribe to baseline-h2c
[info] skip: zix does not subscribe to json-h2c
[info] skip: zix does not subscribe to baseline-h3
[info] skip: zix does not subscribe to static-h3
[info] skip: zix does not subscribe to gateway-64
[info] skip: zix does not subscribe to gateway-h3
[info] skip: zix does not subscribe to production-stack
[info] skip: zix does not subscribe to unary-grpc
[info] skip: zix does not subscribe to unary-grpc-tls
[info] skip: zix does not subscribe to stream-grpc
[info] skip: zix does not subscribe to stream-grpc-tls
[info] skip: zix does not subscribe to echo-ws
[info] skip: zix does not subscribe to echo-ws-pipeline
[info] rebuilding site/data/*.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/frameworks.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/baseline-4096.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/baseline-512.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/json-4096.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/limited-conn-4096.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/limited-conn-512.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/pipelined-4096.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/pipelined-512.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/static-1024.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/static-4096.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/static-6800.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/upload-256.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/upload-32.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/current.json
[info] done
[info] restoring loopback MTU to 65536
```
</details>
