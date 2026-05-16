# HTTP Specification -- zix.Http

Research notes, confirmed behaviors, and open proposals for the HTTP layer.
Resolved architectural decisions are in [`docs/adr.md`](../docs/adr.md).
Public API and design rationale are in [`docs/hld-http.md`](../docs/hld-http.md).
Implementation details are in [`docs/lld-http.md`](../docs/lld-http.md).

Supersedes: `rnd/http_explicit_implicit.md`, `rnd/http_explicit_without_burden.md` (original research documents, kept for history).

---

## Confirmed Behaviors

### Explicit Defaults (Config as Contract)

Every server behavior is named in `HttpServerConfig`. Nothing is hidden in `server.zig` internals.
If it is not in the config struct, it does not happen.

Current state -- named fields in config:

| Behavior | Config field | Default | Status |
| :- | :- | :- | :- |
| Static file root | `public_dir` | `""` (disabled) | Named field |
| Upload subdir | `public_dir_upload` | `"u"` | Named field |
| TCP listen backlog | `max_kernel_backlog` | `4096` | Named field |
| Read buffer per connection | `max_client_request` | `4096` | Named field |
| Write buffer per connection | `max_client_response` | `4096` | Named field |
| Per-connection arena backing | `max_allocator_size` | `4096` | Named field |
| Custom response headers cap | `max_response_headers` | `.COMMON` (32) | Named field (ADR-009) |
| Connection guard (Layer D) | `conn_timeout_ms` | `0` (disabled) | Named field, model 2 only. ADR-018 |
| Handler budget (Layer B) | `handler_timeout_ms` | `0` (disabled) | Named field, ctx.timedOut(). ADR-018 |

Pending additions -- proposed in ADR-012:

| Behavior | Proposed field | Proposed default |
| :- | :- | :- |
| 404 handler | `not_found: ?HandlerFn` | `null` (built-in plain text) |
| Keep-alive toggle | `keep_alive: bool` | `true` |

### Middleware Pattern (Accepted, ADR-011)

Comptime wrapper functions -- confirmed, implemented. See `examples/http_middleware.zig`.

```zig
fn withOriginCheck(comptime next: zix.Http.HandlerFn) zix.Http.HandlerFn {
    return struct {
        fn handle(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) anyerror!void {
            const origin = req.header("origin") orelse "";
            if (!isAllowedOrigin(origin)) {
                res.setStatus(.FORBIDDEN);
                try res.sendJson("{\"error\":\"forbidden origin\"}");
                return;
            }
            return next(req, res, ctx);
        }
    }.handle;
}
```

Compose left-to-right -- outermost wrapper runs first:
```zig
server.registerHandler("/private", withOriginCheck(withBasicAuth(privateHandler)));
```

### Routing Priority (3-pass, Accepted, ADR-004)

Pass 1 exact -> Pass 2 param (first-registered) -> Pass 3 prefix (longest match).

First-match-wins routing was proposed as a replacement (see `rnd/http_explicit_implicit.md` section 2) but
deferred: the change would be breaking and the benefit is marginal for typical route counts.

### Arena Allocator Lifetime (Accepted, ADR-003)

`ctx.allocator` is a per-connection `ArenaAllocator` reset between requests.
Rename to `ctx.request_arena` was considered and declined -- the arena lifetime is documented, not encoded in the name.

---

## Performance Notes

These are implementation improvements, independent of API shape.

### 1. Exact Route Hash Map (Implemented)

Was: O(N) linear scan over exact_routes per request.
Now: O(1) via `exact_map: StringHashMapUnmanaged(HandlerFn)`. `register()` inserts into both
`routes` (for param/prefix scanning) and `exact_map`. Pass 1 dispatch is `exact_map.get(path)`.

Impact: measurable at 50+ routes zero cost at low route counts.

### 2. Stack-Allocated I/O Buffers

Current: two heap allocations per connection (read_buf + write_buf from smp_allocator).
Proposed: if buffer sizes are comptime-known, use stack buffers. Reduces allocator contention
under high concurrency (100+ simultaneous connections).

### 3. Connection Buffer Pool

Alternative to stack buffers for sizes >8 KB: pre-allocated pool. Connections borrow a buffer
pair on accept, return on close. Eliminates per-connection alloc/free under sustained load.

### 4. Per-Request Arena Pre-Sizing

Current: arena grows on demand. Proposed: optional per-handler hint at registration time.

```zig
server.registerHandler("/upload", uploadHandler, .{ .arena_hint = 64 * 1024 });
```

Only upload, body-parsing, or large response handlers benefit.

### 5. Zero-Copy Static Serving

Current: file bytes read into buffer -> written to socket (two copies).
Proposed: `sendfile(2)` on Linux -- page cache -> socket directly, no userspace copy.
Add as runtime-detected code path in `static.zig`. Relevant for files > 64 KB.

---

## Open Questions

| Question | Status |
| :- | :- |
| ADR-012: explicit not_found / keep_alive fields | Proposed -- not yet implemented |
| Hash map for exact routes | Implemented -- `exact_map: StringHashMapUnmanaged(HandlerFn)` in router.zig |
| conn_timeout_ms / handler_timeout_ms | Implemented (ADR-018) |
| First-match-wins routing | Deferred (ADR-004) |
| Middleware chain runner | Not needed -- comptime wrapper is the pattern |

---

###### end of http specification
