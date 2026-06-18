# ADR-041 (proposal record)

> This is part of 0.4.x-rc3

## Objective
Make the `.URING` dispatch competitive with (and ideally close the gap) `.EPOLL`. The original framing was a write-path split (move every write fully on-ring, comptime write strategies, multishot recv). The 64-core data forced a pivot: the composite is gated by connection-churn cells, not the write path. This record now tracks both the original write-path items and the churn-scaling pivot, with the honest status of each.

## Background
Benchmark v2 cut memory 45-73% across all cells but regressed large-response and high-connection cells. The first read blamed the `.URING` write path: responses larger than the 16 KiB send buffer fell back to off-ring blocking writes (`fdWriteAllDirect`) that stall the whole ring worker. That diagnosis produced increments 1 and 2 below.

The 64-core run (the real competition box) then showed the write path is not what gates the composite. See the pivot section.

## The pivot (64-core finding)
On the 64c box, `.URING` vs `.EPOLL` splits cleanly by reqs-per-connection (inverse of churn):

| cell | reqs/conn | URING vs EPOLL | URING cores busy |
| :- | :- | :- | :- |
| pipelined | unlimited | +9 to +13% | ~64 / 64 |
| baseline | unlimited | +14 to +20% | ~64 / 64 |
| static | persistent | -1 to -2% (tie) | ~55 / 64 |
| json | 25 | -73% | 13 / 64 |
| limited-conn | 10 | -87% | 7 / 64 |

Per-core throughput is equal or better for URING (limited-conn 47.7k/core vs EPOLL 44.3k/core). URING is not slow per unit work, it cannot get cores busy when connections churn. The composite is dragged down entirely by json and limited-conn, and the write-path items do not touch them (static already ties). So the make-or-break lever for HttpArena is connection setup and teardown scaling, not the write path.

## Outcome (64-core, validated)
The churn ring close was measured on the 64-core box, `.URING` vs `.EPOLL`, identical handler. It worked. The churn cells that held `.URING` back recovered, and `.URING` now reaches parity or better on every cell at a fraction of the memory, closing the gap that kept it off the public entry.

| cell | URING vs EPOLL (now) | before (pivot) | URING mem vs EPOLL |
| :- | :- | :- | :- |
| baseline 512 / 4096 | +13.0% / +18.7% | +14 to +20% | 134 vs 342, 185 vs 395 MiB |
| pipelined 512 / 4096 | +6.9% / +10.2% | +9 to +13% | about 50% less |
| limited-conn 512 | +5.5% | -87% | 152 vs 485 MiB |
| limited-conn 4096 | -1.5% | -87% | 231 MiB vs 1.5 GiB |
| json 4096 | -2.4% | -73% | 289 MiB vs 1.3 GiB |
| static (all) | -0.6 to -1.3% | -1 to -2% | about 50% less |
| upload 32 / 256 | -1.9% / +1.9% | tie | about 60% less |

Mechanism confirmed: on limited-conn 512 the server CPU rose from about 722% (around 7 of 64 cores) to about 5443% (around 54 cores). The synchronous `close` was the bottleneck. With `prep_close` the worker keeps reaping completions across teardowns, so the cores fill, exactly as the pivot diagnosed. The absolute jump on the churn cells is large: limited-conn went from about 343k to about 2.72M (around 8x), json from about 638k to about 2.36M (around 3.7x).

Decision: ship `.URING` as the HttpArena entry. The single reason the public entry ran `.EPOLL` (the churn collapse) is gone, and `.EPOLL` barely moved this release. The two kept changes (increment 1 grow plus the ring close) carry the result, with the ring close doing the heavy lifting on the churn cells. This validates the pivot: churn scaling, not the write path, was the lever that closed the gap, which is why increments 2 to 4 were correctly deprioritized or reverted.

## Increment ledger (current state)

