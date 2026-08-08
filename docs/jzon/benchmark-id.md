# Benchmark jzon

Biaya setiap jalur jzon pada satu record, diukur oleh dua contoh bench yang ikut di paketnya.

Ini bukan gate. Ini pembacaan yang diambil di satu mesin dengan satu record, diterbitkan supaya metodenya bisa diulang dan bentuk pertukarannya terlihat. Jalankan ulang pada bentuk yang benar-benar dilayani sebelum memutuskan apa pun.

## Yang diukur

Dua binary contoh, masing-masing berdiri sendiri:

| Contoh | Yang diukur waktunya |
| :- | :- |
| [`bench_serialize`](../../src/jzon/examples/bench_serialize.zig) | satu record dirender lewat setiap strategy tulis |
| [`bench_deserialize`](../../src/jzon/examples/bench_deserialize.zig) | satu dokumen di-parse lewat setiap strategy baca, minified dan ditata rapi |

Keduanya berjalan di atas record yang sama: satu integer unsigned, satu string, satu enum exhaustive, satu string optional, satu array string, dan satu slice berisi dua struct bersarang yang memuat sebuah string, sebuah integer unsigned, dan sebuah integer bertanda.

## Metode

- 100000 operasi per ronde, 5 ronde per jalur.
- Ronde tercepat yang dilaporkan, bukan reratanya. Satu ronde ikut menangkap apa pun yang sedang dikerjakan mesinnya.
- Satu operasi tanpa pengukuran berjalan lebih dulu per jalur, yang memanaskan jalur kodenya sekaligus menghasilkan nilai yang jadi acuan pemeriksaan setiap operasi terukur.
- Bench serialize memastikan keempat jalur tulis merender byte yang identik sebelum pengukuran dimulai, jadi tabelnya membandingkan kerja yang setara.
- Bench deserialize memeriksa bentuk hasil parse sekali per jalur, jadi jalur yang membaca lebih sedikit tidak bisa lolos tanpa diukur.
- Reset arena sengaja diletakkan di dalam loop deserialize yang terukur. Itulah yang dibayar sebuah worker per permintaan, dan setiap baris membayarnya sama rata.
- String disalin, itu default-nya. Borrow adalah lever terpisah, ditunjukkan di `examples/strings.zig`.
- Jamnya adalah monotonic clock (`CLOCK_MONOTONIC` di Linux) yang dibaca lewat `std.Io`.

## Sistem

| Item | Nilai |
| :- | :- |
| CPU | AMD Ryzen 5 5600H with Radeon Graphics |
| Arsitektur | x86_64 |
| Core / thread | 6 core, 12 thread, 1 socket, 2 thread per core |
| Clock | 4280.98 MHz maks, 412.63 MHz min |
| Cache L3 | 16 MiB |
| ISA yang relevan | avx2, sse4_2, aes, pclmulqdq, sha_ni |
| Memory | 30.7 GiB |
| OS | Arch Linux |
| Kernel | Linux 7.1.5-arch1-2 x86_64 |
| Zig | 0.16.0 |
| Build | `-Doptimize=ReleaseFast`, target native |
| CPU governor | powersave, energy preference balance_performance, boost menyala |

Mesinnya tidak dikosongkan dan governor-nya tidak dipaku ke performance, jadi angka absolutnya konservatif. Rasio antar barislah yang jadi tujuan tabel ini, dan rasio itu bertahan pada pengulangan.

## Hasil: serialize

Record dirender jadi 208 byte. Setiap jalur menghasilkan byte yang identik.

| Strategy | ns/render | render/s | vs default |
| :- | :- | :- | :- |
| `.STD` | 319 | 3138976 | 1.00x |
| `.GENERATED_FMT` | 101 | 9873387 | 3.15x |
| `.GENERATED` | 74 | 13516564 | 4.31x |
| `.GENERATED_VECTOR` | 75 | 13410095 | 4.27x |

Dua hal yang ditunjukkannya:

- Sebagian besar keuntungannya datang dari generated emitter itu sendiri, sebelum trik integer apa pun: `.GENERATED_FMT` sudah 3.15x laju default, dan ia masih memformat integer lewat `std.fmt`. Itu adalah tanda baca key object yang runtuh jadi satu literal comptime per field.
- Menulis digit langsung ke buffer menambahkan sisanya, dari 3.15x ke 4.31x. Konversi digitnya identik di kedua jalur, jadi yang dibeli langkah itu adalah membuang penyiapan `std.Io.Writer` per panggilan, pass lebar dan perataan, serta error union di setiap call site.
- Scan escape vector setara dengan yang skalar di sini (4.27x berbanding 4.31x). String di record ini pendek, jadi satu lane hanya membeli sekitar satu perbandingan.

