# localbench

> English: [`README-en.md`](README-en.md)

Tiap direktori di sini adalah satu server zig mandiri yang bergantung pada checkout ini
lewat path, jadi membangun satu entry berarti membangun source zix lokal. Ada tiga script
yang membungkusnya: build, validate, run.

Jalankan semua perintah dari root repository.

<br>

## Quick run

Tiga langkah berurutan, untuk run yang angkanya akan Anda kutip:

```bash
./scripts/localbench-build.sh all --release
./scripts/localbench-validate.sh http1-uring
sudo -E ./scripts/localbench-isolate.sh http1-uring --probe --sample-mem --summarize
```

Tiap langkah dijelaskan di bawah.

<br>

## Yang dibutuhkan

| Tool | Dipakai untuk |
| :- | :- |
| `zig-0.16` | membangun entry (set `ZIG_BIN` untuk menunjuk versi lain) |
| `openssl` | certificate self-signed yang dipakai profile TLS |
| `unzip` | mengekstrak `static.zip` bila tidak ada checkout fixtures |
| `docker` | sidecar postgres dan redis, serta load generator HTTP/3 |
| `gcannon` `wrk` `h2load` `ghz` | load generator, satu per keluarga profile |
| `grpcurl` | pengecekan gRPC di langkah 2 |

Load generator yang tidak ada membuat profile terkait dilewati, bukan menggagalkan run.
Profile HTTP/1.1 hanya butuh `gcannon`.

Fixtures (dataset, static set, template request) dibaca dari checkout HttpArena, tidak ada
yang disalin ke repository ini. Lokasi default-nya adalah direktori `HttpArena` sebelah
checkout ini, dan tiap script menerima path lain sebagai argumen terakhir. Tanpa checkout
itu, build menawarkan `static.zip` yang sudah ada di repository, yang hanya mencakup
profile static.

<br>

## Langkah 1: build

```bash
./scripts/localbench-build.sh --list           # entry yang punya source
./scripts/localbench-build.sh http1-uring      # satu entry
./scripts/localbench-build.sh all --release    # semua entry, build release
./scripts/localbench-build.sh http1-uring /path/HttpArena
```

Debug adalah default, sama seperti cara zix dibangun di tempat lain. Pakai `--release`
untuk run yang angkanya akan Anda kutip.

Langkah ini juga membuat `certs/server.crt` dan `certs/server.key` bila belum ada, lalu
mengarahkan `data/` ke fixtures. Keduanya tidak di-commit.

<br>

## Langkah 2: validate

```bash
./scripts/localbench-validate.sh http1-uring
./scripts/localbench-validate.sh http1-uring json    # satu profile
```

Tiap endpoint yang di-subscribe `meta.json` milik entry mendapat PASS atau FAIL. Jawaban
yang salah membuat angka di langkah 3 tidak berarti, jadi bereskan ini lebih dulu.

<br>

## Langkah 3: run

```bash
./scripts/localbench-run.sh http1-uring          # semua profile di meta.json
./scripts/localbench-run.sh http1-uring json     # satu profile
sudo ./scripts/localbench-run.sh http1-uring --quiesce --probe --save --summarize
```

Default-nya dry run: 3 pass per jumlah koneksi, masing-masing 5 detik, pass terbaik yang
dipakai, tidak ada yang ditulis ke `results/`. Server selalu di-pin ke separuh mesin dan
load generator ke separuh lainnya, jadi tidak ada sisi yang mengukur stall sisi lain.

| Flag | Fungsinya |
| :- | :- |
| `--runs N` | pass per jumlah koneksi, terbaik yang dipakai (default 3) |
| `--duration SPEC` | panjang satu pass (default 5s) |
| `--load-threads N` | menimpa jumlah thread load generator yang diturunkan otomatis |
| `--quiesce` | menahan knob host selama run, butuh root, dikembalikan saat keluar |
| `--probe` | menolak mengukur bila mesin bervariasi lebih dari 1 persen |
| `--sample-mem` | mencatat memori server ke file terpisah selama run |
| `--save` | menulis `results/<profile>/<conns>/<entry>.json` |
| `--summarize` | menutup dengan tabel markdown, bukan teks berkolom |

`./scripts/localbench-isolate.sh <entry>` adalah run yang sama dengan knob host sudah
diterapkan, disimpan sebelum jalan dan dikembalikan saat keluar. Semua flag di tabel atas
juga berlaku di sana, diteruskan persis seperti yang diketik dan tidak pernah ditambahkan
sendiri:

```bash
sudo -E ./scripts/localbench-isolate.sh http1-uring json --probe --sample-mem --summarize
```

Profile HTTP/3 butuh satu image, dibangun dari checkout arena:

```bash
docker build -t h2load-h3:local -f docker/h2load-h3.Dockerfile docker
```

<br>

## Langkah 4: membaca hasil

Transkrip lengkap ditulis ke `logs/localbench/run-<entry>-<stamp>.txt`, dan path-nya
dicetak di baris terakhir run. `--save` menambah satu file json per tier di
`logs/localbench/results/`, dan `--sample-mem` menambah log memori di sebelahnya.

Dengan `--summarize`, run ditutup dengan sebuah tabel:

| Test | Conn | RPS | CPU | Mem |
| :- | :- | :- | :- | :- |
| baseline | 512 | 4,187,491 | 6366.9% | 134MiB |
| static | 4096 | 2,022,455 | 5491.0% | 191MiB |

Cara membacanya:

| Kolom | Artinya |
| :- | :- |
| RPS | response sukses dibagi durasi terukur, bukan baris throughput milik driver |
| CPU | persen dari SATU core, jadi 6366.9% berarti 63.7 core |
| Mem | puncak dari jumlah per-snapshot seluruh proses server |

Ketiga angka itu berasal dari pass yang sama, yaitu pass dengan throughput terbaik.

<br>

## Daftar entry

```
gateway-async     gateway-epoll     gateway-uring
http1-async       http1-epoll       http1-uring
http1-ws-async    http1-ws-epoll    http1-ws-uring
http2-async       http2-epoll       http2-uring
http2-grpc-async  http2-grpc-epoll  http2-grpc-uring
http3-async       http3-epoll       http3-uring
```

Satu entry hanya melayani apa yang terdaftar di `meta.json`-nya, jadi nama profile di luar
daftar itu ditolak, bukan diukur. Tiap entry punya `README.md` sendiri yang menjelaskan apa
yang di-cache dan apa yang tidak.
