## Benchmark Results

**Framework:** `zix-http2` | **Test:** `all tests`

| Test | Conn | RPS | CPU | Mem | Δ RPS | Δ Mem |
|------|------|-----|-----|-----|-------|-------|
| baseline-h2 | 256 | 10,497,580 | 4058.2% | 142MiB | NEW | NEW |
| baseline-h2 | 1024 | 10,152,985 | 3892.9% | 213MiB | NEW | NEW |
| static-h2 | 256 | 1,662,951 | 6070.9% | 224MiB | NEW | NEW |
| static-h2 | 1024 | 1,669,997 | 6067.1% | 550MiB | NEW | NEW |
| baseline-h2c | 256 | 1,480,053 | 6467.2% | 130MiB | NEW | NEW |
| baseline-h2c | 1024 | 1,532,916 | 6572.2% | 183MiB | NEW | NEW |
| baseline-h2c | 4096 | 1,499,170 | 6584.5% | 390MiB | NEW | NEW |
| json-h2c | 1024 | 1,431,951 | 6416.0% | 182MiB | NEW | NEW |
| json-h2c | 4096 | 1,397,486 | 6439.9% | 394MiB | NEW | NEW |

<details><summary>Full log</summary>

```
63.Main benchmark duration is started for thread #9.

53.Main benchmark duration is started for thread #40.

49.
5.


36. Stopping all clients.Main benchmark duration is over for thread #
41. Stopping all clients.
18Main benchmark duration is over for thread #Stopped all clients for thread #31
. Stopping all clients.
22. Stopping all clients.
. Stopping all clients.

. Stopping all clients.
17. Stopping all clients.
60. Stopping all clients.

finished in 5.08s, 1451728.20 req/s, 4.81GB/s
requests: 7258641 total, 7291409 started, 7258641 done, 7258641 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 7258676 2xx, 0 3xx, 0 4xx, 0 5xx
traffic: 24.05GB (25822552713) total, 144.38MB (151394780) headers (space savings 62.56%), 23.79GB (25540445364) data
                     min         max         mean         sd        +/- sd
time for request:      136us     47.23ms     11.18ms      3.17ms    77.79%
time for connect:       18us      1.27ms       404us       227us    63.48%
time to 1st byte:     1.23ms     46.65ms     13.73ms      8.46ms    64.45%
req/s           :     784.75     2611.24     1417.56      314.64    67.38%
[info] CPU 6542.5% | Mem 183MiB

=== Best: 1431951 req/s (CPU: 6416.0%, Mem: 182MiB) ===
[info] saved results/json-h2c/1024/zix-http2.json
httparena-bench-zix-http2
httparena-bench-zix-http2

==============================================
=== zix-http2 / json-h2c / 4096c (tool=h2load) ===
==============================================
[info] waiting for server...
[info] server ready

[run 1/3]
starting benchmark...
1411.Main benchmark duration is started for thread #4.
36.
33.
.Warm-up phase is over for thread #831.
60.
.Main benchmark duration is started for thread #
26
60.
.52.
.



44.Warm-up phase is over for thread #47.



.
23Main benchmark duration is started for thread #2.
.

55.
51.
28.
38. Stopping all clients.
14. Stopping all clients.
39. Stopping all clients.

. Stopping all clients.
. Stopping all clients.
44. Stopping all clients.Stopped all clients for thread #

10. Stopping all clients.
. Stopping all clients.
. Stopping all clients.
. Stopping all clients.
47
25. Stopping all clients.

finished in 5.11s, 1411024.20 req/s, 4.67GB/s
requests: 7055121 total, 7186193 started, 7055121 done, 7055121 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 7055162 2xx, 0 3xx, 0 4xx, 0 5xx
traffic: 23.36GB (25081306619) total, 140.33MB (147148661) headers (space savings 62.56%), 23.10GB (24806939780) data
                     min         max         mean         sd        +/- sd
time for request:     2.36ms    236.39ms     49.93ms     19.63ms    94.11%
time for connect:       17us      7.78ms      2.30ms      1.77ms    62.30%
time to 1st byte:     9.34ms    236.95ms    128.69ms     37.25ms    71.44%
req/s           :     263.93      486.36      344.36       38.05    71.29%
[info] CPU 6271.6% | Mem 389MiB

[run 2/3]
starting benchmark...
62.Warm-up phase is over for thread #Warm-up phase is over for thread #
61Main benchmark duration is started for thread #62.
31Warm-up phase is over for thread #.

49.
Application protocol: h2c
.Main benchmark duration is started for thread #61.

6Main benchmark duration is started for thread #.
56.
16.
.Warm-up phase is over for thread #59.

.
51.

35.

12. Stopping all clients.
62. Stopping all clients.

59. Stopping all clients.
14. Stopping all clients.

finished in 5.13s, 1430255.20 req/s, 4.74GB/s
requests: 7151276 total, 7282348 started, 7151276 done, 7151276 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 7151318 2xx, 0 3xx, 0 4xx, 0 5xx
traffic: 23.68GB (25424071950) total, 142.24MB (149154117) headers (space savings 62.56%), 23.42GB (25145968802) data
                     min         max         mean         sd        +/- sd
time for request:      339us    204.70ms     46.87ms     10.81ms    86.99%
time for connect:       19us      7.73ms      3.09ms      2.31ms    54.79%
time to 1st byte:     4.64ms    207.14ms     71.85ms     32.76ms    65.41%
req/s           :     259.13      537.52      349.05       46.91    71.19%
[info] CPU 6570.2% | Mem 390MiB

[run 3/3]
starting benchmark...
35Warm-up phase is over for thread #Main benchmark duration is started for thread #51Warm-up phase is over for thread #Warm-up phase is over for thread #52.
.


46Warm-up phase is over for thread #Main benchmark duration is started for thread #38.

.

2733..

.
.
44.
41.Warm-up phase is over for thread #25.

53.
.
45.


Application protocol: h2c
41. Stopping all clients.
24Main benchmark duration is over for thread #. Stopping all clients.
18. Stopping all clients.
12. Stopping all clients.
13
14. Stopping all clients.

finished in 5.10s, 1425431.20 req/s, 4.72GB/s
requests: 7127156 total, 7258228 started, 7127156 done, 7127156 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 7127182 2xx, 0 3xx, 0 4xx, 0 5xx
traffic: 23.60GB (25337574121) total, 141.76MB (148650848) headers (space savings 62.56%), 23.34GB (25060408663) data
                     min         max         mean         sd        +/- sd
time for request:      413us    237.31ms     46.97ms     10.96ms    87.90%
time for connect:       17us      7.55ms      2.80ms      2.12ms    57.25%
time to 1st byte:     3.10ms    238.60ms     69.62ms     34.06ms    66.11%
req/s           :     248.09      489.44      347.88       45.38    71.09%
[info] CPU 6439.9% | Mem 394MiB

=== Best: 1397486 req/s (CPU: 6439.9%, Mem: 394MiB) ===
[info] saved results/json-h2c/4096/zix-http2.json
httparena-bench-zix-http2
httparena-bench-zix-http2
[info] skip: zix-http2 does not subscribe to baseline-h3
[info] skip: zix-http2 does not subscribe to static-h3
[info] skip: zix-http2 does not subscribe to gateway-64
[info] skip: zix-http2 does not subscribe to gateway-h3
[info] skip: zix-http2 does not subscribe to production-stack
[info] skip: zix-http2 does not subscribe to unary-grpc
[info] skip: zix-http2 does not subscribe to unary-grpc-tls
[info] skip: zix-http2 does not subscribe to stream-grpc
[info] skip: zix-http2 does not subscribe to stream-grpc-tls
[info] skip: zix-http2 does not subscribe to echo-ws
[info] skip: zix-http2 does not subscribe to echo-ws-pipeline
[info] rebuilding site/data/*.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/frameworks.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/baseline-h2-1024.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/baseline-h2-256.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/baseline-h2c-1024.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/baseline-h2c-256.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/baseline-h2c-4096.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/json-h2c-1024.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/json-h2c-4096.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/static-h2-1024.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/static-h2-256.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/current.json
[info] done
[info] restoring loopback MTU to 65536
```
</details>
