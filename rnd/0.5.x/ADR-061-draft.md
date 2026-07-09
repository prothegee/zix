# ADR-061 Draft: REUSEPORT CPU steering (reuseport_cbpf), worker pin completion, and per-worker load counters

Draft for the docs/adr-en.md + docs/adr-id.md entry. Numbers below are from the isolate
bench runs of 2026-07-09 / 2026-07-10 (three states per subject: before, steering off,
steering on).

## ADR-061: REUSEPORT CPU steering (reuseport_cbpf), worker pin completion, and per-worker load counters

**Status:** Accepted

**Context:** The multiplexed engines pin one SO_REUSEPORT worker per core, but the kernel places connections by 4-tuple hash, blind to which CPU received the packets: a connection can land on worker A while its packets soft-irq on CPU B, costing cross-CPU wakeups and cold caches on every request. `zix.Tcp` and `zix.Fix` also predated the pinning convention (their workers ran unpinned), pin order followed the raw affinity mask (SMT siblings interleaved with physical cores), and load balance across workers was unobservable (no per-worker counters).

**Decision:** Three placement moves behind one new flat config field:

- `reuseport_cbpf: bool = false` on every server config except `zix.Uds`: attach SO_ATTACH_REUSEPORT_CBPF to the per-worker REUSEPORT group (`src/multiplexers/reuseport.zig`), placing a new connection (TCP) or each datagram (UDP) at listener index = receiving CPU mod workers instead of the 4-tuple hash. Listeners bind inside racing worker threads, so a startup-only bind-order gate (`BindOrderGate` / `BindTurn`) serializes the joins: group index i = worker i = pin slot i. The turn release is idempotent and defer-backed, so a failed bind never wedges the sibling workers. TLS dual listeners form a second REUSEPORT group with their own attach.
- Pinning completes the family: `zix.Tcp` and `zix.Fix` `.EPOLL` / `.URING` workers now pin per-core with a cpuset-aware worker count, and every engine's pin order fills physical cores first, SMT siblings after (sysfs package/core keys, stable two-pass, mask order kept when sysfs is absent).
- Per-worker load counters report at worker exit through the system logger (requests, frames, accepted connections, or messages, per engine), so REUSEPORT skew across workers is observable. The two h2-mux engines (`zix.Http2`, `zix.Grpc`) carry no counter: a threadlocal increment in their mux dispatch measured about 1 percent of throughput at multi-million req/s and was removed.
- QUIC: `reuseport_cbpf` stays available on `zix.Http3` but is warned against in the field doc comment and the config reference, not rejected. Per-packet CPU steering breaks QUIC flow affinity (a flow's packets land on workers without its connection state), measured as a heavy throughput drop with zero failed requests. Nothing hard-fails, so the guard is documentation, keeping the opt-in contract identical on every engine.

**Rationale:** Default false keeps the kernel hash, which already balances on a loopback box (measured throughput-neutral across the TCP engines). The value case is a multi-CPU host where NIC RSS spreads soft-irqs: steering makes connection placement follow the receiving core, which the per-core pin then serves without a cross-CPU handoff. An opt-in field with a documented QUIC warning preserves the one flat config vocabulary across engines instead of a per-engine exception or a hard error on a field that is valid everywhere else.

**Consequences:**
- Zero hot-path cost: the CBPF program runs in the kernel at placement time (per SYN on TCP, per packet on UDP), and the bind-order gate exists only during the startup binds.
- The counters cost one per-worker-local increment per unit served on six engines, and nothing on the mux engines (cost measured there, so removed there).
- Isolate A/B (before / steering off / steering on, five subjects, three full runs each): steering off is throughput-neutral with lower CPU-at-best on several cells, steering on is neutral on the TCP subjects over loopback and collapses `zix.Http3`, which is recorded as the warning in the field comment and `docs/zix-config-en.md` / `-id.md`.
- Silent no-op on a kernel before 4.5 (no SO_ATTACH_REUSEPORT_CBPF), matching the busy-poll posture.
