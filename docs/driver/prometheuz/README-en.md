# prometheuz

A Prometheus and node-exporter driver written in pure Zig, standard library only.

- Prometheus text exposition format 0.0.4 parser: HELP/TYPE, multi-line histogram and summary families, label escaping, `+Inf`/`-Inf`/`Nan`, optional timestamps.
- A one-shot scrape primitive and a background `Scraper` that polls on an interval and publishes a refcounted snapshot.
- `remote_write` push: real `WriteRequest` protobuf schema, snappy-compressed.
- PromQL instant and ranged query against a real Prometheus.
- An app-authored metric registry (`Counter`, `Gauge`) for values that never come from a scrape, plus a text 0.0.4 encoder for serving them.
- Own minimal HTTP/1.1 client, cleartext only: standalone package, does not depend on `zix.Http.Client` (see `hld-en.md`).
- Builds on Zig 0.16 and 0.17.

For the architecture see `hld-en.md`, for the wire-level details see `lld-en.md`, for the config fields see `config-en.md`.

## Install

Add the package as a path dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .prometheuz = .{ .path = "path/to/prometheuz" },
},
```

Wire the module in `build.zig`:

```zig
const prometheuz = b.dependency("prometheuz", .{}).module("prometheuz");
exe.root_module.addImport("prometheuz", prometheuz);
```

## Quickstart

Scrape a node-exporter (or any Prometheus text 0.0.4 endpoint):

```zig
const std = @import("std");
const prometheuz = @import("prometheuz");

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var snapshot = try prometheuz.scrapeOnce(arena.allocator(), process.io, .{ .ip = "127.0.0.1", .port = 9100 });
    defer snapshot.deinit();

    if (snapshot.family("node_cpu_seconds_total")) |family| {
        std.debug.print("{s}: {d} samples\n", .{ family.name, family.samples.len });
    }
}
```

`scrapeOnce` never throws a network or parse error: a failed scrape comes back as `snapshot.up == false` with `snapshot.last_error` set, so a bad target is observable, not thrown.

Record an app-authored value and push it:

```zig
var registry = prometheuz.Registry.init(allocator);
defer registry.deinit();

const write_errors = try registry.counter("app_write_errors_total", "Failed write operations", &.{"reason"});
write_errors.with(&.{"user_create_failed"}).inc();

const samples = try registry.snapshot(arena.allocator());
try prometheuz.remoteWrite(arena.allocator(), process.io, .{ .ip = "127.0.0.1", .port = 9090 }, samples);
```

## Target URL

`http://host[:port][/path]`

- `https://` is rejected: the driver's own HTTP client is cleartext only.
- `parseScrapeUrl` defaults the port to `9100` and the path to `/metrics`.
- `parseWriteUrl` defaults the port to `9090` and the path to `/api/v1/write`.
- `parseQueryUrl` defaults the port to `9090` (the path is fixed per call, `query`/`queryRange` append it).
- The host may be an IP literal or a hostname (a hostname goes through the hosts and DNS lookup).

## Config

Three flat, per-surface configs, no shared struct: a scrape target, a remote_write receiver, and a query API target are three different servers in a real deployment. See `config-en.md` for the full field list and tuning notes.

| Config | Default port | Default path | Use |
| :- | :- | :- | :- |
| `ScrapeConfig` | `9100` | `/metrics` | `scrapeOnce`, `Scraper` |
| `WriteConfig` | `9090` | `/api/v1/write` | `remoteWrite` |
| `QueryConfig` | `9090` | (fixed per call) | `query`, `queryRange` |

## API surface

| Type / function | Use |
| :- | :- |
| `scrapeOnce` | one blocking GET plus parse, returns an owned `*Snapshot` |
| `Scraper` | background poller thread: `start`, `latest`, `deinit` |
| `Snapshot` | refcounted scrape result: `family`, `retain`, `release`/`deinit` |
| `MetricFamily` | `sumSample`, `countSample`, `bucket`, `quantile` |
| `Sample` | `label` |
| `parse` | parse a raw text 0.0.4 body directly |
| `Registry` | app-authored metrics: `counter`, `gauge`, `snapshot`, `families` |
| `Counter` / `Gauge` | `inc`, `dec` (gauge only), `add`, `set` (gauge only), `get` |
| `CounterVec` / `GaugeVec` | `.with(&label_values)` returns the `*Counter`/`*Gauge` cell for that combination |
| `expose` | encode a `Registry`'s current state as text 0.0.4 (serve it yourself) |
| `remoteWrite` | push samples to a remote_write receiver |
| `query` / `queryRange` | PromQL instant / ranged query, returns an owned `*QueryResult` |
| `parseScrapeUrl` / `parseWriteUrl` / `parseQueryUrl` | parse a target URL into the matching config |

### Registry: labels and `.with()`

A `CounterVec`/`GaugeVec` holds one cell per label-value combination, created the first time it is seen:

```zig
const write_errors = try registry.counter("app_write_errors_total", "Failed write operations", &.{"reason"});

write_errors.with(&.{"user_create_failed"}).inc();
write_errors.with(&.{"tx_failed"}).add(3);
```

`.with()` never returns an error: an allocation failure on a brand-new combination falls back to a shared discard cell instead of propagating into the caller's hot path. See `hld-en.md` for why.

### PromQL query

```zig
var result = try prometheuz.query(allocator, io, .{ .ip = "127.0.0.1", .port = 9090 }, "up");
defer result.deinit();

for (result.vector) |entry| std.debug.print("{d}\n", .{entry.value});
```

`query` returns `result_type = .vector`, `queryRange` returns `.matrix`. Only the matching field (`vector` or `matrix`) is populated.

## Testing

```
zig build test-unit          # in-process, no server
zig build examples           # build every one-shot example into zig-out/bin
zig build test-runner        # runs every one-shot example against real containers (owns the lifecycle)
```

`test-runner` builds and starts `containers/node-exporter` and `containers/prometheus` (repo root), waits for both to answer, runs every one-shot example, then tears the containers down. `examples/registry_live_demo.zig` is not part of any of the above: it is a long-running demo that self-manages its own container lifecycle, see `hld-en.md`.
