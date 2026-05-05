# HTTP: Explicit Without Burden (was: zix-cmod-1)

> **Superseded.** Renamed from `rnd/zix-cmod-1.md`. Content has been redistributed:
> - Resolved decisions → [`docs/adr.md`](../docs/adr.md) (ADR-011, ADR-012)
> - Specification and performance notes → [`rnd/http_specification.md`](http_specification.md)
>
> This file is kept for historical reference only.

---

The goal: remove hidden behavior ("magic") without making the user write boilerplate for every line.

The tension to resolve:

> Explicit over implicit — but the user should be able to run a hello-world in under 10 lines.

The key distinction: **explicit** means the user can read the code and know exactly what the server does, without reading internal source or docs. It does **not** mean the user must assemble everything from scratch.

---

## The Problem With Current State

Hidden behaviors in the current implementation:

| Behavior | Where it hides |
| :- | :- |
| Static fallback on no route match | buried in `handleConnection` |
| 3-pass route priority (exact > param > prefix) | invisible at registration time |
| 404 auto-response when nothing matches | buried in server internals |
| Connection keep-alive loop | hidden in `handleConnection` |
| Per-request arena lifetime | only in docs, not in the name `ctx.allocator` |
| Per-connection heap allocation of I/O buffers | invisible to user |

None of these are wrong. They become a problem when the user can't override, observe, or reason about them without reading `server.zig`.

---

## Option A — Explicit Defaults (Recommended)

**Philosophy:** keep sensible defaults, but name every behavior in the config struct. Nothing is hidden in server internals. If it exists, it's in the config.

```zig
var server = try zix.HttpServer.init(.{
    .io              = process.io,
    .allocator       = arena.allocator(),
    .ip              = "127.0.0.1",
    .port            = 9000,

    // explicit: what happens when no route matches
    // null = 404 plain text (built-in); supply a handler to override
    .not_found       = null,

    // explicit: static file serving; null = disabled (no fallback magic)
    .static_dir      = null,
    .static_prefix   = "/",

    // explicit: keep-alive behavior
    .keep_alive      = true,
});
```

The user who wants a quick server writes nothing extra — defaults do the right thing. The user who wants control changes one field. Every behavior has a name.

**Static serving becomes a config field, not a side effect:**
```zig
// before (magic): routes fall through to filesystem silently
// after (explicit): user opts in
.static_dir = "./public",
.static_prefix = "/static",
```

**Not-found handling becomes a field:**
```zig
// custom 404
.not_found = myNotFoundHandler,
```

**Tradeoff:** config struct grows. Mitigate with sensible grouping (static fields together, connection fields together).

---

## Option B — Pipeline Assembly

**Philosophy:** the server is a blank slate. The user assembles the pipeline from named pieces. Nothing runs unless registered.

```zig
var server = try zix.HttpServer.init(.{ .io = process.io, .port = 9000 });

// user explicitly places static serving in the pipeline
server.useStatic("/static", "./public");

// user explicitly registers error handlers
server.onNotFound(myNotFoundHandler);

// routes registered in priority order (first-match-wins, no 3-pass magic)
server.registerHandler("/", homeHandler);

try server.run();
```

**Routing becomes top-down (first-match-wins):**
No 3-pass priority system. Order of registration is truth — matches zix's "explicit over implicit" most fully.

```zig
server.registerHandler("/api/v2/user", v2Handler); // checked first
server.registerPrefix("/api",          v1Handler); // fallback if above didn't match
server.registerPrefix("/",             homeHandler); // catch-all
```

**Tradeoff:** more assembly work for the user. A minimal server now needs 3-4 calls instead of 1. Acceptable for library users who understand what they're building; potentially alienating for first-time users.

---

## Option C — Layered API (Simple + Explicit)

**Philosophy:** two tiers. The simple API (Option A) is the default. The explicit API (Option B) is available for users who want full control. Same underlying engine, different entry points.

```zig
// Simple — explicit defaults, sensible for most cases
var server = try zix.HttpServer.init(.{
    .io   = process.io,
    .port = 9000,
    .static_dir = "./public",
});
server.registerHandler("/", homeHandler);
try server.run();

// Explicit — zero magic, full pipeline control
var server = try zix.HttpServer.initExplicit(.{
    .io   = process.io,
    .port = 9000,
});
server.onNotFound(my404Handler);
server.useStatic("/", "./public");
server.registerHandler("/", homeHandler);
try server.run();
```

