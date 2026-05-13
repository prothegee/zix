# HTTP Request/Response Optimization Notes

Triaged list of optimizations for the HTTP request/response hot path,
ranked by impact/effort. Numbers in brackets are very rough order-of-magnitude
estimates, verify with benchmarks before committing to anything micro.

Status as of writing: Connection/Content-Type are now opt-in
(omitted when not set). qmark_pos, method_cache, and the proxy Date override
are pre-computed once per request in `server.zig` so `path()`, `query()`,
`method()` pay no scan cost in the hot path.

## Applied Batch (Tiers 1-3)

**Status: APPLIED** -- all items #1-#7 implemented and passing unit + integration tests.

| # | Item | File | Status |
| :- | :- | :- | :- |
| 1 | Pre-built status lines | `status.zig` + `response.zig` | Done |
| 2 | Skip CL/CT for 204 | `response.zig` | Done |
| 3 | Router exact-match HashMap | `router.zig` | Done |
| 4 | Lazy header index | `request.zig` | Done |
| 5 | Hand-rolled usize decimal | `response.zig` | Done |
| 6 | addHeader incremental alloc | `response.zig` | Done |
| 7 | Fast-path buffer 320 -> 512 | `response.zig` | Done |

## Tier 1 — biggest wins, smallest code

### 1. Pre-built status lines for common codes

Location: `src/tcp/http/response.zig:187`

Current:
```zig
const sl = try std.fmt.bufPrint(fixed[offset..], "HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(self.status), status_text });
```

90%+ of responses use one of ~6 status codes (200, 201, 204, 400, 404, 500).
Pre-build them as comptime constants in `status.zig`:

```zig
pub fn statusLine(c: Code) []const u8 {
    return switch (c) {
        .OK         => "HTTP/1.1 200 OK\r\n",
        .CREATED    => "HTTP/1.1 201 Created\r\n",
        .NO_CONTENT => "HTTP/1.1 204 No Content\r\n",
        .NOT_FOUND  => "HTTP/1.1 404 Not Found\r\n",
        // ... + fallback that bufPrints the rest
    };
}
```

In `send()`: `@memcpy` instead of `bufPrint` — cuts format-machinery overhead
on the hot path.

### 2. Skip Content-Length and Content-Type for 204

Location: `src/tcp/http/response.zig:193`

204 No Content per RFC 7230 must not have either. Currently we always emit
`Content-Length: 0` and `Content-Type` if set. Check status first, skip both.
Saves ~25 bytes + bufPrint per `noContent()` call.

## Tier 2 — scales with workload

### 3. Router exact-match StringHashMap

Location: `src/tcp/http/router.zig:108-117`

Current:
```zig
for (self.routes.items) |route| {
    if (route.kind == .exact and std.mem.eql(u8, route.path, p)) { ... }
}
```

