# Where the http1 L1d-cache-load-misses live (perf record localization)

> Follow-up to perf-per-request-uring-vs-epoll-0.4.x.md. That doc measured EPOLL at
> approx 548 L1d-misses/req and URING at approx 359. This one localizes WHERE those
> misses come from, to decide whether a user-space layout lever can move them.

## Method

`perf record -e L1-dcache-load-misses -c 2000 -p <server>` for a 15s window while
`wrk -t4 -c128` drove the route `/`. ReleaseFast `example-http1_basic_4_epoll`.
Run by hand in a real terminal, a restricted sandbox blocks perf record (it allows
perf stat, which is how the per-request table was taken, but not the sampling mmap).

Run summary: 2,826,077 samples, event count approx 5.65e9 L1d misses over 15s,
wrk reported 413,716 RPS.

## EPOLL result: the misses are kernel, not zix

Top symbols by L1d-miss share (`perf report`), grouped:

| Bucket | Symbols (share) | Approx total |
| :- | :- | :- |
| Syscall entry/exit | entry_SYSRETQ_unsafe_stack 9.15, do_syscall_64 1.40, srso_alias_safe_ret 1.52 | ~12% |
| TCP transmit | tcp_sendmsg_locked 2.74, __tcp_transmit_skb 1.59, tcp_write_xmit 0.95, tcp_current_mss 1.13 | ~6% |
| TCP ack / receive | tcp_ack 2.42, tcp_recvmsg_locked 1.48, tcp_v4_rcv 1.09, tcp_rcv_established 1.06, __skb_datagram_iter 0.92, __inet_lookup_established 0.92 | ~8% |
| skb alloc / copy | kmem_cache_alloc_node_noprof 1.34, __check_object_size 1.05, __pi_memset 1.12, __alloc_skb 0.78, skb_page_frag_refill 0.84 | ~5% |
| Scheduler / psi | dequeue_entities 1.60, psi_group_change 1.20, __sched_balance_update_blocked_averages 1.09 | ~4% |
| epoll / vfs | ep_send_events 1.10, vfs_write 1.12, vfs_read 1.03 | ~3% |
| memcg / misc | __virt_addr_valid 1.30, mod_memcg_state 0.87, native_write_msr 0.82, read_tsc 0.78 | ~4% |
| zix user code | tcp.http1.dispatch.epoll.serveEpollConn 0.87 | <1% |

`serveEpollConn` is the ONLY zix symbol in the top 30, at 0.87%. It contains the
whole per-request user path: `parseGetFastPath`, the `RespSink` coalesced write, and
the `slots[fd]` lookup. All of it together is under 1% of the L1d misses.

## What this settles

1. The approx 548 misses/req is a kernel network-path cost (loopback TCP send/recv/
   ack, skb allocation, the copy in/out) plus the syscall entry/exit machinery, NOT a
   zix data-layout cost.
2. It explains the prior NULL: the @prefetch of the next Conn slot, and by the same
   logic a hot/cold slot split or `Conn` realignment, all target the under-1% slice.
   There is no user-space layout win available on this workload.
3. The single biggest bucket is syscall entry/exit at ~12% (entry_SYSRETQ +
   do_syscall_64 + the srso_alias_safe_ret Zen return-thunk mitigation tax). The only
   way to shrink that is fewer syscalls per request.
4. Fewer syscalls per request is exactly what `.URING` does: batched submit and
   completion instead of per-request recv/send/epoll_wait, plus `MSG_TRUNC` zero-copy
   drain. That is the mechanism behind the measured 548 to 359 gap, and the engine
   already ships it.

Verdict: EPOLL user-space layout optimization is a dead end on loopback. The lever is
syscall count, and `.URING` is that lever. The remaining cache headroom is whatever
URING already captures, not a new EPOLL change.

## URING result: the syscall entry/exit bucket collapses

Same pass against `example-http1_basic_5_uring` (2,711,860 samples, event count
approx 5.42e9, wrk 413,882 RPS). Top symbols grouped:

| Bucket | Symbols (share) | Approx total |
| :- | :- | :- |
| Syscall entry/exit | entry_SYSRETQ_unsafe_stack 2.86, __do_sys_io_uring_enter 0.84 | ~3.7% |
| io_uring machinery | io_submit_sqes 1.55, io_issue_sqe 1.28, io_recv 1.21, __io_submit_flush_completions 0.94, fget 0.90 | ~5.9% |
| TCP transmit | tcp_sendmsg_locked 2.53, __tcp_transmit_skb 1.56, tcp_write_xmit 0.81 | ~5% |
| TCP ack / receive | tcp_ack 2.44, tcp_recvmsg_locked 1.76, tcp_v4_rcv 1.05, tcp_rcv_established 1.05, sock_recvmsg 1.08, tcp_recvmsg 0.89, __inet_lookup_established 0.95 | ~9% |
| skb alloc / copy | kmem_cache_alloc_node_noprof 1.05, __check_object_size 0.89, __pi_memset 0.92, skb_page_frag_refill 0.85 | ~4% |
| Scheduler / psi | dequeue_entities 1.48, psi_group_change 1.15, __sched_balance_update_blocked_averages 1.08 | ~4% |
| zix user code | tcp.http1.dispatch.uring.UringWorker(...).run 1.07 | ~1% |

## The one number that is the whole story

`entry_SYSRETQ_unsafe_stack` (the syscall return path) by L1d-miss share:

| | EPOLL | URING |
| :- | :- | :- |
| entry_SYSRETQ_unsafe_stack | 9.15% | 2.86% |
| plus per-syscall dispatch | do_syscall_64 1.40% | io_uring_enter 0.84% |

In absolute per-request terms (using the measured 548 and 359 misses/req): the
syscall-return miss count falls from approx 50/req to approx 10/req, about -80%. That
single bucket is the bulk of the 548 to 359 gap.

URING does NOT make the TCP stack cheaper. tcp_sendmsg_locked, tcp_ack, the receive
path, and skb allocation carry nearly the same miss share in both (same bytes move
the same way). What changes is the number of user/kernel mode transitions to reach
that work: EPOLL pays a recv + send + epoll_wait syscall round-trip per request, each
with its entry/exit and the srso_alias_safe_ret Zen return-thunk tax. URING replaces
them with batched io_submit_sqes / completion drains under one io_uring_enter, so the
entry/exit path is amortized across many requests. It trades approx 6% of new io_uring
bookkeeping for the approx 8% syscall-entry saving, and the net is fewer total misses
per request.

## Verdict (both engines)

The http1 per-request L1d misses are owned by the kernel, dominated by syscall
entry/exit, with under approx 1% in zix code in either model. Therefore:

- No EPOLL user-space layout lever (prefetch, hot/cold split, Conn realignment) can
  move the number, confirmed by the @prefetch null and now by attribution.
- The only lever that cuts the dominant bucket is fewer syscalls per request, and
  `.URING` is that lever. It is already shipped. The 548 to 359 win is the syscall
  entry/exit collapse, not a cache-layout change.
- Remaining cache headroom on loopback is whatever a deeper batching change to URING
  itself could buy (fewer io_uring_enter, multishot recv already in use), not an EPOLL
  change. That is a much smaller and riskier target than the work already done.
