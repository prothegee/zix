# ADR-049 (proposal record)

> This is part of 0.5.x

Lean note. The full decision lives in `docs/adr-en.md` / `docs/adr-id.md` (ADR-049). This file keeps
the rnd-only rationale and the agreed scope: the implementation phasing, the deferral reasons, and
the test-harness gotcha that are not carried into the public ADR.

## Objective
Grow `zix.Udp` from a fixed-struct datagram messaging engine into a production datagram transport,
so it earns its keep for any high-throughput UDP workload and becomes a fit substrate for the later
QUIC / HTTP3 work (Layer I of `http3-plan.md`). Today every datagram must be exactly one
`@sizeOf(Packet)` extern struct, sent and received one syscall at a time, with no dispatch model.

## Decision (summary)
Two parts, both backward compatible.

1. Typed mode `Server(comptime Packet)` keeps its current contract and gains the scaling knobs the
   TCP family already has. No existing field changes meaning, no behavior changes by default.
2. A new raw-bytes mode `Raw(comptime handler)` is added: variable-length datagrams up to the path
   MTU, a user handler over `[]const u8` plus the peer address, replies through a batching sink. No
   `Packet` struct, no `endianness`, no built-in ack / echo / broadcast.

The raw mode is the genuinely new public surface. It is useful on its own (echo, DNS-style,
telemetry / game servers that do not want the fixed-struct contract) and is the substrate QUIC sits
on later. QUIC-specific machinery (Destination Connection ID demux, per-connection crypto and
transport state, connection-id worker steering) stays OUT of `zix.Udp` and lives in
`src/udp/http3/`.

## Config diff (against `UdpServerConfig`)

Added (generic transport, names aligned to the TCP base in `src/tcp/config.zig`):

| Field | Purpose |
| :- | :- |
| `dispatch_model: DispatchModel = .ASYNC` | reuse the shared enum, EPOLL / URING per-core (today: none) |
| `workers: usize = 0` | one pinned worker per CPU when 0 |
| `reuse_address: bool = false` | SO_REUSEPORT, kernel fans datagrams across workers |
| `recv_batch: usize` | recvmmsg: datagrams per syscall (the `server.zig:232` PERF TODO) |
| `send_batch: usize` | sendmmsg: coalesce the reply / broadcast fan-out |
| `max_recv_buf: usize` | raw mode only: MTU-sized buffer (typed mode keeps `@sizeOf(Packet)`) |

Changed (scope, not rename, to keep typed code working):

| Item | Change |
| :- | :- |
| `endianness`, `auto_ack`, `auto_echo`, `broadcast`, `error_report` | apply to typed mode only, no meaning in raw mode |
| `allocator` "no arena, per-packet snapshots" caveat | raw mode allocates a per-worker buffer / connection pool, not a per-packet heap snapshot |

Unchanged: `io`, `ip`, `port`, `allow_args`, `logger`, the timeout fields.

Not added: `kernel_backlog`. UDP has no `listen()` backlog, so the TCP field does not carry over.
Stated here so nobody mirrors it blindly.

## Raw API shape
Pattern-A (handler baked into the type, `run()` takes no args), the same as `zix.Tcp` / `zix.Http1`.

```zig
/// Raw datagram handler: the bytes as received, the peer, and a sink to reply through.
/// Param:
/// dg - []const u8 (the datagram, up to max_recv_buf)
/// peer - the sender address
/// sink - reply queue, coalesced into one sendmmsg per received batch
fn handler(dg: []const u8, peer: *const std.Io.net.IpAddress, sink: *zix.Udp.Sink) void {
    sink.replyTo(peer, dg);
}

const EchoServer = zix.Udp.Raw(handler);
```

The `Sink` makes batching invisible: every `reply` / `replyTo` during one received batch leaves as a
single sendmmsg (GSO-segmented when enabled), replacing today's one `send()` per reply.

## Why this lands before QUIC / HTTP3
The batched, variable-length, ECN-aware, per-core datagram path is a prerequisite for a serious QUIC
engine and is independently valuable. Building it as a clean `zix.Udp` capability first keeps the
QUIC layer focused on transport semantics (DCID demux, crypto, streams) instead of reaching around a
fixed-struct messaging toy. This is the honest reading of "src/udp/http3 on zix.Udp".

## Open questions (to settle before code)
- Raw handler reply: a `*Sink` (shown) versus a return-value style. The sink wins for batching and
  for handlers that reply to peers other than the sender, at the cost of one more parameter.
