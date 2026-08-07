# Rujukan Config zixer

Semua yang bisa dikendalikan operator di zixer ada di dua jenis file teks biasa: satu `main.cfg` untuk daemon, dan satu `.cfg` per site. Tidak ada input lain, tidak ada penyetelan lewat environment, dan tidak ada flag command yang mengubah perilaku serving. Halaman ini memuat tiap key, default-nya, apa yang benar-benar dilakukannya hari ini, dan cara memeriksanya sendiri di mesin Anda.

Baca `how-to-use-id.md` dulu bila belum pernah menjalankan satu site. Internal di balik tiap key ada di `lld-id.md`.

<br>

## Dua file itu

```
~/.zixer
|
|___/sites
|   |___example.cfg.sample             (ditulis init, tidak aktif)
|   |___my_service.cfg                 (satu site per file)
|
|___/logs
|
|___main.cfg
|___control.sock                       (dibuat daemon selama berjalan)
```

| file | siapa yang membaca | kapan |
| :- | :- | :- |
| `main.cfg` | daemon, sekali saat start | `zixer daemon`, atau auto-spawn di balik `zixer start` pertama |
| `sites/<name>.cfg` | daemon, per site | tiap `start` dan `restart` site itu |

Root dir di-resolve dengan urutan tetap: `--dir <path>`, lalu environment variable `ZIXER_DIR`, lalu `$HOME/.zixer` (`%USERPROFILE%\.zixer` di Windows). `zixer` polos mencetak sumber mana yang menjawab dan apakah root itu sudah diinisialisasi.

Nama file site adalah identitas site itu. Hanya file berakhiran `.cfg` yang dimuat, itu sebabnya contoh bawaan dikirim sebagai `example.cfg.sample`.

<br>

## Sintaks nilai

Kedua file memakai grammar flat yang sama.

| bentuk | arti |
| :- | :- |
| `key: value` | satu setting per baris, spasi di sekitar titik dua dipangkas |
| `# teks` | comment, satu baris penuh |
| `port: 8080  # port edge` | comment di ekor baris |
| `tls_cert: C:/certs/full.pem` | hanya titik dua pertama yang memisah, jadi sebuah path tetap utuh |
| `upstreams: a:1, b:2` | list dengan koma, tiap item dipangkas |
| `max_recv_buf: 16 * 1024` | math integer, lihat di bawah |
| `tls: true` | boolean, hanya `true` dan `false` |

Nilai numerik menerima aritmetika integer dengan `+ - * /` dan tanda kurung, perkalian dan pembagian mengikat lebih dulu, kiri ke kanan. Pembagian harus pas: `10 / 4` ditolak alih-alih dipotong diam-diam, karena sisa bagi biasanya berarti salah ketik. Hasilnya harus muat di math 64-bit.

Apa pun yang tidak terbaca grammar menjadi fault, tidak pernah dilewati diam-diam:

| ditulis | dilaporkan sebagai |
| :- | :- |
| `no colon here` | `line 9 has no ':', write key: value` |
| `: 8080` | `line 3 has no key before ':'` |
| `port:` | `line 4 has no value after ':'` |
| `wrokers: 2` | `unknown key, remove it or fix the typo` |
| key yang sama dua kali | `duplicate key, keep one line` |

<br>

## main.cfg

| key | default | controls | applies | if wrong |
| :- | :- | :- | :- | :- |
| workers | `1` | jumlah accept loop yang dijalankan tiap site, `0` berarti semua thread yang tersedia | site http1, http2, dan grpc yang melayani upstream atau `public_dir` | di atas jumlah thread yang boleh dipakai proses ini ia fault dan tetap di default |
| dispatch | `async` | dispatch model: `async`, `epoll`, `uring` | hanya dilaporkan, lihat di bawah | `epoll` dan `uring` fault di luar Linux, kata lain fault di mana pun |
| logs_dir | `<root>/logs` | tempat output log akan ditulis | direktorinya harus ada, belum ada yang menulis ke sana | direktori yang hilang menjadi fault dan `status` keluar dengan kode 1 |
| sites_dir | `<root>/sites` | tempat file `.cfg` site dibaca | tiap `list`, `status`, `start`, dan `restart` | direktori yang hilang menjadi fault, dan tidak ada site yang ditemukan |
| kernel_backlog | `1024` | panjang listen queue default untuk listener site tcp | site http1, http2, dan grpc yang tidak punya nilai sendiri, plus listener companion acme | `0` fault, kernel tetap membatasi nilainya di `net.core.somaxconn` |
| max_recv_buf | `8192` | jumlah byte untuk satu stream buffer per koneksi, lihat di bawah | site http1, http2, grpc, dan TLS, sebagai default yang boleh ditimpa file site | di luar `1024` sampai `262144` ia fault dan tetap di default |

