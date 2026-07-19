# rediz

Driver database Redis yang ditulis murni dengan Zig, hanya memakai standard library.

- RESP3 lewat HELLO dengan fallback RESP2 di tempat, kompatibel dengan Redis 7 dan 8.
- Helper nilai bertipe plus jalan pintas raw command.
- Command pipelining dan jalur deferred write-behind.
- Pool koneksi yang thread-safe.
- TLS 1.3 (`rediss://`).
- Kompatibel dengan Zig 0.16 dan 0.17.

Untuk arsitektur lihat `hld-id.md`, untuk detail wire-level lihat `lld-id.md`, untuk field config dan sizing lihat `config-id.md`.

## Instalasi

Tambahkan paket sebagai dependency path di `build.zig.zon`:

```zig
.dependencies = .{
    .rediz = .{ .path = "path/to/rediz" },
},
```

Sambungkan modulnya di `build.zig`:

```zig
const rediz = b.dependency("rediz", .{}).module("rediz");
exe.root_module.addImport("rediz", rediz);
```

## Mulai cepat

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

Nilai yang dikembalikan hidup di arena per reply koneksi dan tetap valid hingga command berikutnya pada koneksi itu.

## URL koneksi

`redis://[user[:password]@]host[:port][/db]`

- `rediss://` memilih TLS.
- Akhiran `/db` memilih indeks database setelah handshake.
- Host boleh berupa IP literal atau hostname (hostname melewati lookup hosts dan DNS).

## Config

`rediz.Config` bersifat flat. Koneksi membaca grup atas, pool memakai sisanya.

| Field | Default | Arti |
| :- | :- | :- |
| `ip` | `127.0.0.1` | IP literal atau hostname |
| `port` | `6379` | port server |
| `user` | `""` | ACL user, kosong memakai user default |
| `password` | `""` | kosong berarti tanpa auth |
| `database` | `0` | indeks SELECT setelah handshake |
| `client_name` | `rediz` | nama CLIENT lewat HELLO (RESP3), null = tidak ada |
| `conn_timeout_ms` | `10000` | batas fase connect plus handshake, 0 menonaktifkan |
| `protocol_version` | `.AUTO` | `.AUTO`, `.RESP2`, `.RESP3` |
| `tls` | `.OFF` | `.OFF`, `.REQUIRE` |
| `dispatch_model` | `.ASYNC` | transport yang me-multiplex I/O socket: `.ASYNC` (Pool), `.EPOLL`, `.URING` |
| `max_pending_replies` | `16` | batas pipeline dan batas deferred tertunggak, 0 = tanpa batas |
| `process_queue_len` | `0` | pool saja: batas acquire yang parkir |
| `pool_size` | `6` | pool saja: jumlah koneksi per pool |
| `retry_max` | `3` | pool saja: percobaan connect per acquire di luar yang pertama |
| `retry_delay_ms` | `250` | pool saja: jeda antar retry connect |

## Permukaan API

| Grup | Method |
| :- | :- |
| String | `set`, `get`, `append`, `strlen`, `incr`, `decr`, `incrBy`, `mget`, `mset` |
| JSON bertipe | `setJson`, `getJson` |
| Key | `del`, `exists`, `expire`, `pexpire`, `ttl`, `pttl`, `persist`, `keyType` |
| Deferred (write-behind) | `setDeferred`, `delDeferred`, `drainDeferred`, `pendingDeferred`, `deferredErrorCount` |
| Server dan db | `ping`, `select`, `dbSize`, `flushDb` |
| Raw | `command(args)` mengembalikan `Reply` yang sudah di-decode |
| Pipelining | `pipeline()` lalu `add`, `sync` |
| Transport | dispatch EPOLL/URING yang di-multiplex (`Config.dispatch_model`): `open`, `submit`, `poll`, `pending` |
| Pool | `acquire`, `release`, `discard` |

### Deferred write-behind

`setDeferred` dan `delDeferred` mengirim command seketika tetapi tidak menunggu reply, keduanya mendorong reply itu ke antrean pending yang menguras sebelum panggilan pembaca-reply berikutnya. Ini pola mirror write-behind: pengisian cache atau invalidasi yang harus sampai ke server tetapi reply-nya tidak dibutuhkan pemanggil.

```zig
try conn.setDeferred("item:42", body, .{ .ex_s = 1 });
// SET sudah di wire, reply-nya menguras pada pembacaan berikutnya
```

Hitungan pending dibatasi `max_pending_replies`, jadi server yang macet menguras alih-alih menumbuhkan memori. Sebuah error server dalam drain dihitung (`deferredErrorCount`), bukan dilempar, sebuah error transport dalam drain dilempar agar pemanggil melepas koneksi.

### Pipelining

```zig
var pipe = try conn.pipeline();
try pipe.add(&.{ "SET", "a", "1" });
try pipe.add(&.{ "SET", "b", "2" });
try pipe.add(&.{ "GET", "a" });

const replies = try pipe.sync();
```

`sync` mengembalikan satu raw `Reply` per command yang antre sesuai urutan `add`. Command yang gagal kembali sebagai reply `.err` miliknya (data, bukan error yang dilempar) sehingga satu command buruk tidak membatalkan penguras sisanya.

## Pengujian

Setiap suite memegang siklus hidup container Redis sendiri:

```
zig build test-unit          # in-process, tanpa server
zig build test-integration   # start, uji, teardown container
zig build test-runner        # jalankan setiap example terhadap container
```
