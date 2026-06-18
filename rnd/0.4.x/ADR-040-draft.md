# ADR-040 (proposal record)

Records the user-space hot-path optimization set for the zix engines, derived
from the 0.4.x server-process perf profiles (`rnd/0.4.x/perfreport-*.txt`). Kept
here as the rnd proposal. Folded into `docs/adr-en.md` (before the `end of adr`
footer) and mirrored into `docs/adr-id.md` once the increments land and the A/B
numbers are recorded. Unlike a pure consistency ADR, this one carries measured
before-numbers (the perf symbols) and will carry measured after-numbers.

---

## ADR-040: user-space hot-path optimizations across the engine family (integer-compare, baked response prefix, lazy parse, writer bypass, copy reduction)

**Status:** Accepted

**Context:**

The 0.4.x kernel-cycle pass (`rnd/0.4.x/accept-summary-kernel-20260616.txt`)
showed loopback is ~94% kernel TCP, identical for `.EPOLL` and `.URING`. The
io_uring syscall levers (direct descriptors, fixed buffers, send_zc, SQPOLL) are
sub-noise on this box, and a probe of the top io_uring HTTP engines (ringzero,
zeemo) found they use none of them, so those are deprioritized.

The remaining wins that clear the 1% bar are in the shared user-space hot path.
They are measurable on loopback and they help every dispatch model (`.EPOLL`,
`.URING`, `.POOL`, `.ASYNC`, `.MIXED`) at once, because the code lives in the
shared parse and response paths, not in a dispatch loop. The server-process
profiles name the hot user-space leaves:

| Symbol | http1 EPOLL | http1 URING | http EPOLL | http URING | Pattern |
| :- | :- | :- | :- | :- | :- |
| `mem.eql` (fixed-string compares) | present | 14.99% | present | present | P1 |
| `buildSimpleHeaderInto` / response build | 4.63% | 9.92% | 5.39% | 7.02% | P2 |
| `mem.findScalarPos` (eager header scan) | low | low | present | 10.98% | P3 |
| `Io.Writer.alignBufferOptions` (std writer) | n/a | n/a | 1.91% | 1.97% | P4 |
| `memcpy.memcpyFast` (build-then-copy) | 1.40% | 1.99% | 4.95% | 9.03% | P5 |

The numbers are a share of the server-process profile. Projected end-to-end
throughput per pattern is roughly that share times the fraction removed times
~0.5 (wrk shares the loopback box), confirmed per increment by A/B.

**Decision:**

Apply five optimization patterns. Each pattern is one increment, applied to every
engine whose hot path contains it, gated by `zig build test-all`,
`zig build examples`, and `zig build test-runner-all` before the next increment.

| Id | Pattern | What | Targets |
| :- | :- | :- | :- |
| P1 | integer-compare | Replace a hot `mem.eql` against a fixed-length string literal with one integer (u32/u64) load-and-compare. | HTTP/1 version + method, HTTP/2 connection preface, audited FIX markers |
| P2 | baked response prefix | Replace per-request assembly of a response header (many small appends or `bufPrint`) with one `@memcpy` of a comptime-baked constant prefix per (status, content-type), plus variable Content-Length digits and optional cached Date. | Http1, Http, Http2, Grpc |
| P3 | lazy header parse | Parse only the headers needed to frame the request (Content-Length, Connection, Transfer-Encoding, Expect) up front, defer the rest to on-demand lookup. | Http |
| P4 | writer bypass | Write the response straight into the engine sink/fd on the hot path instead of through `std.Io.Writer`. | Http |
| P5 | copy reduction | Build the response header directly into the send/sink buffer (write-in-place), removing one copy generation. | any build-then-copy response path |

For the WebSocket paths (in both `zix.Http1` and `zix.Http`) P1 manifests as the
RFC 6455 mask/unmask: the per-byte XOR loop becomes a word-at-a-time (u64) XOR,
and P5 as unmasking in place plus coalescing the frame header with its payload in
one write. The broadcast build-once path (a P2 analogue) already exists.

Per-engine application (a pattern applies only where the hot path has it):

