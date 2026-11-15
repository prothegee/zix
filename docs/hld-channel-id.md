# HLD: zix.Channel

Channel untuk pengiriman pesan bertipe dalam satu proses.

---

## Status

Sudah diimplementasi. Lihat ADR-017 untuk dasar keputusan desain.

---

## Tujuan

- Komunikasi bertipe dalam satu proses antara task konkuren (`io.concurrent`) atau OS thread.
- Hanya `send`/`recv` yang blocking. Varian non-blocking ditunda (lihat di bawah).
- Mode buffered (capacity > 0). Unbuffered (rendezvous) belum didukung.
- Satu struct biasa untuk semua tipe pesan. Tipe diberikan ke `init`, `send`, dan `recv`,
  lalu dicek saat runtime (ring byte yang type-erased, seperti std `Io.TypeErasedQueue`).
- Tidak ada batas lintas proses atau lintas jaringan (hanya dalam satu proses).
- Eksplisit bukan implisit: pemanggil menyediakan allocator.

---

## Model

```
Sender task  -->  [ Channel ring buffer ]  -->  Receiver task
               capacity N: blocks when full/empty
```

| Operasi | Blocking saat |
| :- | :- |
| `send(io, T, value)` | buffer penuh |
| `recv(io, T)` | buffer kosong |

Setelah `close(io)` tidak ada send baru yang diterima. `recv()` menguras semua item yang tersisa lalu mengembalikan `error.ZixChannel_Channel_Closed`.

---

## API

```zig
// buffered, capacity 8, element type u32
var channel: zix.Channel = try .init(allocator, u32, 8);
defer channel.deinit();

// send blocks when full, returns error.ZixChannel_Channel_Closed after close()
try channel.send(io, u32, 42);

// recv blocks when empty, drains remaining items after close(),
// then returns error.ZixChannel_Channel_Closed
const value = try channel.recv(io, u32); // value == 42

// close: no more sends, blocked receivers are unblocked and drain remaining items
channel.close(io);
```

Capacity harus > 0. `init()` menegaskan ini saat runtime. Unbuffered (rendezvous) belum didukung.

Tipe elemen ditetapkan oleh `init`. `send` dan `recv` menerima tipe yang sama lagi, dan tipe yang
berbeda mengembalikan `error.ZixChannel_Channel_TypeMismatch`.

| Error | Kapan |
| :- | :- |
| `ZixChannel_Channel_Closed` | `send` setelah `close`, atau `recv` pada channel yang sudah ditutup dan kosong |
| `ZixChannel_Channel_OutOfMemory` | `init` gagal mengalokasikan ring buffer |
| `ZixChannel_Channel_TypeMismatch` | `send` atau `recv` dengan tipe selain tipe `init` |

---

## Struktur Berkas

```
src/zix/channel
|
|___Channel.zig            (Channel struct, fields at file scope, in-file tests)
```

Ekspor dari `src/zix/lib.zig`:
```zig
pub const Channel = @import("channel/Channel.zig");
```

---

## Persyaratan Konkurensi

`Channel.send()` dan `Channel.recv()` memanggil `std.Io.Mutex.lockUncancelable(io)`. Ini memerlukan `io` yang valid pada thread pemanggil. io dari satu `std.Io.Threaded` boleh dipakai bersama oleh beberapa OS thread (contoh-contohnya melakukan ini), atau setiap thread membuat miliknya sendiri.

```zig
var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
defer threaded.deinit();
const io = threaded.io();

var channel: zix.Channel = try .init(std.heap.smp_allocator, u32, 8);
defer channel.deinit();

const worker_thread = try std.Thread.spawn(.{}, workerFn, .{ &channel, io });
```

---

## Hubungan dengan Model Konkurensi Server

Channel bersifat ortogonal terhadap model dispatch HTTP (`.ASYNC`, `.EPOLL`, `.URING`). Channel tidak menggantikan atau memperluas model manapun. Channel adalah primitif koordinasi dalam satu proses yang dapat digunakan berdampingan dengan model apapun.

```
.ASYNC / .EPOLL / .URING server
  handler task A  -->  Channel(Event)  -->  background task B
```

Contoh integrasi: `uds_http.zig` menghubungkan task fetcher UDS ke SSE handler melalui `Channel(u64)`:

```
[uds_server] /tmp/zix.sock [fetcher task] Channel(u64) [SSE handler]
                                                      \ [/data handler]
```

Lihat [`docs/concurrency-id.md`](concurrency-id.md) untuk entri Channel dalam tabel Applicability Protokol.

---

## Contoh

| Berkas | Pola |
| :- | :- |
| `examples/channel_basic.zig` | Producer/consumer: channel u32 dengan dua OS thread |
| `examples/channel_worker_pool.zig` | Fan-out worker pool: satu producer banyak consumer |
| `examples/channel_pipeline.zig` | Multi-stage pipeline: setiap stage berjalan sesuai kecepatannya sendiri |
| `examples/channel_ipc_a.zig` | Sisi proses IPC A (UDS server, mengirim dan menerima), pasangkan dengan ipc_b |
| `examples/channel_ipc_b.zig` | Sisi proses IPC B (UDS client, mengirim dan menerima), pasangkan dengan ipc_a |
| `examples/uds_http.zig` | Integrasi HTTP + UDS + Channel: pola nyata lengkap |

---

## Integrasi Logger

`Channel` tidak memiliki struct konfigurasi server, sehingga tidak ada field `logger`. `Channel` tidak mencetak apa pun (kode library tidak memakai `std.debug.print`, lihat ADR-023). Untuk logging lifecycle gunakan `logger.system()` secara manual:

```zig
// Uncomment to add logger (console only):
// var logger = try zix.Logger.init(std.heap.smp_allocator, .{
//     .console           = .ALWAYS,
//     .console_min_level = .INFO,
// });
// defer logger.deinit();

// Use logger.system(.INFO, "channel", "started", .{}) for manual lifecycle logging.
```

Contoh Channel tidak menyertakan blok ini. Tambahkan di tempat yang butuh logging.

---

## Belum Diimplementasi

| Fitur | Catatan |
| :- | :- |
| `trySend`/`tryRecv` non-blocking | Ditunda. Varian blocking mencakup semua contoh saat ini. |
| Unbuffered (rendezvous, capacity = 0) | `init()` menegaskan capacity > 0. Sinkronisasi dua sisi menambah kompleksitas. |
| `select` / multiplex atas N channel | Ditunda. Desain ring internal tidak menghalangi implementasinya. |
| `send` / `recv` dengan timeout | Ditunda. `std.Io.Condition` di Zig 0.17 punya `waitTimeout`, jadi bisa dibuat nanti. |

---

###### end of hld-channel
