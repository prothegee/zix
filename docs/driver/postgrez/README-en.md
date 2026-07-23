# postgrez

A PostgreSQL database driver written in pure Zig, standard library only.

- Wire protocol 3.2 with an in-place 3.0 fallback, minimum server is PostgreSQL 15.
- Binary-first value encoding with an automatic text fallback per parameter.
- Prepared statements, query pipelining, a batching executor, a thread-safe pool.
- SCRAM and SCRAM-PLUS (channel binding) plus cleartext auth, TLS 1.3.
- COPY streaming, LISTEN and NOTIFY.
- Builds on Zig 0.16 and 0.17.

For the architecture see `hld-en.md`, for the wire-level details see `lld-en.md`, for the config fields and sizing see `config-en.md`.

## Install

Add the package as a path dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .postgrez = .{ .path = "path/to/postgrez" },
},
```

Wire the module in `build.zig`:

```zig
const postgrez = b.dependency("postgrez", .{}).module("postgrez");
exe.root_module.addImport("postgrez", postgrez);
```

## Quickstart

```zig
const std = @import("std");
const postgrez = @import("postgrez");

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    const config = try postgrez.parseUrl("postgres://app:secret@localhost:5432/shop");

    const conn = try postgrez.Conn.connect(arena.allocator(), process.io, config);
    defer conn.deinit();

    const affected = try conn.exec("INSERT INTO items (name) VALUES ($1)", .{"widget"});
    std.debug.print("inserted {d}\n", .{affected});

    const Item = struct { id: i64, name: []const u8 };
    const items = try conn.query(Item, "SELECT id, name FROM items ORDER BY id", .{});
    for (items) |item| std.debug.print("{d} {s}\n", .{ item.id, item.name });
}
```

The connection allocator is the caller's: an arena means mapped rows need no per-item free.

## Connection URL

`postgres://[user[:password]@]host[:port][/database][?sslmode=MODE]`

- `postgresql://` is an accepted alias.
- `sslmode` selects TLS: `disable` (default), `prefer` (ask, continue cleartext when refused), `require` (fail when refused).
- The host may be an IP literal or a hostname (a hostname goes through the hosts and DNS lookup).
- Query parameters other than `sslmode` are ignored.

## Config

`postgrez.Config` is flat. The connection reads the top group, the pool and executor add the rest.

| Field | Default | Meaning |
| :- | :- | :- |
| `ip` | `127.0.0.1` | IP literal or hostname |
| `port` | `5432` | server port |
| `user` | required | role name |
| `password` | `""` | role password |
| `database` | null | database name, null uses the user name |
| `application_name` | `postgrez` | reported to the server |
| `conn_timeout_ms` | `10000` | connect plus startup bound, 0 disables |
| `protocol_version` | `.AUTO` | startup protocol selector, negotiates 3.2 with a 3.0 fallback |
| `tls` | `.OFF` | `.OFF`, `.PREFER`, `.REQUIRE` |
| `dispatch_model` | `.ASYNC` | transport that multiplexes socket I/O: `.ASYNC` (Executor), `.EPOLL`, `.URING` |
| `max_pending_replies` | `16` | replies a connection may owe (pipeline and batch bound), 0 = no bound |
| `process_queue_len` | `0` | pool only: parked-acquire bound, 0 sheds instead of parking |
| `pool_size` | `6` | pool only: connections per pool |
| `retry_max` | `3` | pool only: connect attempts per acquire beyond the first |
| `retry_delay_ms` | `250` | pool only: delay between connect retries |

## API surface

| Type | Use |
| :- | :- |
| `Conn` | one connection: `exec`, `query`, `queryRow`, `rows`, `prepare`, `pipeline`, `copyIn`, `copyOut`, `listen`, `notify`, `begin` |
| `Transaction` | `begin()` result: `exec`, `query`, `queryRow`, `rows`, `commit`, `rollback` |
| `Statement` | prepared statement: `exec`, `rows`, `query`, `queryRow`, `sendRows`, `awaitRows` |
| `Pipeline` | batch commands in one round trip: `begin`, `add`, `sync` |
| `Executor` | batching fleet over a pool for high-throughput parameterized queries |
| `Transport` | multiplexed EPOLL/URING dispatch (`Config.dispatch_model`): `open`, `submit`, `poll`, `pending` |
| `dispatch.Line` | reactor-less single-connection pipeline for a caller-owned event loop: `open`, `submit` (stages), `flush`, `pump`, `pending` |
| `Pool` | thread-safe connection pool: `acquire`, `release`, `discard` |
| `CopyIn` / `CopyOut` | COPY streaming |

### Prepared statements and pipelining

```zig
var by_id = try conn.prepare("SELECT name FROM items WHERE id = $1");
defer by_id.deinit();

const name = try by_id.queryRow(struct { name: []const u8 }, .{@as(i64, 7)});
```

`sendRows` and `awaitRows` queue several executions behind one Sync so they share one round trip. See `lld-en.md` for the batch rules.

### Executor

`Executor(Job, statement_count)` owns an intake queue, worker threads, an internal pool, and a per-connection prepared-statement cache. Submit a job and a worker runs it on a pooled connection, several jobs per round trip.

```zig
const Db = postgrez.Executor(MyJob, 3);

var db = try Db.init(allocator, io, config, .{ .run_batch = runBatch });
defer db.deinit();

_ = db.submit(job);
```

The consumer writes only the `Job` type and `run_batch`, the driver owns the concurrency. See `hld-en.md` for the model.

## Testing

The suites own their PostgreSQL 18 container lifecycle:

```
zig build test-unit          # in-process, no server
zig build test-integration   # starts, tests, tears down the container
zig build test-runner        # runs every example against the container
```