Hanya `dispatch` yang divalidasi tanpa dipakai. `main.cfg` kosong tetap valid: tiap key jatuh ke default di atas.

### Apa yang dilakukan workers

Site tcp yang sudah start menjalankan `workers` accept loop, bukan satu. Tiap
loop memegang listener-nya sendiri di port site itu, dan kernel memberi tiap
listener sebagian dari koneksi yang datang, jadi menerima koneksi tidak lagi
menjadi pekerjaan satu thread saja.

- `workers: 0` berarti semua thread yang boleh dipakai proses ini. Di Linux nilainya dibaca dari affinity mask proses, jadi daemon yang di-pin ke sebuah cpuset mendapat core yang diberikan padanya, bukan core yang dimiliki mesin. Container yang dibatasi cpu quota, bukan cpuset, sebaiknya menyebut angkanya langsung.
- Tiap loop juga memiliki upstream pool dan idle connection cache sendiri. Batas idle milik site dibagi di antara mereka, jadi backend tidak pernah kehilangan kapasitas lebih banyak hanya karena edge menjalankan lebih banyak loop.
- `zixer status` mencetak nilai hasil resolusi di samping nilai config setiap kali keduanya berbeda, misalnya `workers: 0 (resolved to 12)`.
- Nilainya dibaca sekali, saat daemon start. Mengubah `main.cfg` lalu restart satu site tidak mengubahnya, daemon-nya yang harus di-restart.
- Windows tetap memakai satu loop berapa pun angkanya. Dua listener tidak bisa berbagi port di sana: bind kedua mengambil alih port itu, bukan bergabung, jadi loop tambahan tidak akan melayani apa pun.
- Hanya engine proxy tcp yang memakainya. Site http3 dan site udp masing-masing memiliki satu socket yang state per koneksinya terikat ke socket itu.

Loop tambahan membantu ketika menerima koneksi adalah dindingnya, yaitu banyak
koneksi, bukan banyak request di beberapa koneksi. Diukur pada site static demo
project ini, 12 loop dibanding 1: tidak ada perubahan di 8 koneksi, 8 persen di
1024, dan 61 persen di 4096.

### Apa yang dilakukan max_recv_buf

Tiap koneksi yang diterima mengalokasikan stream buffer-nya saat mulai dan
melepasnya saat selesai. `max_recv_buf` adalah ukuran satu buffer tersebut,
dan berapa banyak yang dipegang satu koneksi tergantung apa yang dilakukan
site itu:

| bentuk site | buffer per koneksi | pada default `8192` |
| :- | :- | :- |
| static saja, `public_dir` tanpa `upstreams` | 2, baca dan tulis sisi client | 16 KiB |
| proxy, engine apa pun | 4, pasangan client dan pasangan upstream | 32 KiB |
| grpc | 2 untuk client, plus 2 per koneksi h2 upstream yang benar-benar dibuka | 32 KiB dengan satu upstream |

Ukurannya tidak membatasi apa pun: site dengan nilai terkecil tetap mem-parse
head request penuh, tetap menyajikan file sepanjang apa pun, dan tetap
meneruskan body sepanjang apa pun. Ia hanya menentukan berapa banyak byte yang
berpindah per baca dan per tulis, jadi nilai lebih kecil berarti lebih banyak
syscall untuk transfer besar, dan nilai lebih besar berarti lebih banyak
resident memory di tiap koneksi yang terbuka.

