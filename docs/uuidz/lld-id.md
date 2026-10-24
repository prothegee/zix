# uuidz low-level design

Dokumen ini membahas detail tingkat byte dan internal. Untuk bentuk library baca `hld-en.md` terlebih dahulu.

<br>

## Hex alphabet

`hex.zig` memiliki satu konstanta:

```zig
pub const hex = "0123456789abcdef";
```

Setiap konversi string memakainya. Tidak ada salinan kedua alphabet di mana pun dalam library.

<br>

## UUID v1

### Layout bit

UUID v1 adalah 16 byte, big-endian di seluruh field:

| Byte | Field | Lebar |
| :- | :- | :- |
| 0-3 | time_low | 32 bit |
| 4-5 | time_mid | 16 bit |
| 6-7 | time_high_and_version | 16 bit (versi di nibble tinggi) |
| 8 | clock_seq_high_and_reserved | 8 bit (varian di bit tinggi) |
| 9 | clock_seq_low | 8 bit |
| 10-15 | node | 48 bit |

Nibble versi adalah `0x1`. Bit varian adalah `10` (RFC 4122), sehingga byte 8 memiliki dua bit teratas di-set ke `10`.

<br>

### Generate

`init` mengunci mutex, lalu menjalankan yang berikut sekali per proses:

1. Isi `node` dengan 6 byte secure random. Set multicast bit (`node[0] |= 0x01`) supaya node bukan MAC address asli.
2. Isi `clock_sequence` dengan 14 bit dari dua byte secure random.

Lalu untuk setiap pemanggilan:

1. Baca clock sebagai nanodetik.
2. Bagi dengan 100 untuk mendapat interval 100 nanodetik, lalu tambahkan `UUID_EPOCH_OFFSET` (selisih antara epoch UUID dan epoch Unix).
3. Jika timestamp tidak lebih besar dari `last_timestamp`, increment `clock_sequence` dan wrap di 14 bit. Ini menjaga identifier tetap monoton saat clock diam atau mundur.
4. Simpan timestamp baru.
5. Pecah timestamp ke tiga field waktu.
6. OR nibble versi ke `time_high_and_version`.
7. OR bit varian ke `clock_seq_high_and_reserved`.
8. Tulis field ke `data` dalam urutan big-endian.

Mutex mencakup seluruh pemanggilan, sehingga dua thread tidak bisa membaca `clock_sequence` atau `last_timestamp` bersama di saat yang sama.

### Parse

`initFromString` menerima 36 atau 32 karakter. Untuk bentuk 36 karakter dibutuhkan tanda hubung di posisi 8, 13, 18, dan 23. Untuk bentuk 32 karakter dibaca digit hex secara langsung.

Setiap byte di-decode dari dua karakter hex. Huruf besar dan kecil keduanya diterima. Karakter di luar set hex adalah `InvalidHexCharacter`.

Setelah 16 byte terisi, v1 tidak melakukan pengecekan versi. Parser v1 menerima bentuk UUID apa pun. Jika penegakan versi ketat diinginkan, pemanggil mengecek nibble versi.

<br>

## UUID v4

### Layout bit

UUID v4 adalah 16 byte acak dengan dua region yang dimasking:

| Byte | Isi |
| :- | :- |
| 0-15 | Acak |
| 6 (nibble tinggi) | `0x4` (versi 4) |
| 8 (dua bit teratas) | `10` (varian RFC 4122) |

### Generate

`init` mengisi seluruh 16 byte dengan data secure random, lalu masking:

```zig
self.data[6] = (self.data[6] & 0x0F) | 0x40;
self.data[8] = (self.data[8] & 0x3F) | 0x80;
```

Tidak perlu mutex karena tidak ada state bersama yang disentuh.

### Parse

Jalur parse sama dengan jalur hex 16 byte seperti v1, dengan satu tambahan: setelah decode, v4 mengecek bahwa byte 6 memiliki nibble versi `0x4` dan byte 8 memiliki bit varian `10`. Ketidakcocokan menjadi `InvalidUuidVersion` atau `InvalidUuidVariant`.

