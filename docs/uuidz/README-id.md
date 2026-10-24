# uuidz

Pembuatan dan parsing UUID dengan Zig murni, hanya library standar.

- Satu paket, tiga versi UUID: v1 (berbasis waktu), v4 (acak), v7 (terurut waktu).
- Setiap versi menyediakan permukaan yang sama: `init`, `initFromString`, `asString`, `asReffID`.
- Generate dan parse tidak mengalokasikan apa pun. Pemanggil memiliki semua buffer.
- `initFromString` menerima bentuk 36 karakter dengan tanda hubung dan bentuk referensi 32 karakter.
- Validasi versi dan varian yang ketat saat parse, sehingga string yang bukan versi yang diminta menjadi error, bukan nilai yang diterima diam-diam.
- Dibangun dengan Zig 0.16 dan 0.17.

Untuk arsitektur lihat `hld-en.md`, untuk detail tingkat bit lihat `lld-en.md`.

## Import

`uuidz` dikirim di dalam `zix` dan dapat diakses darinya:

```zig
const zix = @import("zix");
const v4 = zix.uuidz.v4;
```

Ini juga merupakan paket mandiri di `src/uuidz` dengan file build sendiri, sehingga dapat dijadikan dependensi secara terpisah. Tambahkan sebagai dependensi path di `build.zig.zon`:

```zig
.dependencies = .{
    .uuidz = .{ .path = "path/to/uuidz" },
},
```

Sambungkan module di `build.zig`:

```zig
const uuidz = b.dependency("uuidz", .{}).module("uuidz");
exe.root_module.addImport("uuidz", uuidz);
```

<br>

## Mulai cepat

Setiap versi memiliki tipe sendiri. Cara pakainya sama untuk ketiganya.

```zig
const std = @import("std");
const uuidz = @import("uuidz");
const v4 = uuidz.v4;
const v7 = uuidz.v7;

pub fn main() !void {
    var io = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer io.deinit();

    const random_id = try v4.init(&io);
    const time_id = try v7.init(&io);

    var buf: [36]u8 = undefined;
    const random_str = random_id.asString(&buf);

    var ref: [32]u8 = undefined;
    const time_ref = time_id.asReffID(&ref);

    _ = random_str;
    _ = time_ref;
}
```

Parse kembali dari string:

```zig
const v4 = uuidz.v4;

const uuid = try v4.initFromString("f47ac10b-58cc-4372-a567-0e02b2c3d479");
```

Nilai hasil parse memiliki method yang sama dengan nilai hasil generate:

```zig
var buf: [36]u8 = undefined;
const text = uuid.asString(&buf);
```

<br>

## Panduan versi

| Versi | Dasar | Dapat diurutkan | Membocorkan MAC | Penggunaan yang disarankan |
| :- | :- | :- | :- | :- |
| v1 | Timestamp + node | Tidak | Ya | Sistem lama yang membutuhkan v1 |
| v4 | Acak | Tidak | Tidak | Identifier tujuan umum |
| v7 | Timestamp + acak | Ya | Tidak | Key database, sistem terdistribusi |

<br>

## API yang tersedia

Setiap struct versi menyediakan empat call yang sama:

| Call | Apa yang dilakukan |
| :- | :- |
| `init(io) !Self` | Generate UUID baru |
| `initFromString(str) !Self` | Parse string UUID 36 karakter atau 32 karakter |
| `asString(buf) []u8` | Tulis bentuk 36 karakter dengan tanda hubung ke buffer pemanggil |
| `asReffID(buf) []u8` | Tulis bentuk referensi 32 karakter ke buffer pemanggil |

Ukuran buffer adalah konstanta:
- `BUFF_SIZE = 36` untuk `asString`
- `REFF_SIZE = 32` untuk `asReffID`

<br>

## Error

`init` dan `initFromString` mengembalikan error dari kumpulan kecil.

| Error | Artinya |
| :- | :- |
| `InvalidUuidLength` | String bukan 36 atau 32 byte |
| `InvalidUuidFormat` | Tanda hubung hilang di posisi 8, 13, 18, atau 23 |
| `InvalidHexCharacter` | Karakter bukan digit hex (0-9, a-f, A-F) |
| `InvalidUuidVersion` | Nilai hasil parse bukan versi yang diminta |
| `InvalidUuidVariant` | Nilai hasil parse tidak membawa varian RFC 4122 |

<br>

---

###### akhir readme
