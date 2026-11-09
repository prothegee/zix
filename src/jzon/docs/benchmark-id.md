# Benchmark jzon

Biaya setiap jalur jzon pada satu record, diukur oleh dua contoh bench yang ikut di paketnya.

Ini bukan gate. Ini pembacaan yang diambil di satu mesin dengan satu record, diterbitkan supaya metodenya bisa diulang dan bentuk pertukarannya terlihat. Jalankan ulang pada bentuk yang benar-benar dilayani sebelum memutuskan apa pun.

## Yang diukur

Dua binary contoh, masing-masing berdiri sendiri:

| Contoh | Yang diukur waktunya |
| :- | :- |
| [`bench_serialize`](../examples/bench_serialize.zig) | satu record dirender lewat setiap strategy tulis JSON dan kedua layout ZON |
| [`bench_deserialize`](../examples/bench_deserialize.zig) | satu record di-parse lewat setiap strategy baca JSON (minified dan ditata rapi), lewat ZON (kedua layout), dan dibaca dari file asli dibanding di-parse |

Keduanya berjalan di atas record yang sama: satu integer unsigned, satu string, satu enum exhaustive, satu string optional, satu array string, dan satu slice berisi dua struct bersarang yang memuat sebuah string, sebuah integer unsigned, dan sebuah integer bertanda.

## Metode

- 100000 operasi per ronde, 5 ronde per baris.
- Ronde tercepat yang dilaporkan, bukan reratanya. Satu ronde ikut menangkap apa pun yang sedang dikerjakan mesinnya.
- Satu operasi tanpa pengukuran berjalan lebih dulu per baris, yang memanaskan jalur kodenya.
- Bench serialize memastikan keempat jalur tulis JSON merender byte yang identik sebelum pengukuran dimulai, jadi baris JSON membandingkan kerja yang setara.
- Bench deserialize memeriksa bentuk hasil parse sekali per baris, jadi jalur yang membaca lebih sedikit tidak bisa lolos tanpa diukur.
- Reset arena sengaja diletakkan di dalam loop deserialize yang terukur. Itulah yang dibayar sebuah worker per permintaan, dan setiap baris membayarnya sama rata.
- String disalin, itu default-nya. Borrow adalah lever terpisah, ditunjukkan di `examples/strings.zig`.
- Baris file membaca `examples/order.json` dan `examples/order.zon` dengan satu `readFileAlloc` per operasi. Baris parse saja mem-parse byte yang sama dengan isi file.
- Jamnya adalah monotonic clock yang dibaca lewat `std.Io`.

## Sistem

| Item | Nilai |
| :- | :- |
| CPU | AMD Ryzen 5 5600H with Radeon Graphics |
| Arsitektur | x86_64 |
| Core / thread | 6 core, 12 thread, 1 socket, 2 thread per core |
| Clock | maks 4280.98 MHz, min 412.63 MHz |
| L3 cache | 16 MiB |
| Memory | 30 GiB |
| OS | Arch Linux |
| Kernel | Linux 7.2.14-arch1-1 x86_64 |
| Zig | 0.17.0 |
| Build | `-Doptimize=ReleaseFast`, target native |
| CPU governor | powersave, energy preference balance_performance, boost menyala |

Mesinnya tidak didiamkan dan governor-nya tidak dikunci ke performance, jadi angka absolutnya konservatif. Rasio antarbaris adalah tujuan tabel ini, dan rasionya bertahan di beberapa kali jalan.

## Hasil: serialize

Record dirender menjadi 208 byte JSON. Setiap jalur JSON menghasilkan byte yang identik.

| Jalur | ns/render | render/s | vs default |
| :- | :- | :- | :- |
| JSON `.STD` | 322 | 3104655 | 1.00x |
| JSON `.GENERATED_FMT` | 98 | 10218641 | 3.29x |
| JSON `.GENERATED` | 93 | 10768555 | 3.47x |
| JSON `.GENERATED_VECTOR` | 99 | 10139825 | 3.27x |
| ZON `.MULTILINE` | 117 | 8520924 | 2.74x |
| ZON `.COMPACT` | 112 | 8919532 | 2.87x |

Yang ditunjukkannya:

- Sebagian besar keuntungan JSON datang dari generated emitter itu sendiri: `.GENERATED_FMT` sudah 3.29x laju default, padahal integer-nya masih lewat `std.fmt`. Itulah tanda baca key object yang runtuh menjadi satu literal comptime per field.
- Menulis digit langsung ke buffer menambah sedikit lagi (3.47x). Scan escape vector setara dengan yang skalar di sini, karena string di record ini pendek dan satu lane hanya membeli sekitar satu perbandingan.
- ZON menjalankan satu jalur generated, dibangun dengan cara yang sama: setiap `.name = ` adalah satu literal comptime. Ia menulis lebih banyak byte dari JSON untuk record yang sama (indent, spasi di sekitar `=`), dan itulah sebagian besar selisihnya dengan JSON `.GENERATED`.

## Hasil: deserialize JSON, minified

Dokumen 208 byte, tanpa whitespace, seperti yang datang dari jaringan.

| Strategy | ns/parse | parse/s | vs default |
| :- | :- | :- | :- |
| `.STD` | 917 | 1090781 | 1.00x |
| `.SCANNER` | 933 | 1071975 | 0.98x |
| `.GENERATED` | 263 | 3809369 | 3.49x |
| `.GENERATED_VECTOR` | 268 | 3733694 | 3.42x |

