# zixer

Proxy gateway yang dijalankan sebagai program, dibangun di atas engine zix, hanya memakai standard library.

- Digerakkan config: sebuah service dipasang di belakangnya dengan menulis satu file teks, bukan dengan mengubah service-nya.
- Satu daemon memegang banyak site yang saling bebas, satu site per file, masing-masing dengan port dan engine sendiri.
- Menerminasi http1 (dengan SSE dan WebSocket), http2 (dengan rfc 8441), gRPC, dan http3, lalu me-re-originate http1 ke backend. Plus forward udp per flow.
- TLS di edge dengan ACME http-01 untuk certbot, dan reload certificate yang cukup dengan `zixer restart`.
- File static per site, upstream round-robin dengan pengecekan ketersediaan O(1), retry terbatas, dan `Proxy-Status` rfc 9209 di tiap kegagalan lokal.
- Validasi dulu: key yang tidak dikenal, nilai yang salah, atau key yang tidak bisa berlaku akan ditolak dengan fix hint, bukan default diam-diam.
- Kompatibel dengan Zig 0.16 dan 0.17.

Untuk panduan langkah demi langkah lihat `how-to-use-id.md`, untuk arsitektur lihat `hld-id.md`, untuk detail wire-level lihat `lld-id.md`, untuk tiap key config lihat `config-id.md`.

## Build

zixer adalah executable yang ikut dari repository zix, bukan paket yang Anda jadikan dependency:

```bash
zig build zixer
```

Binary-nya jatuh di `zig-out/bin/zixer-<triplet>-<optimize>`, mis. `zixer-x86_64-linux-debug`. Tanpa `-Doptimize`, mode-nya `debug`. Salin ke mana pun di path Anda. Sisa halaman ini menulisnya sebagai `zixer`.

```bash
$ zixer version
zixer 0.5.0-rc3 (zig 0.16.0, x86_64-linux)
```

zixer tidak punya versi sendiri. Ia ikut bersama engine dan melaporkan versi package, jadi baris itu menyebut persis build mana yang sedang berjalan.

## Mulai cepat

Misalnya sesuatu sudah berjalan di `127.0.0.1:3000`:

```bash
zixer init
```

Tulis `~/.zixer/sites/api.cfg`:

```
engine: http1
ip: 0.0.0.0
port: 8080

upstreams: 127.0.0.1:3000
```

Lalu periksa dan sajikan:

```bash
zixer status
zixer start api.cfg
```

`http://localhost:8080/` kini mencapai service itu, dan service-nya tidak disentuh.

## Root dir

Semua yang dibaca zixer berada di bawah satu direktori:

```
~/.zixer
|
|___/sites
|   |___example.cfg.sample             (ditulis oleh init, inert)
|   |___api.cfg                        (satu site per file)
|
|___/logs
|
|___main.cfg
|___control.sock                       (dibuat daemon selama ia berjalan)
```

Root diselesaikan berurutan: `--dir <path>`, lalu `ZIXER_DIR`, lalu `$HOME/.zixer`.

## Perintah

| yang Anda mau | jalankan |
| :- | :- |
| membuat root dir | `zixer init` |
| memeriksa semua config | `zixer status` |
| memeriksa satu config | `zixer status api` (`.cfg` opsional) |
| melihat site apa saja yang ada | `zixer list` |
| menyajikan sebuah site | `zixer start api.cfg` |
| berhenti menyajikannya | `zixer stop api.cfg` |
| menerapkan perubahan file site | `zixer restart api.cfg` |
| menghentikan semuanya | `zixer daemon stop` |
| menjalankan daemon di foreground | `zixer daemon` |

`status` keluar dengan kode 1 saat ada yang salah, jadi ia berfungsi sebagai gate di script deploy. Site yang sedang berjalan tidak pernah mengambil perubahan sendiri: perubahan config menjadi live saat Anda yang memutuskan.

## Config site

Baris `key: value` yang flat, komentar `#`, list dipisah koma, dan matematika integer pada nilai numerik:

| key | artinya |
| :- | :- |
| `engine` | `http1`, `http2`, `grpc`, `http3`, atau `udp` |
| `ip`, `port` | socket yang mendengarkan |
| `tls`, `tls_cert`, `tls_key` | terminasi TLS di edge ini |
| `acme_webroot`, `acme_proxy` | menjawab challenge http-01 rfc 8555 |
| `upstreams` | list `host:port` dipisah koma, dipilih round-robin |
| `public_dir`, `public_prefix`, `spa_fallback` | menyajikan file static dari site ini |
| `public_dir_cache_ttl_ms` | menahan file itu tetap terbuka antar request, `0` berarti mati |
| `kernel_backlog`, `max_recv_buf` | tuning listener |
| `upstream_timeout_ms` | berapa lama edge menunggu upstream yang diam sebelum menjawab 504 |
| `process_limit`, `process_queue_len`, `process_queue_timeout_ms` | katup beban, berapa request yang boleh berjalan ke backend sekaligus |

Sebuah site butuh `upstreams` atau `public_dir`. Selebihnya punya default. Lihat `config-id.md` untuk aturan tiap key, engine mana yang berlaku, dan tiap pesan fault.

## Apa yang dilakukan tiap engine di edge

| engine | sisi client | sisi upstream |
| :- | :- | :- |
| http1 | http1, SSE dan WebSocket diteruskan | http1, keep-alive dipakai ulang |
| http2 | h2 prior knowledge atau ALPN, extended CONNECT rfc 8441 | http1, di-re-originate per stream |
| grpc | h2 dengan trailer | h2 ujung ke ujung, jadi trailer selamat |
| http3 | QUIC diterminasi di zixer | http1, di-re-originate per stream |
| udp | datagram mentah, satu flow per alamat client | satu socket ephemeral per flow |

Tiap request di-re-originate: zixer mem-parse framing client dan membangun pesan upstream miliknya sendiri, jadi byte mentah dari client tidak pernah tersambung langsung.

## Demo

`examples/proxies/` membawa satu demo per bentuk, tiap demo satu upstream `.zig` plus satu site `.cfg` yang jalan dari root mana pun:

```bash
zig build zixer-examples
```

Lihat `examples/proxies/README-id.md` untuk matriks dan perintah penggeraknya.

## Pengujian

```
zig build zixer-unit-test        # in-process, tanpa daemon
zig build zixer-test-runner-all  # tiap demo, dijalankan dan digerakkan ujung ke ujung
```

`zixer-unit-test` adalah step terpisah dari `unit-test` dan `test-all` milik zix, karena zixer memegang build file-nya sendiri. Runner-nya membangun root sekali pakai yang disalin dari `examples/proxies`, jadi satu run tidak pernah mengganggu daemon seorang developer.