| # | item | status | local 12t result |
| :- | :- | :- | :- |
| 1 | inline overflow grows `send_buf` on-ring (`RespSink.grow`), kills `fdWriteAllDirect` fallback | done, committed | neutral (no cell emits >16 KiB inline) |
| churn | ring close via `prep_close` instead of synchronous `linux.close` at teardown | done, committed, VALIDATED on 64c | 12t neutral, 64c healed the churn cells (see Outcome) |
| 2 | ring `sendFile` for static (comptime `.copy` / `.splice`) | deprioritized by the pivot (static already ties) | not started |
| 3 | comptime `Route.profile` write-strategy API | not started (scaffolding, see note) | n/a |
| 4 | HTTP buffer-select recv + parse-in-place (refined, not true multishot) | TRIED then REVERTED (attempt 4) | pipelined -13 to -16% (benchmark-zix-uring.4.txt vs benchmark-zix-epoll.4.txt), reverted |
| 5 | per-machine config profiles | done | app-level comptime PROFILE, no engine change, 64c throughput bench pending (benchmark-zix-*.5.txt) |

Note (increment 3): the `Route.profile` field is mostly an API surface. Parsing happens before routing (the path is needed to pick the route), and writing happens inside the handler (which does not know its profile), so a standalone profile field is behaviorally neutral. Its payoff is realized by the behaviors that increments 2 and 4 would select. Decision (2026-06-17): reorder so a behavior-bearing increment lands first, then `Route.profile` selects over real behaviors at comptime.

Note (increment 4): multishot recv + provided buffer ring was already implemented and REVERTED for HTTP under ADR-037 Phase 3 (`server.zig` run-loop comment). It forces a memcpy from the kernel-selected buffer into `conn.buf` for cross-recv accumulation, and that copy (largest at pipeline depth 16) outweighs the multishot re-arm saving that the plain recv-into-`conn.buf` path avoids by receiving in place. It survives only in WebSocket (smaller frames, parse-in-place).

The refined variant (buffer-select recv, not true multishot, parse in place when a request fits one selected buffer, copy only the trailing partial) was implemented and benched as attempt 4, then REVERTED. Same-session A/B on the 12t box, identical handler:

| cell | URING a4 | EPOLL a4 | URING vs EPOLL | a3 -> a4 (URING) |
| :- | :- | :- | :- | :- |
| baseline 512 | 684,291 | 642,487 | +6.5% | +7.4% |
| pipelined 512 | 6,877,921 | 7,570,722 | -9.1% | -14.4% |
| pipelined 4096 | 4,968,818 | 5,941,218 | -16.4% | -13.4% |
| json 4096 | 327,487 | 320,369 | +2.2% | +11.3% |
| limited 512 | 380,824 | 374,511 | +1.7% | ~flat |
| static (all) | 251k/219k/210k | 259k/228k/221k | -3 to -5% | ~flat |

Root cause and correction to the premise: the plain recv path already receives directly into `conn.buf` and parses it in place, so it never copied. Buffer-select therefore saves no copy and only adds per-recv buffer-ring bookkeeping (get, put, advance, re-arm). Pipelined is the highest recv-rate cell, so the overhead bites hardest there, turning a flagship URING win (pipelined was +4% on 12t, +9 to +13% on 64c) into a -9 to -16% loss versus EPOLL. The baseline and json gains are within the cross-session swing and do not offset that. Reverted to the attempt-3 engine (increment 1 plus churn ring close). The buffer ring stays WebSocket-only. Conclusion: io_uring provided buffers help only a path that would otherwise copy, which the in-place `conn.buf` recv is not.

## Original proposed changes (kept for the record)

### 1. Comptime Write-Strategy API
Add a comptime `profile` to each `Route` (`.auto` | `.baseline` | `.pipelined` | `.short_lived` | `.json` | `.static_file`), specializing parse and write at compile time with zero hot-path branching. Keep `writeSimple` / `fdWriteAll` as the AUTO default, with explicit `writeDirect` / `writeCoalesced` as manual escapes. See the increment-3 note for why this is scaffolding until a real behavior exists to select.