- Whether the typed and raw modes share one event loop or keep separate `run()` paths per dispatch
  model. Leaning shared loop, raw versus typed chosen at the buffer / decode step.

## Dispatch model
`dispatch_model` is functional on the raw path and partitioned per ADR-043, the same as
`src/tcp/http1/`: a `src/udp/dispatch/` folder with one file per model plus `common.zig`, and a thin
`run()` switch in `raw.zig`. The mapping for phase 1:

| Model | Raw behavior |
| :- | :- |
| `.ASYNC` (default), `.POOL`, `.MIXED` | single recvmmsg worker on the calling thread (`runSingle`) |
| `.EPOLL`, `.URING` | one SO_REUSEPORT recvmmsg worker per CPU (`runPerCore`) |

`.URING` folds to the recvmmsg per-core loop with a logged notice, exactly as `zix.Http2` folds
EPOLL / URING to POOL. A dedicated io_uring submission path (multishot recv, registered buffers)
replaces that fold in a later phase.

### Per-core model is stateless fan-out
The `.EPOLL` / `.URING` per-core mapping uses plain SO_REUSEPORT, so the kernel routes datagrams by
4-tuple hash. This is correct only when any worker can handle any datagram (echo, DNS-style,
telemetry). It is not safe for connection-oriented protocols that need datagram-to-owner affinity: a
QUIC connection migration changes the 4-tuple, so a migrated datagram can hash to a worker that does
not hold the connection state. Such protocols either run the single-worker shape and demux internally
(HTTP/3 v1), or use the phase 3 steering hook. The per-core model never inspects the payload, the
affinity policy lives in the upper layer.

## Phase 2 (deferred)
- A dedicated io_uring submission path behind `.URING` (today it folds to the recvmmsg loop).
- GSO (`UDP_SEGMENT`), GRO (`UDP_GRO`), and ECN (`IP_TOS` / `IP_RECVTOS`). They need per-send /
  per-recv ancillary-data (cmsg) paths whose correctness depends on hardware this box cannot
  validate. GRO in particular coalesces several datagrams into one buffer, so enabling it without a
  correct splitter would hand a datagram handler a wrong super-datagram. Added once a cmsg path can
  be hardware-tested.

## Phase 3 (deferred): connection-affinity steering
Adds an optional `steering` knob to `UdpServerConfig` so the per-core models route by a
protocol-supplied byte-range key instead of the 4-tuple hash. The mechanism is an SO_REUSEPORT eBPF
program parameterized by `(key_offset, key_len)`. `zix.Udp` stays protocol-agnostic: it hashes an
opaque byte range, it never learns what a Connection ID is. HTTP/3 supplies the range pointing at its
fixed-length DCID, which keeps the existing boundary that CID demux lives in `src/udp/http3/`.
No-eBPF fallback: per-core workers forward a non-owned datagram to the owner worker over an
in-process queue (one extra hop per misroute). On macOS, Windows, or Linux without eBPF the per-core
models fold to the v1 demux path with a logged notice. Independent of phase 2.

## Status: phase 1 landed (2026-06-24)
- `src/udp/datagram.zig`: raw-fd socket, recvmmsg (MSG_WAITFORONE) + sendmmsg batches, SO_REUSEPORT,
  address conversion. `src/udp/core.zig`: `HandlerFn` + `Sink`. `src/udp/dispatch/`: `common.zig`
  (worker loop, `runSingle` / `runPerCore` / fallback) + one file per model. `src/udp/raw.zig`:
  `Raw(handler)` thin facade + `run()` switch.
- `zix.Udp.Raw` / `zix.Udp.Sink` / `zix.Udp.HandlerFn` / `zix.Udp.DispatchModel` exported.
- Typed `Server(Packet)` keeps its single async receive loop. The new config fields are additive,
  and a non-ASYNC `dispatch_model` on the typed path folds with a logged notice (not a silent
  no-op), since the per-core models belong to the raw path.
- Example `examples/udp_server_raw.zig` (port 9064, `.ASYNC` shown explicitly), runner
  `tests/runner/udp_raw_runner.zig`, plus a `udp-raw` case in `all_runner.zig`. Green on Zig 0.16 +
  0.17 across unit-test, `test-runner-udp-raw`, and `test-runner-all` (60 protocols).

## Gate
unit-test + the `test-runner-udp-raw` end-to-end echo (send a datagram, assert the exact bytes echo
back) pass on Zig 0.16 and 0.17. A throughput / memory check on the raw path follows the isolate-
bench discipline, not loopback noise, when the perf work begins.
