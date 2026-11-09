# jzon

JSON dan ZON dua arah, ditulis murni dengan Zig, hanya memakai standard library.

- Satu pasang panggilan per format: `serialize` mengubah nilai bertipe menjadi teks, `deserialize` mengubah teks kembali menjadi nilai bertipe.
  - JSON: `jzon.json.serialize`, `jzon.json.deserialize`.
  - ZON: `jzon.zon.serialize`, `jzon.zon.deserialize`.
- JSON punya empat jalur tulis dan empat jalur baca. Semuanya menghasilkan byte yang sama dan membaca dokumen yang sama, jadi memilih salah satunya adalah keputusan biaya, bukan keputusan kebenaran.
- ZON punya satu jalur tulis dan satu jalur baca, di-generate dari tipenya. Ia mencakup bentuk yang dipakai `build.zig.zon`.
- Serialize tidak mengalokasi apa pun. Pemanggil menyerahkan buffer, dan nilai yang tidak muat adalah error `NoSpaceLeft`.
- Deserialize hanya mengalokasi apa yang ditunjuk hasilnya, dari allocator yang diserahkan, jadi satu reset arena membebaskan seluruh parse dalam satu langkah.
- String bisa di-borrow dari dokumennya, bukan disalin.
- Tipe field yang tidak punya bentuk di jalur generated adalah compile error yang menyebut tipenya, bukan kegagalan runtime.
- Kompatibel dengan Zig 0.17.

Untuk arsitektur lihat `docs/hld-id.md`, untuk detail internal lihat `docs/lld-id.md`, untuk biaya terukur lihat `docs/benchmark-id.md`.

## Import

jzon ikut di dalam zix dan bisa dicapai dari sana:

```zig
const zix = @import("zix");

const len = try zix.jzon.json.serialize(&buf, order, .{});
```

Ia juga paket mandiri di bawah `src/jzon` dengan build file miliknya sendiri, jadi bisa dipakai berdiri sendiri. Tambahkan sebagai dependency path di `build.zig.zon`:

```zig
.dependencies = .{
    .jzon = .{ .path = "path/to/jzon" },
},
```

Pasang module-nya di `build.zig`:

```zig
const jzon = b.dependency("jzon", .{}).module("jzon");
exe.root_module.addImport("jzon", jzon);
```

## Mulai cepat

Satu record membawa kedua arah dan kedua format:

```zig
const Status = enum { PENDING, SHIPPED, CANCELLED };

const Line = struct {
    sku: []const u8,
    qty: u32,
    price_cents: i64,
};

const Order = struct {
    id: u64,
    customer: []const u8,
    status: Status,
    note: ?[]const u8 = null,
    tags: []const []const u8,
    lines: []const Line,
};
```

### Nilai menjadi teks

```zig
var buf: [1024]u8 = undefined;

const json_len = try jzon.json.serialize(&buf, order, .{});
const zon_len = try jzon.zon.serialize(&buf, order, .{});
```

Buffer milik pemanggil, jadi handler bisa me-render langsung ke send buffer yang diberikan engine. Tidak ada yang dialokasi, dan satu-satunya kegagalan adalah buffer penuh.

### Teks kembali menjadi nilai

```zig
const from_json = try jzon.json.deserialize(Order, arena.allocator(), json_text, .{});
const from_zon = try jzon.zon.deserialize(Order, arena.allocator(), zon_text, .{});
```

Semua yang ditunjuk hasilnya berasal dari allocator itu. Arena paling cocok untuk server: parse body request ke dalamnya, jawab, lalu reset.

### File

jzon membaca dan menulis slice, bukan file. Pemanggil membaca file sekali, lalu menyerahkan slice-nya:

```zig
const cwd = std.Io.Dir.cwd();

const text = try cwd.readFileAlloc(io, "order.zon", allocator, .limited(1 << 16));
const order = try jzon.zon.deserialize(Order, allocator, text, .{});

const len = try jzon.zon.serialize(&buf, order, .{});
try cwd.writeFile(io, .{ .sub_path = "order.zon", .data = buf[0..len] });
```

Teks yang ditulis berakhir di `}` penutup tanpa line feed. Tambahkan sendiri jika file harus diakhiri line feed.

### Parameter ketiga

Parameter terakhir adalah struct options. `.{}` berarti semua field memakai default, jadi hanya field yang berubah yang ditulis:

```zig
const len = try jzon.json.serialize(&buf, order, .{ .strategy = .GENERATED });

const parsed = try jzon.json.deserialize(Order, arena.allocator(), body, .{
    .strategy = .GENERATED,
    .strings = .BORROW,
    .unknown = .SKIP,
});

const compact = try jzon.zon.serialize(&buf, order, .{ .layout = .COMPACT });

const package_text = try jzon.zon.serialize(&buf, package, .{
    .hex_fields = &.{"fingerprint"},
});
```

Options bersifat comptime, jadi hanya jalur yang disebut yang dikompilasi ke binary.