- File site boleh menyebut `max_recv_buf` sendiri, dan nilainya menimpa yang ini untuk site tersebut.
- Rentangnya `1024` sampai `262144` byte di keduanya, dan nilai di luar itu fault, bukan diam-diam di-clamp.
- Ini bukan seluruh biaya per koneksi. Koneksi http1 yang di-proxy juga memegang tiga head buffer masing-masing 16 KiB, yang merupakan batas protokol bukan pilihan tuning, dan koneksi TLS menambah sekitar 58 KiB untuk record dan plaintext buffer milik session-nya.

Diukur pada site static demo project ini, resident memory per koneksi yang
ditahan: 62,7 KiB di `1024`, 64,7 KiB di `2048`, 76,7 KiB di `8192`, dan
124,7 KiB di `32768`. Site yang di-proxy adalah 112,7, 116,8, 140,8, dan
236,8 KiB pada empat nilai yang sama.

### Key yang divalidasi tapi belum dipakai

`dispatch` di-parse, dicek rentangnya, dan dicetak oleh `zixer status`, dan tidak ada satu pun jalur serving yang membacanya. `dispatch: async`, `dispatch: epoll`, dan `dispatch: uring` semuanya melayani lewat edge loop yang sama, dan tiap accept loop menjalankan tiap koneksi sebagai task bersamaan.

Anggap keduanya reserved. Keduanya dipertahankan karena validasi adalah bagian yang pertama dibutuhkan operator (config yang nanti akan dipakai tetap harus ditolak sekarang bila salah), tapi jangan menghitung kapasitas mesin berdasarkan keduanya.

<br>

## Config site

Satu file, satu site. `engine` dan `port` wajib, sisanya punya default atau opsional.

| key | default | controls | engines | if wrong |
| :- | :- | :- | :- | :- |
| engine | wajib | edge mana yang melayani site: `http1`, `http2`, `grpc`, `http3`, `udp` | semua | hilang atau tidak dikenal menjadi fault, dan site tidak pernah bind |
| ip | `0.0.0.0` | alamat bind, literal IPv4 atau IPv6 | semua | apa pun yang bukan literal alamat menjadi fault, hostname tidak diterima |
| port | wajib | port edge | semua | di luar 1 sampai 65535 menjadi fault, port yang dimiliki site lain yang sudah start ditolak saat `start` |
| tls | `false` | terminasi TLS di edge | http1, http2, grpc, wajib di http3, ditolak di udp | nilai non boolean menjadi fault |
| tls_cert | tidak ada | path certificate chain, PEM | dengan `tls: true` | wajib saat tls on, ditolak saat off, file yang hilang menjadi fault di `status` dan menolak `start` |
| tls_key | tidak ada | path private key, PEM | dengan `tls: true` | sama dengan `tls_cert` |
| acme_webroot | tidak ada | direktori yang disajikan di bawah `/.well-known/acme-challenge/` | http1 cleartext, atau site TLS mana pun | butuh `tls: true` atau site http1, ditolak di udp, tidak boleh berpasangan dengan `acme_proxy` |
| acme_proxy | tidak ada | `host:port` tujuan relay path challenge | sama dengan `acme_webroot` | harus `host:port`, tidak boleh berpasangan dengan `acme_webroot` |
| upstreams | tidak ada | list `host:port` dipisah koma, dipilih round-robin | semua | tiap item harus `host:port`, host-nya harus literal ip (lihat di bawah), sebuah site butuh `upstreams` atau `public_dir` |
| public_dir | tidak ada | direktori yang disajikan sebagai file static | http1, http2, http3, ditolak di grpc dan udp | direktori yang hilang menjadi fault di `status` |
| public_prefix | tidak ada | prefix path yang diikat ke `public_dir`, mis. `/assets` | dengan `public_dir` | harus diawali `/`, butuh `public_dir` |
| spa_fallback | tidak ada | file yang disajikan saat tidak ada file static yang cocok, mis. `index.html` | dengan `public_dir` | butuh `public_dir`, dan butuh `public_prefix` saat site juga punya upstreams |
| kernel_backlog | nilai main.cfg | panjang listen queue untuk site ini | http1, http2, grpc, ditolak di udp, diterima tapi tidak dipakai di http3 | `0` fault |
| max_recv_buf | nilai main.cfg | jumlah byte untuk satu stream buffer per koneksi | site http1, http2, grpc, dan TLS | di luar `1024` sampai `262144` ia fault dan site jatuh ke nilai main.cfg |
| upstream_timeout_ms | `30000` | berapa lama edge menunggu upstream yang diam sebelum menjawab 504 | http1, http2, http3, ditolak di grpc dan udp | butuh `upstreams`, `0` menunggu selamanya, di atas 4294967295 fault |

