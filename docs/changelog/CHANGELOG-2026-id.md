# CHANGELOG

<!--
IMPORTANT:
- Do not remove this
- Naming file is always based on year
- The latest is always on top, bottom next is previous change
- Format:
```
## MAJOR.MINOR.PATCH (YYYY-MM-DD)

__*Update:*__
- Foo
- Bar:
    - Baz
    ---

<br>

__*Fix:*__

- ISSUE_FIX_SHORT_NAME:
    - ISSUE_LINK
    - SHORT_SUMMARY
    - PROFILE_CONTRIBUTOR:
        - NAME_OR_USERNAME / PROFILE_LINK

<br>

## PREVIOUS_CHANGELOG
...
```
-->

<br>

## 0.4.0 (TBD)

__*Ditambahkan:*__
- Response cache awareness (opt-in, ADR-036):
    - Modul bersama baru `src/utils/response_cache.zig`: precomputed-response cache per-worker yang lock-free (structure-of-arrays slab, open addressing, lazy on-access TTL). Mati secara default, dipasang hanya di bawah `.EPOLL` (dispatch model lain membiarkannya tidak terpasang dan API menurun menjadi plain send).
    - Lima field config flat dengan nama yang identik di `Http1ServerConfig`, `HttpServerConfig`, dan `GrpcServerConfig`: `response_cache` (`bool`, default `false`), `cache_max_entries` (`u32`), `cache_max_value_bytes` (`u32`), `cache_ttl_ms` (`u32`), dan `cache_max_total_bytes` (`usize`).
    - `zix.Http`: `res.serveCached(req)` dan `res.sendCached(req, body, ttl)` mem-cache respons yang sudah di-serialize penuh, di-key pada method, path, dan query. `zix.Http1` tetap memakai `cacheLookup` / `cacheStore` / `writeWithCache`.
    - `zix.Grpc` (unary): `ctx.serveCached(content_type)` dan `ctx.sendCached(content_type, data, ttl)` mem-cache pesan respons, di-key pada path plus body request, di-frame ulang per stream sehingga HPACK dan stream id tetap benar.
    - Crossover terukur dekat 4 KiB: JSON berat ~32 KiB +34% throughput di c512, tanpa regresi di bawah ~2 KiB. Lihat ADR-036.
    ---
- WebSocket build-once broadcast fanout:
    - Baru `zix.Http1.WebSocket.broadcast(conns, opcode, payload)`: men-serialize frame sekali dan menulis byte yang sama ke setiap fd dalam room yang dikelola pemanggil, sehingga sebuah broadcast hanya berbiaya satu serialization tidak peduli jumlah member. Write yang gagal ke peer mati dilewati (engine EPOLL memanen fd itu pada event berikutnya), dan jalur payload besar membangun header sekali dan menulis payload tanpa salinan staging.
    - `zix.Http.WebSocket.RoomMap.broadcast` memakai ulang satu staging buffer untuk semua member alih-alih membuat ulang per koneksi (build once, fan out).
    ---
- Http epoll shared-nothing:
    - `zix.Http` `.EPOLL` ditulis ulang dari model terpusat (satu accept thread mendorong ke `ConnQueue` bersama, pool worker pop) menjadi arsitektur shared-nothing yang cocok dengan `zix.Http1`. Setiap worker mengikat `SO_REUSEPORT` listener tersendiri, membuat `epoll` instance tersendiri, dan menjalankan event loop level-triggered tersendiri. Kernel mendistribusikan koneksi baru ke worker tanpa antrian bersama, tanpa mutex, dan tanpa handoff fd.
    - `workers` (bukan `pool_size`) sekarang adalah jumlah worker EPOLL untuk `zix.Http`. `0` memilih cpu_count. `pool_size` diabaikan secara diam untuk `.EPOLL` (pemanggil yang menggunakan `.pool_size = N` dengan `.EPOLL` harus migrasi ke `.workers = N`).
    - Level-triggered `EPOLLIN` menggantikan `EPOLLONESHOT`. Tidak perlu re-arm eksplisit setelah setiap request: koneksi tetap terdaftar dan re-fires saat data baru tiba.
    - Throughput: 428k menjadi 451k req/s di c1000 (`wrk -c1000 -t4 -d10s`), mempersempit gap vs `zix.Http1` dari 11% menjadi 6,8%. Gap yang tersisa bersifat struktural (alokasi arena per request). Lihat ADR-034.
    ---