Linear scan over all routes. With 50 routes, that's ~50 string compares
per request even when an exact match exists. Add a
`std.StringHashMapUnmanaged(HandlerFn)` alongside `routes` for `.exact` routes
— O(1) lookup. Param/prefix routes stay in the list (can't be hashed).

### 4. Header lookup index per request

Location: `src/tcp/http/request.zig:70-76`

Current:
```zig
pub fn header(self: Request, name: []const u8) ?[]const u8 {
    var it = self.inner.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
}
```

Each `header()` call walks every header doing case-insensitive compare.
Handlers commonly read 3-5 headers (Auth, Content-Type, Accept, etc.).
Two approaches:

- Cheap: pre-resolve a fixed set in `server.zig` (content_type, content_length,
  authorization) into Request fields. Most-common lookups become field reads.
- General: build a small lowercase-keyed index lazily on first call, cache for
  rest of request. Costs one full pass on first call but every subsequent
  lookup is hash O(1).

## Tier 3 — micro-optimizations (measure first)

### 5. Hand-rolled usize -> decimal for Content-Length

Location: `src/tcp/http/response.zig:193`

`std.fmt.bufPrint` for `{d}` works but has format-spec parsing overhead.
Direct loop is ~30 cycles vs ~100+. Marginal only worth it if profiling
shows `bufPrint` hot.

### 6. addHeader incremental allocation

Location: `src/tcp/http/response.zig:151-153`

Currently allocates the full `max_headers` slot array on first `addHeader()`.
For `max_headers = 32` and a handler adding 1 custom header, we waste
31 slots in the arena. Start with 4, double on overflow. Saves arena
memory trivial code change.

### 7. Larger fast-path buffer

Location: `src/tcp/http/response.zig:185`

Bump `fixed[320]` to 512 to keep more responses on the fast path
(single `writeAll`). Trade: +192 bytes per concurrent request on stack.
Pool threads have ~stack_threshold budget check before bumping.

## Tier 4 — architectural (much bigger lift)

### 8. Custom HTTP parser

Replace `std.http.Server`. Already noted in `project_perf_baseline` memory
as the remaining ceiling. Major work.

### 9. writev for slow path

Location: `src/tcp/http/response.zig:220-228`

When extra headers present, we do N+1 `writeAll` calls. One `writev` syscall
instead. Needs std.Io.net writev support — check what's available.

### 10. Per-thread response buffer pool

Instead of stack `fixed[320]` per call, give each pool thread a reusable
4 KB buffer. Lets fast path cover much larger responses without per-request
allocation.

## Recommendation

Start with #1 and #3:

- #1 is ~20 lines, eliminates format work on the most-common per-response path.
- #3 scales the win as routes grow — important if anyone registers many
  exact routes.

Both are isolated, easy to verify, and no test changes needed.

After those, run the existing perf benchmark and decide if #4 or anything in
Tier 3 is worth chasing. Tier 4 is its own project.

## Combined plan: Tiers 1 + 2 + 3 (this batch)

Tier 4 is deferred as a separate decision. The remaining items (#1-#7) form
one cohesive batch. Apply order, with rationale for grouping:

1. **#1 status line lookup** — `status.zig` gets `statusLine(Code) []const u8`.
   `send()` swaps the status `bufPrint` for a `@memcpy` of the lookup result;
   unknown codes fall back to `bufPrint`.

2. **#2 skip CL/CT for 204** — guard the Content-Length and Content-Type
   blocks on `self.status != .NO_CONTENT`. Independent change in `send()`.

3. **#3 router exact-match HashMap** — add `exact_map: std.StringHashMapUnmanaged(HandlerFn)`
   to `Router`. `register()` inserts there too (still appends to `routes` for
   listing/iteration symmetry). `dispatch()` Pass 1 becomes `exact_map.get(p)`.
   `deinit()` frees the map.

4. **#4 header index** — go with the lazy approach:
   - Add `header_index: ?std.StringHashMapUnmanaged([]const u8) = null` to `Request`
     (lowercase-keyed).
   - `header()` builds the map on first call from `iterateHeaders()`,
     lowercases names into the request arena, then uses `get()` for lookups.
   - Skips first-call cost when handler never calls `header()`.

5. **#5 hand-rolled u64 decimal** — small helper in `response.zig`,
   used only for `Content-Length`. Keep `bufPrint` for `Date` (string),
   the integer one is the only hot decimal write.

6. **#6 addHeader incremental alloc** — start with 4, double on growth,
   capped at `self.max_headers`. Replace the single `try alloc(max_headers)`
   with a grow-on-need path. Existing `TooManyHeaders` semantics preserved.

7. **#7 fast-path buffer 320 -> 512** — last because it interacts with
   stack pressure. Confirm `stack_threshold` headroom before bumping.

### Why this order works as one batch

- #1, #2, #5, #6, #7 are all in `response.zig` (and one helper in `status.zig`)
  — same file, can be reviewed together.
- #3 is in `router.zig` — independent.
- #4 is in `request.zig` — independent.
- No test modifications needed for any of them (all changes preserve current
  behavior on the fallback / non-cached paths).
- All can be benchmarked with the existing perf rig before/after the batch.

### Out of scope for this batch

- Tier 4 (#8 custom parser, #9 writev, #10 buffer pool) — larger architectural
  decisions, separate planning.
