# Cara memakai zixer

zixer adalah proxy gateway yang Anda jalankan sebagai program. Anda menaruh service di belakangnya dengan menulis satu file config, bukan dengan mengubah service itu. Halaman ini berjalan dari mesin kosong sampai satu site berjalan, lalu memberi satu resep per bentuk.

Tiap key yang disebut di sini dijelaskan lengkap di `config-id.md`.

<br>

## Build

zixer dibangun dari repository zix:

```bash
zig build zixer
```

Binary-nya mendarat di `zig-out/bin/zixer-<triplet>`, mis. `zixer-x86_64-linux`. Salin ke mana pun di path Anda. Sisa halaman ini menulisnya sebagai `zixer`.

```bash
$ zixer version
zixer 0.5.0-rc3 (zig 0.16.0, x86_64-linux)
```

zixer tidak punya versi sendiri: ia dikirim bersama engine dan melaporkan versi package, jadi baris di atas menyebut persis build mana yang berjalan.

<br>

## Lima menit menuju service yang diproxy

Misalkan Anda sudah menjalankan sesuatu di `127.0.0.1:3000`.

```bash
zixer init
```

Itu membuat root dir, yaitu `$HOME/.zixer` kecuali Anda menentukan lain:

```
~/.zixer
|
|___/sites
|   |___example.cfg.sample
|
|___/logs
|
|___main.cfg
```

Tulis satu file site:

```bash
cat > ~/.zixer/sites/api.cfg <<'CFG'
engine: http1
ip: 0.0.0.0
port: 8080
upstreams: 127.0.0.1:3000
CFG
```

Periksa sebelum menyalakan apa pun. Ini membaca parser yang sama dengan daemon:

```bash
$ zixer status
# /home/you/.zixer/main.cfg
main.cfg:
status: ok
...

# /home/you/.zixer/sites/api.cfg
api.cfg:
status: ok
engine: http1
ip: 0.0.0.0
port: 8080
tls: false
upstreams: 127.0.0.1:3000
```

Nyalakan. Daemon di-spawn untuk Anda pada kali pertama:

```bash
$ zixer start api.cfg
api.cfg started on 0.0.0.0:8080

$ curl -s http://127.0.0.1:8080/
```

Hentikan satu site, atau semuanya:

```bash
zixer stop api.cfg
zixer daemon stop
```

<br>

## Memilih di mana root dir berada

Tiga cara, yang pertama ketemu menang:

```bash
zixer --dir /srv/zixer status        # eksplisit, per command
export ZIXER_DIR=/srv/zixer          # untuk satu shell atau unit service
# tidak keduanya: $HOME/.zixer
```

Mana pun yang Anda pilih, pakai yang sama untuk tiap command, termasuk yang men-spawn daemon. `zixer` polos melaporkan root mana yang akan dipakainya dan apakah sudah diinisialisasi.

Jaga path-nya pendek. Daemon memegang unix socket di `<root>/control.sock`, dan seluruh string itu harus muat pada batas platform (108 byte di Linux). Path yang terlalu dalam ditolak dengan `control socket path is too long for this platform`.

<br>

## Command

| Anda ingin | jalankan |
| :- | :- |
| membuat root dir | `zixer init` |
| memeriksa tiap config | `zixer status` |
| memeriksa satu config | `zixer status api` (`.cfg` opsional) |
| melihat site apa saja yang ada | `zixer list` |
| melayani sebuah site | `zixer start api.cfg` |
| berhenti melayaninya | `zixer stop api.cfg` |
| menerapkan perubahan file site | `zixer restart api.cfg` |
| menghentikan semuanya | `zixer daemon stop` |
| menjalankan daemon di foreground | `zixer daemon` |

`status` keluar dengan kode 1 saat ada yang salah, jadi ia bisa dipakai sebagai gerbang di skrip deploy:

```bash
zixer --dir /srv/zixer status || exit 1
zixer --dir /srv/zixer restart api.cfg
```

