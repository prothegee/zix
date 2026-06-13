# Timeout Specification

Reference implementations: `rnd/http_timeout_model_a.zig` through `rnd/http_timeout_model_d.zig`
Combined recommendation: `rnd/http_timeout_model_bd.zig`

---

## Background: Why SO_RCVTIMEO Cannot Be Used

`std.Io.Threaded.netReadPosix` maps `.AGAIN -> errnoBug` (panic in debug, `error.Unexpected`
in release). On Linux, `SO_RCVTIMEO` on a blocking socket returns `EAGAIN` when it fires,
not `ETIMEDOUT`. Setting `SO_RCVTIMEO` via `setsockopt` would therefore panic the pool thread.
All four options below work around this constraint.

---

## Option A: Connection Max-Age (server-enforced, zero threads)

Record a deadline once at accept time. Check it at the top of each keep-alive iteration. Break
when the connection lifetime exceeds the deadline.

This is a **connection max-age** check, not a per-idle-gap timeout. The deadline is never reset.
It fires at the first loop iteration boundary after the lifetime has elapsed, meaning the
connection closes after the next request completes, not mid-request.

```zig
const deadline = std.Io.Clock.Timestamp.fromNow(io,
    std.Io.Clock.Duration{ .raw = std.Io.Duration.fromMilliseconds(cfg.timeout_ms), .clock = .real });

while (true) {
    if (std.Io.Clock.Timestamp.now(io, .real).compare(.gte, deadline)) break;
    var inner_req = http_server.receiveHead() catch |err| { ... };
    inner_req.respond(...) catch {};
    // no deadline reset. it is fixed at accept time
}
```

**Verified behavior (tested):**
Two requests sent with a 6s gap (timeout = 5s). Both requests received a response. After the
second response, `nc` exited. The server broke the loop at the next deadline check. The 6s
gap passed inside `receiveHead()` undetected, the deadline fired only after `receiveHead()`
returned with the second request.

**Covers:**
- Connections that exceed the max age and then send another request (detected at next boundary)

**Does NOT cover:**
- A client that goes permanently idle. The deadline passes inside `receiveHead()` and the
  check never runs again. The thread is held indefinitely. Use C or D for that.
- Handler execution time or slow response drain.

**Cost:** 0 extra threads.

---

## Option B: Context Deadline (cooperative, handler-level)

Add a `deadline` field to `Context`. The server optionally sets a global deadline before
dispatch. Handlers opt in by calling `ctx.withTimeout()` and checking `ctx.timedOut()`.

```zig
pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream = undefined,
    deadline: ?std.Io.Clock.Timestamp = null,

    pub fn withTimeout(self: Context, ms: u64) Context {
        var c = self;
        c.deadline = std.Io.Clock.Timestamp.fromNow(self.io,
            std.Io.Clock.Duration{ .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)), .clock = .real });
        return c;
    }

    pub fn timedOut(self: Context) bool {
        const d = self.deadline orelse return false;
        return std.Io.Clock.Timestamp.now(self.io, .real).compare(.gte, d);
    }
};
```

Handler usage:
```zig
pub fn slowHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    const tctx = ctx.withTimeout(5_000);

    doStep1();
    if (tctx.timedOut()) {
        res.setStatus(.REQUEST_TIMEOUT);
        return res.sendJson("{\"error\":\"timeout\"}");
    }

    doStep2();
    if (tctx.timedOut()) {
        res.setStatus(.REQUEST_TIMEOUT);
        return res.sendJson("{\"error\":\"timeout\"}");
    }

    try res.sendJson("{\"result\":\"ok\"}");
}
```

**Verified behavior (tested):**
Handler budget = 5s, step 1 = 3s sleep, step 2 = 3s sleep. After step 1 (3s elapsed, within
budget), step 2 began. After step 2 (6s total, over budget), `ctx.timedOut()` returned true.
Server responded with HTTP 408. Stderr: `model-b: timed out after step 2`.

**Covers:**
- Handler execution time when the handler explicitly checks `ctx.timedOut()` between steps.

**Does NOT cover:**
- Blocking I/O inside the handler (`std.Io.sleep`, DB calls, file reads): the handler is
  not interrupted. It only notices on the next explicit `timedOut()` call.
- `receiveHead()` stalling (handler has not started yet).
- Keep-alive idle gaps.

**Cost:** 0 extra threads. Null deadline is a branch-on-null, no overhead when unused.

---

## Option C: Watchdog Thread per Connection

Spawn one OS thread per accepted connection. The watchdog sleeps for `timeout_ms`. If the
connection has not finished, it calls `stream.shutdown(.both)`, which signals the peer and
causes the next read or write on that socket to fail.

```zig
const WatchdogCtx = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    timeout_ms: u64,
    done: std.atomic.Value(bool) = .init(false),
};

fn watchdog(w: *WatchdogCtx) void {
    std.Io.sleep(w.io, std.Io.Duration.fromMilliseconds(@intCast(w.timeout_ms)), .real) catch {};
    if (!w.done.load(.acquire)) w.stream.shutdown(w.io, .both) catch {};
}

// in handleConnection:
var wdog = WatchdogCtx{ .stream = stream, .io = io, .timeout_ms = cfg.timeout_ms };
const wdog_thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, watchdog, .{&wdog});
defer { wdog.done.store(true, .release); wdog_thread.join(); }
```

`shutdown(.both)` causes `readv()` to return 0 (EOF on Linux) which propagates as
`error.HttpConnectionClosing` through `std.http.Server.receiveHead()`.