- Http1 EPOLL slab, RawFn, dan kontrol Date:
    - `zix.Http1` `.EPOLL` kini menyokong setiap koneksi terdaftar dengan slab buffer receive per-koneksi (`ConnTable`), berukuran `max_recv_buf`, sehingga sebuah koneksi mengakumulasi satu request penuh tanpa alokasi ulang per event.
    - Tipe handler baru `zix.Http1.RawFn` plus `zix.Http1.Server.initRaw`: handler raw menerima fd koneksi dan head yang sudah diparse serta memiliki kendali penuh atas wire, melewati jalur response terkelola (streaming, framing kustom).
    - Field config baru `send_date_header` (default `true` untuk kepatuhan RFC 7231). Set `false` untuk membuang header `Date` dan menghemat 37 byte per response pada jalur panas di mana klien tidak membutuhkannya.
    - `buildSimpleHeaderInto` menulis status line dan header ke sink milik pemanggil, jalur cepat untuk penulis slab.
    ---
- Optimasi WebSocket:
    - Unmask SIMD: `parseFrame` pada engine WebSocket `zix.Http1` dan `zix.Http` kini meng-unmask payload klien dengan XOR `@Vector(16, u8)` selebar 16 byte terhadap mask 4 byte yang direplikasi, dengan ekor skalar untuk sisanya. Menggantikan loop per-byte `i % 4`.
    - Field config baru `ws_recv_buf` pada `Http1ServerConfig` (default `0`, jatuh ke `max_recv_buf`). Set lebih besar dari `max_recv_buf` untuk memberi koneksi WebSocket EPOLL ruang lebih mengakumulasi frame pipelined sebelum compact dan re-read.
    - Pembacaan WebSocket EPOLL `zix.Http1` kini menguras hingga `EAGAIN` per wakeup (baca semua frame tersedia dalam satu event) dan menggabungkan write, alih-alih satu frame per wakeup.
    - WebSocket `zix.Http`: `buildHeader` (framing header-only ke buffer pemanggil), jalur broadcast `RoomMap` yang dibersihkan.
    ---
- Staging dan corking per-koneksi gRPC mux:
    - `GrpcMuxConn` kini memiliki `stage_buf` 64 KB (sebelumnya `ReplyStage.buf` inline 4096 byte). Satu panggilan streaming ~5000 pesan (~85 KB puncak) flush dalam dua write, dan ~100 reply unary konkuren (~6 KB) digabung menjadi satu write. `ReplyStage.buf` kini slice milik pemanggil. Jalur inline blocking tetap memakai backing stack 4096 byte.
    - Frame SETTINGS server dipra-komputasi sekali per koneksi: `buildSettingsFrame` mengisi blob 33 byte di `GrpcMuxConn.init`, dan handshake menambahkannya apa adanya alih-alih meng-encode ulang loop parameter pada setiap koneksi.
    - `TCP_CORK` membungkus handler streaming di `muxDispatch`: kernel menggabungkan beberapa flush stage perantara yang dihasilkan handler streaming menjadi lebih sedikit segmen TCP, lalu uncork saat kembali. Reply unary tidak terpengaruh (sudah single-write). No-op pada non-Linux.
    ---
- Timeout epoll dinamis (worker gRPC, TCP, FIX):
    - Loop worker EPOLL kini membalik timeout `epoll_wait` ke `0` setelah satu batch event aktif (busy-poll batch siap berikutnya) dan kembali ke `-1` (blok) saat sebuah wakeup mengembalikan nol event. Menukar spin ketat di bawah beban demi latensi lebih rendah antar batch beruntun tanpa membakar core saat idle.
    ---
- Pemecahan build:
    - `build.zig` dipecah menjadi sub-file terfokus yang diimpor oleh root: `zix-build-examples.zig`, `zix-build-tests.zig`, `zix-build-test_runner.zig`. Root `build.zig` menyusut dari ~682 baris ke wiring modul dan step. Tanpa perubahan perintah build.
    - File sumber root library diganti nama dari `src/zix.zig` menjadi `src/lib.zig` (mengikuti konvensi `lib.zig` Zig). Modul tetap terdaftar sebagai `b.addModule("zix", ...)`, sehingga API publik tidak berubah: pengguna tetap `@import("zix")` dan memakai `zix.Http`, `zix.Grpc`, dll.
    ---
