# prometheuz

Driver Prometheus dan node-exporter yang ditulis murni dengan Zig, hanya memakai standard library.

- Parser Prometheus text exposition format 0.0.4: HELP/TYPE, family histogram dan summary multi-line, escaping label, `+Inf`/`-Inf`/`Nan`, timestamp opsional.
- Primitive scrape sekali jalan dan `Scraper` latar belakang yang polling per interval dan menerbitkan snapshot ber-refcount.
- Push `remote_write`: schema protobuf `WriteRequest` asli, terkompresi snappy.
- Query PromQL instant dan ranged terhadap Prometheus asli.
- Registry metrik yang ditulis aplikasi (`Counter`, `Gauge`) untuk nilai yang tidak pernah berasal dari scrape, plus encoder text 0.0.4 untuk menyajikannya.
- Client HTTP/1.1 minimal milik sendiri, cleartext saja: paket standalone, tidak bergantung pada `zix.Http.Client` (lihat `hld-id.md`).
- Kompatibel dengan Zig 0.16 dan 0.17.

Untuk arsitektur lihat `hld-id.md`, untuk detail wire-level lihat `lld-id.md`, untuk field config lihat `config-id.md`.

## Instalasi

Tambahkan paket sebagai dependency path di `build.zig.zon`:

```zig
.dependencies = .{
    .prometheuz = .{ .path = "path/to/prometheuz" },
},
```

Sambungkan modulnya di `build.zig`:

```zig
const prometheuz = b.dependency("prometheuz", .{}).module("prometheuz");
exe.root_module.addImport("prometheuz", prometheuz);
```

## Mulai cepat

Scrape sebuah node-exporter (atau endpoint Prometheus text 0.0.4 mana pun):

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

`scrapeOnce` tidak pernah melempar error network atau parse: scrape yang gagal kembali sebagai `snapshot.up == false` dengan `snapshot.last_error` terisi, sehingga target yang bermasalah bisa diamati, bukan dilempar sebagai error.

Catat nilai yang ditulis aplikasi lalu push:

```zig
var registry = prometheuz.Registry.init(allocator);
defer registry.deinit();

const write_errors = try registry.counter("app_write_errors_total", "Failed write operations", &.{"reason"});
write_errors.with(&.{"user_create_failed"}).inc();

const samples = try registry.snapshot(arena.allocator());
try prometheuz.remoteWrite(arena.allocator(), process.io, .{ .ip = "127.0.0.1", .port = 9090 }, samples);
```

## URL target

`http://host[:port][/path]`

- `https://` ditolak: client HTTP milik driver ini cleartext saja.
- `parseScrapeUrl` memakai default port `9100` dan path `/metrics`.
- `parseWriteUrl` memakai default port `9090` dan path `/api/v1/write`.
- `parseQueryUrl` memakai default port `9090` (path tetap per pemanggilan, `query`/`queryRange` yang menambahkannya).
- Host boleh berupa IP literal atau hostname (hostname melewati lookup hosts dan DNS).

## Config

Tiga config flat per-permukaan, tanpa struct bersama: target scrape, receiver remote_write, dan target API query adalah tiga server berbeda pada deployment nyata. Lihat `config-id.md` untuk daftar field lengkap dan catatan tuning.

| Config | Port default | Path default | Kegunaan |
| :- | :- | :- | :- |
| `ScrapeConfig` | `9100` | `/metrics` | `scrapeOnce`, `Scraper` |
| `WriteConfig` | `9090` | `/api/v1/write` | `remoteWrite` |
| `QueryConfig` | `9090` | (tetap per pemanggilan) | `query`, `queryRange` |

## Permukaan API

| Tipe / fungsi | Kegunaan |
| :- | :- |
| `scrapeOnce` | satu GET blocking plus parse, mengembalikan `*Snapshot` yang dimiliki pemanggil |
| `Scraper` | thread poller latar belakang: `start`, `latest`, `deinit` |
| `Snapshot` | hasil scrape ber-refcount: `family`, `retain`, `release`/`deinit` |
| `MetricFamily` | `sumSample`, `countSample`, `bucket`, `quantile` |
| `Sample` | `label` |
| `parse` | parse body text 0.0.4 mentah langsung |
| `Registry` | metrik yang ditulis aplikasi: `counter`, `gauge`, `snapshot`, `families` |
| `Counter` / `Gauge` | `inc`, `dec` (gauge saja), `add`, `set` (gauge saja), `get` |
| `CounterVec` / `GaugeVec` | `.with(&label_values)` mengembalikan cell `*Counter`/`*Gauge` untuk kombinasi itu |
| `expose` | encode state `Registry` saat ini sebagai text 0.0.4 (disajikan sendiri) |
| `remoteWrite` | push sample ke receiver remote_write |
| `query` / `queryRange` | query PromQL instant / ranged, mengembalikan `*QueryResult` yang dimiliki pemanggil |
| `parseScrapeUrl` / `parseWriteUrl` / `parseQueryUrl` | parse URL target menjadi config yang sesuai |

### Registry: label dan `.with()`

`CounterVec`/`GaugeVec` menyimpan satu cell per kombinasi nilai label, dibuat pada saat pertama kali dilihat:

```zig
const write_errors = try registry.counter("app_write_errors_total", "Failed write operations", &.{"reason"});

write_errors.with(&.{"user_create_failed"}).inc();
write_errors.with(&.{"tx_failed"}).add(3);
```

`.with()` tidak pernah mengembalikan error: kegagalan alokasi pada kombinasi baru jatuh ke cell discard bersama, bukan merambat ke hot path pemanggil. Lihat `hld-id.md` untuk alasannya.

### Query PromQL

```zig
var result = try prometheuz.query(allocator, io, .{ .ip = "127.0.0.1", .port = 9090 }, "up");
defer result.deinit();

for (result.vector) |entry| std.debug.print("{d}\n", .{entry.value});
```

`query` mengembalikan `result_type = .vector`, `queryRange` mengembalikan `.matrix`. Hanya field yang sesuai (`vector` atau `matrix`) yang terisi.

## Pengujian

```
zig build test-unit          # in-process, tanpa server
zig build examples           # build setiap example sekali jalan ke zig-out/bin
zig build test-runner        # jalankan setiap example sekali jalan terhadap container asli (memegang siklus hidupnya)
```

`test-runner` membangun dan menjalankan `containers/node-exporter` dan `containers/prometheus` (root repo), menunggu keduanya siap, menjalankan setiap example sekali jalan, lalu teardown container. `examples/registry_live_demo.zig` bukan bagian dari langkah di atas: ia demo yang berjalan terus-menerus dan memegang siklus hidup container-nya sendiri, lihat `hld-id.md`.
