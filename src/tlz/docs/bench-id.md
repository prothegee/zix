# tlz bench

Biaya tiap primitive tlz di satu core, diukur dengan empat bench example yang ikut dalam package, bersebelahan dengan `openssl speed` di mesin yang sama.

Ini bukan gate. Ini satu pembacaan di satu mesin, dipublikasikan supaya metodenya bisa diulang dan selisihnya terlihat. Jalankan ulang di mesin target sebelum memutuskan apa pun.

## Apa yang diukur

Empat binary example, masing-masing berdiri sendiri:

| Example | Yang diukur |
| :- | :- |
| [`bench_rsa`](../examples/bench_rsa.zig) | satu RSA sign atas SHA-256 dengan kunci 2048, 3072, dan 4096 bit, PKCS#1 v1.5 dan PSS |
| [`bench_ecdsa_p256`](../examples/bench_ecdsa_p256.zig) | satu ECDSA P-256 SHA-256 sign |
| [`bench_ed25519`](../examples/bench_ed25519.zig) | satu Ed25519 sign |
| [`bench_record`](../examples/bench_record.zig) | satu record TLS 1.3 penuh 16 KiB dengan TLS_AES_128_GCM_SHA256, di-seal oleh server dan di-open oleh client |

Ini operasi yang dibayar server TLS: satu sign per full handshake (CertificateVerify), lalu satu seal atau open per record setelahnya.

Kunci RSA adalah kunci uji yang dibuat dengan `openssl genpkey` dan ada di `examples/certs/`. Kunci ECDSA dan Ed25519 deterministik, dibuat dari seed tetap.

## Metode

- RSA: 100 sign per round. ECDSA dan Ed25519: 10000 sign per round. Record: 4096 record per round, dalam batch berisi 64. 5 round per baris.
- Yang dilaporkan adalah round tercepat, bukan rata-rata. Satu round bisa terkena apa pun yang sedang dikerjakan mesin.
- Satu operasi tanpa diukur berjalan dulu di tiap baris, untuk menghangatkan code path.
- Setiap signature dicek oleh verifier std sebelum pengukuran, dan setiap record yang di-open dibandingkan dengan byte yang dikirim, jadi tabel mengukur kerja yang nyata.
- RSA PSS memakai salt tetap, dan ECDSA serta Ed25519 sign tanpa noise, jadi sumber random tidak ikut terukur.
- Pasangan record berasal dari TLS 1.3 handshake sungguhan di memori. Tiap baris membayar jalur record penuh: header, byte inner content type, sequence nonce, AES-128-GCM, dan copy ke buffer record.
- Clock-nya adalah monotonic clock yang dibaca lewat `std.Io`.

Perintah referensi:

```
openssl speed -seconds 3 rsa2048 rsa3072 rsa4096 ecdsap256 ed25519
openssl speed -seconds 3 -evp aes-128-gcm -bytes 16384
openssl speed -seconds 3 -evp aes-128-gcm -decrypt -bytes 16384
```

`openssl speed rsa` sign dengan PKCS#1 v1.5. `openssl speed -evp aes-128-gcm` mengukur AEAD mentah tanpa framing record.

## Sistem

| Item | Nilai |
| :- | :- |
| CPU | AMD Ryzen 5 5600H with Radeon Graphics |
| Arsitektur | x86_64 |
| Fitur CPU yang dipakai | aes, pclmulqdq, vaes, vpclmulqdq, avx2, adx |
| Core / thread | 6 core, 12 thread, 1 socket, 2 thread per core |
| Clock | 4280.98 MHz max, 412.63 MHz min |
| Cache L1d / L1i | 192 KiB / 192 KiB (masing-masing 6 instance) |
| Cache L2 | 3 MiB (6 instance) |
| Cache L3 | 16 MiB (1 instance) |
| Memori | 30 GiB |
| OS | Arch Linux |
| Kernel | Linux 7.2.14-arch1-1 x86_64 |
| Zig | 0.17.0 |
| OpenSSL | 3.6.5 |
| Build | `-Doptimize=ReleaseFast`, native target |
| CPU governor | powersave, energy preference balance_performance, boost on |

Mesin tidak dikosongkan dan governor tidak dikunci ke performance, jadi angka absolutnya konservatif. Kolom ratio adalah tujuan halaman ini. Setiap bench berjalan di satu thread, jadi hanya satu core yang dipakai.

## Cara membaca kolom

| Kolom | Lebih baik |
| :- | :- |
| ms/sign, us/sign, us/record | lower is better (makin kecil makin baik, waktu per operasi lebih sedikit) |
| signs/s, MB/s | higher is better (makin besar makin baik, kerja per detik lebih banyak) |
| ratio | higher is better (1.00x adalah rate OpenSSL, di atas 1.00x berarti rate lebih tinggi dari OpenSSL) |

## Hasil: RSA sign

Ratio adalah rate tlz dibagi rate OpenSSL (1.00x berarti rate-nya sama). Kolom waktu: lower is better. Kolom rate dan ratio: higher is better.

