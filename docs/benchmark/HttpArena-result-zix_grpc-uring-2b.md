## Benchmark Results

**Framework:** `zix-grpc` | **Test:** `all tests`

| Test | Conn | RPS | CPU | Mem | Δ RPS | Δ Mem |
|------|------|-----|-----|-----|-------|-------|
| unary-grpc | 256 | 0 | 0.0% | 0MiB | -100.0% | -100.0% |
| unary-grpc | 1024 | 7,128,735 | 2789.3% | 1.2GiB | +2.7% | ~0% |
| unary-grpc-tls | 256 | 6,992,067 | 2675.8% | 397MiB | NEW | NEW |
| unary-grpc-tls | 1024 | 6,936,455 | 2816.6% | 1.2GiB | NEW | NEW |
| stream-grpc | 64 | 8,300,000 | 42.8% | 132MiB | -2.4% | -5.0% |
| stream-grpc-tls | 64 | 8,375,000 | 48.0% | 144MiB | NEW | NEW |

<details><summary>Full log</summary>

```
  [OK]         8192 responses   
  [Canceled]   250 responses    

Error distribution:
  [250]   rpc error: code = Canceled desc = grpc: the client connection is closing   
[info] CPU 40.2% | Mem 132MiB

[run 3/3]

Summary:
  Count:	8510
  Total:	5.05 s
  Slowest:	802.46 ms
  Fastest:	19.80 ms
  Average:	146.45 ms
  Requests/sec:	1683.76

Response time histogram:
  19.802  [1]    |
  98.068  [2864] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  176.334 [2490] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  254.601 [1957] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  332.867 [486]  |∎∎∎∎∎∎∎
  411.133 [312]  |∎∎∎∎
  489.399 [102]  |∎
  567.665 [48]   |∎
  645.931 [20]   |
  724.197 [15]   |
  802.463 [5]    |

Latency distribution:
  10 % in 31.32 ms 
  25 % in 47.53 ms 
  50 % in 151.95 ms 
  75 % in 190.65 ms 
  90 % in 277.75 ms 
  95 % in 344.58 ms 
  99 % in 492.28 ms 

Status code distribution:
  [OK]         8300 responses   
  [Canceled]   210 responses    

Error distribution:
  [210]   rpc error: code = Canceled desc = grpc: the client connection is closing   
[info] CPU 42.8% | Mem 132MiB

=== Best: 8300000 req/s (CPU: 42.8%, Mem: 132MiB) ===
[info] saved results/stream-grpc/64/zix-grpc.json
httparena-bench-zix-grpc
httparena-bench-zix-grpc

==============================================
=== zix-grpc / stream-grpc-tls / 64c (tool=ghz) ===
==============================================
[info] waiting for server...
[info] gRPC server ready
[info] ghz warm-up 2s

[run 1/3]

Summary:
  Count:	8432
  Total:	5.06 s
  Slowest:	793.53 ms
  Fastest:	18.48 ms
  Average:	147.21 ms
  Requests/sec:	1665.32

Response time histogram:
  18.477  [1]    |
  95.983  [2703] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  173.488 [2496] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  250.993 [1967] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  328.499 [603]  |∎∎∎∎∎∎∎∎∎
  406.004 [248]  |∎∎∎∎
  483.510 [94]   |∎
  561.015 [40]   |∎
  638.520 [16]   |
  716.026 [7]    |
  793.531 [5]    |

Latency distribution:
  10 % in 32.01 ms 
  25 % in 51.65 ms 
  50 % in 152.71 ms 
  75 % in 192.91 ms 
  90 % in 274.26 ms 
  95 % in 328.68 ms 
  99 % in 470.68 ms 

Status code distribution:
  [OK]            8180 responses   
  [Canceled]      251 responses    
  [Unavailable]   1 responses      

Error distribution:
  [251]   rpc error: code = Canceled desc = grpc: the client connection is closing                                                                     
  [1]     rpc error: code = Unavailable desc = error reading from server: read tcp 127.0.0.1:35368->127.0.0.1:8443: use of closed network connection   
[info] CPU 47.7% | Mem 144MiB

[run 2/3]

Summary:
  Count:	8558
  Total:	5.08 s
  Slowest:	662.56 ms
  Fastest:	19.84 ms
  Average:	146.20 ms
  Requests/sec:	1683.44

Response time histogram:
  19.837  [1]    |
  84.109  [2324] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  148.381 [1495] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  212.653 [3283] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  276.924 [601]  |∎∎∎∎∎∎∎
  341.196 [451]  |∎∎∎∎∎
  405.468 [135]  |∎∎
  469.740 [47]   |∎
  534.012 [28]   |
  598.284 [7]    |
  662.556 [3]    |

Latency distribution:
  10 % in 31.49 ms 
  25 % in 62.27 ms 
  50 % in 154.16 ms 
  75 % in 190.67 ms 
  90 % in 253.21 ms 
  95 % in 310.47 ms 
  99 % in 408.04 ms 

Status code distribution:
  [OK]            8375 responses   
  [Canceled]      182 responses    
  [Unavailable]   1 responses      

Error distribution:
  [182]   rpc error: code = Canceled desc = grpc: the client connection is closing                                                                     
  [1]     rpc error: code = Unavailable desc = error reading from server: read tcp 127.0.0.1:35914->127.0.0.1:8443: use of closed network connection   
[info] CPU 48.0% | Mem 144MiB

[run 3/3]

Summary:
  Count:	8538
  Total:	5.05 s
  Slowest:	656.06 ms
  Fastest:	19.82 ms
  Average:	146.36 ms
  Requests/sec:	1689.26

Response time histogram:
  19.818  [1]    |
  83.443  [2419] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  147.067 [1196] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  210.692 [3298] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  274.316 [659]  |∎∎∎∎∎∎∎∎
  337.941 [458]  |∎∎∎∎∎∎
  401.565 [168]  |∎∎
  465.189 [60]   |∎
  528.814 [30]   |
  592.438 [9]    |
  656.063 [6]    |

Latency distribution:
  10 % in 31.03 ms 
  25 % in 47.43 ms 
  50 % in 156.93 ms 
  75 % in 191.82 ms 
  90 % in 262.05 ms 
  95 % in 316.68 ms 
  99 % in 422.68 ms 

Status code distribution:
  [OK]         8304 responses   
  [Canceled]   234 responses    

Error distribution:
  [234]   rpc error: code = Canceled desc = grpc: the client connection is closing   
[info] CPU 53.1% | Mem 144MiB

=== Best: 8375000 req/s (CPU: 48.0%, Mem: 144MiB) ===
[info] saved results/stream-grpc-tls/64/zix-grpc.json
httparena-bench-zix-grpc
httparena-bench-zix-grpc
[info] skip: zix-grpc does not subscribe to echo-ws
[info] skip: zix-grpc does not subscribe to echo-ws-pipeline
[info] rebuilding site/data/*.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/frameworks.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/stream-grpc-64.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/stream-grpc-tls-64.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/unary-grpc-1024.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/unary-grpc-256.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/unary-grpc-tls-1024.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/unary-grpc-tls-256.json
[updated] /home/diogo/actions-runner/_work/HttpArena/HttpArena/site/data/current.json
[info] done
[info] restoring loopback MTU to 65536
```
</details>
