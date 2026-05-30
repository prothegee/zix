# LLD: zix.Channel

Detail implementasi internal. Untuk alasan desain lihat [`docs/hld-channel-id.md`](hld-channel-id.md) dan ADR-017.

---

## Struktur Berkas

```
src/channel/
    channel.zig   // Channel(comptime T: type) implementasi generik
    Channel.zig   // namespace aggregator
```

---

## Struktur Data

Ring buffer yang didukung oleh slice `[]T` yang dialokasikan di heap. Semua state berada dalam struct `Channel(T)` yang dikembalikan oleh `init()`.

```
buf: []T          // ring yang dialokasikan di heap, panjang = capacity
head: usize       // indeks item berikutnya yang akan dibaca
count: usize      // jumlah item yang saat ini ada di buffer
closed: bool      // di-set oleh close(), tidak ada send baru setelah titik ini
mutex: std.Io.Mutex
not_empty: std.Io.Condition
not_full:  std.Io.Condition
allocator: std.mem.Allocator
```

Aritmetika ring:
- Indeks tulis (tail): `(head + count) % buf.len`
- Majukan head saat recv: `head = (head + 1) % buf.len`

---

## Penguncian

`std.Io.Mutex` + `std.Io.Condition` (fiber-aware). Diperlukan agar Channel dapat digunakan dari task handler `io.concurrent()` maupun OS thread biasa.

`std.Thread.Mutex` pernah dievaluasi dan ditolak karena memblokir OS thread alih-alih menyerahkan kontrol ke scheduler, yang tidak kompatibel dengan konkurensi berbasis fiber.

---

## Algoritma Send/Recv

### send()

```
lock mutex
while count == buf.len:
    if closed: unlock + return error.Closed
    not_full.waitUncancelable(io, &mutex)
if closed: unlock + return error.Closed
buf[(head + count) % buf.len] = value
count += 1
unlock
not_empty.signal(io)
```

### recv()

```
lock mutex
while count == 0:
    if closed: unlock + return error.Closed
    not_empty.waitUncancelable(io, &mutex)
value = buf[head]
head = (head + 1) % buf.len
count -= 1
unlock
not_full.signal(io)
return value
```

---

## close()

```
lock mutex
closed = true
unlock
not_empty.broadcast(io)   // buka blokir semua recv yang menunggu
not_full.broadcast(io)    // buka blokir semua send yang menunggu
```

---

## Memori

`init()` memanggil `allocator.alloc(T, capacity)`. `deinit()` memanggil `allocator.free(buf)`. Tidak ada alokasi heap lainnya.

---

###### end of lld-channel
