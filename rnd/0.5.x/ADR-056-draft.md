# ADR-056 draft: HTTP/3 hot-path loss recovery, congestion control, and real per-core .EPOLL / .URING

Lean note (proposal). The full record is proposed for `docs/adr-en.md` / `docs/adr-id.md` as ADR-056 on acceptance. Extends ADR-049, ADR-050, ADR-051.

**Status:** Proposed

## Decision in one line

Bring RFC 9002 loss recovery and NewReno congestion control into the `zix.Http3` serving hot path (a timer-driven maintenance sweep, a Probe Timeout that retransmits but does NOT cut the congestion window per RFC 9002 6.2), reclaim a connection slot only on CONNECTION_CLOSE or idle-timeout (never on loss) with tombstone slot reuse, and run `.EPOLL` / `.URING` as real per-core SO_REUSEPORT workers (`.URING` a genuine io_uring ring) instead of folding to the v1 single worker.

## Why

ADR-051 shipped HTTP/3 v1 as one single-worker demux with loss-and-congestion deferred, and `.EPOLL` / `.URING` folded to that worker. Under sustained multi-connection large-body load one worker is the throughput ceiling, and without loss recovery a dropped tail packet stalls a response (no later packet acks it, so nothing re-pumps the tail). The fix serves per-core (one SO_REUSEPORT worker per core, the kernel load-balancing by 4-tuple, each worker owning its own CID table) and runs the recovery / congestion machinery the deterministic `recovery.zig` layer already carried, on the serve path.

## Shape

- Loss recovery + NewReno on the serve path: `recovery.zig` (RttEstimator, PTO with backoff, `CongestionController.onCongestionEvent`, persistent congestion), driven by `connection.onAckFrame`. Only ack-detected loss cuts the congestion window.
- Timer-driven maintenance sweep: `common.sweepMaintenance` every `maintenance_interval_us` (5 ms), armed by a bounded `epoll_wait` timeout (`.EPOLL`) and a timeout SQE (`.URING`). It declares a timed-out in-flight range lost and re-pumps it.
- A Probe Timeout is not a congestion signal: `connection.onMaintenance` retransmits and bumps `pto_backoff` only. It does NOT reduce cwnd (RFC 9002 6.2). A prior attempt that halved cwnd on every PTO collapsed the window and pinned connections congestion-window-blocked, and was reverted.
- Eviction policy: `onMaintenance` frees a connection (via `demux.remove`) only when `close_state` is draining or closed (CONNECTION_CLOSE, frames 0x1c / 0x1d) or the peer has been idle past `max_idle_ms`. Loss never evicts a live-but-lossy peer.
- Table slot reuse: `demux` gained `remove` / `freeSlot` / `at` / `occupied[]` with a tombstone sentinel, so a reclaimed slot is reused without growing the index.
- Per-core `.EPOLL` / `.URING`: `server.run` routes `.POOL` / `.MIXED` / `.EPOLL` / `.URING` to multi-core workers (`common.runMulti` / `runEpoll` / `runUring`), only `.ASYNC` stays single-core. `.URING` is a real io_uring ring (recvmsg SQEs plus ring sendmsg through `SendBatch.submitUring`), falling back to the `.EPOLL` loop when io_uring is unavailable.
- Real io_uring datagram ring plus GSO also for `zix.Udp` raw (ADR-049 phase two): `src/udp/dispatch/uring.zig` a real recv ring, `datagram.zig` GSO (UDP_SEGMENT) via `probeGso` / `flushGso` / `submitUringGso`.

## Landed

- `src/udp/http3/`: `connection.zig` (`onMaintenance`, `pto_backoff`, `Maintenance`, `last_activity_us`, `peer_addr`), `demux.zig` (`remove` / `at` / `freeSlot` / tombstone), `dispatch/common.zig` (`sweepMaintenance`, `resumeStreams`, CONNECTION_CLOSE arm, liveness stamps), `dispatch/epoll.zig` and `dispatch/uring.zig` (bounded timeout plus sweep, real ring).
- `src/udp/dispatch/uring.zig` (real recv ring) and `datagram.zig` (GSO plus `submitUring`).
- Green on Zig 0.16 and 0.17. Correctness gate: full-body byte-exact under heavy fragmentation (~218 packets per response) plus recovery after an overload burst.

## Supersedes and relation

- ADR-051: supersedes ".EPOLL / .URING fold to the v1 worker" (now real per-core) and the "loss-and-congestion in the hot path" deferral (now shipped). Cross-core CID steering for mid-connection migration remains the only v2 item.
- ADR-049: lands phase two (dedicated io_uring submission path behind `.URING` plus GSO) for `zix.Udp` raw. GRO / ECN stay deferred. Corrects the ".POOL / .MIXED run a single worker" wording (now multi-core).
- ADR-050: closes the "zix.Udp raw .POOL / .MIXED aliasing to a single worker" gap (both multi-core via `runMulti`). This ADR is the second consumer that makes ADR-050's Proposed contract real, so ADR-050 can move to Accepted.

## Deferred

Send pacing to spread a congestion window over the RTT instead of one burst (the residual `.EPOLL` throughput gap under sustained large-body load, `.URING` paces implicitly through completions), cross-core CID steering (eBPF) for mid-connection migration, GRO / ECN, key update.
