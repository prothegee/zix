# rediz

A Redis database driver written in pure Zig, standard library only.

- RESP3 via HELLO with an in-place RESP2 fallback, compatible with Redis 7 and 8.
- Typed value helpers plus a raw command escape hatch.
- Command pipelining and a deferred write-behind path.
- A thread-safe connection pool.
- TLS 1.3 (`rediss://`).
- Builds on Zig 0.16 and 0.17.

For the architecture see `hld-en.md`, for the wire-level details see `lld-en.md`, for the config fields and sizing see `config-en.md`.

## Install

Add the package as a path dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .rediz = .{ .path = "path/to/rediz" },
},
```

Wire the module in `build.zig`:

```zig
const rediz = b.dependency("rediz", .{}).module("rediz");
exe.root_module.addImport("rediz", rediz);
```

## Quickstart

```zig
const std = @import("std");
const rediz = @import("rediz");

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    const config = try rediz.parseUrl("redis://localhost:6379");

    const conn = try rediz.Conn.connect(arena.allocator(), process.io, config);
    defer conn.deinit();

    _ = try conn.set("greeting", "hello", .{ .ex_s = 60 });

    if (try conn.get("greeting")) |value| {
        std.debug.print("{s}\n", .{value});
    }
}
```

The returned value lives in the connection's per-reply arena and stays valid until the next command on that connection.

## Connection URL

`redis://[user[:password]@]host[:port][/db]`

- `rediss://` selects TLS.
- A trailing `/db` selects the database index after the handshake.
- The host may be an IP literal or a hostname (a hostname goes through the hosts and DNS lookup).

## Config

`rediz.Config` is flat. The connection reads the top group, the pool adds the rest.

| Field | Default | Meaning |
| :- | :- | :- |
| `ip` | `127.0.0.1` | IP literal or hostname |
| `port` | `6379` | server port |
| `user` | `""` | ACL user, empty uses the default user |
| `password` | `""` | empty means no auth |
| `database` | `0` | SELECT index after the handshake |
| `client_name` | `rediz` | CLIENT name through HELLO (RESP3), null = none |
| `conn_timeout_ms` | `10000` | connect plus handshake bound, 0 disables |
| `protocol_version` | `.AUTO` | `.AUTO`, `.RESP2`, `.RESP3` |
| `tls` | `.OFF` | `.OFF`, `.REQUIRE` |
| `dispatch_model` | `.ASYNC` | transport that multiplexes socket I/O: `.ASYNC` (Pool), `.EPOLL`, `.URING` |
| `max_pending_replies` | `16` | pipeline bound and outstanding deferred bound, 0 = no bound |
| `process_queue_len` | `0` | pool only: parked-acquire bound |
| `pool_size` | `6` | pool only: connections per pool |
| `retry_max` | `3` | pool only: connect attempts per acquire beyond the first |
| `retry_delay_ms` | `250` | pool only: delay between connect retries |

## API surface

| Group | Methods |
| :- | :- |
| Strings | `set`, `get`, `append`, `strlen`, `incr`, `decr`, `incrBy`, `mget`, `mset` |
| Typed JSON | `setJson`, `getJson` |
| Keys | `del`, `exists`, `expire`, `pexpire`, `ttl`, `pttl`, `persist`, `keyType` |
| Deferred (write-behind) | `setDeferred`, `delDeferred`, `drainDeferred`, `pendingDeferred`, `deferredErrorCount` |
| Server and db | `ping`, `select`, `dbSize`, `flushDb` |
| Raw | `command(args)` returns a decoded `Reply` |
| Pipelining | `pipeline()` then `add`, `sync` |
| Transport | multiplexed EPOLL/URING dispatch (`Config.dispatch_model`): `open`, `submit`, `poll`, `pending` |
| Pool | `acquire`, `release`, `discard` |

### Deferred write-behind

`setDeferred` and `delDeferred` send the command immediately but do not wait for the reply, they push it onto a pending queue that drains before the next reply-reading call. This is the write-behind mirror pattern: a cache fill or invalidation that must reach the server but whose reply the caller does not need.

```zig
try conn.setDeferred("item:42", body, .{ .ex_s = 1 });
// the SET is on the wire, its reply drains on the next read
```

The pending count is bounded by `max_pending_replies`, so a stalled server drains rather than growing memory. A server error in the drain is counted (`deferredErrorCount`), not thrown, a transport error in the drain is thrown so the caller drops the connection.

### Pipelining

```zig
var pipe = try conn.pipeline();
try pipe.add(&.{ "SET", "a", "1" });
try pipe.add(&.{ "SET", "b", "2" });
try pipe.add(&.{ "GET", "a" });

const replies = try pipe.sync();
```

`sync` returns one raw `Reply` per queued command in `add` order. A failed command comes back as its `.err` reply (data, not a thrown error) so one bad command does not abort draining the rest.

## Testing

The suites own their Redis container lifecycle:

```
zig build test-unit          # in-process, no server
zig build test-integration   # starts, tests, tears down the container
zig build test-runner        # runs every example against the container
```
