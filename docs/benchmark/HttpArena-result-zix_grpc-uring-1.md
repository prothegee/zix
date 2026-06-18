## Benchmark Results

**Framework:** `zix-grpc` | **Test:** `all tests`

| Test | Conn | RPS | CPU | Mem | Δ RPS | Δ Mem |
|------|------|-----|-----|-----|-------|-------|
| unary-grpc | 256 | 7,211,952 | 3746.9% | 393MiB | -0.4% | -0.3% |
| unary-grpc | 1024 | 7,108,678 | 4002.1% | 1.2GiB | -0.2% | ~0% |
| stream-grpc | 64 | 8,542,000 | 35.8% | 141MiB | +0.9% | ~0% |

<details><summary>Full log</summary>

```

46.
31. Stopping all clients.
17. Stopping all clients.
54. Stopping all clients.
56

finished in 5.05s, 7130540.00 req/s, 448.82MB/s
requests: 35652700 total, 35755100 started, 35652700 done, 35652700 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 35652700 2xx, 0 3xx, 0 4xx, 0 5xx
traffic: 2.19GB (2353134520) total, 1.06GB (1140886400) headers (space savings 42.86%), 238.01MB (249568900) data
                     min         max         mean         sd        +/- sd
time for request:      563us     72.24ms      7.84ms      3.70ms    95.14%
time for connect:       19us      4.23ms      1.25ms       812us    63.67%
time to 1st byte:     5.10ms     75.25ms     30.99ms     17.77ms    64.84%
req/s           :    6698.01     7333.70     6961.61       97.99    69.24%
[info] CPU 3996.8% | Mem 1.2GiB

[run 3/3]
starting benchmark...
% of clients startedWarm-up phase is over for thread #21.
37Main benchmark duration is started for thread #21..

6.
39.
17.
19.


Application protocol: h2c
2
58. Stopping all clients.
. Stopping all clients.

38Stopped all clients for thread #. Stopping all clients.31

44. Stopping all clients.

finished in 5.06s, 7180540.00 req/s, 451.97MB/s
requests: 35902700 total, 36005100 started, 35902700 done, 35902700 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 35902700 2xx, 0 3xx, 0 4xx, 0 5xx
traffic: 2.21GB (2369634520) total, 1.07GB (1148886400) headers (space savings 42.86%), 239.68MB (251318900) data
                     min         max         mean         sd        +/- sd
time for request:      532us     74.93ms      7.76ms      3.46ms    94.43%
time for connect:       18us      5.58ms      1.34ms       870us    67.19%
time to 1st byte:     5.23ms     76.33ms     29.04ms     16.64ms    64.36%
req/s           :    6678.32     7432.84     7010.49      103.34    70.70%
[info] CPU 4036.4% | Mem 1.2GiB

=== Best: 7108678 req/s (CPU: 4002.1%, Mem: 1.2GiB) ===
[info] saved results/unary-grpc/1024/zix-grpc.json
httparena-bench-zix-grpc
httparena-bench-zix-grpc
[info] skip: zix-grpc does not subscribe to unary-grpc-tls

==============================================
=== zix-grpc / stream-grpc / 64c (tool=ghz) ===
==============================================
[info] waiting for server...
[info] gRPC server ready
[info] ghz warm-up 2s

[run 1/3]

Summary:
  Count:	8761
  Total:	5.08 s
  Slowest:	814.14 ms
  Fastest:	18.91 ms
  Average:	143.59 ms
  Requests/sec:	1723.81

Response time histogram:
  18.912  [1]    |
  98.436  [2954] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  177.959 [2832] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  257.482 [1825] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  337.005 [605]  |∎∎∎∎∎∎∎∎
  416.528 [186]  |∎∎∎
  496.051 [86]   |∎
  575.574 [27]   |
  655.098 [20]   |
  734.621 [4]    |
  814.144 [2]    |

Latency distribution:
  10 % in 30.16 ms 
  25 % in 45.74 ms 
  50 % in 150.50 ms 
  75 % in 189.56 ms 
  90 % in 272.18 ms 
  95 % in 323.86 ms 
  99 % in 467.57 ms 

Status code distribution:
  [OK]            8542 responses   
  [Canceled]      216 responses    
  [Unavailable]   3 responses      

Error distribution:
  [216]   rpc error: code = Canceled desc = grpc: the client connection is closing                                                                     
  [1]     rpc error: code = Unavailable desc = error reading from server: read tcp 127.0.0.1:28894->127.0.0.1:8080: use of closed network connection   
  [2]     rpc error: code = Unavailable desc = error reading from server: read tcp 127.0.0.1:28922->127.0.0.1:8080: use of closed network connection   
[info] CPU 35.8% | Mem 141MiB

[run 2/3]

Summary:
  Count:	8665
  Total:	5.07 s
  Slowest:	813.42 ms
  Fastest:	19.01 ms
  Average:	144.08 ms
  Requests/sec:	1709.67

Response time histogram:
  19.014  [1]    |
  98.455  [2743] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  177.896 [2972] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  257.336 [1817] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  336.777 [544]  |∎∎∎∎∎∎∎
  416.218 [200]  |∎∎∎
  495.658 [83]   |∎
  575.099 [35]   |
  654.539 [10]   |
  733.980 [9]    |
  813.421 [2]    |

Latency distribution:
  10 % in 30.83 ms 
  25 % in 47.20 ms 
  50 % in 150.82 ms 
  75 % in 189.02 ms 
  90 % in 264.31 ms 
  95 % in 323.08 ms 
  99 % in 464.56 ms 

Status code distribution:
  [OK]         8416 responses   
  [Canceled]   249 responses    

Error distribution:
  [249]   rpc error: code = Canceled desc = grpc: the client connection is closing   
[info] CPU 35.9% | Mem 143MiB

[run 3/3]

Summary:
  Count:	8664
  Total:	5.09 s
  Slowest:	649.98 ms
  Fastest:	19.13 ms
  Average:	145.22 ms
  Requests/sec:	1701.32

Response time histogram:
  19.130  [1]    |
  82.215  [2556] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  145.300 [966]  |∎∎∎∎∎∎∎∎∎∎∎
  208.385 [3504] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  271.470 [832]  |∎∎∎∎∎∎∎∎∎
  334.556 [397]  |∎∎∎∎∎
  397.641 [197]  |∎∎
  460.726 [48]   |∎
  523.811 [23]   |
  586.896 [4]    |
  649.981 [4]    |

Latency distribution:
  10 % in 30.40 ms 
  25 % in 43.03 ms 
  50 % in 157.73 ms 
  75 % in 193.25 ms 
  90 % in 245.69 ms 
  95 % in 308.14 ms 
  99 % in 390.90 ms 

Status code distribution:
  [OK]         8532 responses   
  [Canceled]   132 responses    

Error distribution:
  [132]   rpc error: code = Canceled desc = grpc: the client connection is closing   
[info] CPU 38.3% | Mem 142MiB

=== Best: 8542000 req/s (CPU: 35.8%, Mem: 141MiB) ===
[info] saved results/stream-grpc/64/zix-grpc.json
httparena-bench-zix-grpc
httparena-bench-zix-grpc
[info] skip: zix-grpc does not subscribe to stream-grpc-tls
[info] skip: zix-grpc does not subscribe to echo-ws
[info] skip: zix-grpc does not subscribe to echo-ws-pipeline
[info] rebuilding site/data/*.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/frameworks.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/stream-grpc-64.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/unary-grpc-1024.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/unary-grpc-256.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/current.json
[info] done
[info] restoring loopback MTU to 65536
```
</details>
