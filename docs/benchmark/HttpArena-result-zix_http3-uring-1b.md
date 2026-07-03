## Benchmark Results

**Framework:** `zix-http3` | **Test:** `all tests`

| Test | Conn | RPS | CPU | Mem | Δ RPS | Δ Mem |
|------|------|-----|-----|-----|-------|-------|
| baseline-h3 | 64 | 1,429 | 5.2% | 288MiB | NEW | NEW |
| static-h3 | 64 | 1,159 | 0.0% | 290MiB | NEW | NEW |

<details><summary>Full log</summary>

```
status codes: 7058 2xx, 0 3xx, 0 4xx, 0 5xx
traffic: 55.33KB (56656) total, 20.68KB (21174) headers (space savings 70.00%), 6.89KB (7058) data
UDP datagram: 968 sent, 7501 received
                 min         max         median     p95        p99        mean         sd        +/- sd
request     :      393us      4.62ms       723us     2.23ms     3.66ms      923us       623us    90.88%
connect     :      905us      2.69ms      1.44ms     2.38ms     2.69ms     1.52ms       437us    68.75%
TTFB        :     1.40ms      4.47ms      2.08ms     3.61ms     4.47ms     2.36ms       693us    76.56%
req/s       :      22.17    29517.98       22.37      22.39   29517.98    1185.66     5475.97    95.31%
min RTT     :       47us      1.93ms       392us      932us     1.93ms      461us       290us    85.94%
smoothed RTT:      420us      2.90ms       577us     2.03ms     2.90ms      764us       509us    92.19%
packets sent:         14          18          17         18         18      16.92        0.76    59.38%
packets recv:         69         120         119        120        120     117.12        8.08    95.31%
packets lost:          0           0           0          0          0       0.00        0.00   100.00%
GRO packets :          1          21           2         17         20       5.67        6.55    76.11%
[info] CPU 3.8% | Mem 288MiB

=== Best: 1429 req/s (CPU: 5.2%, Mem: 288MiB) ===
[info] saved results/baseline-h3/64/zix-http3.json
httparena-bench-zix-http3
httparena-bench-zix-http3

==============================================
=== zix-http3 / static-h3 / 64c (tool=h2load-h3) ===
==============================================
[info] waiting for server...
[info] server ready

[run 1/3]
starting benchmark...
.Warm-up phase is over for thread #37.

.
.
.Main benchmark duration is started for thread #60.

15.
TLS Protocol: TLSv1.3
Cipher: TLS_AES_128_GCM_SHA256
Server Temp Key: X25519 253 bits
Certificate: ED25519 256 bits
Negotiated Group: x25519
Resumption: no
Application protocol: h3
. Stopping all clients.

63. Stopping all clients.
40. Stopping all clients.
59. Stopping all clients.


. Stopping all clients.Stopped all clients for thread #30

13. Stopping all clients.
47. Stopping all clients.
5. Stopping all clients.


finished in 5.02s, 1042.00 req/s, 62.27MB/s
requests: 5210 total, 9306 started, 5210 done, 5210 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 5805 2xx, 0 3xx, 0 4xx, 0 5xx
traffic: 311.36MB (326487885) total, 17.01KB (17415) headers (space savings 70.00%), 311.31MB (326433339) data
UDP datagram: 3013 sent, 307187 received
                 min         max         median     p95        p99        mean         sd        +/- sd
request     :      208us     20.51ms      8.48ms    19.37ms    20.18ms     8.58ms      5.03ms    67.52%
connect     :      890us     19.91ms      1.54ms    16.29ms    19.91ms     4.04ms      4.89ms    82.81%
TTFB        :     1.62ms     33.59ms      6.04ms    19.68ms    33.59ms     7.87ms      6.66ms    85.94%
req/s       :       0.00     4234.04       18.09    2960.35    4234.04     504.85     1119.97    82.81%
min RTT     :        0us     10.42ms       394us     8.19ms    10.42ms     1.83ms      2.63ms    84.38%
smoothed RTT:      149us    333.00ms      8.09ms    15.85ms   333.00ms    13.03ms     40.83ms    98.44%
packets sent:         25          89          43         81         89      48.94       14.33    81.25%
packets recv:       1765        6052        4991       6002       6052    4799.61      986.61    78.13%
packets lost:          0           0           0          0          0       0.00        0.00   100.00%
GRO packets :          1          32           7         32         32      11.62       11.72    78.24%
[info] CPU 42.5% | Mem 291MiB

[run 2/3]
starting benchmark...
22.
0.
60.
3.
TLS Protocol: TLSv1.3
Cipher: TLS_AES_128_GCM_SHA256
Server Temp Key: X25519 253 bits
Certificate: ED25519 256 bits
Negotiated Group: x25519
Resumption: no
Application protocol: h3
.
27.Main benchmark duration is started for thread #53.

0. Stopping all clients.
1. Stopping all clients.
22. Stopping all clients.

39. Stopping all clients.

8. Stopping all clients.
43. Stopping all clients.
4. Stopping all clients.
23. Stopping all clients.
54. Stopping all clients.
49. Stopping all clients.

. Stopping all clients.
25. Stopping all clients.
. Stopping all clients.

finished in 5.02s, 1025.00 req/s, 61.67MB/s
requests: 5125 total, 9221 started, 5125 done, 5125 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 5689 2xx, 0 3xx, 0 4xx, 0 5xx
traffic: 308.35MB (323325729) total, 16.67KB (17067) headers (space savings 70.00%), 308.30MB (323272199) data
UDP datagram: 2990 sent, 306483 received
                 min         max         median     p95        p99        mean         sd        +/- sd
request     :      125us     12.50ms      5.68ms    10.51ms    12.02ms     5.77ms      2.75ms    67.61%
connect     :      815us      7.32ms      1.51ms     4.00ms     7.32ms     1.95ms      1.20ms    89.06%
TTFB        :     1.60ms     10.97ms      2.36ms     8.95ms    10.97ms     3.58ms      2.39ms    81.25%
req/s       :       0.00     7129.83       18.68    6236.10    7129.83    1207.31     2233.93    78.13%
min RTT     :        0us      9.11ms       146us     3.58ms     9.11ms      911us      1.54ms    87.50%
smoothed RTT:       64us    333.00ms      3.45ms     9.11ms   333.00ms    14.10ms     57.78ms    96.88%
packets sent:         17         118          42         89        118      48.62       20.07    79.69%
packets recv:       1801        6083        4938       5956       6083    4788.53     1007.34    75.00%
packets lost:          0           0           0          0          0       0.00        0.00   100.00%
GRO packets :          1          32           8         32         32      11.74       11.75    77.94%
[info] CPU 21.2% | Mem 289MiB

[run 3/3]
starting benchmark...

0.
TLS Protocol: TLSv1.3
Cipher: TLS_AES_128_GCM_SHA256
Server Temp Key: X25519 253 bits
Certificate: ED25519 256 bits
Negotiated Group: x25519
Resumption: no
Application protocol: h3
10. Stopping all clients.. Stopping all clients.Main benchmark duration is over for thread #
. Stopping all clients.Stopped all clients for thread #Stopped all clients for thread #19
18
21Stopped all clients for thread #10


. Stopping all clients.

. Stopping all clients.Main benchmark duration is over for thread #Stopped all clients for thread #63
13. Stopping all clients.
12. Stopping all clients.

32. Stopping all clients.
24. Stopping all clients.



40. Stopping all clients.Stopped all clients for thread #60

. Stopping all clients.
44. Stopping all clients.
53. Stopping all clients.
58. Stopping all clients.Stopped all clients for thread #61


finished in 5.02s, 1034.60 req/s, 62.45MB/s
requests: 5173 total, 9269 started, 5173 done, 5173 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 5823 2xx, 0 3xx, 0 4xx, 0 5xx
traffic: 312.24MB (327406102) total, 17.06KB (17469) headers (space savings 70.00%), 312.19MB (327351282) data
UDP datagram: 2819 sent, 314607 received
                 min         max         median     p95        p99        mean         sd        +/- sd
request     :      262us     17.63ms      5.48ms    10.83ms    16.87ms     5.50ms      3.17ms    71.29%
connect     :      905us      9.15ms      1.70ms     3.98ms     9.15ms     2.00ms      1.26ms    92.19%
TTFB        :     1.45ms     13.91ms      2.57ms     9.02ms    13.91ms     3.62ms      2.72ms    87.50%
req/s       :      13.38     6608.52       17.98    4499.95    6608.52     668.79     1588.19    84.38%
min RTT     :        0us      6.18ms       105us     3.75ms     6.18ms      758us      1.37ms    85.94%
smoothed RTT:      100us    333.00ms      3.75ms     8.63ms   333.00ms     8.68ms     41.26ms    98.44%
packets sent:         16          84          43         69         84      46.00       12.28    79.69%
packets recv:       1318        5967        4999       5832       5967    4915.58      821.56    82.81%
packets lost:          0           0           0          0          0       0.00        0.00   100.00%
GRO packets :          1          32           8         32         32      11.85       11.78    77.65%
[info] CPU 0.0% | Mem 290MiB

=== Best: 1159 req/s (CPU: 0.0%, Mem: 290MiB) ===
[info] saved results/static-h3/64/zix-http3.json
httparena-bench-zix-http3
httparena-bench-zix-http3
[info] skip: zix-http3 does not subscribe to gateway-64
[info] skip: zix-http3 does not subscribe to gateway-h3
[info] skip: zix-http3 does not subscribe to production-stack
[info] skip: zix-http3 does not subscribe to unary-grpc
[info] skip: zix-http3 does not subscribe to unary-grpc-tls
[info] skip: zix-http3 does not subscribe to stream-grpc
[info] skip: zix-http3 does not subscribe to stream-grpc-tls
[info] skip: zix-http3 does not subscribe to echo-ws
[info] skip: zix-http3 does not subscribe to echo-ws-pipeline
[info] rebuilding site/data/*.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/frameworks.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/baseline-h3-64.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/static-h3-64.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/current.json
[info] done
[info] restoring loopback MTU to 65536
```
</details>
