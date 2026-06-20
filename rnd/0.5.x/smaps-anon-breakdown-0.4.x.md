# Anon RSS breakdown: EPOLL vs URING (zix.Http1, 0.4.x)

Source records for the per-mapping anonymous memory split of the two native
Linux dispatch models, parsed from the full `/proc/pid/smaps` dumps captured by
the isolate bench (`--sample-mem`) on the 2026-06-20 12-load-thread run.

Run identity:

| Field | EPOLL | URING |
| :- | :- | :- |
| smaps file | isolate-smaps-zix_http_epoll-20260620-140149.txt | isolate-smaps-zix_http_uring-20260620-140939.txt |
| pid | 153559 | 196143 |
| load-threads | 12 | 12 |
| probe gate | 0.10% (PASS) | 0.05% (PASS) |
| total Rss at peak | 36.9MiB | 157.5MiB |
| total Anonymous at peak | 36.5MiB | 150.9MiB |

The peak smaps snapshot lines up with the sampler summary (EPOLL anon median
8.1MiB / peak 106.6MiB total, URING anon median 22.2MiB / peak 188.0MiB total).
The numbers below are the single peak smaps frame, not the median.

## Anon mapping groups

Every byte of anonymous RSS lives under the `[anon]` label on both engines (the
`anon_inode:[io_uring]` ring region, 6.2MiB on URING, is inode-backed and is not
counted as anonymous). The difference is entirely in how the `[anon]` total is
shaped.

| Engine | [anon] regions | [anon] Rss MiB |
| :- | -: | -: |
| EPOLL | 17 | 36.5 |
| URING | 690 | 150.9 |

## Size histogram with residency

EPOLL: a few huge demand-paged reservations, almost none of it resident.

| Bucket | Count | vsz MiB | Rss MiB | Resident |
| :- | -: | -: | -: | -: |
| >=8MiB | 11 | 3167.2 | 34.9 | 1% |
| 1-8MiB | 2 | 5.2 | 0.6 | 12% |
| 256k-1M | 3 | 2.0 | 1.0 | 49% |
| 64-256k | 2 | 0.2 | 0.1 | 24% |
| <64k | 2 | 0.0 | 0.0 | 43% |

URING: many mostly-resident blocks, two distinct shapes (a few big grown send
buffers and a long tail of per-connection buffers).

| Bucket | Count | vsz MiB | Rss MiB | Resident |
| :- | -: | -: | -: | -: |
| >=8MiB | 4 | 81.4 | 56.3 | 69% |
| 1-8MiB | 23 | 88.4 | 27.6 | 31% |
| 256k-1M | 64 | 25.1 | 15.4 | 61% |
| 64-256k | 600 | 68.2 | 51.6 | 76% |
| <64k | 2 | 0.0 | 0.0 | 43% |

## Top individual anon regions by Rss

EPOLL (the big reservations are the per-worker contiguous slab and slots, each
~264 to 527MiB reserved, ~3MiB touched):

| Region | perm | vsz MiB | Rss MiB |
| :- | :- | -: | -: |
| [anon] | rw-p | 527.1 | 5.4 |
| [anon] | rw-p | 264.4 | 3.1 |
| [anon] | rw-p | 264.4 | 3.1 |
| [anon] | rw-p | 264.4 | 3.0 |
| [anon] | rw-p | 264.4 | 3.0 |
| [anon] | rw-p | 264.4 | 3.0 |
| [anon] | rw-p | 264.4 | 3.0 |
| [anon] | rw-p | 264.4 | 2.9 |

URING (the >=8MiB blocks are grown RespSink send buffers, the rest is the
per-connection recv and send buffers held on the idle pool):

| Region | perm | vsz MiB | Rss MiB |
| :- | :- | -: | -: |
| [anon] | rw-p | 39.1 | 28.5 |
| [anon] | rw-p | 17.5 | 12.0 |
| [anon] | rw-p | 11.4 | 8.4 |
| [anon] | rw-p | 13.4 | 7.4 |
| [anon] | rw-p | 6.7 | 4.9 |
| [anon] | rw-p | 4.4 | 3.4 |
| [anon] | rw-p | 4.5 | 3.4 |
| [anon] | rw-p | 3.9 | 3.0 |

## Reading

EPOLL reserves big and touches little: 3.1 GiB of virtual address space across 11
mappings, only 34.9MiB resident (1%). That is the slab design working as
intended, one contiguous demand-paged mmap per worker, the kernel faults only the
live working set, and `slab.releaseSlabPages` (MADV_DONTNEED) returns pages on
close, so resident memory tracks live connections.

URING has the opposite shape: 690 separate general-allocator mappings, the top
ones 69 to 76% resident. Two culprits account for the 150.9MiB:

- The 600 mappings in the 64-256k bucket (~52MiB resident) are per-connection
  recv and send buffers held on the idle pool (`free_list`) after close. There is
  no page-return on the URING close path, so resident memory tracks the lifetime
  high-water of concurrent connections, not the live count.
- The 4 mappings in the >=8MiB bucket (~56MiB resident) are RespSink send buffers
  that the grow allocator doubled to serve an oversized response and never shrank
  (`grow` never shrinks, and `dispatch` adopts the grown buffer back onto the
  connection at `conn.send_buf = sink.buf`).

This is the evidence base for the A2 lever (URING idle-pool bound and send_buf
cap). See the issue comment for the confirmed close path and the lever sketch.
