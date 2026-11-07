## Benchmark Results

**Framework:** `zix` | **Test:** `all tests`

| Test | Conn | RPS | CPU | Mem | Δ RPS | Δ Mem |
|------|------|-----|-----|-----|-------|-------|
| baseline | 512 | 4,187,491 | 6366.9% | 134MiB | +14.1% | -60.8% |
| baseline | 4096 | 4,425,576 | 6420.2% | 185MiB | +21.1% | -53.2% |
| pipelined | 512 | 53,432,531 | 6391.4% | 134MiB | +7.9% | -60.7% |
| pipelined | 4096 | 55,410,400 | 6453.2% | 186MiB | +11.8% | -53.0% |
| limited-conn | 512 | 2,719,256 | 5443.3% | 152MiB | +7.3% | -68.5% |
| limited-conn | 4096 | 2,735,230 | 5793.4% | 231MiB | -0.5% | -85.0% |
| json | 4096 | 2,361,377 | 5453.5% | 289MiB | -1.5% | -76.5% |
| upload | 32 | 8,251 | 1086.1% | 123MiB | -1.7% | -63.5% |
| upload | 256 | 6,657 | 941.2% | 130MiB | -0.7% | -65.8% |
| static | 1024 | 2,018,663 | 5521.1% | 142MiB | -0.8% | -59.5% |
| static | 4096 | 2,022,455 | 5491.0% | 191MiB | -0.7% | -54.2% |
| static | 6800 | 1,982,961 | 5265.5% | 245MiB | ~0% | -50.6% |

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
    Latency   38.90ms   39.20ms   43.10ms   46.20ms   48.20ms

  32714 requests in 5.02s, 32718 responses
  Throughput: 6.51K req/s
  Bandwidth:  453.21KB/s
  Status codes: 2xx=32718, 3xx=0, 4xx=0, 5xx=0
  Latency samples: 32718 / 32718 responses (100.0%)
  Reconnects: 6547
  Per-template: 8177,8181,8181,8179
  Per-template-ok: 8177,8181,8181,8179
[info] CPU 898.2% | Mem 131MiB

=== Best: 6657 req/s (CPU: 941.2%, Mem: 130MiB) ===
[info] input BW: 52.80GB/s (avg template: 8516680 bytes)
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
    Latency   370.83us    1.19ms  51.76ms   99.46%
    Req/Sec    31.43k     1.05k   40.16k    97.18%
  10204415 requests in 5.10s, 155.45GB read
Requests/sec: 2000754.66
Transfer/sec:     30.48GB
[info] CPU 5385.8% | Mem 140MiB

[run 2/3]
Running 5s test @ http://localhost:8080
  64 threads and 1024 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   299.88us  113.83us   8.37ms   73.45%
    Req/Sec    31.70k   659.88    39.66k    97.70%
  10296168 requests in 5.10s, 156.85GB read
Requests/sec: 2018663.71
Transfer/sec:     30.75GB
[info] CPU 5521.1% | Mem 142MiB

[run 3/3]
Running 5s test @ http://localhost:8080
  64 threads and 1024 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   301.27us  111.14us   3.67ms   71.28%
    Req/Sec    31.67k   606.14    39.87k    97.43%
  10284850 requests in 5.10s, 156.68GB read
Requests/sec: 2016515.47
Transfer/sec:     30.72GB
[info] CPU 5475.4% | Mem 141MiB

=== Best: 2018663 req/s (CPU: 5521.1%, Mem: 142MiB) ===
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
    Latency     1.13ms    1.02ms  51.39ms   99.16%
    Req/Sec    31.18k     1.34k   41.62k    96.53%
  10106978 requests in 5.10s, 153.97GB read
Requests/sec: 1981969.86
Transfer/sec:     30.19GB
[info] CPU 5276.4% | Mem 193MiB

[run 2/3]
Running 5s test @ http://localhost:8080
  64 threads and 4096 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.06ms  272.30us   8.00ms   91.67%
    Req/Sec    31.77k     1.10k   45.23k    97.33%
  10313597 requests in 5.10s, 157.11GB read
Requests/sec: 2022455.94
Transfer/sec:     30.81GB
[info] CPU 5491.0% | Mem 191MiB

[run 3/3]
Running 5s test @ http://localhost:8080
  64 threads and 4096 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.06ms  252.23us   4.70ms   92.44%
    Req/Sec    31.77k     0.92k   44.69k    96.10%
  10289418 requests in 5.10s, 156.75GB read
Requests/sec: 2017646.48
Transfer/sec:     30.74GB
[info] CPU 5424.2% | Mem 196MiB

=== Best: 2022455 req/s (CPU: 5491.0%, Mem: 191MiB) ===
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
    Latency     1.83ms    0.89ms  52.64ms   94.31%
    Req/Sec    30.64k     0.89k   39.86k    96.26%
  9906533 requests in 5.08s, 150.91GB read
Requests/sec: 1948331.48
Transfer/sec:     29.68GB
[info] CPU 5116.2% | Mem 240MiB

[run 2/3]
Running 5s test @ http://localhost:8080
  64 threads and 6800 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.79ms  409.36us   6.47ms   93.18%
    Req/Sec    30.86k     1.11k   44.23k    92.55%
  9984234 requests in 5.10s, 152.10GB read
Requests/sec: 1959521.44
Transfer/sec:     29.85GB
[info] CPU 5238.3% | Mem 240MiB

[run 3/3]
Running 5s test @ http://localhost:8080
  64 threads and 6800 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.76ms  350.84us   8.83ms   94.69%
    Req/Sec    31.19k     0.89k   42.88k    95.06%
  10089828 requests in 5.09s, 153.71GB read
Requests/sec: 1982961.96
Transfer/sec:     30.21GB
[info] CPU 5265.5% | Mem 245MiB

=== Best: 1982961 req/s (CPU: 5265.5%, Mem: 245MiB) ===
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