Pengecekan ketat ini berarti string v1 yang diberikan ke `v4.initFromString` ditolak, bukan diinterpretasi ulang diam-diam.

<br>

## UUID v7

### Layout bit

UUID v7 adalah 16 byte:

| Byte | Field | Lebar |
| :- | :- | :- |
| 0-5 | unix_ts_ms | 48 bit |
| 6 (nibble tinggi) | versi | 4 bit (`0x7`) |
| 6 (nibble rendah) - 15 | acak | 74 bit |
| 8 (dua bit teratas dari bagian acak) | varian | 2 bit (`10`) |

### Generate

`init` mengunci mutex untuk seluruh pemanggilan. Alurnya adalah:

1. Baca clock dalam milidetik.
2. Jika clock mundur (`current_ms < last_timestamp_ms`), pin `current_ms` ke `last_timestamp_ms`. Ini adalah penjaga NTP-sync.
3. Jika `current_ms` lebih besar dari `last_timestamp_ms`, isi field acak 74 bit dengan data secure random dan simpan timestamp baru.
4. Jika `current_ms` sama dengan `last_timestamp_ms`, increment field acak 74 bit sebagai counter big-endian. Ini menjaga identifier yang di-generate di milidetik yang sama tetap naik monoton.
5. Setelah increment, bandingkan field acak baru dengan yang lama. Jika tidak bertambah (artinya counter 74 bit overflow), tambah satu milidetik ke `current_ms`, acak ulang field, dan simpan timestamp baru.
6. Terapkan mask versi dan varian.
7. Tulis timestamp 48 bit ke byte 0-5 dalam urutan big-endian.

Mutex mencakup `last_timestamp_ms` bersama dan state monotonicity bersama.

### Parse

Jalur parse sama dengan jalur hex 16 byte, dengan dua pengecekan setelah decode:

- Byte 6 harus memiliki nibble versi `0x7`.
- Byte 8 harus memiliki bit varian `10`.

Ketidakcocokan menjadi `InvalidUuidVersion` atau `InvalidUuidVariant`.

<br>

## Format string

Baik `asString` maupun `asReffID` memakai loop dalam yang sama: untuk setiap 16 byte, tulis karakter hex nibble tinggi, lalu nibble rendah.

Bedanya ada di separator:

| Call | Ukuran buffer | Separator |
| :- | :- | :- |
| `asString` | 36 | `-` setelah byte 3, 5, 7, dan 9 |
| `asReffID` | 32 | tidak ada |

Loop-nya `inline for`, sehingga batas-batasnya adalah konstanta waktu kompilasi dan compiler melihat urutan store yang tetap tanpa branch runtime pada indeks.

<br>

## Mutex

v1 dan v7 berbagi state mutable (`clock_sequence`, `last_timestamp`, `last_timestamp_ms`, `node`, `is_initialized`). Keduanya memakai `std.Io.Mutex` yang dideklarasikan sebagai variabel file-scope di dalam struct versi.

Polanya selalu sama:

```zig
try mutex.lock(io);
defer mutex.unlock(io);
```

`defer` adalah penjaganya. Tidak ada jalur yang kembali tanpa unlock.

<br>

## Baca dan tulis integer

Timestamp ditulis dengan `std.mem.writeInt` dalam urutan big-endian, sehingga byte di `data` cocok dengan layout RFC tanpa urutan shift manual.

Timestamp v7 ditulis byte per byte dari `u64`, shift kanan sebesar 40, 32, 24, 16, 8, dan 0. Ini adalah urutan big-endian yang sama dalam bentuk eksplisit.

<br>

## Penanganan error

Tidak ada error yang ditelan. Setiap `try` diteruskan ke pemanggil, dan setiap validasi khusus versi mengembalikan error bernama dari kumpulan parse yang sama. Jalur generate tidak punya validasi karena mask diterapkan tanpa syarat.
