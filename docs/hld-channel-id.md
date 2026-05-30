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
- Generic bertipe secara comptime atas tipe pesan (tidak ada type erasure saat runtime).
- Tidak ada batas lintas proses atau lintas jaringan (hanya dalam satu proses).
- Eksplisit bukan implisit: pemanggil menyediakan allocator.

---

## Model

```
Sender task  -->  [ Channel(T) ring buffer ]  -->  Receiver task
               capacity N: blocks when full/empty
```

| Operasi | Blocking saat |
| :- | :- |
| `send(io, value)` | buffer penuh |
| `recv(io)` | buffer kosong |

Setelah `close(io)` tidak ada send baru yang diterima. `recv()` menguras semua item yang tersisa lalu mengembalikan `error.Closed`.

---

## API

```zig
const MyChan = zix.Channel(u32);

// buffered, capacity 8
var ch = try MyChan.init(allocator, 8);
defer ch.deinit();

// send blocks when full, returns error.Closed if ch.close() was called
try ch.send(io, 42);

// recv blocks when empty, drains remaining items after close(), then returns error.Closed
const v = try ch.recv(io);  // v == 42

// close: no more sends, blocked receivers are unblocked and drain remaining items
ch.close(io);
```

Capacity harus > 0. `init()` menegaskan ini saat runtime. Unbuffered (rendezvous) belum didukung.

---

## Struktur Berkas

```
src/channel/
    channel.zig   // Channel(comptime T: type) generic implementation
    Channel.zig   // namespace aggregator (pub const Channel = channel.zig.Channel)
```

Ekspor dari `src/zix.zig`:
```zig
pub const Channel = @import("channel/Channel.zig").Channel;
```

---

## Persyaratan Konkurensi

`Channel.send()` dan `Channel.recv()` memanggil `std.Io.Mutex.lockUncancelable(io)`. Ini memerlukan `io` yang valid pada thread pemanggil. Setiap thread harus memiliki `std.Io` sendiri (misalnya dari `std.Io.Threaded`).

```zig
var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
defer threaded.deinit();
const io = threaded.io();

var ch = try MyChan.init(std.heap.smp_allocator, 8);
defer ch.deinit();

const t = try std.Thread.spawn(.{}, workerFn, .{ &ch, io });
```

---

## Hubungan dengan Model Konkurensi Server

Channel bersifat ortogonal terhadap model dispatch HTTP (`.POOL`, `.ASYNC`, `.MIXED`). Channel tidak menggantikan atau memperluas model manapun. Channel adalah primitif koordinasi dalam satu proses yang dapat digunakan berdampingan dengan model apapun.

```
.POOL / .ASYNC / .MIXED server
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
| `examples/channel_basic.zig` | Producer/consumer: Channel(u32) dengan dua OS thread |
| `examples/channel_worker_pool.zig` | Fan-out worker pool: satu producer banyak consumer |
| `examples/channel_pipeline.zig` | Multi-stage pipeline: setiap stage berjalan sesuai kecepatannya sendiri |
| `examples/channel_ipc_a.zig` | Sisi proses IPC A (writer), pasangkan dengan ipc_b |
| `examples/channel_ipc_b.zig` | Sisi proses IPC B (reader), pasangkan dengan ipc_a |
| `examples/uds_http.zig` | Integrasi HTTP + UDS + Channel: pola nyata lengkap |

---

## Integrasi Logger

`Channel` tidak memiliki struct konfigurasi server, sehingga tidak ada field `logger`. Gunakan `logger.system()` secara manual untuk event lifecycle:

```zig
// Uncomment to add logger (console only):
// var logger = try zix.Logger.init(std.heap.smp_allocator, .{
//     .console           = .ALWAYS,
//     .console_min_level = .INFO,
// });
// defer logger.deinit();

// Use logger.system(.INFO, "channel", "started", .{}) for manual lifecycle logging.
```

Semua contoh Channel menyertakan blok yang sudah dikomentari ini dan siap untuk diaktifkan.

---

## Belum Diimplementasi

| Fitur | Catatan |
| :- | :- |
| `trySend`/`tryRecv` non-blocking | Ditunda. Varian blocking mencakup semua contoh saat ini. |
| Unbuffered (rendezvous, capacity = 0) | `init()` menegaskan capacity > 0. Sinkronisasi dua sisi menambah kompleksitas. |
| `select` / multiplex atas N channel | Ditunda. Desain ring internal tidak menghalangi implementasinya. |
| `send` / `recv` dengan timeout | Tidak dapat diimplementasi: `std.Io.Condition` tidak memiliki metode `timedWait`. Tertahan hingga stdlib menambahkannya. |

---

###### end of hld-channel
