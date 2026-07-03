## Benchmark Results

**Framework:** `zix` | **Test:** `all tests`

| Test | Conn | RPS | CPU | Mem | Δ RPS | Δ Mem |
|------|------|-----|-----|-----|-------|-------|
| baseline | 512 | 4,091,220 | 6305.5% | 229MiB | -3.0% | +76.2% |
| baseline | 4096 | 4,321,447 | 6417.6% | 281MiB | -3.8% | +51.1% |
| pipelined | 512 | 53,047,907 | 6372.3% | 229MiB | -1.0% | +70.9% |
| pipelined | 4096 | 54,914,998 | 6306.1% | 282MiB | -1.9% | +51.6% |
| limited-conn | 512 | 2,674,776 | 5483.8% | 246MiB | -2.4% | +64.0% |
| limited-conn | 4096 | 2,700,631 | 5783.8% | 315MiB | -1.8% | +32.9% |
| json | 4096 | 2,402,888 | 6314.2% | 347MiB | +2.3% | +19.7% |
| json-comp | 512 | 2,217,930 | 5357.4% | 250MiB | NEW | NEW |
| json-comp | 4096 | 3,057,904 | 6042.4% | 310MiB | NEW | NEW |
| json-comp | 16384 | 2,905,970 | 6399.9% | 518MiB | NEW | NEW |
| json-tls | 4096 | 1,923,174 | 5054.5% | 354MiB | NEW | NEW |
| upload | 32 | 8,209 | 1095.8% | 221MiB | +0.3% | +78.2% |
| upload | 256 | 6,700 | 899.6% | 228MiB | +0.6% | +75.4% |
| static | 1024 | 2,008,338 | 5502.7% | 236MiB | -0.8% | +68.6% |
| static | 4096 | 2,002,759 | 5487.1% | 290MiB | -1.7% | +48.7% |
| static | 6800 | 1,980,096 | 5263.1% | 341MiB | -0.3% | +41.5% |

<details><summary>Full log</summary>

```
  Threads:   64
  Conns:     256 (4/thread)
  Pipeline:  1
  Req/conn:  5
  Templates: 4
  Expected:  200
  Duration:  5s


  Thread Stats   Avg      p50      p90      p99    p99.9
    Latency   37.93ms   38.40ms   41.60ms   43.50ms   45.20ms

  33637 requests in 5.02s, 33638 responses
  Throughput: 6.70K req/s
  Bandwidth:  466.21KB/s
  Status codes: 2xx=33638, 3xx=0, 4xx=0, 5xx=0
  Latency samples: 33638 / 33638 responses (100.0%)
  Reconnects: 6748
  Per-template: 8410,8408,8410,8410
  Per-template-ok: 8410,8408,8410,8410
[info] CPU 899.6% | Mem 228MiB

=== Best: 6700 req/s (CPU: 899.6%, Mem: 228MiB) ===
[info] input BW: 53.14GB/s (avg template: 8516680 bytes)
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
    Latency   355.80us  849.21us  29.48ms   99.45%
    Req/Sec    31.15k     1.34k   40.96k    96.57%
  10110351 requests in 5.10s, 154.02GB read
Requests/sec: 1982373.18
Transfer/sec:     30.20GB
[info] CPU 5418.1% | Mem 236MiB

[run 2/3]
Running 5s test @ http://localhost:8080
  64 threads and 1024 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   306.47us  118.11us   4.98ms   71.14%
    Req/Sec    31.49k   569.76    37.91k    96.26%
  10225139 requests in 5.10s, 155.77GB read
Requests/sec: 2004808.53
Transfer/sec:     30.54GB
[info] CPU 5502.2% | Mem 236MiB

[run 3/3]
Running 5s test @ http://localhost:8080
  64 threads and 1024 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   304.38us  114.63us   2.71ms   71.15%
    Req/Sec    31.55k   581.64    38.44k    97.55%
  10242520 requests in 5.10s, 156.03GB read
Requests/sec: 2008338.83
Transfer/sec:     30.59GB
[info] CPU 5502.7% | Mem 236MiB

=== Best: 2008338 req/s (CPU: 5502.7%, Mem: 236MiB) ===
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
    Latency     1.17ms    1.27ms  37.06ms   99.19%
    Req/Sec    31.07k     1.25k   41.54k    96.71%
  10065393 requests in 5.10s, 153.33GB read
Requests/sec: 1973607.24
Transfer/sec:     30.07GB
[info] CPU 5286.5% | Mem 292MiB

[run 2/3]
Running 5s test @ http://localhost:8080
  64 threads and 4096 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.07ms  269.07us   6.19ms   91.52%
    Req/Sec    31.48k     1.06k   47.14k    96.99%
  10214482 requests in 5.10s, 155.60GB read
Requests/sec: 2002759.50
Transfer/sec:     30.51GB
[info] CPU 5487.1% | Mem 290MiB

[run 3/3]
Running 5s test @ http://localhost:8080
  64 threads and 4096 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.09ms  261.97us   7.82ms   92.28%
    Req/Sec    30.87k     0.98k   45.97k    96.44%
  10011937 requests in 5.10s, 152.52GB read
Requests/sec: 1962734.66
Transfer/sec:     29.90GB
[info] CPU 5333.5% | Mem 290MiB

=== Best: 2002759 req/s (CPU: 5487.1%, Mem: 290MiB) ===
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
    Latency     1.88ms    1.09ms  44.15ms   92.86%
    Req/Sec    30.43k     1.35k   39.31k    97.00%
  9836484 requests in 5.08s, 149.85GB read
Requests/sec: 1934453.65
Transfer/sec:     29.47GB
[info] CPU 5103.5% | Mem 337MiB

[run 2/3]
Running 5s test @ http://localhost:8080
  64 threads and 6800 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.79ms  404.56us   8.76ms   93.20%
    Req/Sec    30.90k     1.02k   41.48k    94.22%
  9989561 requests in 5.09s, 152.18GB read
Requests/sec: 1960743.18
Transfer/sec:     29.87GB
[info] CPU 5333.7% | Mem 335MiB

[run 3/3]
Running 5s test @ http://localhost:8080
  64 threads and 6800 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.77ms  367.69us   6.49ms   94.13%
    Req/Sec    31.13k     1.02k   46.35k    97.25%
  10060375 requests in 5.08s, 153.26GB read
Requests/sec: 1980096.83
Transfer/sec:     30.16GB
[info] CPU 5263.1% | Mem 341MiB

=== Best: 1980096 req/s (CPU: 5263.1%, Mem: 341MiB) ===
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
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/json-comp-16384.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/json-comp-4096.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/json-comp-512.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/json-tls-4096.json
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