## Hasil: deserialize JSON, ditata rapi

Nilai yang sama, di-pretty print menjadi 257 byte.

| Strategy | ns/parse | parse/s | vs default |
| :- | :- | :- | :- |
| `.STD` | 979 | 1021912 | 1.00x |
| `.SCANNER` | 982 | 1018271 | 1.00x |
| `.GENERATED` | 281 | 3564767 | 3.49x |
| `.GENERATED_VECTOR` | 302 | 3309182 | 3.24x |

Yang ditunjukkannya:

- `.SCANNER` memindahkan dispatch field ke waktu kompilasi tetapi meninggalkan tokenisasi ke `std.json.Scanner`, dan di situlah biaya bacanya duduk. Pada record ini dispatch itu sendiri hampir tidak bernilai.
- `.GENERATED` memiliki seluruh proses baca: grammar-nya, scan-nya, decoding escape-nya, dan dispatch-nya. Itu 3.49x pada kedua bentuk, karena melangkahi whitespace itu murah kalau tidak ada refleksi lain.
- `.GENERATED_VECTOR` setara dengan `.GENERATED` pada teks minified dan sedikit tertinggal pada teks yang ditata rapi. Deretan whitespace di record ini pendek (dua sampai empat spasi), jadi satu lane jarang menguntungkan. Ia pilihan yang perlu diukur pada dokumen dengan deretan whitespace panjang atau string panjang.

## Hasil: deserialize ZON

Nilai yang sama sebagai ZON: file multiline (`examples/order.zon`, 461 byte beserta komentarnya) dan nilai yang sama dalam satu baris.

| Layout | ns/parse | parse/s | vs multiline |
| :- | :- | :- | :- |
| multiline | 727 | 1376019 | 1.00x |
| compact | 624 | 1602964 | 1.16x |

ZON terbaca sekitar 0.37x laju JSON `.GENERATED`. Teksnya lebih panjang, dan setiap angka melewati `std.zig.parseNumberLiteral` sebelum dikonversi `std.fmt`, jadi grammar Zig yang memutuskan angka yang valid.

## Hasil: baca file dibanding parse

Satu `readFileAlloc` per operasi, lalu parse, dengan reset arena setelah masing-masing.

| File | Parse saja | Baca saja | Baca + parse |
| :- | :- | :- | :- |
| `examples/order.json` (259 byte, JSON `.GENERATED`) | 278 ns | 3927 ns | 4452 ns |
| `examples/order.zon` (461 byte) | 739 ns | 3998 ns | 4998 ns |

Membaca file berbiaya 5 sampai 14 kali parse-nya. Untuk file konfigurasi yang dibaca sekali saat mulai, format dan jalurnya tidak berpengaruh. Untuk data yang dibaca per permintaan, simpan byte-nya di memory dan parse slice-nya.

## Cara membacanya

Default JSON adalah jalur yang paling mampu, bukan jalur lambat yang harus dihindari. Ia menerima setiap bentuk yang diterima std, dan pada record ini ia masih menghasilkan lebih dari 3.1 juta render dan 1.0 juta parse per detik di satu core.

Strategy generated adalah yang dipilih sebuah call site begitu bentuknya diketahui berupa record biasa dan panggilannya ada di jalur permintaan:

| Keadaan | Pakai |
| :- | :- |
| bentuk apa pun, belum ada pengukuran | `.{}` |
| record biasa di jalur permintaan | `.strategy = .GENERATED` di kedua sisi |
| nilainya mati bersama buffer tempat ia dibaca | tambahkan `.strings = .BORROW` |
| field teks panjang atau deretan whitespace panjang | ukur `.GENERATED_VECTOR` |
| file konfigurasi yang ditulis orang | `jzon.zon`, dibaca sekali |

## Mengulanginya

Dari root paketnya (`src/jzon`):

```
zig build example-bench_serialize example-bench_deserialize -Doptimize=ReleaseFast
./zig-out/bin/jzon-example-bench_serialize-<arch>-<os>-fast
./zig-out/bin/jzon-example-bench_deserialize-<arch>-<os>-fast
```

Jalankan dari `src/jzon`, karena baris file membaca `examples/order.json` dan `examples/order.zon` lewat path relatif. Build Debug mengukur safety check, bukan jalurnya, dan membuat barisnya saling menempel, jadi flag optimize di sini bukan pilihan.

Untuk mengukur record lain, ubah tipe `Order` dan konstanta payload di bagian atas tiap file bench, serta dua file di `examples/`. Jumlah iterasi dan jumlah ronde adalah konstanta di tempat yang sama.

## Yang tidak dikatakan angka ini

- Ini satu record di satu mesin. Bentuk dengan string lebih panjang, integer lebih banyak, atau bersarang lebih dalam menggeser jalur mana yang paling murah.
- Ini single threaded dan in-process. Tidak ada di sini yang menyatakan apa yang dilakukan sebuah server di bawah beban, di mana jalur permintaan membawa banyak hal selain JSON.
- Ini tidak menyatakan apa pun tentang memory. Meminjam string alih-alih menyalinnya adalah lever yang menggeser hal itu, dan lever itu bukan sumbu di sini.
- Baris file berjalan dengan file di page cache. Baca dingin dari disk berbiaya lebih.