- Init logging server terpadu dan ter-gate Debug:
    - Setiap server (`zix.Http`, `zix.Http1`, `zix.Http2`, `zix.Grpc`, `zix.Fix`, `zix.Tcp`, `zix.Udp`, `zix.Uds`) kini mengeluarkan baris lifecycle (listening, fallback EPOLL, error accept) melalui satu bentuk `logSystem` ter-gate: rute ke `config.logger` bila diset, selain itu `std.debug.print` hanya pada Debug build, diam pada release. Server release tanpa logger tidak mengeluarkan init noise.
    - Menghapus print mentah junk dan duplikat: `zix.Grpc` sebelumnya mencetak tiap baris listening mentah sekaligus me-log-nya; `zix.Http2`/`zix.Fix`/`zix.Tcp` mencetak baris lifecycle/fallback mentah tanpa syarat. Baris init `zix.Udp`/`zix.Uds` kini juga muncul pada Debug build tanpa logger (sebelumnya logger-only).
    - `zix.Channel.init` mendapat notice init khusus Debug (`zix channel: init <T> cap=<N>`), ditekan pada release dan di bawah test runner (`builtin.is_test`) untuk menghindari peracunan IPC test.
    - Menyusun ulang komentar `src/tcp/http1/server.zig` untuk membuang referensi benchmark eksternal yang usang.
    ---

<br>

__*Perbaikan:*__
- Write stream gRPC dan HTTP/2 di bawah EPOLL:
    - `fdWriteAll` (`src/tcp/http2/frame.zig`) kini menangani `EAGAIN` pada socket EPOLL non-blocking dengan buffer kirim penuh: ia poll fd hingga bisa ditulis lalu mengulang write, alih-alih memperlakukan write parsial sebagai broken pipe. Socket blocking tidak pernah masuk cabang ini. Memperbaiki reply streaming yang terpotong dan stream error semu di bawah konkurensi tinggi.

<br>

## 0.3.0 (2026-06-10)

__*Ditambahkan:*__
- Http1 router prefix param:
    - `zix.Http1.Router` mendapat jenis rute `.PREFIX` dan `.PARAM` (menambah `RouteKind` dan field `kind` pada `zix.Http1.Route`, default `.EXACT`), mencapai paritas dengan router `zix.Http` dan prioritas `exact > param > prefix` (ADR-004). Param path yang ditangkap dibaca dengan fungsi bebas baru `zix.Http1.pathParam(name)` (thread-local per-handler, karena handler Http1 tidak punya `Request`, lihat ADR-029), dibatasi 8 param per pencocokan.
    - Pass prefix kini menjaga byte batas di belakang `startsWith`. Perbaikan yang sama diterapkan ke router `zix.Http`, yang membaca satu byte melewati path permintaan yang lebih pendek dari prefix terdaftar (panic pada Debug/ReleaseSafe, pembacaan out-of-bounds yang tersamarkan pada ReleaseFast).
    - Kompatibel mundur: `.kind` default ke `.EXACT`, jadi tabel rute Http1 exact-only yang ada tidak berubah. `examples/http1_static.zig` kini merutekan `/secret` via rute `.PREFIX`. Lihat ADR-033.
    ---
- Epoll max events 512:
    - Batch epoll (jumlah event yang dikuras per `epoll_wait`) dinaikkan dari 256 ke 512 di seluruh server epoll native (`zix.Tcp`, `zix.Http`, `zix.Fix`, `zix.Grpc`, `zix.Http1`) dan diseragamkan menjadi satu konstanta file-level bernama dan terdokumentasi `EPOLL_MAX_EVENTS: usize = 512` per server. Campuran sebelumnya antara const `epoll_max_events` huruf kecil dan literal `256` inline dihapus.
    - 512 memungkinkan worker mengosongkan ready-fd set dalam satu syscall pada jumlah koneksi tinggi: worker dengan lebih dari 256 fd readable tidak lagi butuh `epoll_wait` kedua. Tidak ada perubahan API publik, konstanta ini adalah default internal yang disetel. Lihat ADR-032.
    ---
