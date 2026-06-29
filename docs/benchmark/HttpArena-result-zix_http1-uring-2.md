## Benchmark Results

**Framework:** `zix` | **Test:** `all tests`

| Test | Conn | RPS | CPU | Mem | Δ RPS | Δ Mem |
|------|------|-----|-----|-----|-------|-------|
| baseline | 512 | 4,207,121 | 6273.3% | 230MiB | -0.3% | +76.9% |
| baseline | 4096 | 4,385,696 | 6435.4% | 283MiB | -2.4% | +52.2% |
| pipelined | 512 | 53,889,875 | 6455.1% | 228MiB | +0.5% | +70.1% |
| pipelined | 4096 | 55,712,675 | 6308.8% | 284MiB | -0.5% | +52.7% |
| limited-conn | 512 | 2,693,448 | 5469.9% | 247MiB | -1.7% | +64.7% |
| limited-conn | 4096 | 2,716,030 | 5758.4% | 316MiB | -1.3% | +33.3% |
| json | 4096 | 2,388,816 | 5574.6% | 343MiB | +1.7% | +18.3% |
| json-comp | 512 | 2,200,689 | 5116.9% | 249MiB | NEW | NEW |
| json-comp | 4096 | 3,078,692 | 6307.6% | 308MiB | NEW | NEW |
| json-comp | 16384 | 2,925,097 | 6408.6% | 526MiB | NEW | NEW |
| json-tls | 4096 | 1,898,413 | 4965.3% | 354MiB | NEW | NEW |
| upload | 32 | 8,220 | 1063.4% | 223MiB | +0.4% | +79.8% |
| upload | 256 | 6,626 | 928.0% | 233MiB | -0.5% | +79.2% |
| static | 1024 | 1,992,585 | 5473.9% | 236MiB | -1.6% | +68.6% |
| static | 4096 | 2,001,296 | 5419.0% | 292MiB | -1.7% | +49.7% |
| static | 6800 | 1,982,035 | 5280.6% | 340MiB | -0.2% | +41.1% |

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
    Latency   38.77ms   39.20ms   42.70ms   45.10ms   67.80ms

  32831 requests in 5.02s, 32833 responses
  Throughput: 6.54K req/s
  Bandwidth:  454.77KB/s
  Status codes: 2xx=32833, 3xx=0, 4xx=0, 5xx=0
  Latency samples: 32833 / 32833 responses (100.0%)
  Reconnects: 6592
  Per-template: 8206,8209,8210,8208
  Per-template-ok: 8206,8209,8210,8208
[info] CPU 896.1% | Mem 234MiB

=== Best: 6626 req/s (CPU: 928.0%, Mem: 233MiB) ===
[info] input BW: 52.56GB/s (avg template: 8516680 bytes)
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
    Latency   350.55us    0.89ms  38.17ms   99.51%
    Req/Sec    31.11k     1.38k   37.29k    97.06%
  10102305 requests in 5.10s, 153.90GB read
Requests/sec: 1980783.53
Transfer/sec:     30.17GB
[info] CPU 5479.9% | Mem 235MiB

[run 2/3]
Running 5s test @ http://localhost:8080
  64 threads and 1024 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   308.87us  119.28us   3.64ms   70.94%
    Req/Sec    31.31k   617.16    37.80k    97.39%
  10162020 requests in 5.10s, 154.81GB read
Requests/sec: 1992585.76
Transfer/sec:     30.35GB
[info] CPU 5473.9% | Mem 236MiB

[run 3/3]
Running 5s test @ http://localhost:8080
  64 threads and 1024 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   308.22us  117.91us   3.74ms   71.90%
    Req/Sec    31.18k   525.66    37.94k    97.03%
  10122356 requests in 5.10s, 154.20GB read
Requests/sec: 1984778.80
Transfer/sec:     30.24GB
[info] CPU 5490.3% | Mem 237MiB

=== Best: 1992585 req/s (CPU: 5473.9%, Mem: 236MiB) ===
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
    Latency     1.21ms    1.76ms  47.08ms   99.02%
    Req/Sec    31.04k     1.83k   41.00k    96.72%
  10065443 requests in 5.10s, 153.33GB read
Requests/sec: 1973623.24
Transfer/sec:     30.07GB
[info] CPU 5312.5% | Mem 291MiB

[run 2/3]
Running 5s test @ http://localhost:8080
  64 threads and 4096 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.08ms  274.48us   5.71ms   91.39%
    Req/Sec    31.40k     0.93k   45.10k    95.06%
  10178360 requests in 5.10s, 155.05GB read
Requests/sec: 1995585.48
Transfer/sec:     30.40GB
[info] CPU 5509.9% | Mem 290MiB

[run 3/3]
Running 5s test @ http://localhost:8080
  64 threads and 4096 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.07ms  252.32us   4.62ms   92.48%
    Req/Sec    31.48k     0.97k   46.03k    97.21%
  10206923 requests in 5.10s, 155.49GB read
Requests/sec: 2001296.63
Transfer/sec:     30.49GB
[info] CPU 5419.0% | Mem 292MiB

=== Best: 2001296 req/s (CPU: 5419.0%, Mem: 292MiB) ===
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
    Latency     2.16ms    2.32ms  96.76ms   99.01%
    Req/Sec    27.61k     1.76k   37.84k    96.91%
  8934472 requests in 5.10s, 136.11GB read
Requests/sec: 1752613.97
Transfer/sec:     26.70GB
[info] CPU 5003.4% | Mem 335MiB

[run 2/3]
Running 5s test @ http://localhost:8080
  64 threads and 6800 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.80ms  433.69us   6.47ms   92.21%
    Req/Sec    30.81k     0.99k   45.72k    96.88%
  9955808 requests in 5.08s, 151.66GB read
Requests/sec: 1958167.65
Transfer/sec:     29.83GB
[info] CPU 5226.0% | Mem 336MiB

[run 3/3]
Running 5s test @ http://localhost:8080
  64 threads and 6800 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.76ms  355.10us   5.71ms   94.51%
    Req/Sec    31.21k     1.00k   44.10k    97.62%
  10094433 requests in 5.09s, 153.78GB read
Requests/sec: 1982035.80
Transfer/sec:     30.19GB
[info] CPU 5280.6% | Mem 340MiB

=== Best: 1982035 req/s (CPU: 5280.6%, Mem: 340MiB) ===
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