## Hasil: deserialize, minified

Dokumen 208 byte, tanpa whitespace, bentuk yang datang dari wire.

| Strategy | ns/parse | parse/s | vs default |
| :- | :- | :- | :- |
| `.STD` | 1212 | 825184 | 1.00x |
| `.SCANNER` | 1082 | 924623 | 1.12x |
| `.GENERATED` | 271 | 3688013 | 4.47x |
| `.GENERATED_VECTOR` | 374 | 2671197 | 3.24x |

## Hasil: deserialize, ditata rapi

Nilai yang sama, di-pretty print jadi 257 byte.

| Strategy | ns/parse | parse/s | vs default |
| :- | :- | :- | :- |
| `.STD` | 1245 | 803165 | 1.00x |
| `.SCANNER` | 1123 | 890708 | 1.11x |
| `.GENERATED` | 294 | 3403677 | 4.24x |
| `.GENERATED_VECTOR` | 635 | 1574325 | 1.96x |

Tiga hal yang ditunjukkannya:

- `.SCANNER` memindahkan dispatch field ke waktu kompilasi tetapi meninggalkan tokenisasi ke `std.json.Scanner`, dan di situlah biaya bacanya duduk. 1.12x adalah nilai dispatch itu sendiri.
- `.GENERATED` memiliki seluruh proses baca: grammar-nya, scan-nya, decoding escape-nya, dan dispatch-nya. Itu 4.47x pada trafik minified dan hampir tidak bergeser ketika whitespace ditambahkan, karena melangkahi whitespace itu murah kalau tidak ada refleksi lain.
- `.GENERATED_VECTOR` jadi beban pada kedua bentuk di sini, dan paling berat pada yang ditata rapi: 1.96x berbanding 4.24x milik `.GENERATED`. Ini kebalikan dari maksud scan vector yang melangkahi whitespace, dan layak dibaca sebagai pertanyaan terbuka tentang scan di sisi baca, bukan sebagai sifat scan vector. Bench-nya mencetak kedua bentuk justru supaya hal ini tetap terlihat dan tidak terkubur rerata.

## Cara membacanya

Default adalah jalur yang paling mampu, bukan jalur lambat yang harus dihindari. Ia menerima setiap bentuk yang diterima std, dan pada record ini ia masih menghasilkan lebih dari 3.1 juta render dan 825 ribu parse per detik di satu core.

Strategy generated adalah yang dipilih sebuah call site begitu bentuknya diketahui berupa record biasa dan panggilannya ada di jalur permintaan. Angka di atas menyarankan urutannya:

| Keadaan | Pakai |
| :- | :- |
| bentuk apa pun, belum ada pengukuran | `.{}` |
| record biasa di jalur permintaan | `.strategy = .GENERATED` di kedua sisi |
| nilainya mati bersama buffer tempat ia dibaca | tambahkan `.strings = .BORROW` |
| field teks panjang yang dirender | ukur `.GENERATED_VECTOR` di sisi tulis |

## Mengulanginya

Dari root paketnya:

```
zig build example-bench_serialize example-bench_deserialize -Doptimize=ReleaseFast
./zig-out/bin/jzon-example-bench_serialize-<arch>-<os>-releasefast
./zig-out/bin/jzon-example-bench_deserialize-<arch>-<os>-releasefast
```

Build Debug mengukur safety check, bukan jalurnya, dan membuat barisnya saling menempel, jadi flag optimize di sini bukan pilihan.

Untuk mengukur record lain, ubah tipe `Order` dan konstanta payload di bagian atas tiap file bench. Jumlah iterasi dan jumlah ronde adalah konstanta di tempat yang sama.

## Yang tidak dikatakan angka ini

- Ini satu record di satu mesin. Bentuk dengan string lebih panjang, integer lebih banyak, atau bersarang lebih dalam menggeser jalur mana yang paling murah.
- Ini single threaded dan in-process. Tidak ada di sini yang menyatakan apa yang dilakukan sebuah server di bawah beban, di mana jalur permintaan membawa banyak hal selain JSON.
- Ini tidak menyatakan apa pun tentang memory. Meminjam string alih-alih menyalinnya adalah lever yang menggeser hal itu, dan lever itu bukan sumbu di sini.