**Verified behavior (tested):**
`nc` connected without sending any data. Watchdog fired at exactly **5.000s**. `nc` exited.
Curl on a normal request responded in **8ms**; watchdog exited cleanly via `done = true`.

**Covers:**
- Slow initial connect (client connects but stalls before sending headers).
- Keep-alive idle gaps (client goes silent after prior requests).
- Slow response drain (write failure after shutdown on the send path).

**Does NOT cover:**
- Handler blocking on non-socket I/O (`std.Io.sleep`, DB, file). `shutdown()` does not
  interrupt a handler that is not doing socket I/O.
- A `readv()` already in progress. `shutdown(.both)` on Linux causes the blocked `readv()`
  to return 0 (EOF) in practice, but POSIX does not guarantee interruption of in-progress
  syscalls. Tested and working on Linux.

**Cost:** 1 OS thread per active connection (sleeping, ~64KB stack virtual memory each).

---

## Option D: Shared Timer Thread + Connection Registry

The server maintains a registry of active connections and their deadlines. The existing timer
thread calls `registry.evict()` each tick. `evict()` scans the list and calls
`stream.shutdown(.both)` on expired entries.

```zig
const ConnEntry = struct {
    stream: std.Io.net.Stream,
    deadline: std.Io.Clock.Timestamp,
    done: std.atomic.Value(bool) = .init(false),
};

const ConnRegistry = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayListUnmanaged(*ConnEntry) = .empty,

    fn evict(self: *ConnRegistry, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const now = std.Io.Clock.Timestamp.now(io, .real);
        for (self.entries.items) |e| {
            if (!e.done.load(.acquire) and now.compare(.gte, e.deadline))
                e.stream.shutdown(io, .both) catch {};
        }
    }
};

// handleConnection registers on entry, deregisters (done=true) in defer
```

**Verified behavior (tested):**
`nc` connected without sending data. Registry evicted at **5.208s** (5s deadline + ~200ms
timer jitter from 500ms tick interval). `nc` exited. Jitter is bounded by `TIMER_INTERVAL_MS`.

**Covers:** Same as Option C.

**Does NOT cover:** Same as Option C. Same `shutdown()` caveat applies.

**Cost:** 0 extra threads (reuses timer thread). Per-accept: 2 mutex lock/unlock pairs.
Per 500ms tick: 1 mutex lock + O(n) scan over active connections.
Eviction precision: `[deadline, deadline + TIMER_INTERVAL_MS]`.

---

## Option BD: Recommended Strategy (B + D combined)

B and D are orthogonal and complement each other without overlap:

- **D** fires if the client stalls before or during header send. The handler never starts.
- **B** fires if the handler takes too long after it starts. The network is healthy.

Neither depends on the other. Both can fire independently on the same connection.

```
accept()
  |
  +-- D: register ConnEntry (deadline = now + CONN_TIMEOUT_MS)
  |
  receiveHead() <-- D timer can fire here: shutdown(.both) -> ReadFailed -> break
  |
  dispatch(ctx.withTimeout(HANDLER_TIMEOUT_MS))
    |
    step 1
    ctx.timedOut()? <-- B fires here if handler is slow
    step 2
    ctx.timedOut()? <-- B fires here if still over budget
    respond()
  |
  +-- D: deregister (done=true, watchdog cancelled)
```

**Config fields (replacing the dead `response_timeout_ms`):**
```zig
conn_timeout_ms:    u32 = 30_000,  // D: network-level connection guard
handler_timeout_ms: u32 = 10_000,  // B: per-handler execution budget
```

**Constraint:** `conn_timeout_ms` should be >= `handler_timeout_ms`. If D fires mid-handler,
the connection closes before the handler can send a response. This is technically valid but
produces an abrupt close rather than a clean 408.

Reference: `rnd/http_timeout_model_bd.zig`

---

## Summary

| Option | Covers | Read hang | Handler exec | Idle keep-alive | Extra threads |
| :- | :- | :- | :- | :- | :- |
| A: max-age | Lifetime exceeded, at next request boundary | no | no | no* | 0 |
| B: ctx.deadline | Handler steps that call timedOut() | no | yes (cooperative) | no | 0 |
| C: watchdog thread | Slow connect, idle keep-alive, slow drain | yes | no | yes | 1 per conn |
| D: shared registry | Same as C, lower thread count | yes | no | yes | 1 total (shared) |
| **BD: recommended** | **Full lifecycle: network + handler** | **yes** | **yes** | **yes** | **1 total (shared)** |

\* Option A does not cover permanent idle: if the client stops sending, the thread is held in
`receiveHead()` indefinitely regardless of the deadline.

---

## API Corrections Discovered During Testing

The following `std.Io` API mistakes were found and corrected in the model files:

- `std.Io.Clock.Duration.fromMilliseconds(x)`: does not exist.
  Correct: `std.Io.Clock.Duration{ .raw = std.Io.Duration.fromMilliseconds(x), .clock = .real }`

- `std.Io.Clock.real.now(io)`: returns `Io.Timestamp` (no `compare` method).
  Correct: `std.Io.Clock.Timestamp.now(io, .real)` returns `Clock.Timestamp` (has `compare`).

- `std.Io.sleep(io, Timeout{ .duration = ... })`: wrong signature.
  Correct: `std.Io.sleep(io, Io.Duration, Io.Clock)` e.g. `std.Io.sleep(io, dur, .real)`.

---

###### end of timeout specification