<br>

## Menerapkan perubahan config

| yang Anda ubah | cara menerapkan |
| :- | :- |
| satu file site | `zixer restart <site.cfg>`, yang membaca ulang file itu dari disk |
| `main.cfg` | `zixer daemon stop`, lalu nyalakan lagi site Anda |
| certificate di disk | `zixer restart <site.cfg>` |

Site yang berjalan tidak pernah mengambil perubahan dengan sendirinya. Itu disengaja: perubahan config menjadi aktif saat Anda menyatakannya, dan `status` membiarkan Anda memeriksanya lebih dulu.

<br>

## Resep

### Site static

Tanpa backend sama sekali. zixer yang menjadi origin:

```
engine: http1
ip: 0.0.0.0
port: 8080
public_dir: /var/www/site
```

Request ke sebuah direktori dipetakan ke `index.html`. Bila ada sibling `.br` atau `.gz` di sebelah sebuah file, sibling itu disajikan ke client yang menerima coding tersebut, dengan `Vary: Accept-Encoding` di response.

### Single page app

Path apa pun yang bukan file nyata menjawab app shell, jadi routing di sisi client tetap bekerja saat direfresh:

```
engine: http1
ip: 0.0.0.0
port: 8080
public_dir: /var/www/app/dist
spa_fallback: index.html
```

### Aset static berdampingan dengan backend

Hanya `/assets/...` yang diambil dari disk, sisanya diproxy:

```
engine: http1
ip: 0.0.0.0
port: 8080
upstreams: 127.0.0.1:3000
public_dir: /var/www/app/dist
public_prefix: /assets
```

Prefix-nya wajib begitu sebuah site punya kedua plane plus sebuah fallback, kalau tidak 404 asli dari backend akan lenyap ke app shell.

Perhatikan bahwa path request digabungkan ke `public_dir` apa adanya, jadi `public_prefix: /assets` butuh direktori `assets/` yang nyata di dalam `public_dir`.

### Beberapa backend

Request berputar di daftar itu. Backend yang menolak koneksi dilewati beberapa detik lalu dicoba lagi:

```
engine: http1
ip: 0.0.0.0
port: 8080
upstreams: 127.0.0.1:3000, 127.0.0.1:3001, 127.0.0.1:3002
```

Host upstream harus literal ip. `localhost:3000` lolos pemeriksaan config lalu gagal di tiap request.

### TLS di edge

Backend tetap cleartext, jadi tidak ada yang di belakang zixer perlu certificate:

```
engine: http1
ip: 0.0.0.0
port: 443
tls: true
tls_cert: /etc/letsencrypt/live/example.com/fullchain.pem
tls_key: /etc/letsencrypt/live/example.com/privkey.pem
upstreams: 127.0.0.1:3000
```

Certificate menentukan nama mana yang dijawab site itu. Request untuk host yang tidak dicakup certificate dijawab `421`, dan itulah jawaban yang benar untuk request salah alamat alih-alih diam-diam menjawab dari site yang keliru.

### Renewal dengan certbot

Tambahkan path challenge ke site dan biarkan certbot menulis ke webroot:

```
acme_webroot: /var/www/acme
```

```bash
certbot certonly --webroot -w /var/www/acme -d example.com \
  --deploy-hook 'zixer --dir /srv/zixer restart example.cfg'
```

Site TLS di port selain 80 juga bind port 80 untuk challenge, jadi prosesnya butuh hak itu. Bila program lain sudah memegang port 80, pakai `acme_proxy: 127.0.0.1:9080` dan biarkan program itu yang menjawab challenge.

### HTTP/2

```
engine: http2
ip: 0.0.0.0
port: 8443
tls: true
tls_cert: /etc/letsencrypt/live/example.com/fullchain.pem
tls_key: /etc/letsencrypt/live/example.com/privkey.pem
upstreams: 127.0.0.1:3000
```

