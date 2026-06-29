## Benchmark Results

**Framework:** `zix-grpc` | **Test:** `all tests`

| Test | Conn | RPS | CPU | Mem | Δ RPS | Δ Mem |
|------|------|-----|-----|-----|-------|-------|
| unary-grpc | 256 | 7,055,079 | 2624.8% | 382MiB | +0.2% | -2.8% |
| unary-grpc | 1024 | 7,057,470 | 2739.9% | 1.2GiB | +1.7% | ~0% |
| unary-grpc-tls | 256 | 6,976,488 | 2698.8% | 394MiB | NEW | NEW |
| unary-grpc-tls | 1024 | 6,866,824 | 2765.0% | 1.2GiB | NEW | NEW |
| stream-grpc | 64 | 8,371,000 | 39.7% | 130MiB | -1.6% | -6.5% |
| stream-grpc-tls | 64 | 8,235,000 | 53.9% | 140MiB | NEW | NEW |

<details><summary>Full log</summary>

```

Status code distribution:
  [OK]         8371 responses   
  [Canceled]   146 responses    

Error distribution:
  [146]   rpc error: code = Canceled desc = grpc: the client connection is closing   
[info] CPU 39.7% | Mem 130MiB

[run 3/3]

Summary:
  Count:	8449
  Total:	5.07 s
  Slowest:	719.14 ms
  Fastest:	20.22 ms
  Average:	148.05 ms
  Requests/sec:	1667.24

Response time histogram:
  20.221  [1]    |
  90.112  [2526] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  160.004 [1515] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  229.896 [3176] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  299.787 [442]  |∎∎∎∎∎∎
  369.679 [413]  |∎∎∎∎∎
  439.571 [91]   |∎
  509.462 [44]   |∎
  579.354 [15]   |
  649.245 [7]    |
  719.137 [3]    |

Latency distribution:
  10 % in 30.72 ms 
  25 % in 42.51 ms 
  50 % in 161.52 ms 
  75 % in 195.92 ms 
  90 % in 258.66 ms 
  95 % in 324.63 ms 
  99 % in 422.44 ms 

Status code distribution:
  [OK]         8233 responses   
  [Canceled]   216 responses    

Error distribution:
  [216]   rpc error: code = Canceled desc = grpc: the client connection is closing   
[info] CPU 42.6% | Mem 130MiB

=== Best: 8371000 req/s (CPU: 39.7%, Mem: 130MiB) ===
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
  Count:	8427
  Total:	5.05 s
  Slowest:	673.26 ms
  Fastest:	19.85 ms
  Average:	147.16 ms
  Requests/sec:	1667.55

Response time histogram:
  19.847  [1]    |
  85.188  [2384] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  150.529 [1442] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  215.871 [3134] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  281.212 [539]  |∎∎∎∎∎∎∎
  346.553 [470]  |∎∎∎∎∎∎
  411.894 [150]  |∎∎
  477.235 [53]   |∎
  542.576 [16]   |
  607.917 [4]    |
  673.258 [3]    |

Latency distribution:
  10 % in 31.64 ms 
  25 % in 56.01 ms 
  50 % in 155.85 ms 
  75 % in 192.71 ms 
  90 % in 263.62 ms 
  95 % in 315.67 ms 
  99 % in 403.65 ms 

Status code distribution:
  [OK]         8196 responses   
  [Canceled]   231 responses    

Error distribution:
  [231]   rpc error: code = Canceled desc = grpc: the client connection is closing   
[info] CPU 45.8% | Mem 139MiB

[run 2/3]

Summary:
  Count:	8465
  Total:	5.06 s
  Slowest:	1.03 s
  Fastest:	20.26 ms
  Average:	146.23 ms
  Requests/sec:	1673.93

Response time histogram:
  20.264   [1]    |
  120.984  [3276] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  221.703  [3715] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  322.423  [741]  |∎∎∎∎∎∎∎∎
  423.142  [324]  |∎∎∎
  523.862  [125]  |∎
  624.581  [30]   |
  725.301  [11]   |
  826.020  [3]    |
  926.740  [1]    |
  1027.460 [1]    |

Latency distribution:
  10 % in 32.02 ms 
  25 % in 51.73 ms 
  50 % in 150.79 ms 
  75 % in 191.39 ms 
  90 % in 268.69 ms 
  95 % in 337.99 ms 
  99 % in 492.85 ms 

Status code distribution:
  [OK]            8228 responses   
  [Canceled]      236 responses    
  [Unavailable]   1 responses      

Error distribution:
  [236]   rpc error: code = Canceled desc = grpc: the client connection is closing                                                                     
  [1]     rpc error: code = Unavailable desc = error reading from server: read tcp 127.0.0.1:64806->127.0.0.1:8443: use of closed network connection   
[info] CPU 48.6% | Mem 140MiB

[run 3/3]

Summary:
  Count:	8484
  Total:	5.06 s
  Slowest:	758.48 ms
  Fastest:	20.01 ms
  Average:	145.93 ms
  Requests/sec:	1675.89

Response time histogram:
  20.010  [1]    |
  93.857  [2487] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  167.704 [2612] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  241.552 [2087] |∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎∎
  315.399 [653]  |∎∎∎∎∎∎∎∎∎∎
  389.246 [262]  |∎∎∎∎
  463.093 [93]   |∎
  536.941 [31]   |
  610.788 [8]    |
  684.635 [0]    |
  758.482 [1]    |

Latency distribution:
  10 % in 32.01 ms 
  25 % in 56.77 ms 
  50 % in 151.64 ms 
  75 % in 190.08 ms 
  90 % in 265.98 ms 
  95 % in 313.16 ms 
  99 % in 426.52 ms 

Status code distribution:
  [OK]         8235 responses   
  [Canceled]   249 responses    

Error distribution:
  [249]   rpc error: code = Canceled desc = grpc: the client connection is closing   
[info] CPU 53.9% | Mem 140MiB

=== Best: 8235000 req/s (CPU: 53.9%, Mem: 140MiB) ===
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