- Http config naming consistency:
    - Penggantian nama field `HttpServerConfig` demi konsistensi lintas API (nilai default tidak berubah): `max_kernel_backlog` menjadi `kernel_backlog` (kini menyamai `Tcp`, `Fix`, `Http1`, `http2`, dan `Grpc` yang sudah memakai nama tanpa awalan), dan `max_client_request` menjadi `max_recv_buf` (menyamai `zix.Http1`).
    - Migrasi: ganti nama field di sisi pemanggil. `.max_kernel_backlog = N` menjadi `.kernel_backlog = N`, dan `.max_client_request = N` menjadi `.max_recv_buf = N`. `max_allocator_size` dan `max_client_response` tidak berubah (tidak ada padanannya di luar `zix.Http`).
    ---
- Http1 handler at init:
    - `zix.Http1.Server.init` kini menerima handler comptime sebagai argumen pertama dan menanamkannya ke tipe server, sehingga `run()` tidak lagi menerima argumen. Ini menyamai `zix.Http` dan `zix.Grpc` yang mendaftarkan route di init. Inti server tetap agnostik terhadap routing: handler boleh berupa `Router(routes).dispatch`, `HandlerFn` biasa, atau rantai middleware.
    - Migrasi: `Server.init(.{ ... })` lalu `server.run(Routes.dispatch)` menjadi `Server.init(Routes.dispatch, .{ ... })` lalu `server.run()`.
    ---
- Grpc epoll multiplexed:
    - `.EPOLL` pada `zix.Grpc` ditulis ulang dari pool blocking thread-per-koneksi menjadi event loop multiplex shared-nothing. Tiap worker memiliki listener `SO_REUSEPORT` privat, instance epoll sendiri, dan tabel koneksi privat ber-indeks fd, kernel menyeimbangkan koneksi antar worker. Satu worker menjalankan banyak koneksi non-blocking melalui state machine HTTP/2 resumable (`GrpcMuxConn` / `grpcMuxOnReadable`), sehingga konkurensi dibatasi jumlah koneksi, bukan jumlah thread.
    - Setiap route, termasuk server-streaming, di-dispatch inline pada worker di bawah `.EPOLL` (tanpa thread per stream, tanpa write mutex koneksi). Handler streaming berjalan di event loop dan harus terbatas, pakai `.ASYNC` untuk stream tak terbatas. Jalur blocking `serveGrpcConn` tidak berubah untuk `.ASYNC` / `.POOL` / `.MIXED`.
    - `pool_size` kini adalah jumlah worker multiplex untuk `.EPOLL` (0 = jumlah cpu), bukan ukuran pool blocking. Lihat ADR-031.
    ---
- Grpc unary hotpath:
    - Reply unary dan streaming (HEADERS awal, tiap DATA, trailer, dan frame kontrol) digabung menjadi satu `write()` per event readable melalui cork `ReplyStage` per koneksi.
    - `SETTINGS_INITIAL_WINDOW_SIZE` dinaikkan ke 16 MB dengan bump window koneksi sekali, sehingga body request kecil tidak lagi memicu `WINDOW_UPDATE` per-DATA, window koneksi di-replenish secara bulk hanya melewati threshold.
    - Pembacaan frame ter-buffer (pasangan HEADERS plus DATA berbiaya satu `read()`), dan `body` / `header_scratch` per stream dipindah ke slice backing per koneksi berukuran `max_body` / `max_header_scratch` alih-alih array inline tetap.
    - Blok header reply yang konstan (`:status 200` + `content-type: application/grpc+proto`, dan trailer `grpc-status: 0`) dienkode HPACK sekali di comptime dan di-memcpy pada jalur panas. `HpackEncoder.writeString` kini menandai hasil Huffman sebagai `?usize` agar encoder berjalan di comptime. Content-type / status lain memakai encoder dinamis.
    - Efek gabungan: unary ~110k ke ~420k req/s pada 256 koneksi, streaming ~2.6k ke ~28k panggilan/s. Lihat ADR-031.
    ---