## Strategy tulis JSON

| Strategy | Apa yang dijalankan |
| :- | :- |
| `.STD` | `std.json.Stringify`, yang me-render semua bentuk yang di-render std |
| `.GENERATED_FMT` | di-generate dari tipenya, integer lewat `std.fmt` |
| `.GENERATED` | di-generate dari tipenya, digit integer ditulis langsung ke buffer |
| `.GENERATED_VECTOR` | seperti `.GENERATED`, dengan string dipindai satu vector lane sekaligus |

## Strategy baca JSON

| Strategy | Apa yang dijalankan |
| :- | :- |
| `.STD` | reflection `std.json`, yang mem-parse semua bentuk yang di-parse std |
| `.SCANNER` | token dari `std.json.Scanner`, dengan dispatch field di-generate dari tipenya |
| `.GENERATED` | di-generate dari tipenya, di atas read cursor milik jzon, satu byte sekaligus |
| `.GENERATED_VECTOR` | seperti `.GENERATED`, satu vector lane sekaligus |

`.GENERATED_VECTOR` tidak selalu yang tercepat, di sisi mana pun. Ia untung pada string panjang dan rugi pada string pendek, itulah sebabnya lebar scan tetap pilihan di call site, bukan default. Lihat `docs/benchmark-id.md` untuk hasil ukurnya pada satu record.

## Options

`jzon.json.SerializeOptions`:

| Field | Default | Yang diputuskan |
| :- | :- | :- |
| `strategy` | `.STD` | jalur tulis yang dijalankan |

`jzon.json.DeserializeOptions`:

| Field | Default | Yang diputuskan |
| :- | :- | :- |
| `strategy` | `.STD` | jalur baca yang dijalankan |
| `strings` | `.COPY` | `.COPY` menyalin setiap string ke allocator, `.BORROW` mengarahkan string tanpa escape ke dokumennya, yang lalu harus hidup lebih lama dari nilainya |
| `unknown` | `.REJECT` | `.REJECT` gagal pada key yang tidak dideklarasikan tipenya, `.SKIP` melompati key itu beserta seluruh nilainya sedalam apa pun nesting-nya |

`jzon.zon.ZonOptions` (satu struct untuk kedua arah):

| Field | Default | Dibaca oleh | Yang diputuskan |
| :- | :- | :- | :- |
| `strings` | `.COPY` | deserialize | sama dengan JSON. String `\\` satu baris tanpa `\r` juga bisa di-borrow |
| `unknown` | `.REJECT` | deserialize | sama dengan JSON |
| `max_depth` | `256` | deserialize | berapa level `.{}` yang boleh di-nest sebelum dokumen ditolak (pelindung dari input berbahaya, bukan batas ukuran) |
| `layout` | `.MULTILINE` | serialize | `.MULTILINE` menulis satu entri per baris dengan empat spasi per level, seperti `build.zig.zon`. `.COMPACT` menulis satu baris |
| `hex_fields` | `&.{}` | serialize | nama field yang ditulis sebagai hex (`.fingerprint = 0x4cc61d74dc93a20b`), di level mana pun. Field lain tetap desimal. Nama yang bukan field, atau field yang bukan integer atau integer optional, menjadi compile error |

## ZON

Yang dibaca dan ditulis jalur ZON:

- struct `.{ .name = value }` dan list `.{ a, b }`
- string `"..."` dengan escape Zig, dan string multiline `\\`
- integer di basis apa pun (`10`, `0x1F`, `0o17`, `0b101`, `1_000`), float (juga `inf`, `-inf`, `nan`)
- `true`, `false`, `null`
- enum literal `.tag`
- komentar `//`
- nama `.@"..."`, untuk nama yang bukan identifier Zig biasa (seperti `error`)

Di luar cakupan: pointer selain slice, tuple (pakai array), union, char literal, dan `@import`. Angka dicek terhadap grammar Zig dengan `std.zig.parseNumberLiteral`, jadi `+1`, `012`, dan `1__0` ditolak.

Output `MULTILINE` untuk satu record:

```zig
.{
    .id = 2,
    .name = "bar_1",
    .tags = .{
        "retail",
    },
    .status = .PENDING,
    .note = null,
}
```

## Cakupan tipe

Jalur JSON generated dan kedua jalur ZON menerima: `bool`, integer lebar apa pun signed maupun unsigned, float lebar apa pun, `[]const u8` sebagai string, slice dari tipe yang tercakup, optional dari tipe yang tercakup, enum exhaustive, dan struct yang field-nya semua dari daftar itu. ZON juga menerima array berukuran tetap.

Yang ditolak saat compile, dengan menyebut tipenya: pointer non-slice, enum non-exhaustive, dan tuple. JSON `.STD` tetap menerima bentuk apa pun yang diterima std, jadi field di luar cakupan adalah pilihan strategy, bukan tembok.

## Error

