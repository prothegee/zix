# A2 URING idle-pool reclaim: four-way per-cell results (0.4.x)

Per-cell results for the four idle-pool approaches tried for A2, on the
12-load-thread isolate bench (`benchmark-httparena-lite-isolate zix_http_uring
--source local --probe --sample-mem --load-threads 12`). Each cell entry is
`req/s / peak MiB`, where the memory is the framework container cgroup peak
sampled during that cell. The whole-run sampler memory is in the second table.

The four ways:

| Tag | Idle pool on close |
| :- | :- |
| pre-A2 | unbounded: closed connections pooled with buffers resident, never reclaimed |
| flat-256 | flat cap 256, madvise the released connection past the cap |
| adaptive | cap = max(live_count, 64), madvise the released connection past the cap |
| cold-tail | warm MRU head / LRU tail pool, evict and madvise the LRU tail past max(live_count, 64) |

Run identity and noise floor (probe gate, all under the 1% bar so all are
trustworthy):

| Tag | result file | probe |
| :- | :- | -: |
| pre-A2 | isolate-zix_http_uring-20260620-140939.txt | 0.05% |
| flat-256 | isolate-zix_http_uring-20260620-145235.txt | 0.30% |
| adaptive | isolate-zix_http_uring-20260620-152648.txt | 0.07% |
| cold-tail | isolate-zix_http_uring-20260620-155056.txt | 0.26% |

## Per-cell: req/s / peak MiB

| Cell | pre-A2 | flat-256 | adaptive | cold-tail |
| :- | -: | -: | -: | -: |
| baseline 512 | 560,517 / 26 | 573,863 / 25 | 555,013 / 26 | 557,005 / 26 |
| baseline 4096 | 449,171 / 85 | 436,102 / 84 | 442,760 / 83 | 436,914 / 82 |
| pipelined 512 | 6,747,328 / 25 | 6,930,576 / 25 | 6,815,606 / 25 | 6,837,161 / 24 |
| pipelined 4096 | 5,007,696 / 80 | 4,958,789 / 81 | 4,966,786 / 80 | 4,924,009 / 81 |
| limited-conn 512 | 357,254 / 44 | 352,737 / 42 | 313,076 / 39 | 353,250 / 32 |
| limited-conn 4096 | 329,257 / 137 | 308,022 / 118 | 307,831 / 126 | 326,997 / 111 |
| json 4096 | 305,192 / 180 | 292,429 / 135 | 295,357 / 149 | 300,008 / 128 |
| upload 32 | 2,224 / 22 | 2,228 / 26 | 2,256 / 27 | 2,278 / 23 |
| upload 256 | 2,161 / 34 | 2,264 / 29 | 2,228 / 24 | 2,275 / 29 |
| static 1024 | 237,265 / 36 | 236,594 / 37 | 236,662 / 37 | 233,680 / 36 |
| static 4096 | 205,541 / 92 | 206,618 / 91 | 209,400 / 92 | 205,140 / 92 |
| static 6800 | 195,535 / 128 | 195,354 / 127 | 197,879 / 135 | 196,409 / 125 |

Tool per cell: gcannon for baseline, pipelined, limited-conn, json, upload, wrk
for static.

## Whole-run sampler memory (MiB)

| Metric | pre-A2 | flat-256 | adaptive | cold-tail |
| :- | -: | -: | -: | -: |
| peak total | 188.0 | 131.2 | 144.2 | 121.9 |
| steady median | 38.9 | 36.5 | 33.2 | 32.2 |
| anon median | 22.2 | 21.4 | 19.5 | 13.5 |

## Notes

- The churn cell (limited-conn) is the gate sentinel. flat-256 and adaptive
  regressed it (4096c -6.4% and 512c -12.4% versus pre-A2) by reclaiming the
  released, most-recently-used connection. cold-tail reclaims the
  least-recently-used tail instead, bringing both cells back into the noise band
  (512c -1.1%, 4096c -0.7%) while shedding the most per-cell memory (limited-conn
  4096c 137 to 111MiB, json 180 to 128MiB).
- cold-tail is the best on all three whole-run memory metrics, steady anon down to
  13.5MiB (closing on the EPOLL anon median of about 8MiB).
- This box has ~2 to 3% whole-run variance, so it confirms the churn regression is
  gone and the memory win is real but cannot resolve the sub-1% throughput sign-off.
  That is owed on the 64-core gate.
