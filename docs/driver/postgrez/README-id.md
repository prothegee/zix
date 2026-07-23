# postgrez

Driver database PostgreSQL yang ditulis murni dengan Zig, hanya memakai standard library.

- Wire protocol 3.2 dengan fallback 3.0 di tempat, server minimum adalah PostgreSQL 15.
- Encoding nilai binary-first dengan fallback text otomatis per parameter.
- Prepared statement, query pipelining, executor batching, pool yang thread-safe.
- Auth SCRAM dan SCRAM-PLUS (channel binding) serta cleartext, TLS 1.3.
- Streaming COPY, LISTEN dan NOTIFY.
- Kompatibel dengan Zig 0.16 dan 0.17.

Untuk arsitektur lihat `hld-id.md`, untuk detail wire-level lihat `lld-id.md`, untuk field config dan sizing lihat `config-id.md`.

## Instalasi

Tambahkan paket sebagai dependency path di `build.zig.zon`:

```zig
.dependencies = .{
    .postgrez = .{ .path = "path/to/postgrez" },
},
```

Sambungkan modulnya di `build.zig`:

```zig
const postgrez = b.dependency("postgrez", .{}).module("postgrez");
exe.root_module.addImport("postgrez", postgrez);
```

## Mulai cepat

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

Allocator koneksi dipegang oleh pemanggil: memakai arena berarti row hasil map tidak perlu dibebaskan per item.

## URL koneksi

`postgres://[user[:password]@]host[:port][/database][?sslmode=MODE]`

- `postgresql://` diterima sebagai alias.
- `sslmode` memilih TLS: `disable` (default), `prefer` (minta, lanjut cleartext bila ditolak), `require` (gagal bila ditolak).
- Host boleh berupa IP literal atau hostname (hostname melewati lookup hosts dan DNS).
- Query parameter selain `sslmode` diabaikan.

## Config

`postgrez.Config` bersifat flat. Koneksi membaca grup atas, pool dan executor memakai sisanya.

| Field | Default | Arti |
| :- | :- | :- |
| `ip` | `127.0.0.1` | IP literal atau hostname |
| `port` | `5432` | port server |
| `user` | wajib | nama role |
| `password` | `""` | password role |
| `database` | null | nama database, null memakai nama user |
| `application_name` | `postgrez` | dilaporkan ke server |
| `conn_timeout_ms` | `10000` | batas fase connect plus startup, 0 menonaktifkan |
| `protocol_version` | `.AUTO` | selector protocol startup, menegosiasi 3.2 dengan fallback 3.0 |
| `tls` | `.OFF` | `.OFF`, `.PREFER`, `.REQUIRE` |
| `dispatch_model` | `.ASYNC` | transport yang me-multiplex I/O socket: `.ASYNC` (Executor), `.EPOLL`, `.URING` |
| `max_pending_replies` | `16` | reply yang boleh tertunggak satu koneksi (batas pipeline dan batch), 0 = tanpa batas |
| `process_queue_len` | `0` | pool saja: batas acquire yang parkir, 0 shed alih-alih parkir |
| `pool_size` | `6` | pool saja: jumlah koneksi per pool |
| `retry_max` | `3` | pool saja: percobaan connect per acquire di luar yang pertama |
| `retry_delay_ms` | `250` | pool saja: jeda antar retry connect |

## Permukaan API

| Tipe | Kegunaan |
| :- | :- |
| `Conn` | satu koneksi: `exec`, `query`, `queryRow`, `rows`, `prepare`, `pipeline`, `copyIn`, `copyOut`, `listen`, `notify`, `begin` |
| `Transaction` | hasil `begin()`: `exec`, `query`, `queryRow`, `rows`, `commit`, `rollback` |
| `Statement` | prepared statement: `exec`, `rows`, `query`, `queryRow`, `sendRows`, `awaitRows` |
| `Pipeline` | batch beberapa command dalam satu round trip: `begin`, `add`, `sync` |
| `Executor` | fleet batching di atas pool untuk query berparameter throughput tinggi |
| `Transport` | dispatch EPOLL/URING yang di-multiplex (`Config.dispatch_model`): `open`, `submit`, `poll`, `pending` |
| `dispatch.Line` | pipeline satu-koneksi tanpa reactor untuk event loop milik pemanggil: `open`, `submit` (men-stage), `flush`, `pump`, `pending` |
| `Pool` | pool koneksi thread-safe: `acquire`, `release`, `discard` |
| `CopyIn` / `CopyOut` | streaming COPY |

### Prepared statement dan pipelining

```zig
var by_id = try conn.prepare("SELECT name FROM items WHERE id = $1");
defer by_id.deinit();

const name = try by_id.queryRow(struct { name: []const u8 }, .{@as(i64, 7)});
```

`sendRows` dan `awaitRows` mengantre beberapa eksekusi di belakang satu Sync sehingga berbagi satu round trip. Lihat `lld-id.md` untuk aturan batch.

### Executor

`Executor(Job, statement_count)` memiliki intake queue, worker thread, pool internal, dan cache prepared statement per koneksi. Submit satu job, lalu satu worker menjalankannya di atas koneksi dari pool, beberapa job per round trip.

```zig
const Db = postgrez.Executor(MyJob, 3);

var db = try Db.init(allocator, io, config, .{ .run_batch = runBatch });
defer db.deinit();

_ = db.submit(job);
```

Pemakai hanya menulis tipe `Job` dan `run_batch`, driver yang memegang concurrency-nya. Lihat `hld-id.md` untuk modelnya.

## Pengujian

Setiap suite memegang siklus hidup container PostgreSQL 18 sendiri:

```
zig build test-unit          # in-process, tanpa server
zig build test-integration   # start, uji, teardown container
zig build test-runner        # jalankan setiap example terhadap container
```