Client berbicara h2, backend tetap berbicara HTTP/1.1. Websocket lewat extended CONNECT di-bridge ke backend websocket biasa.

### gRPC

```
engine: grpc
ip: 0.0.0.0
port: 50051
upstreams: 127.0.0.1:9109
```

Kedua leg h2 sehingga trailer, dan karenanya status grpc, selamat melewati hop. Site grpc tidak bisa menyajikan file static.

### HTTP/3

```
engine: http3
ip: 0.0.0.0
port: 443
tls: true
tls_cert: /etc/letsencrypt/live/example.com/fullchain.pem
tls_key: /etc/letsencrypt/live/example.com/privkey.pem
upstreams: 127.0.0.1:3000
```

TLS di sini bukan pilihan, ia bagian dari QUIC. Port-nya UDP, jadi buka sebagai UDP di firewall.

### Forward datagram

Relay buta, satu flow per client, yang persis dibutuhkan jalur media di depan engine WebRTC:

```
engine: udp
ip: 0.0.0.0
port: 3478
upstreams: 127.0.0.1:9083
```

Tidak ada yang di-parse dan tidak ada yang ditulis ulang. Tiap client mendapat socket sendiri ke arah backend, jadi backend melihat satu peer berbeda per client.

<br>

## Menjalankannya sebagai service

Daemon berjalan di foreground dengan `zixer daemon`, dan itulah yang diinginkan service manager. Nyalakan site Anda setelah ia hidup:

```bash
ZIXER_DIR=/srv/zixer zixer daemon
```

Belum ada output log. `logs_dir` harus ada karena `status` memeriksanya, dan tidak ada yang menulis ke sana.

<br>

## Penelusuran masalah

| yang Anda lihat | artinya | yang harus dilakukan |
| :- | :- | :- |
| `zixer is not initialized` | tidak ada `main.cfg` di root | `zixer init`, atau arahkan `--dir` ke root yang benar |
| `daemon did not answer after spawn` | daemon tidak bisa start | jalankan `zixer daemon` di foreground dan baca pesannya |
| `control socket path is too long for this platform` | path root dir terlalu dalam | pindahkan root ke tempat yang lebih pendek |
| `api.cfg has config errors` | site tidak lolos validasi | `zixer status api`, perbaiki tiap key yang disebut |
| `port 8080 is already used by other.cfg` | site lain yang start memilikinya | ganti port, atau hentikan site itu |
| `bind failed (AddressInUse)` | sesuatu di luar zixer memiliki port itu | cari dengan `ss -ltnp` |
| `bind failed (BadUpstreamAddress)` | upstream site udp bukan literal ip | tulis alamatnya, bukan nama |
| `502 all upstreams failed` | tiap backend menolak atau gagal | periksa backend, dan pastikan alamat upstream adalah literal ip |
| `503 no upstream available` | tiap backend sedang di jendela cooldown-nya | periksa backend, coba lagi beberapa detik kemudian |
| `421 misdirected request` | Host tidak dicakup `tls_cert` | pakai nama yang dicakup certificate, atau terbitkan certificate yang mencakupnya |
| `404 not found` di path static | file-nya tidak ada di bawah `public_dir` | periksa path-nya, dan ingat `public_prefix` tidak dipotong sebelum digabungkan |
| challenge acme menjawab 404 | token tidak ada di bawah webroot | ia harus ada di `<acme_webroot>/.well-known/acme-challenge/<token>` |
| perubahan tidak berpengaruh | site masih menjalankan file lama | `zixer restart <site.cfg>` |

<br>

## Selanjutnya ke mana

| pertanyaan | halaman |
| :- | :- |
| apa persisnya yang dilakukan key ini | `config-id.md` |
| bagaimana gateway ini disusun | `hld-id.md` |
| apa yang terjadi di wire | `lld-id.md` |
| adakah contoh jalan untuk tiap bentuk | `examples/proxies/README-id.md` di repository |