`ip` dan `port` bersama menentukan socket yang mendengarkan. `0.0.0.0` bind ke semua interface, `127.0.0.1` bind loopback saja, `::` bind ke semua interface IPv6.

### Forwarded menulis proto=http bahkan di site TLS

Tiap request yang diproxy membawa header `Forwarded` (rfc 7239) berisi alamat client, scheme, dan host asli:

```
forwarded: for="127.0.0.1:50250";proto=http;host="localhost:9707"
```

Parameter `proto` bernilai `http` di tiap edge hari ini, termasuk edge TLS. Backend yang memutuskan "apakah request ini aman" dari header itu akan salah baca di site `tls: true`, jadi putuskan hal itu dari port yang didengarkan backend.

### Host upstream harus literal ip

zixer tidak melakukan resolusi nama di leg upstream, dan pemeriksaan config belum menangkap sebuah nama hari ini. `upstreams: localhost:3000` lolos `zixer status` lalu gagal saat dipakai:

| engine | apa yang terjadi |
| :- | :- |
| http1, http2, grpc, http3 | site start, dan tiap request dijawab `502 all upstreams failed` dengan `Proxy-Status: zixer; error="connection_refused"` |
| udp | site menolak start: `bind failed (BadUpstreamAddress)` |

Tulis `127.0.0.1:3000`, bukan sebuah nama. Upstream IPv6 ditulis polos, `::1:3000`, karena nilai dipisah pada titik dua terakhirnya. Bentuk berkurung `[::1]:3000` lolos pemeriksaan config lalu gagal dengan cara yang sama seperti sebuah nama.

### Apa yang dicakup upstream_timeout_ms

Batas ini berlaku pada edge yang menunggu backend, bukan pada seluruh request:

| menunggu | dibatasi |
| :- | :- |
| head response upstream, termasuk stall setelah 1xx interim | ya |
| body response `Content-Length` | ya |
| body response chunked | tidak |
| body response yang diakhiri close | tidak |
| tunnel websocket setelah 101 | tidak |
| connect ke upstream | tidak |

Body chunked atau yang diakhiri close tidak membawa jumlah byte total untuk mengakhiri loop, dan stream server-sent-event memang diam di antara event, jadi deadline di sana akan memotong stream yang sehat. Connect tidak punya batas karena backend std yang akan dipakainya panic saat diberi satu.

Saat head tidak pernah datang, client menerima:

```
HTTP/1.1 504 upstream timeout
Proxy-Status: zixer; error="http_response_timeout"
```

Upstream tidak ditandai down karena timeout, dan request tidak diulang ke upstream lain: request itu sudah terkirim, jadi mengulangnya bisa menjalankan pekerjaan yang sama dua kali, dan backend yang lambat tetap backend yang melayani. Stall di tengah body `Content-Length` mengakhiri response itu, karena head-nya sudah ada di wire.

Set `upstream_timeout_ms: 0` pada site yang backend-nya memang berpikir lebih lama dari budget. Itu sama dengan menunggu tanpa batas seperti sebelum key ini ada.

<br>

## Key mana berlaku untuk engine mana

| key | http1 | http2 | grpc | http3 | udp |
| :- | :- | :- | :- | :- | :- |
| engine, ip, port | ya | ya | ya | ya | ya |
| tls | opsional | opsional | opsional | wajib | ditolak |
| tls_cert, tls_key | dengan tls | dengan tls | dengan tls | wajib | ditolak |
| acme_webroot, acme_proxy | ya | TLS saja | TLS saja | ya (selalu TLS) | ditolak |
| upstreams | ya | ya | ya | ya | ya, wajib |
| public_dir, public_prefix, spa_fallback | ya | ya | ditolak | ya | ditolak |
| kernel_backlog | ya | ya | ya | diterima, tanpa efek | ditolak |
| max_recv_buf | menentukan ukuran stream buffer | menentukan ukuran stream buffer | menentukan ukuran stream buffer | diterima, tanpa efek | diterima, tanpa efek |
| upstream_timeout_ms | ya | ya | ditolak | ya | ditolak |