### 2. Fix Inline Overflow (Keep it On-Ring)
Done as increment 1. `RespSink` grows `send_buf` (power-of-two realloc up to `URING_SEND_BUF_MAX` = 1 MiB, never shrinks) to stage an oversized response on the ring instead of the blocking `fdWriteAllDirect` fallback. `.EPOLL` installs a null grow allocator and is byte-for-byte unchanged.

### 3. Ring sendFile for Static Content
Deprioritized by the pivot. Comptime `SendFileMode` (`.copy` from a warm in-RAM fixture cache via `prep_send`, `.splice` zero-copy via a per-worker pipe). Static already ties `.EPOLL`, so this is quality (move static on-ring), not a composite mover.

### 4. Multishot Recv + Buffer Ring
Tried twice and reverted both times (the naive accumulate-copy form under ADR-037 Phase 3, and the refined parse-in-place form as attempt 4). See the increment-4 note: provided buffers cannot reach the in-place `conn.buf` recv, and the bookkeeping regresses pipelined. Closed, not worth a third attempt on this engine.

### 5. Per-Machine Profiles
12t box (lean): small buffers, memory-bound. 64c box (throughput): larger recv/send buffers, 64 workers, RAM-abundant. The 12t results do not extrapolate to 64c.

## Churn-scaling work (the live track)

### Done: ring close (prep_close)
`finishClose` submits a `prep_close` SQE tagged with a new `OpKind.close` and recycles the connection slot first, so the worker keeps draining CQEs across teardowns instead of blocking in a synchronous `close` syscall. Falls back to synchronous `linux.close` only when the SQ is momentarily full. Half-duplex guarantees no in-flight op targets the closing fd. The shared `OpKind` (`src/multiplexers/ring.zig`) gained `close`, so every engine carries a `.close => {}` arm (only http1 arms it for now).

### Next ladder rungs (if ring close is not enough on 64c)
1. trim the per-accept synchronous `setNoDelay` setsockopt (needs a verified-inheritable or ring path).
2. ring-busy-poll, then direct descriptors, per the churn-diagnosis ladder.

## Acceptance Criteria and Testing
- [x] increment 1 and ring close pass `zig build test-all`, `examples`, `test-runner-all`, `zig fmt`.
- [x] 64c EPOLL-vs-URING shows json and limited-conn recovering toward parity (the decisive measurement). MET: json -73% to -2.4%, limited-conn -87% to +5.5% / -1.5%. See Outcome.
- [x] any retried multishot variant must reach the plain recv-into-`conn.buf` path it replaced, not just match it. CLOSED: the buffer-select retry (increment 4) lost (pipelined -13 to -16%) and was reverted, so no variant cleared the bar and the gate is not pursued further.
- [x] transient per-connection memory from grow-on-demand buffers stays capped and pooled. MET by design: growth is capped at `URING_SEND_BUF_MAX` (1 MiB), the buffer never shrinks, and the connection (with its grown buffer) is recycled through the idle-conn free list. The 64c run confirms it: URING memory is 50 to 85% below EPOLL on every cell, no blowup. The grow path is not exercised by any HttpArena cell (no >16 KiB inline response), so it is a correctness and tail-latency guard, not a hot path.

## Risks and Mitigations
- Hardware variance: the 12t dev box is loadgen-bound (server ~3 of 12 cores) and cannot reproduce 64-core churn starvation. Mitigation: gate correctness locally, measure the churn win only on the 64c box.
- Known-negative retries: multishot was already reverted. Mitigation: only retry the parse-in-place variant, and only if it reachs the in-place recv path.
- API blast radius: `Route.profile` flows into HttpArena `main.zig` route tables. Mitigation: default `.auto`, behavior-identical, so the field is additive.

---

###### end of ADR-041