- Http1 logger field:
    - `Http1ServerConfig.logger: ?*Logger` ditambahkan. Server merutekan baris siklus hidup (listening, fallback EPOLL) melaluinya.
    - Logging akses per-request bersifat handler-side: handler Http1 menulis ke fd dan mengembalikan void, sehingga server tidak dapat mengamati status atau byte respons. Handler memanggil `logger.access()` sendiri (contoh memakai global modul).
    ---
- Http1 examples parity and completion:
    - 9 contoh `http1_*` yang ada disetarakan secara presentasi dengan `http_*` (blok konstanta yang dapat disetel penuh, scaffolding logger berkomentar pada keluarga basic).
    - 6 contoh baru melengkapi set (total 15): `http1_manual_concurrent`, `http1_sse`, `http1_xtra_headers`, `http1_client`, `http1_timeout_resp`, `http1_websocket`.
    ---
- Http1 handler timeout:
    - `Http1ServerConfig.handler_timeout_ms` plus `zix.Http1.setTimeout()` dan `zix.Http1.isExpired()`. Server memasang deadline thread-local sebelum setiap dispatch di keempat model.
    - `statusPhrase` mendapat `408 Request Timeout`. Lihat ADR-029.
    ---
- Http1 websocket:
    - Modul baru `zix.Http1.WebSocket`: codec frame RFC 6455 (`parseFrame` / `buildFrame` / `buildHeader` / `acceptKey`) dan `upgrade()` melalui I/O fd mentah.
    - Loop frame dimiliki engine di bawah `.EPOLL`: handler memanggil `WebSocket.serve(fd, key, on_frame)` untuk menyerahkan koneksi ke loop epoll. Engine meng-echo via `on_frame` per event readable (`fn(fd, opcode, payload) void`), membalas ping dengan pong dan meng-echo close secara otomatis. Tidak ada worker yang terparkir per koneksi.
    - `WebSocket.send` menggabungkan setiap frame yang dihasilkan dalam satu event readable ke satu `write()`, sehingga burst pipelined berbiaya satu syscall, bukan satu per frame.
    - `zix.Http1.WsFrameFn` diekspor. WebSocket milik engine hanya untuk `.EPOLL`: di bawah `.ASYNC` / `.POOL` handoff dibersihkan dan koneksi berakhir. Lihat ADR-030.
    ---
- Http1 large body drain:
    - Di bawah `.EPOLL`, body request yang lebih besar dari `max_recv_buf` tidak lagi mengembalikan `431`. Engine memanggil handler dengan body kosong (endpoint body-besar memakai nilai Content-Length), lalu membaca dan membuang sisa byte body lintas event sehingga koneksi tetap bisa dipakai untuk keep-alive. Body yang muat di buffer tidak berubah.
    ---
- Http client version selector:
    - `zix.Http.Client` mendapat field konfigurasi `version` (`zix.Http.ClientVersion`: `HTTP_1`, `HTTP_2`, `HTTP_3`, default `HTTP_1`).
    - `HTTP_2` dan `HTTP_3` mengembalikan `error.UnsupportedVersion` sampai backend tersedia. Lihat ADR-028.
    ---
- Http1 writesimple hotpath:
    - `zix.Http1.writeSimple` kini membangun header respons dengan encoder byte langsung (`buildSimpleHeader` via `appendStatusCode` / `appendDec` / `appendBytes`), menggantikan `std.fmt.bufPrint`.
    - Body kecil (hingga 3840 byte) disalin bersama header ke satu buffer stack kontigu dan dikirim dengan satu `write()`. Body di atas 3840 byte memakai fallback `writev` inline untuk menghindari penyalinan payload besar.
    - `cachedDate()` memanggil `clock_gettime` hanya setiap 256 request via penghitung tick thread-local, bukan per-request.
    - Terukur ~450k ke ~612k req/s pada c128 dibanding jalur `writev`-saja sebelumnya. Lihat ADR-026.
    ---
- Response header default minimal:
    - Default `HttpServerConfig.max_response_headers` diturunkan dari `.COMMON` (32) ke `.MINIMAL` (16).
    - `zix.Http1`: cap `MAX_HEADERS` 32 ke 16, field baru `Http1ServerConfig.max_headers: u8 = 16`.
    - Perubahan perilaku: handler yang menambahkan 17 hingga 32 header kustom kini mengenai `error.TooManyHeaders` sampai tier dinaikkan. Lihat ADR-027.
    ---