"Ditolak" berarti key-nya fault dengan fix hint dan site tidak start. "Diterima, tanpa efek" berarti file lolos validasi dan tidak ada yang membaca nilainya.

`engine` juga menentukan apa yang ditawarkan sebuah handshake TLS: site http1 menawarkan `http/1.1`, site http2 menawarkan `h2` lalu `http/1.1`, site grpc menawarkan `h2` saja.

<br>

## Aturan lintas field

Tiap aturan di bawah diperiksa setelah seluruh file dibaca, jadi satu pass melaporkan semua masalah sekaligus.

| aturan | teks fault |
| :- | :- |
| `engine` hilang | `missing, set one of http1, http2, grpc, http3, udp` |
| `port` hilang | `missing, set 1-65535` |
| `tls: true` tanpa cert | `tls_cert: required when tls: true` |
| `tls_cert` tanpa `tls: true` | `set tls: true or remove it` |
| tidak ada `upstreams` maupun `public_dir` | `site needs upstreams or public_dir` |
| `public_prefix` tanpa `public_dir` | `needs public_dir` |
| `spa_fallback` tanpa `public_dir` | `needs public_dir` |
| `spa_fallback` dengan upstreams tapi tanpa prefix | `needs public_prefix when upstreams are set` |
| `acme_webroot` dan `acme_proxy` bersamaan | `choose acme_webroot or acme_proxy, not both` |
| key acme di site http2, grpc, atau http3 cleartext | `needs tls: true or an http1 site` |
| `engine: http3` tanpa tls | `tls: http3 requires tls: true` |
| `public_dir` atau `upstream_timeout_ms` di site grpc | `not supported on grpc sites, remove it` |
| `upstream_timeout_ms` di site tanpa upstreams | `needs upstreams` |
| `tls` di site udp | `udp forward is blind bytes, tls does not apply` |
| `public_dir`, `kernel_backlog`, `upstream_timeout_ms`, atau key acme di site udp | `does not apply to udp sites, remove it` |

Aturan prefix pada `spa_fallback` ada supaya sebuah miss dari backend tidak lenyap ke halaman fallback: tanpa prefix yang mengikat static plane, tiap 404 dari upstream akan dijawab sebagai app shell.

Path juga diperiksa keberadaannya. `tls_cert`, `tls_key`, `public_dir`, dan `acme_webroot` masing-masing fault saat path-nya tidak ada di mesin ini, dan path relatif dihitung terhadap direktori tempat daemon berjalan, bukan terhadap root dir.

<br>

## Membaca laporan status

```
$ zixer status
# /srv/zixer/main.cfg
main.cfg:
status: ok
workers: 1
dispatch: async
logs_dir: /srv/zixer/logs
sites_dir: /srv/zixer/sites
max_recv_buf: 8192
kernel_backlog: 1024

# /srv/zixer/sites/api.cfg
api.cfg:
status: error
engine: http1
ip: 0.0.0.0
port: 8080
tls: false
errors:
    upstreams: site needs upstreams or public_dir
```

`status: ok` di tiap blok berarti exit code 0. Blok `errors:` mana pun berarti exit code 1, dan itulah yang harus dijadikan gerbang oleh skrip deploy. Site yang punya error ditolak saat `start` dengan penunjuk kembali ke `zixer status <name>`.

<br>

## Contoh siap pakai

Reverse proxy biasa:

```
engine: http1
ip: 0.0.0.0
port: 8080
upstreams: 127.0.0.1:3000, 127.0.0.1:3001
```

Single page app static, tanpa backend:

```
engine: http1
ip: 0.0.0.0
port: 8080
public_dir: /var/www/app/dist
spa_fallback: index.html
```

Aset static berdampingan dengan backend yang diproxy. Hanya `/assets/...` yang diambil dari disk, sisanya ke upstream:

```
engine: http1
ip: 0.0.0.0
port: 8080
upstreams: 127.0.0.1:3000
public_dir: /var/www/app/dist
public_prefix: /assets
```

TLS diterminasi di edge, cleartext ke backend, dengan path renewal disajikan dari disk:

```
engine: http1
ip: 0.0.0.0
port: 443
tls: true
tls_cert: /etc/letsencrypt/live/example.com/fullchain.pem
tls_key: /etc/letsencrypt/live/example.com/privkey.pem
acme_webroot: /var/www/acme
upstreams: 127.0.0.1:3000
```

Site TLS di luar port 80 juga bind port 80 untuk challenge, jadi prosesnya butuh hak untuk bind port itu.

gRPC, h2 ujung ke ujung supaya trailer selamat:

```
engine: grpc
ip: 0.0.0.0
port: 50051
upstreams: 127.0.0.1:9109
```

HTTP/3, TLS bukan pilihan:

```
engine: http3
ip: 0.0.0.0
port: 443
tls: true
tls_cert: /etc/letsencrypt/live/example.com/fullchain.pem
tls_key: /etc/letsencrypt/live/example.com/privkey.pem
upstreams: 127.0.0.1:3000
```

Forward datagram buta, satu flow per client, yang persis dibutuhkan media relay di depan engine WebRTC:

```
engine: udp
ip: 0.0.0.0
port: 3478
upstreams: 127.0.0.1:9083
```

Listen queue lebih ketat di satu site sibuk, sisanya tetap memakai default main.cfg:

```
engine: http1
ip: 0.0.0.0
port: 8080
upstreams: 127.0.0.1:3000
kernel_backlog: 128
```

<br>

## Memeriksa sebuah key sendiri

Tiap klaim di halaman ini bisa diperiksa pada daemon yang berjalan. Ini pemeriksaan yang dipakai saat menulisnya.

Panjang listen queue, kolom `Send-Q` sebuah listening socket adalah backlog-nya:

```bash
zixer --dir /srv/zixer start api.cfg
ss -ltn | grep 8080
```

Alamat bind:

```bash
ss -ltn | grep 8080      # 0.0.0.0:8080 atau 127.0.0.1:8080 sesuai config
```

Kepemilikan port antar dua site:

```bash
zixer --dir /srv/zixer start other.cfg
# other.cfg port 8080 is already used by api.cfg
```

Perubahan config berlaku saat `restart`, yang membaca ulang file dari disk:

```bash
zixer --dir /srv/zixer restart api.cfg
```

Static plane melawan proxy plane pada site dengan `public_prefix`:

```bash
curl -s http://127.0.0.1:8080/assets/app.css   # dari public_dir
curl -s http://127.0.0.1:8080/                 # dari upstream
```

Gerbang nama certificate pada site TLS. Certificate menentukan nilai Host mana yang dijawab site, selebihnya dapat 421:

```bash
curl -sk https://localhost:8443/               # 200
curl -sk --resolve other.test:8443:127.0.0.1 https://other.test:8443/   # 421
```

Path renewal dari webroot:

```bash
echo token-body > /var/www/acme/.well-known/acme-challenge/tok123
curl -s http://127.0.0.1:8080/.well-known/acme-challenge/tok123
```

<br>

## Catatan

- Perubahan config tidak pernah berlaku ke site yang sedang jalan dengan sendirinya. `restart <site.cfg>` membaca ulang satu file site, dan `main.cfg` dibaca sekali per daemon, jadi mengubahnya butuh `daemon stop` lalu start ulang.
- Daemon memegang control socket di `<root>/control.sock`. Seluruh path itu harus muat pada batas platform untuk unix socket (108 byte di Linux), jadi root dir yang terlalu dalam ditolak dengan `control socket path is too long for this platform`.
- File site dibaca berurutan nama, dan namanya adalah identitas yang dipakai `start`, `stop`, `restart`, dan `status`. Akhiran `.cfg` opsional di command line.
- Tidak ada satu pun file config yang membawa timeout, rate limit, aturan rewrite header, atau route per path. Itu bukan knob yang punya default, itu knob yang memang belum ada.