| Panggilan | Error set | Anggota |
| :- | :- | :- |
| `jzon.json.serialize` | `jzon.json.SerializeError` | `Jzon_Serialize_NoSpaceLeft` |
| `jzon.json.deserialize` | `jzon.json.DeserializeError` | `Jzon_Deserialize_*`, lihat di bawah |
| `jzon.zon.serialize` | `jzon.zon.SerializeError` | `Jzon_ZonSerialize_NoSpaceLeft` |
| `jzon.zon.deserialize` | `jzon.zon.DeserializeError` | `Jzon_ZonDeserialize_*`, lihat di bawah |

Kedua set deserialize membawa kondisi yang sama:

| Kondisi | Artinya |
| :- | :- |
| `UnknownField` | dokumen membawa key yang tidak dideklarasikan tipenya, di bawah `unknown = .REJECT` |
| `MissingField` | dokumen tidak menyertakan field yang tidak punya default |
| `UnknownEnumValue` | nama yang tidak punya tag di enum |
| `Truncated` | dokumen berakhir terlalu cepat |
| `Unexpected` | yang ada bukan yang diminta tipenya: syntax error, nilai dengan bentuk yang salah, key yang sama dua kali, atau nesting melewati batas |
| `BadNumber` | teks angka yang tidak diizinkan grammar, atau nilai yang tidak muat di tipe tujuan |
| `BadEscape` | escape sequence yang tidak dikenal aturannya |
| `OutOfMemory` | allocator kehabisan memori |

Beberapa anggota tidak pernah dikembalikan (`Jzon_Serialize_BadNumber`, `Jzon_Serialize_BadEscape`, `Jzon_Deserialize_NoSpaceLeft`, `Jzon_ZonSerialize_BadNumber`). Mereka ada karena setiap anggota inner set dipetakan ke anggota nyata di set publik.

`jzon.lastFailure()` memberi tahu tentang apa parse yang gagal, untuk kedua format: nama field atau tag, byte offset, atau keduanya. Baca tepat setelah error, di thread yang sama.

```zig
const order = jzon.zon.deserialize(Order, allocator, text, .{}) catch |err| {
    const failure = jzon.lastFailure();
    std.debug.print("{t} at byte {d}, field '{s}'\n", .{ err, failure.offset, failure.field });

    return err;
};
```

Mengganti strategy JSON tidak pernah mengubah apa yang harus ditangani pemanggil. `docs/lld-id.md` mencantumkan tiga tempat di mana jalur yang dibangun dari tipe menjawab berbeda dari `.STD`.

## Contoh

Tujuh, di `examples/`. Masing-masing berjalan lalu selesai, tidak ada yang berupa server. Jalankan dari `src/jzon`, karena `zon_file` dan `bench_deserialize` membaca `examples/order.zon` dan `examples/order.json` lewat path relatif. `zon_file` menulis `.tmp/jzon_example_order.zon` dan menyimpannya.

| Contoh | Yang ditunjukkan |
| :- | :- |
| [serialize](examples/serialize.zig) | nilai ke buffer tetap, setiap strategy tulis, dan apa yang dilaporkan buffer yang terlalu kecil |
| [deserialize](examples/deserialize.zig) | body request ke nilai bertipe di arena, setiap strategy baca, reset di antara body |
| [strings](examples/strings.zig) | `.COPY` dibanding `.BORROW`, dan apa yang diminta borrow dari umur dokumen |
| [unknown_keys](examples/unknown_keys.zig) | `.REJECT` dibanding `.SKIP` pada dokumen yang membawa lebih dari yang dideklarasikan tipe |
| [bench_serialize](examples/bench_serialize.zig) | biaya setiap strategy tulis per render, dibanding laju default |
| [bench_deserialize](examples/bench_deserialize.zig) | biaya setiap strategy baca per parse, pada dokumen minified dan yang ber-layout |
| [zon_file](examples/zon_file.zig) | file `.zon` asli dibaca ke record bertipe lalu ditulis kembali |

Build dari paketnya dengan `zig build examples`, atau dari root repo dengan `zig build jzon-examples`. Dua contoh bench butuh `-Doptimize=ReleaseFast`. Build Debug mengukur safety check, bukan jalurnya.

Contoh server tinggal bersama contoh engine, bukan di paket ini: `examples/http1_jzon.zig` membaca body request JSON ke record di arena per-request dan menjawab dengan record yang di-render ke stack buffer. Build dari root repo dengan `zig build zix-example-http1_jzon`.

## Pengujian

Dua tier, 822 test, tidak ada yang butuh instalasi apa pun:

```
zig build unit_edge-test     # 639, test unit dan edge di dalam file di bawah src/
zig build behaviour-test     # 183, apa yang dilakukan tiap bagian saat diberi yang ia mau
zig build all-test           # keduanya
```

Dari root repo langkah yang sama adalah `jzon-unit_edge-test`, `jzon-behaviour-test`, dan `jzon-all-test`.