**Tradeoff:** two init paths to maintain. Risk of divergence. Adds surface area. Only justified if user profiles clearly split between "quick use" and "production control."

---

## Comparison

| | Option A | Option B | Option C |
| :- | :- | :- | :- |
| Hello-world verbosity | low | medium | low (simple tier) |
| Explicit over implicit | partial — config-visible | full | full (explicit tier) |
| Magic eliminated | most | all | all (explicit tier) |
| Maintenance surface | low | medium | high |
| Routing model | 3-pass (unchanged) | first-match-wins | depends on tier |
| Recommended for zix | **yes** as baseline | consider for routing only | not yet |

---

## Recommendation

**Start with Option A.** It eliminates the most impactful hidden behaviors (static fallback, not-found, keep-alive) with minimal user disruption. The config struct is the contract — if it's not in the struct, it doesn't happen.

**Adopt the first-match-wins routing from Option B as a separate change.** It's independent of the config refactor and aligns with zix's "Explicit Over Implicit" most clearly. The 3-pass system is the largest source of non-obvious behavior — a developer reading registration calls cannot predict which handler wins without knowing the priority rules.

**Skip Option C for now.** Two API surfaces are harder to document and maintain than one good one.

---

## Performance Approach

These are orthogonal to the explicitness changes above — implementation improvements independent of API shape.

### 1. Exact Route Hash Map

Current router does a full linear scan (3 passes) over all routes for every request. Exact routes (`/about`, `/api/v2/user`) can be looked up in O(1) with a hash map.

```
current:  O(3N) per request — 3 linear passes over all routes
proposed: O(1) for exact match (hash map) + O(N) for param/prefix fallback
```

At low route count the gain is negligible. At 50+ routes it becomes measurable. Implementation: split `Router` into `exact_map: std.StringHashMap(HandlerFn)` + `fallback: []Route` (param + prefix only).

### 2. Stack-Allocated I/O Buffers

Current `handleConnection` does two heap allocations per connection:

```zig
const buf_read  = std.heap.smp_allocator.alloc(u8, cfg.max_client_request) catch return;
const buf_write = std.heap.smp_allocator.alloc(u8, cfg.max_client_response) catch return;
```

If buffer sizes are comptime-known (or set to a reasonable fixed cap), stack allocation removes heap pressure entirely. Under high concurrency (100+ simultaneous connections) this reduces allocator contention.

Proposed: comptime generic over buffer size, or fixed stack buffers for standard sizes.

### 3. Connection Buffer Pool

Alternative to stack buffers for large buffer sizes (>8KB): a pre-allocated pool. Connections borrow a buffer pair on accept and return it on close. Eliminates per-connection alloc/free under sustained load.

### 4. Per-Request Arena Pre-Sizing

Current arena is initialized with `smp_allocator` and grows on demand. If handlers declare their typical allocation size at registration time (or via a config field), the arena can pre-allocate its backing block once and avoid internal growth.

```zig
// proposed: handler hints at arena size
server.registerHandler("/upload", uploadHandler, .{ .arena_hint = 64 * 1024 });
```

Not all handlers need this — only upload, body-parsing, or response-building handlers benefit.

### 5. UDP Broadcast Batching

Current `processPacket` broadcast does N sequential `send()` syscalls — one per connected client. On Linux, `sendmmsg` can send multiple datagrams in a single syscall.

```
current:  N syscalls per broadcast packet
proposed: 1 sendmmsg call per broadcast packet (at cost of building iovec array)
```

Benefit scales linearly with client count. For ≤4 clients the overhead of building the iovec may outweigh the gain; above that it wins. Mark for `src/udp/` implementation, not the PoC.

### 6. Zero-Copy Static Serving

Current static serving reads file bytes into a buffer then writes them to the connection. On Linux, `sendfile(2)` transfers file data directly from page cache to socket without a userspace copy — relevant for large files.

Applicable only when the OS supports it; add as a runtime-detected code path in `static.zig`.

---

## Summary Priority

| Change | Category | Impact | Effort |
| :- | :- | :- | :- |
| Exact route hash map | Performance | medium | low |
| Static/not-found as config fields | Explicit | high | low |
| First-match-wins routing | Explicit + minor perf | high | medium |
| Stack/pooled I/O buffers | Performance | high under load | medium |
| `ctx.request_arena` rename | Explicit | low (naming) | trivial |
| UDP sendmmsg batching | Performance | high at scale | medium |
| Zero-copy static | Performance | medium for large files | medium |
| Per-request arena hint | Performance | low-medium | medium |

---

###### end of zix-cmod-1