| Kunci | Padding | tlz ms/sign | tlz signs/s | OpenSSL ms/sign | OpenSSL signs/s | ratio |
| :- | :- | :- | :- | :- | :- | :- |
| 2048 | PKCS#1 v1.5 | 0.507 | 1970.9 | 0.501 | 1994.3 | 0.99x |
| 2048 | PSS | 0.509 | 1962.9 | 0.501 | 1994.3 | 0.98x |
| 3072 | PKCS#1 v1.5 | 1.579 | 633.5 | 1.526 | 655.5 | 0.97x |
| 3072 | PSS | 1.577 | 634.1 | 1.526 | 655.5 | 0.97x |
| 4096 | PKCS#1 v1.5 | 3.359 | 297.7 | 3.457 | 289.3 | 1.03x |
| 4096 | PSS | 3.365 | 297.2 | 3.457 | 289.3 | 1.03x |

Baris PSS dibandingkan dengan rate PKCS#1 v1.5 OpenSSL. Kedua padding menjalankan langkah CRT private-key yang sama, yang hampir seluruh biayanya, dan baris tlz menunjukkan kedua padding berselisih kurang dari 1%.

## Hasil: ECDSA P-256 dan Ed25519 sign

Kolom waktu: lower is better. Kolom rate dan ratio: higher is better.

| Kunci | tlz us/sign | tlz signs/s | OpenSSL us/sign | OpenSSL signs/s | ratio |
| :- | :- | :- | :- | :- | :- |
| ECDSA P-256 | 138.81 | 7204 | 16.53 | 60514 | 0.12x |
| Ed25519 | 50.69 | 19726 | 30.97 | 32292 | 0.61x |

## Hasil: record layer, AES-128-GCM, record 16 KiB

MB adalah 1,000,000 byte plaintext, satuan yang dicetak `openssl speed`. Kolom waktu: lower is better. Kolom rate dan ratio: higher is better.

| Sisi | tlz us/record | tlz MB/s | OpenSSL us/record | OpenSSL MB/s | ratio |
| :- | :- | :- | :- | :- | :- |
| seal (encrypt) | 12.44 | 1317 | 3.06 | 5356 | 0.25x |
| open (decrypt) | 12.21 | 1342 | 3.11 | 5266 | 0.25x |

## Cara membaca

- RSA sign berjalan di rate OpenSSL untuk ketiga lebar kunci. Ini adalah CRT signer khusus di `src/crypto/rsa/crt.zig`. RSA juga kunci handshake yang paling mahal, jadi baris inilah yang paling menggerakkan throughput full handshake.
- ECDSA P-256 dan Ed25519 langsung dari `std.crypto`. tlz tidak menambah apa pun di atas pemanggilan sign, jadi selisihnya ada di implementasi std. ECDSA P-256 selisihnya paling besar (0.12x). Meski ada selisih itu, biaya per sign di mesin ini berurutan Ed25519 (50.7 us), lalu ECDSA P-256 (138.8 us), lalu RSA-2048 (507 us), jadi untuk banyak full handshake Ed25519 adalah kunci sertifikat termurah di sini.
- Selisih record berasal dari AES-GCM std, bukan framing tlz. Cek sekali jalan pada `std.crypto.aead.aes_gcm.Aes128Gcm` saja dengan input 16 KiB yang sama (tidak ikut dikirim) membaca sekitar 1384 MB/s, jadi framing record menambah sekitar 5%.
- Baris record bergantung pada build target. Tanpa `aes` dan `pclmulqdq` di target, AES-GCM std jatuh ke software dan record layer jauh lebih lambat. Build untuk CPU tempat server berjalan (native, atau CPU bernama yang punya fitur ini).

| Situasi | Pilih |
| :- | :- |
| banyak full handshake per detik | sertifikat Ed25519, lalu ECDSA P-256, lalu RSA-2048 |
| body besar lewat TLS | build target dengan `aes` dan `pclmulqdq` |
| client yang hanya menawarkan RSA | RSA-2048, rate-nya sama dengan OpenSSL |

## Mengulang pengukuran

Dari root package (`src/tlz`):

```
zig build examples -Doptimize=ReleaseFast
./zig-out/bin/tlz-example-bench_rsa-<arch>-<os>-fast
./zig-out/bin/tlz-example-bench_ecdsa_p256-<arch>-<os>-fast
./zig-out/bin/tlz-example-bench_ed25519-<arch>-<os>-fast
./zig-out/bin/tlz-example-bench_record-<arch>-<os>-fast
```

Jalankan bench satu per satu, tidak paralel, dan jalankan `openssl speed` dengan cara yang sama. Build Debug mengukur safety check, bukan primitive-nya, jadi flag optimize di sini wajib.

Kunci RSA ditanam saat build dari `examples/certs/`. Untuk mengukur kunci lain, ganti file tersebut dengan kunci RSA PKCS#8 lain yang lebarnya sama.

## Yang tidak dikatakan angka ini

- Ini satu mesin dan satu core. Tidak ada di sini yang mengatakan apa yang dilakukan server di bawah beban, ketika jalur request membawa jauh lebih banyak dari crypto.
- Angka ini tidak termasuk key exchange (X25519), key schedule, atau parse sertifikat. Full handshake lebih mahal dari baris sign saja.
- Baris record memakai record penuh 16 KiB. Record kecil lebih sering membayar biaya tetap per record, jadi MB/s-nya lebih rendah.
- `openssl speed` mengukur AEAD mentah, baris record tlz mengukur record penuh. Karena itu ratio-nya sedikit lebih menguntungkan referensi.
