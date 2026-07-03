## Benchmark Results

**Framework:** `zix-http3` | **Test:** `all tests`

| Test | Conn | RPS | CPU | Mem | Δ RPS | Δ Mem |
|------|------|-----|-----|-----|-------|-------|
| baseline-h3 | 64 | 1,424 | 0.0% | 280MiB | NEW | NEW |
| static-h3 | 64 | 1,225 | 46.4% | 281MiB | NEW | NEW |

<details><summary>Full log</summary>

```
Resumption: no
Application protocol: h3
. Stopping all clients.

6123. Stopping all clients.
. Stopping all clients.
. Stopping all clients.60


finished in 5.02s, 1390.80 req/s, 10.90KB/s
requests: 6954 total, 11050 started, 6954 done, 6954 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 6954 2xx, 0 3xx, 0 4xx, 0 5xx
traffic: 54.52KB (55824) total, 20.37KB (20862) headers (space savings 70.00%), 6.79KB (6954) data
UDP datagram: 950 sent, 7394 received
                 min         max         median     p95        p99        mean         sd        +/- sd
request     :      440us      2.06ms       701us     1.40ms     1.78ms      775us       294us    79.42%
connect     :      971us      2.90ms      1.32ms     2.20ms     2.90ms     1.43ms       377us    76.56%
TTFB        :     1.48ms      3.65ms      2.13ms     2.94ms     3.65ms     2.22ms       490us    67.19%
req/s       :      22.17    36199.22       22.38   14929.18   36199.22    1777.10     6682.32    92.19%
min RTT     :       51us       841us       390us      736us      841us      410us       153us    71.88%
smoothed RTT:      427us      1.21ms       558us     1.08ms     1.21ms      638us       206us    82.81%
packets sent:         11          19          17         18         19      16.77        1.27    93.75%
packets recv:         40         121         119        120        121     115.39       15.14    93.75%
packets lost:          0           0           0          0          0       0.00        0.00   100.00%
GRO packets :          1          21           2         17         20       5.67        6.57    76.15%
[info] CPU 4.1% | Mem 280MiB

=== Best: 1424 req/s (CPU: 0.0%, Mem: 280MiB) ===
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
.Main benchmark duration is started for thread #1.

49.
.
27.
23.
050.
.
TLS Protocol: TLSv1.3
Cipher: TLS_AES_128_GCM_SHA256
Server Temp Key: X25519 253 bits
Certificate: ED25519 256 bits
Negotiated Group: x25519
Resumption: no
Application protocol: h3

17. Stopping all clients.Stopped all clients for thread #

1Stopped all clients for thread #3
17
. Stopping all clients.
60Stopped all clients for thread #. Stopping all clients.14

38. Stopping all clients.
13

. Stopping all clients.
. Stopping all clients.

22. Stopping all clients.
. Stopping all clients.


finished in 5.02s, 1133.60 req/s, 67.66MB/s
requests: 5668 total, 9764 started, 5668 done, 5668 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 6151 2xx, 0 3xx, 0 4xx, 0 5xx
traffic: 338.32MB (354752213) total, 18.02KB (18453) headers (space savings 70.00%), 338.26MB (354694353) data
UDP datagram: 3451 sent, 327517 received
                 min         max         median     p95        p99        mean         sd        +/- sd
request     :      229us     26.49ms      9.39ms    19.55ms    24.43ms     9.88ms      5.44ms    71.05%
connect     :      952us     19.51ms      1.70ms    17.86ms    19.51ms     5.19ms      5.70ms    78.13%
TTFB        :     1.47ms     29.39ms      7.05ms    27.55ms    29.39ms     9.88ms      7.92ms    79.69%
req/s       :       0.00     4424.85       18.68    3208.59    4424.85     457.95     1132.72    85.94%
min RTT     :        0us     13.79ms       475us     9.99ms    13.79ms     2.22ms      3.50ms    84.38%
smoothed RTT:      973us    333.00ms      9.41ms    16.78ms   333.00ms    14.41ms     40.64ms    98.44%
packets sent:         25         117          50         91        117      55.86       19.76    73.44%
packets recv:       1972        6082        5385       5989       6082    5117.30      892.58    85.94%
packets lost:          0           0           0          0          0       0.00        0.00   100.00%
GRO packets :          1          32           6         32         32      11.48       11.71    78.50%
[info] CPU 46.4% | Mem 281MiB

[run 2/3]
starting benchmark...


13.
11Main benchmark duration is started for thread #4.
.
TLS Protocol: TLSv1.3
Cipher: TLS_AES_128_GCM_SHA256
Server Temp Key: X25519 Warm-up started for thread #21.
253 bits
Certificate: ED25519 256 bits
Negotiated Group: x25519
Resumption: no
Application protocol: h3
53.
60. Stopping all clients.5. Stopping all clients.
0Stopped all clients for thread #. Stopping all clients.5

55. Stopping all clients.Stopped all clients for thread #0


19. Stopping all clients.Stopped all clients for thread #51

. Stopping all clients.Stopped all clients for thread #7


21. Stopping all clients.
40. Stopping all clients.
50. Stopping all clients.
. Stopping all clients.

finished in 5.02s, 1085.40 req/s, 64.81MB/s
requests: 5427 total, 9523 started, 5427 done, 5427 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 5961 2xx, 0 3xx, 0 4xx, 0 5xx
traffic: 324.05MB (339789316) total, 17.46KB (17883) headers (space savings 70.00%), 323.99MB (339733246) data
UDP datagram: 3209 sent, 317307 received
                 min         max         median     p95        p99        mean         sd        +/- sd
request     :      177us     18.70ms      6.14ms    15.36ms    18.37ms     6.90ms      4.05ms    64.70%
connect     :      904us     14.35ms      1.94ms     6.81ms    14.35ms     2.78ms      2.33ms    85.94%
TTFB        :     1.51ms     20.92ms      3.33ms    14.70ms    20.92ms     5.85ms      4.83ms    81.25%
req/s       :       0.00     7062.71       18.68    3290.92    7062.71     493.83     1409.66    89.06%
min RTT     :        0us      9.47ms       613us     6.19ms     9.47ms     1.96ms      2.43ms    82.81%
smoothed RTT:      280us    333.00ms      4.88ms    13.31ms   333.00ms    15.78ms     57.52ms    96.88%
packets sent:         21         108          44         91        108      52.02       18.55    81.25%
packets recv:       1966        6073        5216       6049       6073    4957.78      957.66    78.13%
packets lost:          0           0           0          0          0       0.00        0.00   100.00%
GRO packets :          1          32           7         32         32      11.59       11.71    78.37%
[info] CPU 22.3% | Mem 280MiB

[run 3/3]
starting benchmark...
7.
TLS Protocol: TLSv1.3
Cipher: TLS_AES_128_GCM_SHA256
Server Temp Key: X25519 253 bits
Certificate: ED25519 256 bits
Negotiated Group: x25519
Resumption: no
Application protocol: h3
48. Stopping all clients.
37Stopped all clients for thread #6
. Stopping all clients.
23. Stopping all clients.

33. Stopping all clients.
21. Stopping all clients.

47. Stopping all clients.
58. Stopping all clients.

finished in 5.02s, 1025.00 req/s, 62.23MB/s
requests: 5125 total, 9221 started, 5125 done, 5125 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 5750 2xx, 0 3xx, 0 4xx, 0 5xx
traffic: 311.15MB (326264694) total, 16.85KB (17250) headers (space savings 70.00%), 311.10MB (326210614) data
UDP datagram: 2982 sent, 309343 received
                 min         max         median     p95        p99        mean         sd        +/- sd
request     :      123us     15.80ms      5.11ms    13.86ms    15.72ms     5.43ms      3.47ms    73.00%
connect     :      860us      6.05ms      1.41ms     4.20ms     6.05ms     1.86ms      1.12ms    87.50%
TTFB        :     1.63ms     12.67ms      2.30ms     9.91ms    12.67ms     3.40ms      2.53ms    84.38%
req/s       :       0.00     6864.22       17.38    5541.09    6864.22     586.89     1622.58    87.50%
min RTT     :        0us     12.18ms        93us     4.29ms    12.18ms      758us      1.83ms    90.63%
smoothed RTT:       58us    333.00ms      3.78ms    12.18ms   333.00ms     8.81ms     41.30ms    98.44%
packets sent:         17          94          45         69         94      48.45       12.73    75.00%
packets recv:       1708        5979        4981       5925       5979    4833.34      894.18    81.25%
packets lost:          0           0           0          0          0       0.00        0.00   100.00%
GRO packets :          1          32           8         32         32      11.83       11.76    77.82%
[info] CPU 0.0% | Mem 281MiB

=== Best: 1225 req/s (CPU: 46.4%, Mem: 281MiB) ===
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