<br>

__*Diperbaiki:*__
- Http1 websocket epoll echo:
    - Echo WebSocket `zix.Http1` tidak bekerja di bawah `.EPOLL`: handshake berhasil tetapi tidak ada frame yang ter-echo. Loop `read()` blocking pada handler langsung mengembalikan `EAGAIN` pada socket non-blocking milik engine. Loop frame milik engine (`WebSocket.serve`, lihat ADR-030) menggantikan pola itu. Contoh `http1_websocket` kini memakai `.EPOLL`.

<br>

## 0.2.2 (2026-06-06)

__*Ditambahkan:*__
- Grpc unary inline dispatch:
    - Route unary (`Route.is_server_streaming = false`, default) kini di-dispatch secara sinkron pada connection thread. Tidak ada alokasi Task per panggilan, tidak ada salinan `header_scratch` 4 KB, tidak ada enqueue `io.async`, tidak ada acquire/release ConnMutex.
    - Route server-streaming memerlukan `is_server_streaming = true` pada entri `Route` untuk menggunakan dispatch thread-per-stream.
    - Field baru pada `zix.Grpc.Route`: `is_server_streaming: bool = false`.
    ---
- Grpc bench fixtures:
    - Menambahkan `examples/grpc_hello_req.bin` dan `examples/grpc_location_req.bin`: fixture biner berframing gRPC untuk benchmarking dengan h2load dan ghz.
    - Perintah benchmark h2load dan ghz ditambahkan ke seluruh 8 contoh server gRPC.
    ---

<br>

__*Diperbaiki:*__
- n/a

<br>

## 0.2.1 (2026-06-05)

__*Ditambahkan:*__
- n/a

<br>

__*Diperbaiki:*__
- Grpc content type:
    - https://codeberg.org/prothegee/zix/issues/67
    - `sendGrpcError` tidak menyertakan `content-type` pada frame HEADERS trailers-only. Client gRPC menolak respons dengan error content-type. Semua frame HEADERS yang dikirim server kini menyertakan `content-type: application/grpc+proto` sesuai spesifikasi gRPC.

<br>

- Grpc concurrent stream:
    - https://codeberg.org/prothegee/zix/issues/68
    - RPC server-streaming bersamaan pada koneksi h2 yang sama dapat mengalami deadlock saat buffer kirim TCP penuh di bawah backpressure. Setiap stream kini di-dispatch pada thread tersendiri yang berbagi write mutex tingkat koneksi, mencegah interleaving frame.

<br>

## 0.2.0 (2026-06-02)

__*Ditambahkan:*__
- Menambahkan TCP raw
- Menambahkan gRPC h2c
- Menambahkan FIX (over TCP)
- Menambahkan EPOLL ke dispatch model
- ASYNC adalah default dispatch model
- Handler/router (Http & gRPC) kini menggunakan comptime
- Dokumentasi dibagi menjadi Bahasa Inggris (en) dan Bahasa Indonesia (id)

<br>

__*Diperbaiki:*__
- n/a

<br>

## 0.1.0 (2026-05-16)

__*Ditambahkan:*__
- Rilis awal, jaringan library Zig 0.16.x (minimum_zig_version: 0.16.0-dev.2974+83c7aba12):
    - HTTP:
        - Server dengan tiga dispatch model: POOL, ASYNC, MIXED
        - Router dengan pencocokan exact, param, dan prefix
        - Middleware (comptime, zero-allocation)
        - WebSocket upgrade
        - Server-Sent Events (SSE)
        - Upload multipart
        - Penyajian berkas statis
        - HTTP client
        ---
    - UDP:
        - Server dan client generik atas tipe paket yang didefinisikan pengguna
        - Snapshot peer broadcast per paket
        ---
    - Unix Domain Sockets (UDS):
        - Server dan client dengan framing
        ---
    - Channel:
        - Pengiriman pesan ring buffer in-process, generik atas tipe elemen
        ---
    - Utils:
        - Helper penyimpanan berkas, resolusi tipe MIME
        ---

<br>

__*Diperbaiki:*__
- n/a

<br>

---

###### end of changelog
