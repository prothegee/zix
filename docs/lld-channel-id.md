# LLD: zix.Channel

Detail implementasi internal. Untuk alasan desain lihat [`docs/hld-channel-id.md`](hld-channel-id.md) dan ADR-017.

---

## Struktur Berkas

```
src/zix/channel
|
|___Channel.zig            (Channel struct, fields at file scope, in-file tests)
```

---

## Struktur Data

Ring buffer yang didukung oleh slice `[]u8` yang dialokasikan di heap (type-erased). `Channel.zig`
adalah struct itu sendiri, field-nya ada di file scope.

```
buf: []u8         // ring yang dialokasikan di heap, panjang = capacity * elem_size
capacity: usize   // jumlah slot
elem_size: usize  // @sizeOf(T) dari tipe init
type_name: []const u8 // @typeName(T) dari tipe init
head: usize       // indeks item berikutnya yang akan dibaca
count: usize      // jumlah item yang saat ini ada di buffer
closed: bool      // di-set oleh close(), tidak ada send baru setelah titik ini
mutex: std.Io.Mutex
not_empty: std.Io.Condition
not_full:  std.Io.Condition
allocator: std.mem.Allocator
```

Aritmetika ring:
- Indeks tulis (tail): `(head + count) % capacity`
- Majukan head saat recv: `head = (head + 1) % capacity`
- Byte slot: `buf[index * elem_size ..][0..elem_size]`, nilai disalin dengan `@memcpy`

---

## Penguncian

`std.Io.Mutex` + `std.Io.Condition` (fiber-aware). Diperlukan agar Channel dapat digunakan dari task handler `io.concurrent()` maupun OS thread biasa.

`std.Thread.Mutex` pernah dievaluasi dan ditolak karena memblokir OS thread alih-alih menyerahkan kontrol ke scheduler, yang tidak kompatibel dengan konkurensi berbasis fiber.

---

## Algoritma Send/Recv

### send()

```
if T is not the init type: return error.ZixChannel_Channel_TypeMismatch
lock mutex
while count == capacity and not closed:
    not_full.waitUncancelable(io, &mutex)
if closed: unlock + return error.ZixChannel_Channel_Closed
copy value bytes into slot (head + count) % capacity
count += 1
unlock
not_empty.signal(io)
```

### recv()

```
if T is not the init type: return error.ZixChannel_Channel_TypeMismatch
lock mutex
while count == 0:
    if closed: unlock + return error.ZixChannel_Channel_Closed
    not_empty.waitUncancelable(io, &mutex)
copy slot head bytes into value
head = (head + 1) % capacity
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

`init()` memanggil `allocator.alloc(u8, capacity * @sizeOf(T))`. `deinit()` memanggil `allocator.free(buf)`. Tidak ada alokasi heap lainnya.

---

###### end of lld-channel
