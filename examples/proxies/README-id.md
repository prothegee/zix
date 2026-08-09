# Demo proxy zixer

> English: [`README-en.md`](README-en.md)

Demo yang bisa dijalankan untuk `zixer`, proxy gateway yang dibangun di atas engine zix. Tiap
demo terdiri dari satu server upstream (`*.zig` di sini) plus satu config site (`sites/*.cfg`).
Config site itulah seluruh konfigurasinya: tidak ada kode di upstream yang tahu dirinya
sedang diproxy.

Direktori ini adalah root dir zixer, jadi `--dir examples/proxies` mengarahkan zixer ke sini.

Untuk rujukan per key di balik file-file ini, baca [`docs/zixer/config-id.md`](../../docs/zixer/config-id.md).

<br>

## Persiapan

Jalankan semuanya dari root repository. Path di config site (`public_dir`, `tls_cert`)
relatif terhadap tempat daemon berjalan.

```bash
zig build zixer                 # membangun zig-out/bin/zixer-<arch>-<os>-<optimize>
zig build zixer-examples        # membangun tiap upstream demo
mkdir -p examples/proxies/logs  # logs/ tidak ada di repository, buat sekali
```

Perpendek path untuk sisa halaman ini. Triplet-nya milik mesin ini, ganti dengan milik Anda, dan
`MODE` adalah nilai `-Doptimize` dalam huruf kecil, yaitu `debug` bila flag-nya tidak diberikan:

```bash
BIN=./zig-out/bin
TRIPLET=x86_64-linux
MODE=debug
ZIXER=$BIN/zixer-$TRIPLET-$MODE
```

Periksa config sebelum menyalakan apa pun. Tiap file mendapat verdict dan tiap masalah
mendapat fix hint:

```bash
$ZIXER --dir examples/proxies status
$ZIXER --dir examples/proxies list
```

<br>

## Alur harian

```bash
$BIN/zixer-example-http1-$TRIPLET-$MODE &   # upstream dulu
$ZIXER --dir examples/proxies start http1.cfg   # men-spawn daemon bila perlu
curl http://127.0.0.1:9100/
$ZIXER --dir examples/proxies stop http1.cfg
$ZIXER --dir examples/proxies daemon stop       # menghentikan tiap site lalu keluar
```

`restart <site.cfg>` membaca ulang file dari disk, dan itulah yang dipanggil deploy hook
certbot setelah renewal.

<br>

## Matriksnya

| Demo | Edge | Upstream | Membuktikan |
| :- | :- | :- | :- |
| http1 | 9100 | 9101 | proxy request biasa, keep-alive di kedua leg |
| http1_sse | 9102 | 9103 | passthrough response yang di-stream, tanpa idle timeout |
| http1_ws | 9104 | 9105 | tunnel upgrade rfc 6455, pilihan upstream dipatok saat upgrade |
| http2 | 9106 | 9107 | edge client h2, http1 di-re-originate ke upstream |
| grpc | 9108 | 9109 | h2 ujung ke ujung, trailer selamat |
| http3 | 9110 | 9111 | edge client QUIC, upstream http1 |
| udp | 9112 | 9113 | forward datagram per flow |
| static | 9114 | tidak ada | site static saja, spa_fallback, cache window sendiri |
| mixed | 9115 | 9116 | static ber-public_prefix berdampingan dengan backend yang diproxy |
| round_robin | 9117 | 9118, 9119 | rotasi, dan retry berbatas saat satu mati |
| tls | 9120 | 9121 | TLS diterminasi di zixer, upstream cleartext |
| rtc_signal | 9122 | 9105 | signaling webrtc: edge wss di atas backend websocket |
| rtc_media | 9123 | 9083 | satu sesi webrtc utuh melintasi forward per flow |
| bounds | 9124 | 9125 | budget client, 408 pada head yang tidak selesai, 503 di atas batas koneksi |
| headers | 9128 | 9129 | dua header section di cfg, token-nya, dan aturan penggantian |

Tiap config site membawa perintah run dan drive-nya sendiri di header, jadi
`sites/<demo>.cfg` adalah rujukan untuk demo itu.

<br>

## Key config mana yang ditunjukkan tiap demo

| key | demo yang dibaca |
| :- | :- |
| `engine` | satu per engine: http1, http2, grpc, http3, udp |
| `ip`, `port` | tiap demo |
| `tls`, `tls_cert`, `tls_key` | tls, http3, rtc_signal |
| `upstreams` (satu) | http1 |
| `upstreams` (beberapa) | round_robin |
| `public_dir`, `spa_fallback` | static |
| `public_prefix` | mixed |
| `public_dir_cache_ttl_ms` | main.cfg untuk default daemon, static untuk override site |
| `public_dir_cache_max_entries` | main.cfg, satu cache table per daemon |
| `kernel_backlog` | main.cfg, diwarisi tiap site di sini |
| `client_timeout_ms`, `client_conn_limit` | bounds |
| `upstream_connect_timeout_ms`, `upstream_idle_ttl_ms` | bounds |
| `[response_headers]`, `[request_headers]` | headers |

`acme_webroot`, `acme_proxy`, `upstream_timeout_ms`, `force_https`, dan `redirect_host` tidak
punya demo: challenge sungguhan butuh port 80 dan sebuah certificate authority, read deadline
baru terlihat pada backend yang sengaja stall, dan redirect butuh port 80 istimewa yang sama
seperti challenge. Perilakunya dijelaskan di
[`docs/zixer/config-id.md`](../../docs/zixer/config-id.md).

Demo bounds memasang `upstream_connect_timeout_ms` pada backend yang benar-benar ada, jadi
key-nya terlihat di file tanpa memperlambat demo. Ia hanya memperpendek penantian terhadap
alamat yang tidak menjawab apa pun.

<br>

## Menjalankan seluruh matriks

Tiap demo di atas juga merupakan check runner. Runner menyalakan tiap upstream, meminta
daemon mem-bind site demo itu, menjalankan client native lewat edge, lalu melaporkan satu
baris per demo:

```bash
zig build zixer-test-runner-all
zig build zixer-test-runner-all -- --only http3   # satu demo
```

Ia membangun root sementaranya sendiri di bawah `tmp/`, disalin dari direktori ini, jadi ia
tidak pernah mengganggu daemon yang sudah berjalan di `examples/proxies`.

<br>

## Catatan

- Port 9100 sampai 9129 milik demo-demo ini, kecuali 9126 dan 9127 yang di-bind runner di sisinya sendiri untuk dua baris udp. Upstream yang dipakai ulang pasangan rtc adalah demo websocket (9105) dan `examples/webrtc/webrtc_datachannel_echo.zig` (9083).
- Demo bounds memutus client setelah dua detik, jadi koneksi yang ditahan terbuka dengan tangan memang akan diambil. Itu demo yang bekerja, bukan daemon yang salah.
- Demo TLS dan http3 memakai `examples/certs/ecdsa_p256_cert.pem`, self-signed untuk
  `localhost` dan `127.0.0.1`, jadi client butuh `-k`. Akses sebagai `https://localhost:<port>`:
  Host yang tidak cocok dengan nama mana pun di certificate dijawab 421 oleh edge.
- Demo http3 butuh curl yang dibangun dengan HTTP/3 (`curl --version` memuat `HTTP3`).
- Demo websocket butuh `websocat` atau `wscat`, demo grpc butuh `grpcurl`.
- Satu daemon melayani tiap site yang start, jadi beberapa demo bisa berjalan bersamaan.
  Tiap site memiliki port-nya, dan tabrakan ditolak saat `start` alih-alih diabaikan diam-diam.