| Engine | P1 | P2 | P3 | P4 | P5 |
| :- | :- | :- | :- | :- | :- |
| zix.Http1 | version, route key | `buildSimpleHeaderInto` | fast path already lazy | already direct | header into sink |
| zix.Http | method, version | `response.zig` status line | eager scan -> lazy | `Response.send` | build-then-copy |
| zix.Http2 | h2 preface | response frame header | HPACK already lazy | audit | frame copy |
| zix.Grpc | h2 preface | unary reply prefix | n/a | audit | reply copy |
| zix.Http1 WS | word-at-a-time mask | broadcast build-once (done) | n/a | engine-owned write | in-place unmask, coalesced frame |
| zix.Http WS | word-at-a-time mask | broadcast build-once (done) | n/a | audit | in-place unmask, coalesced frame |
| zix.Fix | begin-string marker (audit) | n/a | n/a | n/a | framing copy (audit) |
| zix.Tcp | framing marker (audit) | n/a | n/a | n/a | framing copy (audit) |
| zix.Udp | n/a | n/a | n/a | n/a | packet copy (audit) |

**Config:** these are internal optimizations and introduce no new server-config
field. Should a toggle prove necessary (for example to force the legacy path), it
is added to every server config (`Http`, `Http1`, `Http2`, `Grpc`, `Tcp`, `Udp`,
`Uds`, `Fix`) with the same name, type, and default, per the flat-config
consistency rule.

**Consequences:**
- Faster on every dispatch model, and measurable on loopback (unlike the io_uring
  levers). Each pattern targets a symbol that is at least ~1% of a server profile.
- No API or behaviour change. The existing unit / integration / behaviour / edge
  suites plus the end-to-end runners are the regression gate, run after every
  increment.
- New tests: each new helper (integer-compare decoder, baked-prefix builder,
  lazy-parse accessor) gets unit and edge coverage. Equivalence is asserted by a
  test that diffs the new output / parse result against the legacy path for the
  common cases, so the optimization cannot silently change the wire bytes.
- Verification: per increment the three build steps are green. After the full set,
  the A/B percentages are recorded back into this file and the rnd/0.4.x summary.

---

## Implementation status (2026-06-16)

All increments green on `zig build test-all` + `zig build examples` + `zig build test-runner-all` (56/56 runner protocols each).

| Increment | Pattern / engine | Change | Gate |
| :- | :- | :- | :- |
| I1 | P1 zix.Http1 | `parseGetFastPath`: `mem.eql("HTTP/1.1")` + `"GET "` byte checks -> single `readInt` u64/u32 compares | green |
| I2 | P2 zix.Http1 | baked `statusLine` (19 codes), one `memcpy` in `buildSimpleHeaderInto`, piecewise fallback for unknown codes | green |
| I3 | P2+P4 zix.Http | `buildResponse` + `send` staging: Content-Type / Date `bufPrint` -> `@memcpy` (drops the `std.Io.Writer` path) | green |
| I4 | P1 zix.Http | parser framing-header match: `eqlIgnoreCase` if/else-if chain -> length-switch (at most one compare per line) | green |
| I5 | P1 zix.Http2 + zix.Grpc | `:method` / `:path` extraction: length-gated compare (3 sites) | green |

Each increment carries an equivalence test (byte-exact output or behaviour), so the wire bytes are unchanged.

Already optimal (verified by reading, no change): zix.Http `parse` is already lazy (`getHeader` rescans on demand) and vectorized, so P3 was pre-done. zix.Http `buildResponse` already bakes the status line and uses `@memcpy` + `writeDecimal` for Content-Length. WebSocket unmask in both zix.Http1 and zix.Http already uses a 16-wide `@Vector(16, u8)` XOR (better than word-at-a-time). zix.Grpc replies already use comptime-cached HPACK blocks.

No change after audit: zix.Fix framing is byte-level SOH parsing with vectorized field scans (no hot fixed-string compare). zix.Tcp and zix.Udp are length-prefixed raw frames with no header-string matching. Their only `mem.eql`-vs-literal sites are config-time argv parsing.

No new server-config field was introduced: every change is internal and behaviour-identical.

Result (httparena-lite, attempt 3, post-sweep, AMD Ryzen 5 5600H, 6/12 threads, loopback): recorded in the README Benchmark tables (en + id). Representative EPOLL HTTP/1.1 throughput rose versus the prior recorded attempt: baseline 512c 585,239 -> 614,416 req/s (+5.0%), pipelined 512c 7,156,160 -> 7,682,896 req/s (+7.4%). The remaining scenarios moved within loopback variance, and `.URING` tracks `.EPOLL` at parity (expected on a 94%-kernel loopback path). These are full-suite numbers (a fresh server per scenario), so they confirm the direction rather than isolate a per-increment delta.
