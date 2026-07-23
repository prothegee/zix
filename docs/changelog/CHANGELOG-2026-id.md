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

- Qux:
    - Quux

<br>

__*Fix:*__

- ISSUE_FIX_SHORT_NAME:
    - ISSUE_LINK
    - SHORT_SUMMARY
    - PROFILE_CONTRIBUTOR:
        - NAME_OR_USERNAME / PROFILE_LINK

    ---

- SAME_AS_ABOVE:
    - BUT JUST ONE

<br>

## PREVIOUS_CHANGELOG
...
```
-->

<br>

## MAJOR.MINOR.x (TBA)

__*Update:*__

- Breaking: handler hot path `zix.Http1` menjadi trio Request/Response/Context (ADR-062):
    - `HandlerFn` kini `fn(req: *Request, res: *Response, ctx: *Context) anyerror!void`, menggantikan raw `fn(head: *const ParsedHead, body: []const u8, fd: fd_t) void`, menyamai bentuk `zix.Http`. `Request` adalah view zero-copy, `Response` mendelegasikan ke fd writer yang sudah ada dan byte-identical, `Context` membawa `io`, arena per-request, fd, dan hook deadline. `core.invokeHandler` membangun trio per request dan menulis tepat satu 500 saat handler error tanpa sudah mengirim response, di semua dispatch model termasuk jalur buffer TLS.
    - Penamaan `send*` kanonis di kedua engine: `zix.Http1` mengganti nama `json` / `text` / `raw` menjadi `sendJson` / `sendText` / `sendRaw` dan memperoleh `sendNoContent`, `sendFromCache`, `sendCached`, `sendNegotiated`, `sendStream`, `setKeepAlive`, `addHeader`. `zix.Http` mengganti nama `noContent` / `serveCached` / `stream` menjadi `sendNoContent` / `sendFromCache` / `sendStream` dan memperoleh `sendText`, `sendRaw`. `Request.param` menjadi `pathParam` pada `zix.Http1`, kedua engine memperoleh `queryParams`, `pathSegments`, `body()`, `fromRaw`, `keepAlive`. Permukaan trio bertipe di kedua engine: `setStatus(Status.Code)`, `setContentType(Content.Type)`, `req.method()` mengembalikan `Method.Code`.
    - `initRaw` milik `zix.Http1` dan hook `RawFn` dihapus, `Server.init(handler, config)` adalah satu-satunya pintu. `middleware.zig` dihapus dari `zix.Http` (komposisi wrapper comptime, `examples/http_middleware.zig` / `examples/http1_middleware.zig`, adalah idiom middleware di kedua engine sekarang).
    - Migrasi: ganti nama call site `json` / `text` / `raw` / `noContent` / `serveCached` / `stream` / `param` sesuai pemetaan di atas, ganti handler raw `fn(head, body, fd) void` dengan signature trio, dan hapus pemakaian `initRaw` apa pun. Semua handler in-src, tiap `examples/http1_*.zig` dan `examples/tls/tls_http1_*.zig`, serta test integrasi http1 sudah dimigrasikan sebagai bagian dari perubahan ini.

    ---

- Encoder gzip cepat untuk response dinamis (`compression.flate_fast`):
    - Encoder gzip in-tree (LZ greedy di atas hash table single-probe, coding fixed-Huffman, tabel kode bit-reversed yang di-precompute, akumulator 64-bit) untuk body di bawah 64 KiB, beberapa kali lebih cepat dari matcher std dengan rasio mendekati level tercepat std. Output adalah gzip RFC 1952 standar, teruji round-trip terhadap decoder std termasuk input kosong, incompressible, seragam, dan mendekati cap.
    - `sendGzipFD` `zix.Http1` otomatis memakai jalur ini untuk body di dalam cap, body lebih besar tetap lewat jalur `std.compress.flate`. Tidak ada perubahan API.
    - Pada isolate bench lokal, cell json gzip dinamis naik dari ~35K menjadi 154-173K pada 512/4096/16384 koneksi.

    ---

- Latency jalur kirim `zix.Http1` dan render di tempat:
    - Intra-batch submit `.URING`: saat men-dispatch batch completion yang dalam (128 completion atau lebih), SQE send yang ter-stage didorong ke kernel tiap 16 completion alih-alih hanya setelah seluruh batch, sehingga response awal langsung berangkat tanpa menunggu dispatch semua request setelahnya. Batch dangkal melewati stride ini. Pada isolate bench lokal ini mengangkat cell json render-dinamis 4-5% dan cell pipelined serta baseline 4096-koneksi 2-5%, dengan cell 512-koneksi tidak berubah.
    - Wakeup coalescing adaptif `.URING`: loop worker yang panas menunggu hingga 32 completion per enter (wait_nr = setengah reap terakhir, turun ke 1 saat beban mereda) dengan SQE timeout 20 mikrodetik sebagai penjaga stall, sehingga kedatangan yang tersebar berhenti membangunkan worker sekali per completion. Loop yang dingin berperilaku persis seperti sebelumnya.
    - Jalur cepat accept `.URING`: SQE recv koneksi yang baru di-accept langsung di-submit di dalam handler accept alih-alih setelah sisa batch completion di-dispatch, memangkas accept-to-first-byte di bawah churn koneksi (p99 api-4 turun sekitar 30% lokal).
    - `responseReserve(fd, max_body)` / `responseCommit(fd, status, content_type, body_len)`: handler yang membangun body secara dinamis bisa me-render langsung ke buffer response sink, jadi byte body ditulis tepat sekali (tanpa buffer scratch di handler, tanpa salinan staging) dan engine membangun header sederhana tepat di depannya. Reserve yang ditolak (batch pipelined sedang berjalan, region tidak muat) tidak men-stage apa pun dan handler jatuh kembali ke `writeAllFD`. Berlaku di `.URING`, `.EPOLL`, dan jalur capture TLS.
    - Short send `.URING`: jendela ter-stage kini maju di tempat (`staged_off`) alih-alih menggeser sisa ke depan buffer.

    ---

- Lane DB engine-worker: `zix.Http1` `.URING` mendapat external fd watch dan `postgrez` mendapat `dispatch.Line`:
    - `zix.Http1.uringWatchFd(fd)` meng-arm watch readable multishot untuk fd asing (socket driver) di ring milik worker, dan `zix.Http1.setExternalHandler(cb)` mendaftarkan callback per-worker yang berjalan di thread worker. Engine mempertahankan watch (multishot yang lapsed di-re-arm selama fd hidup), dan submission queue yang penuh mem-park arm ke process queue, sehingga watch tidak pernah hilang selama parking punya ruang. Engine `.URING` lain mengabaikan op completion baru ini.
    - `postgrez.dispatch.Line`: pipeline satu-koneksi tanpa reactor (open, submit, flush, pump, pending) untuk pemanggil yang memiliki event loop sendiri. submit men-stage, pemanggil flush sekali per batch (pump juga flush) sehingga banyak request keluar dalam satu write, pump membaca dan mengantar reply ter-frame sesuai urutan submit, dan peer yang tertutup muncul sebagai `error.ConnectionClosed`. `Transport` tidak berubah.
    - Bersama-sama, worker server bisa memiliki koneksi database pipelined di ring-nya sendiri, sehingga reply di-decode, dirender, dan ditulis di core yang memiliki socket klien, tanpa handoff antar thread.

    ---

- `zix.Http1` `.URING`: body request oversized (lebih besar dari receive buffer) kini di-drain sebelum handler-nya berjalan, dan byte yang diterima dihitung lalu diekspos sebagai `Request.bodyReceived()`:
    - Sebelumnya handler berjalan lebih dulu dengan slice body kosong (response bisa keluar sebelum body selesai tiba) dan sisa yang di-drain dibuang tanpa dihitung, sehingga `head.content_length` adalah satu-satunya ukuran yang bisa dilaporkan handler. Engine kini menghitung setiap byte yang di-drain, menunda handler sampai drain selesai, dan `req.bodyReceived()` mengembalikan total terhitung. Pada semua dispatch model nilainya sama dengan `body().len` saat body muat di buffer. Request body kecil menempuh jalur yang identik seperti sebelumnya, `.EPOLL` dan model thread mempertahankan urutan lamanya.

    ---

- Dua driver database internal, `postgrez` (PostgreSQL) dan `rediz` (Redis), murni Zig std saja, tanpa dependency C:
    - `postgrez`: wire protocol 3.2 dengan fallback 3.0 di tempat (PostgreSQL 15 minimum), encoding nilai binary-first dengan fallback text per parameter, prepared statement, query pipelining, `Executor` batching, `Pool` thread-safe, auth SCRAM dan SCRAM-PLUS (channel binding) serta cleartext, TLS 1.3, streaming COPY, LISTEN dan NOTIFY.
    - `rediz`: RESP3 lewat HELLO dengan fallback RESP2 di tempat (Redis 7 dan 8), helper nilai bertipe plus jalan pintas raw command, command pipelining dan jalur deferred write-behind, `Pool` thread-safe, TLS 1.3.
    - Kedua driver berbagi config `dispatch_model`: `.ASYNC` (jalur pooled / executor, default) atau `.EPOLL` / `.URING` (`Transport`, dispatch termultipleks satu-thread yang mem-pipeline banyak request per koneksi, cleartext saja).
    - Dokumentasi: `docs/driver/postgrez` dan `docs/driver/rediz` (README, HLD, LLD, referensi config, Inggris dan Indonesia).

    ---

- `prometheuz`, driver internal ketiga (Prometheus dan node-exporter), murni Zig std saja, tanpa dependency C:
    - Parser Prometheus text exposition format 0.0.4 (scrape), `Scraper` poller latar belakang, push `remote_write` (protobuf plus snappy), query PromQL instant dan ranged, dan registry metrik yang ditulis aplikasi (`Counter`, `Gauge`) untuk nilai yang tidak pernah berasal dari scrape.
    - Client HTTP/1.1 minimal milik sendiri, cleartext saja: berbeda dengan `postgrez`/`rediz` tidak ada transport pooled atau multipleks, GET/POST dengan body response `Content-Length` atau chunked adalah satu-satunya transport yang dibutuhkan driver ini.
    - Dokumentasi: `docs/driver/prometheuz` (README, HLD, LLD, referensi config, Inggris dan Indonesia).

<br>

__*Fix:*__

- Penyambungan `send_timeout_ms` client (`zix.Uds`, `zix.Tcp`, `zix.Fix`):
    - Field config `send_timeout_ms` sisi client diterima tetapi tidak pernah ditegakkan (helper peninggalan yang menyetel `SO_SNDTIMEO` ada tetapi tidak pernah dipanggil). `UdsClient.sendMsg`, `TcpClient.sendMsg`, dan `FixClient.sendMessage` kini melakukan poll pada socket untuk kesiapan tulis sebelum mengirim dan mengembalikan `error.SendTimeout` saat expired, pendekatan yang sama yang sudah dipakai untuk `recv_timeout_ms` (`SO_RCVTIMEO` tidak dipakai: `std.Io.Threaded` panic pada `EAGAIN`). `FixClient` juga memperoleh field `send_timeout_ms` itu sendiri, sebelumnya tidak dibawa sama sekali dari config-nya.

    ---

- Koreksi dokumentasi di `docs/` dan README:
    - `zix.Http`: dokumentasi mengklaim tidak ada dukungan TLS ("proxy-terminated by design"), TLS sudah tersedia sejak ADR-053.
    - `zix.Grpc`: dokumentasi tidak menyebutkan response cache (ADR-036) maupun dual listener TLS (ADR-060), keduanya sudah diimplementasikan.
    - `zix.Uds`: dokumentasi (dan perbandingan pada dokumentasi `zix.Tcp` sendiri, serta ADR-022) mengklaim frame UDS memakai little-endian, padahal memakai big-endian, sama seperti TCP, dan selalu begitu (ADR-010).
    - `zix.Fix`: dokumentasi dan sebuah contoh terpakai memakai nama field `connection_timeout_ms`, field sebenarnya adalah `conn_timeout_ms`.
    - `zix.Tcp`: dokumentasi memakai `max_msg_len`, field sebenarnya adalah `max_recv_buf`. `docs/lld-tcp-en/id.md` juga sebelumnya tidak memuat model dispatch `.EPOLL` / `.URING` sama sekali.

<br>

## 0.5.0-rc1 (2026-07-15)

__*Update:*__
- Zig 0.17 (eksperimental) support: satu source tree build di Zig 0.16.x dan 0.17.x, sedikit divergensi API `std.Io` di-gate di balik cek comptime `ZIG_SEMVER` (ADR-044).

- Breaking: `dispatch_model` kini field config wajib tanpa default. Setiap config server (`Http1ServerConfig`, `HttpServerConfig`, `Http2ServerConfig`, `GrpcServerConfig`, `FixServerConfig`, `TcpServerConfig`, `UdpServerConfig`, `Http3ServerConfig`) melepas default `.ASYNC`, jadi pemanggil harus menyetel `dispatch_model` secara eksplisit.

- Breaking: `Server.init` seragam dan infallible di seluruh engine keluarga HTTP (ADR-014):
    - `zix.Http`, `zix.Http2`, `zix.Grpc`, dan `zix.Http3` kini menyimpan config saat `init` dan tidak bisa gagal, dengan validasi port dan TLS dipindah ke `run()` (`error.PortNotConfigured`, `error.TlsRequired`). Ini mengikuti `zix.Http1`, jadi setiap engine dikonstruksi dengan cara yang sama: `init` membaked comptime handler atau tabel route ke dalam tipe, `run()` memvalidasi lalu melayani.
    - `zix.Http3` mendapat struct `Server`: `zix.Http3.Server.init(handler, config)` menggantikan entry point fungsi-generik `zix.Http3.Http3(handler)` (generic kini menjadi `Http3ServerImpl` privat).
    - `zix.Http.Server.init` melepas argumen comptime `stack_threshold` di depan, jadi pemanggilannya menjadi `Server.init(routes, config)`. Buffer baca per-koneksi tinggal di stack thread koneksi ketika `max_recv_buf` muat pada konstanta internal `stack_read_buf_max` (4096) dan alokasi heap jika tidak, dengan `max_recv_buf` (config) sebagai knob tuning. Field `HttpServerConfig` `max_client_response` yang tidak terpakai dihapus.
    - Migrasi: `zix.Http.Server.init(4096, &routes, cfg)` menjadi `zix.Http.Server.init(&routes, cfg)`. `const S = zix.Http3.Http3(handler); var s = try S.init(cfg)` menjadi `var s = zix.Http3.Server.init(handler, cfg)`. Lepas `try` pada init `zix.Http2` / `zix.Grpc` / `zix.Http` (port tidak valid kini muncul dari `run()`). Hapus setiap `.max_client_response = N` dari `HttpServerConfig`.

- Jalur serve https `zix.Http` (ADR-053):
    - `zix.Http` memperoleh TLS opt-in (`config.tls`), engine HTTP ketiga yang melayani https/1.1. Setiap koneksi menjalankan handshake (TLS 1.3, dengan fallback 1.2 ECDSA) dan loop request keep-alive di worker thread-nya sendiri, response router ditangkap lewat response sink milik engine lalu dienkripsi, jadi handler menulis Response biasa dan jalur cleartext tidak menambah biaya hot-path. Response ter-buffer secara default (WebSocket adalah follow-up, SSE / streaming melalui TLS mendarat di ADR-054). Example baru `examples/tls/tls_http_basic.zig` (port 9071).
    - Worker TLS Http2 dan gRPC yang multipleks kini pin per-core dan menghitung worker count dari cpuset yang tersedia (paritas ADR-052 dengan `tls_mux` Http1), jadi cpuset yang di-pin cgroup tidak lagi meng-oversubscribe satu core di bawah handshake storm.

    ---

- SSE / streaming melalui TLS (ADR-054):
    - `zix.Http` dan `zix.Http1` melayani Server-Sent Events melalui TLS di jalur thread-per-koneksi (`.ASYNC` / `.POOL` / `.MIXED`). Stream sink per-koneksi (`TlsStreamSink`, type-erased atas koneksi TLS 1.3 / 1.2 hidup) mengenkripsi satu TLS record per write dan mengirimnya seketika, menggantikan buffered capture hanya ketika handler memilih streaming. `fdWriteAll` memeriksa buffered sink dulu, lalu stream sink, jadi response normal menjaga jalur cepat ter-buffer tetap utuh.
    - `zix.Http` memakai ulang `res.stream()` (tanpa simbol publik baru, kini menjaga stream sink aktif melalui TLS). `zix.Http1` memperoleh `beginStream()`, no-op di cleartext, jadi satu fd-handler melayani cleartext dan TLS. Jalur `tls_mux` multipleks (`.EPOLL` / `.URING`) tetap request / response saja (kemudian dibuka oleh ADR-060 di bawah).
    - Example baru `examples/tls/tls_http_sse.zig` (port 9072) dan `examples/tls/tls_http1_sse.zig` (port 9073), dengan runner step `test-runner-tls-http-sse` / `test-runner-tls-http1-sse` (client `zix.Tls` native, tanpa curl), dilipat ke `test-runner-all`. `examples/http1_sse.zig` kini memanggil `beginStream()`.

    ---

- WebSocket melalui TLS (ADR-055):
    - `zix.Http` dan `zix.Http1` melayani WebSocket melalui TLS (wss) di jalur thread-per-koneksi (`.ASYNC` / `.POOL` / `.MIXED`). Handler memanggil `WebSocket.serveTls(fd, key, on_frame)`: ia mengirim `101` terenkripsi lewat ADR-054 stream sink dan mendaftarkan handoff, lalu loop serve https menjalankan inline frame loop atas TLS session (dekripsi record, parse frame, `on_frame` untuk text / binary, ping di-auto-pong, close di-auto-echo). Frame keluar memakai ulang ADR-054 stream sink, jadi tiap pump pass mengenkripsi frame ter-coalesce sebagai satu record.
    - `zix.Http1` memakai ulang frame codec-nya (`parseFrame` / `pump` / `send`) dan handoff `requestWebSocket` / `takeWebSocket`. `zix.Http` memperoleh bagian engine-driven yang cocok (`WsFrameFn`, `send`, `pump`, handoff, `upgradeFd`), jadi `on_frame(fd, opcode, payload)` dan `serveTls` yang sama jalan di kedua engine. Rooms / broadcast tidak dilayani melalui TLS (enkripsi per-session), jadi wss bersifat per-koneksi / echo. Jalur `tls_mux` multipleks tetap request / response saja (kemudian dibuka untuk `zix.Http1` oleh ADR-060 di bawah).
    - Example baru `examples/tls/tls_http1_ws.zig` (port 9074) dan `examples/tls/tls_http_ws.zig` (port 9075), dengan runner step `test-runner-tls-http1-ws` / `test-runner-tls-http-ws` (client `zix.Tls` native, tanpa websocat), dilipat ke `test-runner-all`.

    ---

- TLS dual listener (ADR-060):
    - Field config flat baru `tls_port: u16 = 0` pada `Http1ServerConfig`, `HttpServerConfig`, `Http2ServerConfig`, dan `GrpcServerConfig`: dengan `tls` diisi dan `tls_port` non-zero, SATU server melayani cleartext di `port` DAN TLS di `tls_port` dari worker fleet yang sama, menggantikan setup dua-peluncuran yang menduplikasi worker, tabel fd, dan cache. `tls_port == port` ditolak di `run()` (`error.TlsPortConflict`). Default tidak berubah: `tls` null tetap cleartext-only, `tls` diisi dengan `tls_port` 0 tetap TLS-only.
    - Transport TLS per-koneksi dibagi di `src/multiplexers/tls_conn.zig` (session + staging backpressure + tabel slot fd), menggantikan empat salinan nyaris identik di file `tls_mux.zig`. Loop engine tetap per-engine (ADR-050).
    - Di bawah `.URING` sisi TLS berjalan di ring (op user_data `tls_accept` / `tls_recv` / `tls_send`), tanpa fleet epoll tersembunyi. Di bawah `.EPOLL` listener TLS bergabung ke epoll yang sama, ditandai di data word event. Thread model melayani sisi TLS dengan satu accept thread tambahan.
    - Loop mux `zix.Http1` kini menampung WebSocket dan SSE melalui TLS (encrypt-on-write lewat stream sink per-koneksi), dan loop mux `zix.Http` menampung `res.stream()` melalui TLS, membuka batasan thread-path ADR-054 / ADR-055 di sana.
    - Contoh baru `examples/tls/tls_http1_dual.zig` (port 9076 cleartext / 9077 TLS), check runner `tls-http1-dual`, dan integration test dual-listener per-engine.

    ---

- Dispatch `.EPOLL` / `.URING` native untuk `zix.Http2` (ADR-043):
    - `zix.Http2` h2c memperoleh loop multiplexed shared-nothing yang sebelumnya dilipat ke `.POOL`. Sebuah mux state machine h2 yang resumable (`src/tcp/http2/mux.zig`, satu `MuxConn` per fd, akumulator baca bertahan lintas event readable) digerakkan oleh `dispatch/epoll.zig` (satu listener `SO_REUSEPORT` plus epoll plus slab `ConnTable` per worker) dan `dispatch/uring.zig` (satu ring io_uring per worker, multishot accept, `user_data` ber-tag generation). Di ring, worker memegang accept plus recv dan handler menulis reply langsung ke fd non-blocking (tanpa cork per-stream). `.URING` memprobe ring saat startup dan jatuh ke `.EPOLL` ketika io_uring tidak tersedia, keduanya dilipat ke `.POOL` di luar Linux.
    - `zix.Http2.Router` memperoleh query-stripping dan `.kind = .PREFIX`, meniru `zix.Http1`: query di-strip sebelum matching, route EXACT memakai `StaticStringMap`, PREFIX mencocokkan prefix terdaftar terpanjang pada batas segment. `RouteKind` diekspor.
    - Keluarga example baru `examples/http2_basic_{1_async,2_pool,3_mixed,4_epoll,5_uring}.zig` (port 9065-9069) dengan step runner `test-runner-http2-{async,pool,mixed,epoll,uring}`, dilipat ke `test-runner-all`.

    ---

- Optimasi memori dan throughput `zix.Http2` (pool slot-stream per-worker, ADR-058):
    - Pool slot stream per worker (`src/tcp/http2/mux.zig`): mux `.EPOLL` / `.URING` meminjam slot tiap stream (tabel header plus buffer body / scratch) dari free-list thread-local saat stream dibuka dan mengembalikannya saat ditutup, jadi memori stream residen mengikuti stream konkuren, bukan `connections * max_streams`. Tiap koneksi hanya menyimpan array pointer selebar `max_streams`, dan steady state tidak melakukan alokasi per-stream (buffer dipakai ulang lintas pinjaman). Pada 4096 koneksi ini memangkas memori baseline-h2c sekitar 6x sambil menaikkan throughput 8 sampai 20 persen, karena slot hot yang di-pool punya cache working set lebih rapat dibanding tabel per-koneksi lama yang sparse.
    - Cache prefix header respons HPACK (`src/tcp/http2/hpack.zig`, `respHeaderBlock`): blok `[:status, content-type, content-encoding]` untuk triple yang hot di-encode sekali dan dipakai ulang byte-identik lintas koneksi (encoder stateless, tidak pernah dynamic table), hanya `content-length` yang di-encode per balasan. Menaikkan cell body-kecil 18 sampai 26 persen pada CPU lebih rendah.
    - Seal-in-place pada jalur record TLS 1.3 (`src/tls/record.zig` `protect2`, `src/tls/connection.zig` `writeAppData2`, `src/tcp/tls/tls_session.zig` `encrypt2`): gather-encrypt yang menyegel dua slice plaintext ke satu record tanpa copy staging.
    - Default config: `Http2ServerConfig` / `ServeOpts` default `max_streams` 16 ke 128 (concurrency yang diiklankan, murah sekarang slot di-pool) dan `max_body` 64 KiB ke 16 KiB (body request yang di-buffer per stream, body lebih besar di-shed dari stream dengan 413). `max_header_scratch` tetap 4 KiB.

- Optimasi memori dan throughput `zix.Grpc` (pool slot-stream per-worker, ADR-058):
    - Pool slot-stream per-worker (`src/tcp/http2/grpc/core.zig`): mux gRPC `.EPOLL` / `.URING` meminjam slot tiap stream (tabel header plus buffer body / scratch) dari free-list thread-local saat stream dibuka dan mengembalikannya saat ditutup, sehingga memori stream residen mengikuti stream konkuren alih-alih `connections * max_streams`. Tiap koneksi hanya menyimpan array pointer selebar `max_streams`, dan steady state tidak melakukan alokasi per-stream (buffer dipakai ulang lintas pinjam). Pada 1024 koneksi ini memangkas memori unary-grpc sekitar 12x (916 ke 77 MiB) sambil menaikkan throughput 8 sampai 11 persen, hasil dua-sumbu yang sama seperti pool Http2. Path blocking `.ASYNC` / `.POOL` / `.MIXED` mempertahankan array per-koneksinya sendiri, tak berubah.
    - Default config: `GrpcServerConfig` / `GrpcServeOpts` default `max_streams` 16 ke 128 (concurrency yang diiklankan, murah sekarang slot di-pool) dan `max_body` 64 KiB ke 16 KiB (body request yang di-buffer per stream, body lebih besar di-shed dari stream dengan RESOURCE_EXHAUSTED). `max_header_scratch` tetap 4 KiB.

    ---

- gRPC over TLS dan terminator h2-over-TLS bersama:
    - `zix.Grpc` melayani TLS native (TLS 1.3, dengan fallback 1.2, ALPN h2) via `tls: ?*Tls.Context`, aditif di atas default h2c. Jalur TLS menggerakkan mux state machine gRPC resumable (`grpcMuxProcessRing`) langsung di atas record terdekripsi, engine single-owner yang sama dengan model cleartext `.EPOLL` / `.URING`, jadi tidak punya race write per-stream.
    - Terminator h2-over-TLS difaktorkan ke `src/tcp/tls/h2_terminator.zig` yang bersama dan engine-agnostic (handshake 1.3 / 1.2, ALPN h2). Ia menjalankan driver inline-mux dari pemanggil di atas record terdekripsi dan menyegel frame engine kembali ke record TLS lewat write hook thread-local, tanpa socketpair dan tanpa thread kedua. `tls_serve.zig` `zix.Http2` dan `zix.Grpc` adalah wrapper tipis yang menyuplai driver.
    - Dispatch TLS multipleks (ADR-052): untuk `.EPOLL` / `.URING`, satu worker epoll `SO_REUSEPORT` per core menterminasi TLS di tempat lewat session TLS 1.3 resumable (`src/tcp/tls/tls_session.zig`) dan memultipleks banyak koneksi per worker (`tls_mux.zig`), jadi Http2 https dan gRPC TLS tidak lagi men-spawn thread per koneksi di konkurensi tinggi. `.ASYNC` / `.POOL` / `.MIXED` tetap memakai terminator thread-per-koneksi, yang juga melayani fallback 1.2.
    - Docs `hld-grpc`, `hld-tls`, `lld-tls`, dan `hld-grpc-proxy` (en dan -id) diperbarui untuk gRPC TLS native.

    ---

- Response compression (gzip / deflate / brotli):
    - Negosiasi `Accept-Encoding` dengan gzip dan deflate. Codec bersama baru `src/utils/compression/flate.zig` (container-parameterized di atas `std.compress.flate`: gzip = RFC 1952, deflate = zlib-wrapped RFC 1950, bukan raw) plus facade `compression.zig` (negosiasi q-value, penanganan `q=0` dan wildcard, size floor, skip media-type yang sudah terkompresi, dispatch encode/decode).
    - brotli (`br`) bergabung ke facade sebagai `src/utils/compression/brotli.zig`, codec in-tree yang ditulis dari RFC 7932 (std tidak punya brotli): decoder lengkap plus encoder, meng-embed static dictionary Appendix A 122,784 byte (`brotli_dictionary.bin`). `.BR` ada di `supported_default`, tetapi gzip tetap default pada q yang sama (encoder in-tree belum kompetitif dengan gzip pada body kecil), jadi brotli disajikan ketika client memintanya. Interop diverifikasi dua arah terhadap `brotli` CLI sistem. Encoder selalu juga menghasilkan stream store-only dan mengembalikan yang lebih kecil, jadi sebuah body tidak pernah membesar (body sangat kecil cukup fallback ke identity).
    - `zix.Http1` menyajikannya via `core.writeNegotiated(fd, head, status, content_type, body)`, `zix.Http` via `Response.sendNegotiated(req, body)`, keduanya menyetel `Content-Encoding` dan `Vary: Accept-Encoding`. Aktif pada `.EPOLL` dan `.URING`, default off. gRPC tetap memakai `grpc-encoding` per-message miliknya, raw transport tidak punya negosiasi HTTP.
    - `std.compress.flate.Compress` berukuran sekitar 230 KB dan hidup di encode scratch per-worker yang di-map secara lazy (tidak pernah jadi temporary stack), menjaga hot path bebas syscall alokasi. Worker yang mengompresi tetap di-spawn dengan floor stack 2 MiB (demand-paged, RSS mendekati nol) alih-alih default 512 KB, headroom untuk rantai panggilan codec yang lebih dalam. Encoder brotli membangun index dictionary-nya di heap dan dictionary-nya sendiri adalah `@embedFile` `.rodata`, jadi tidak menambah tekanan stack.
    - Codec caller-buffer parity: `brotli.zig` menambah `compressBrotli` / `decompressBrotli` (varian buffer-into di samping tiap varian alloc), jadi cocok dengan bentuk four-function `flate.zig`. `flate.zig` dan `brotli.zig` kini punya named `EncodeError` / `DecodeError` yang serasi (`BufferTooSmall` dibagi), dan `compressBound` mendokumentasikan bahwa brotli tidak pernah membesar sedangkan flate bisa. `writeGzipCached` yang bespoke tetap gzip-only secara desain (A/B json-comp menunjukkan pengganti unified-nya turun sekitar 1.2 sampai 6.8%), jadi tidak ada kembaran `writeBrotliCached`, brotli lewat `writeNegotiated`.
    - Example baru `http1_compression` (port 9058) dan `http_compression` (port 9059), masing-masing dengan `/data` (negotiated) plus route eksplisit `/gzip` `/deflate` `/br` yang memaksa satu coding lewat facade `compression.encode`. Step runner individual `test-runner-http1-compression` / `test-runner-http-compression` (raw-socket, menguji br / gzip / deflate / identity / size-floor), dan kedua example dilipat ke `test-runner-all` sebagai baris `http-compression` / `http1-compression` (raw-socket read, decode, value-check tiap coding), menjadikan runner 69 protokol.

    ---

- TLS (https / h2), pure-Zig di atas `std.crypto`, tanpa OpenSSL:
    - Server TLS 1.3 (RFC 8446) plus floor TLS 1.2 (RFC 5246 / 5288, ECDHE-ECDSA-AES128-GCM), 1.3 diutamakan, tidak pernah di bawah 1.2 (1.0 / 1.1 / SSL tidak pernah ditawarkan, RFC 8996). Handshake sans-I/O di `src/tls`, engine HTTP memiliki socket loop.
    - Client native yang memverifikasi `zix.Tls.Client` (1.3) dan `zix.Tls.Client12` (1.2): menawarkan ALPN, memverifikasi signature server dan chain X.509 + hostname (RFC 5280 / 6125).
    - https bersifat opt-in dan aditif (ADR-046): `zix.Http1` menyajikan https/1.1 dan `zix.Http2` menyajikan h2 over TLS (ALPN h2), keduanya jalur ber-gate di depan engine cleartext yang tidak diubah. HelloRetryRequest, penanganan alert masuk, dan misdirected-request 421 (RFC 9110 7.4) sudah terpasang.
    - TLS server dikonfigurasi oleh object `Tls.Context` milik pengguna (ADR-047), dimodelkan pada logger: `Tls.Context.init(allocator, io, config)` memuat cert / key dan memvalidasi policy sekali. `Tls.Context.Config` mengekspos `cert_path`, `key_path`, `alpn`, `min_version` / `max_version`, `curves`, `ciphers`, `prefer_server_ciphers`, `hsts_max_age_s`. Curve dan cipher adalah allow-list tervalidasi (value tidak didukung = error saat startup). Certificate ECDSA P-256 dan Ed25519, ECDHE-only (tanpa dhparam).
    - Certificate server RSA (ADR-048): certificate RSA menandatangani CertificateVerify TLS 1.3 dengan `rsa_pss_rsae_sha256` (pure-Zig, Montgomery modexp constant-time di `montgomery.zig` plus EMSA-PKCS1-v1_5 / EMSA-PSS, minimum RSA-2048). RSA membutuhkan TLS 1.3, tipe certificate default tetap ECDSA P-256.
    - Example baru di `examples/tls/`: `tls_http1_basic` (9060), `tls_http2_basic` (9061), `tls_http1_ed25519` (9062), dengan step runner yang dilipat ke `test-runner-all`.
    - Docs: `docs/hld-tls-id.md` / `docs/lld-tls-id.md` (dan -en), ADR-045 / 046 / 047 / 048.

    ---

- Mode datagram UDP raw-bytes `zix.Udp.Raw` (ADR-049):
    - `zix.Udp.Raw(handler)` melayani datagram variable-length (hingga `max_recv_buf`) berdampingan dengan typed `zix.Udp.Server(Packet)`. Handler menerima byte datagram, peer, dan `Sink` untuk membalas. Di Linux ia mem-batch receive / send via `recvmmsg` / `sendmmsg`, balasan digabung jadi satu `sendmmsg` per batch yang diterima, dengan worker `SO_REUSEPORT` per-core di bawah `.EPOLL` / `.URING` (satu worker di bawah `.ASYNC` / `.POOL` / `.MIXED`).
    - Dispatch dipartisi sesuai ADR-043: `src/udp/dispatch/` (satu file per model plus `common.zig`) dengan `run()` switch tipis, plus `src/udp/datagram.zig` (socket raw-fd + primitive `recvmmsg` / `sendmmsg`) dan `src/udp/core.zig` (`HandlerFn`, `Sink`). Typed `Server(Packet)` tidak berubah, `dispatch_model` non-ASYNC padanya di-fold dengan notice yang dicatat. Non-Linux jatuh ke satu loop `std.Io.net`.
    - Example baru `examples/udp_server_raw.zig` (port 9064) dengan runner step `test-runner-udp-raw`, dilipat ke `test-runner-all`. GSO dan jalur submission io_uring khusus di balik `.URING` menyusul di ADR-056 (di bawah), GRO / ECN tetap ditunda.

    ---

- Engine HTTP/3 melalui QUIC `zix.Http3`, pure-Zig di atas `std.crypto`, di substrate `zix.Udp` (ADR-051):
    - `zix.Http3.Server.init(handler, config)` melayani HTTP/3 (RFC 9114) melalui QUIC (RFC 9000 / 9001 / 9002), dengan comptime `zix.Http3.Router` yang mengikuti `zix.Http1` / `zix.Http2` (EXACT / PARAM / PREFIX, query di-strip sebelum matching). TLS 1.3 wajib, dikonfigurasi oleh `Tls.Context` user-owned yang sama dengan engine TCP.
    - Layer QUIC / TLS / QPACK yang deterministik adalah pure-Zig dari RFC: packet protection (header protection plus AEAD), key schedule (Initial / Handshake / 1-RTT), handshake TLS 1.3 di atas CRYPTO-stream (ServerHello plus flight EE / Certificate / CertificateVerify / Finished), QPACK static-table field line, dan decoder Huffman RFC 7541 untuk request path.
    - Dispatch model (Linux-only): `.ASYNC` menjalankan satu recv loop single-worker dengan demux connection-id internal (migration-safe). `.POOL` / `.MIXED` menjalankan satu worker recvmmsg SO_REUSEPORT per core, dan `.EPOLL` / `.URING` menambah readiness epoll / completion io_uring pada bentuk per-core itu (`.URING` fold ke loop worker epoll saat io_uring tidak tersedia). Connection-id steering per-core ditunda (ADR-049 phase 3, ADR-050).
    - Loss recovery dan congestion control di hot-path (ADR-056, menggantikan penundaan ADR-051): deteksi loss berbasis ACK (RFC 9002), estimator RTT, Probe Timeout dengan backoff, dan congestion window gaya NewReno kini berjalan di jalur serve, jadi path yang lossy pulih alih-alih satu packet tail yang hilang memacetkan seluruh response. Sebuah maintenance sweep berbasis timer (tiap 5 ms) me-re-pump range in-flight yang timed-out. Hanya loss yang terdeteksi ACK yang memotong congestion window, sebuah PTO me-retransmit tanpa mengurangi cwnd (RFC 9002 6.2). Model `.EPOLL` dan `.URING` kini menjalankan worker `SO_REUSEPORT` per-core yang sebenarnya (tiap worker memiliki tabel connection-id-nya sendiri, `.URING` adalah ring io_uring nyata dengan fallback ke loop `.EPOLL`) alih-alih fold ke worker single v1. Sebuah slot koneksi direklamasi hanya saat close atau idle melewati `max_idle_ms`, tidak pernah karena loss, jadi peer yang hidup-tapi-lossy tetap tersambung. Pada potongan yang sama `zix.Udp` raw memperoleh ADR-049 phase dua-nya (ring recv io_uring nyata di balik `.URING` plus UDP GSO). Steering connection-id lintas-core untuk migrasi di tengah koneksi tetap ditunda.
    - `zix.Http3` mengekspor primitive low-level-nya (`crypto`, `protection`, `keyschedule`, `qpack`, `huffman`, `packet`, `varint`, `frame`, plus `tls_key_schedule`), cara yang sama `zix.Http2` mengekspor primitive frame / HPACK-nya, sehingga sebuah peer bisa membangun sisi lain dari wire.
    - Example baru `examples/tls/http3_basic.zig` (port 9063). Runner menggerakkan client QUIC native yang hermetic, hand-rolled dari primitive itu (tanpa tool eksternal), dengan runner step `test-runner-http3` dilipat ke `test-runner-all`.
    - Docs: `docs/hld-http3-id.md` / `docs/lld-http3-id.md` (dan -en).

    ---

- `zix.utils.multipart` (parser multipart dipindah):
    - Parser `multipart/form-data` dipindah dari `src/tcp/http/upload.zig` ke `src/utils/multipart.zig`, byte parsing yang protocol-agnostic dan dibagikan oleh `zix.Http` dan `zix.Http1`. Type di-rename `MultipartParser` menjadi `Parser` dan `MultipartField` menjadi `Field`, jadi path kanonikalnya `zix.utils.multipart.Parser` / `zix.utils.multipart.Field`. `zix.Http.Multipart` / `zix.Http.MultipartField` tetap ada sebagai thin alias (tanpa break). `examples/http_static.zig` dan `examples/http1_static.zig` memanggil path kanonikal, dan `examples/http1_static.zig` mendapat route upload kedua (`/upload-multipart`) yang mendemokannya pada `zix.Http1`.

    ---

- Server config (knob) ditambahkan:
    - `compress` (bool), `compression_min_size` (usize), dan `compression_max_out` (usize) pada `zix.Http1` dan `zix.Http`. Field gzip-spesifik `max_gzip_out` di-rename menjadi `compression_max_out` yang codec-agnostic.
    - `tls` (`?*Tls.Context`) pada `zix.Http1`, `zix.Http2`, dan `zix.Grpc`, gate opt-in https. Menggantikan field flat `tls_cert_path` / `tls_key_path` / `tls_alpn` / `hsts_max_age_s` Http1 (ADR-047).
    - `dispatch_model`, `workers`, `reuse_address`, `recv_batch`, `send_batch`, `max_recv_buf` pada `zix.Udp` (`UdpServerConfig`), dipakai jalur raw (`zix.Udp.Raw`, ADR-049). Additive, typed `Server(Packet)` tidak berubah.
    - `public_dir` dan `public_dir_upload` pada `zix.Http1` (`Http1ServerConfig`), static file serving untuk route yang tidak match, meniru `zix.Http`. `public_dir` yang non-empty divalidasi saat `run()` dan menghasilkan `error.PublicDirNotFound` jika tidak ada.
    - `uring_send_buf_size` (default 16 KiB), `uring_idle_pool_floor` (default 8), dan `uring_idle_pool_ceiling` (default 256) pada `zix.Http1` (`Http1ServerConfig`), menyetel send buffer per-koneksi `.URING` dan batas warm reconnect-pool (lihat entri optimasi memori Http1 / Http).

    ---

- DATA-frame coalescing untuk gRPC server-streaming (ADR-057):
    - Server-streaming `zix.Grpc` memadatkan pesan berurutan menjadi DATA frame HTTP/2 yang lebih sedikit dan lebih besar (hingga max frame size default 16 KiB) alih-alih satu DATA frame per pesan. Reply `count = 5000` turun dari 5000 DATA frame kecil menjadi sekitar 3, memangkas byte header frame di wire dan biaya parse per-frame di klien. Perbaikan ini ada di `muxDispatch` bersama, jadi `.URING`, `.EPOLL`, dan kedua jalur mux TLS mewarisinya. Unary tetap satu frame per pesan dan byte-nya persis sama. Jalur thread (`.ASYNC` / `.POOL` / `.MIXED`) belum dipadatkan. `zix.Grpc.Client` bawaan meng-unpack beberapa pesan dari satu DATA frame (tiap `recvResponse` menguras sisa frame sebelum membaca frame berikutnya), sesuai coalescing-nya.

    ---

- Negosiasi content-encoding HTTP/3:
    - `zix.Http3` mendapat content-negotiation pada response. `req.accept_encoding` mengekspos Accept-Encoding klien (didekode dari QPACK static entry 31 atau literal, Huffman diperluas), dan handler memanggil `res.setContentEncoding(.br)` / `.gzip`, yang memancarkan header response `content-encoding` sebagai satu QPACK indexed line (indeks static 42 br / 43 gzip). Engine tidak pernah mengompresi di jalur kirim: handler menyajikan body yang sudah ter-compressed (file `.br` / `.gz` yang sudah jadi), jadi tidak ada biaya codec per-request dan aturan perf / memory tetap terpenuhi. Menyajikan varian pre-compressed yang lebih kecil berarti lebih sedikit packet per response, itulah yang menggerakkan static-serving.
    - Static table QPACK diperluas dari indeks 0..28 ke 0..43 (RFC 9204 Appendix A), mencakup `accept-encoding` (31) dan `content-encoding` br / gzip (42 / 43). Decoder request menelusuri melewati pseudo-header untuk menangkap `accept-encoding`, dan `buildRequestStreamContent` / `buildStreamPrefix` memancarkan line `content-encoding` (`SendStream` menyimpan coding-nya agar body multi-packet yang di-resume tetap membawa header-nya). Perubahan ini ada di `dispatch/common.zig` bersama, jadi setiap dispatch model mewarisinya.
    - `zix.Http3.ContentEncoding` diekspor. `examples/tls/http3_basic.zig` mendapat route `/negotiated` yang menyajikan body brotli-precompressed dengan `content-encoding: br` saat klien menerima br. Docs `hld-http3`, `lld-http3` (en dan -id) diperbarui.

    ---

- Rolling flow-control credit HTTP/3 (MAX_STREAMS + MAX_DATA):
    - Handshake QUIC mengiklankan dua budget sekali-pakai ke client, `max_streams` request stream dan `initial_max_data` (1 MiB) byte request seluruh connection. Keduanya kini digulir maju saat client memakainya: grant MAX_STREAMS (frame 0x12, `replenishBidiStreams`) naik saat request stream pensiun, dan grant MAX_DATA (frame 0x10, `replenishMaxData`) naik saat byte request terpakai. Tiap grant dipancarkan begitu konsumsi melewati separuh window-nya dan menumpang prologue reply yang ter-coalesce, seperti ACK.
    - Memperbaiki deadlock seumur connection: tanpa byte grant, connection membisu setelah kira-kira `initial_max_data` request, client terblokir pada connection flow control dan request in-flight terakhirnya tak pernah terjawab, sehingga throughput connection berumur panjang mentok di konstanta yang tidak bergantung hardware. Dengan kedua grant menggulir, connection melayani tanpa batas.
    - Bagian baru: `flight.initial_max_data` (nilai yang diiklankan sekaligus window replenish, satu const), `Connection.replenishMaxData`, `request.streamBytes` (menjumlah byte payload STREAM sebuah packet lintas semua stream, karena flow control level connection menghitung semuanya), dan `response.buildMaxData` plus `Framing.max_data`. Wiring ada di `dispatch/common.zig` bersama, jadi semua dispatch model mewarisinya. Unit test mencakup matematika replenish, encoding frame, dan penghitungan byte.

    ---

- Taksonomi penamaan send / write / FD untuk response-API (ADR-059):
    - Permukaan penulisan response di-rename pada dua sumbu independen agar call site terbaca tanpa ambiguitas: fungsi yang mengirim response, atau komunikasi keluar apa pun, adalah `send*`, sebuah write murni tanpa send adalah `write*`, dan signature yang menerima parameter `fd` mentah diakhiri `FD` (sebuah fd yang ditahan di dalam struct, dijangkau lewat `self`, tidak dihitung, jadi method objek tetap bersih).
    - Breaking untuk kode yang memanggil helper response secara langsung. Helper fd-level di core di-rename lintas setiap engine: `fdWriteAll` -> `writeAllFD`, `fdWriteAllRaw` -> `writeAllRawFD`, `writeSimple` -> `sendSimpleFD`, `writeSimpleNoBody` -> `sendSimpleNoBodyFD`, `writeJson` -> `sendJsonFD`, `writeGzip` -> `sendGzipFD`, `writeGzipCached` -> `sendGzipCachedFD`, `writeBrotli` -> `sendBrotliFD`, `writeNegotiated` -> `sendNegotiateFD`, `writeChunkedStart` / `writeChunk` / `writeChunkedEnd` -> `sendChunkedStartFD` / `sendChunkFD` / `sendChunkedEndFD`, `writeRange` -> `sendRangeFD`, `write100Continue` -> `send100ContinueFD`. Body dan parameter fungsi tak berubah, hanya nama dan teks doc / comment yang merujuknya.
    - Engine yang mampu compression mengekspos enam yang sama: `sendGzipFD`, `sendGzipCachedFD`, `sendBrotliFD`, `sendBrotliCachedFD`, `sendNegotiateFD`, `sendNegotiateCachedFD`. Negotiate merutekan secara internal lewat jalur gzip / brotli bersama, jadi kebijakan compression ada di satu tempat, dan primitif precompressed / caller-encoded (`sendResponseEncodedFD`) tetap menjadi lapisan yang dibangun keenam fungsi itu di atasnya.
    - Digulirkan engine demi engine (`zix.Http1`, WebSocket-nya, `zix.Http2`, `zix.Grpc`, `zix.Http3`, lalu full server plus tls / dispatch bersama), tiap langkah di-gate oleh suite test penuh. Entri HttpArena dan example bawaan pindah ke nama baru (call site saja, tanpa perubahan behavior). Docs `hld-http1`, `lld-http1`, `lld-http`, `lld-http2`, `lld-grpc`, `lld-tls` (en dan -id) diperbarui. Lihat ADR-059.

    ---

- Optimasi memori `zix.Http1` dan `zix.Http` (kompaksi recv-slab EPOLL, batas idle-pool URING):
    - Kompaksi recv-slab EPOLL (`src/tcp/http1/dispatch/epoll.zig`, di-port ke `dispatch/common.zig` milik `zix.Http`): slab receive per-worker diindeks oleh fd global (`slab[fd * buf_size]`), jadi page yang tersentuh tersebar di seluruh ruang 64K-fd dan menahan residen jauh lebih banyak dari yang dibutuhkan set koneksi hidup. Sebuah free-list slot kompak per-worker (tiap `Conn` membawa `slot`, `acquireSlot` memakai ulang slot yang sudah ditutup sebelum menaikkan high-water mark, `free` mengembalikan stride page-aligned via `MADV_DONTNEED`) memampatkan memori residen ke jumlah koneksi hidup terlepas dari nilai fd. Pada jumlah koneksi tinggi ini memangkas memori Http1 puncak sekitar 2.5x (kira-kira 704 ke 281 MiB), membawa `.EPOLL` ke paritas `.URING`, dengan throughput tertahan dalam noise loopback.
    - Batas idle-pool URING (`src/tcp/http1/dispatch/uring.zig`): warm reconnect pool kini meng-evict tail yang paling lama tidak dipakai (`evictColdTail`, list warm MRU plus stack cold) melewati sebuah batas, mengecilkan `send_buf` per-koneksi yang tumbuh kembali ke ukuran dasar saat dilepas, dan mem-prewarm floor residen kecil saat startup untuk menghindari badai page-fault cold-start. Mereklamasi cold tail (bukan hot head yang diambil reconnect berikutnya) menjaga reklamasi keluar dari hot path churn, jadi memori turun tanpa biaya throughput. Dibatasi oleh knob config `uring_send_buf_size` / `uring_idle_pool_floor` / `uring_idle_pool_ceiling` di atas.

    ---

- Penempatan CPU worker (engine multiplexed Linux, ADR-061):
    - Field config flat baru `reuseport_cbpf: bool = false` di semua server config kecuali `zix.Uds`: memasang steering SO_ATTACH_REUSEPORT_CBPF pada grup `SO_REUSEPORT` per-worker (`src/multiplexers/reuseport.zig`), sehingga kernel menyerahkan koneksi baru (TCP) atau tiap datagram (UDP) ke listener index = CPU penerima mod workers alih-alih hash 4-tuple. Listener bind di dalam thread worker yang berpacu, jadi bind-order gate khusus startup menserialkan join grup (worker i = group index i). Opt-in, default false: netral rps pada box loopback, menyasar host multi-CPU tempat NIC RSS menyebarkan softirq. Jangan pernah aktifkan pada jalur QUIC: steering per paket merusak flow affinity QUIC (paket satu flow mendarat di worker berbeda) dan meruntuhkan throughput.
    - Pinning worker meluas ke `zix.Tcp` dan `zix.Fix` (worker `.EPOLL` / `.URING`, jumlah sadar-cpuset plus pin per-core), dan urutan pin semua engine kini mengisi physical core lebih dulu, SMT sibling setelahnya (topologi sysfs, urutan mask dipertahankan bila sysfs absen).
    - Counter beban per-worker melapor saat worker keluar melalui system logger (request, frame, koneksi diterima, atau message, per engine), sehingga distribusi yang miring antar worker bisa diamati. Dua engine h2-mux (`zix.Http2`, `zix.Grpc`) tidak membawa counter ini: increment threadlocal di hot loop mux-nya terukur sekitar 1 persen throughput pada jutaan req/s, jadi dijauhkan dari hot path mereka.

- Receive multishot `zix.Udp` raw `.URING`: ring per-core memasang `recvmsg` multishot dengan provided buffer ring (mencerminkan layer recv `zix.Http3`, 256 buffer), menggantikan re-arm per completion, dengan slot pool one-shot dipertahankan sebagai fallback.

    ---

- Backpressure submission-queue `.URING` (process queue):
    - Field config flat baru `process_queue_len: usize = 0` pada `Http1ServerConfig` dan `HttpServerConfig`: pada `.URING`, re-arm recv atau send yang menemukan submission queue penuh diparkir pada FIFO ring per-worker sepanjang nilai ini (hanya referensi, fd plus generation, reject-newest) dan dicoba ulang pada loop pass berikutnya alih-alih menutup koneksi. 0 (default) mematikan fitur, dan tanpa efek pada dispatch model lain. Atur sekitar puncak koneksi bersamaan per worker.
    - Perbaikan lost-accept re-arm lintas dispatch `.URING` `zix.Http1`, `zix.Http`, `zix.Grpc`, dan `zix.Http2`: re-arm multishot-accept yang jatuh saat SQ penuh membuat worker tidak bisa accept lagi sementara backlog kernel terisi. Worker kini mencatat miss (`accept_pending` / `tls_accept_pending`) dan mencoba ulang arm tepat setelah submit berikutnya, jadi SQ penuh tidak lagi mengunci accept.
    - Kehilangan submission-queue `.URING` `zix.Http3` diperbaiki (`src/udp/http3/dispatch/uring.zig`): re-arm `recvmsg` multishot yang hilang saat SQ penuh membuat worker tuli permanen (retry `recv_unarmed` sticky kini me-re-arm-nya), re-arm slot one-shot yang hilang saat SQ penuh membocorkan slot (daftar pending re-arm terbatas kini memulihkannya), dan tail send yang dibatasi SQ penuh terbuang saat buffer swap (swap kini ditunda selama tail belum terkirim).
    - Body request oversize di-shed alih-alih dipotong: `zix.Http2` menjawab body DATA yang melewati buffer stream dengan `413` dan END_STREAM (hanya window koneksi yang dikredit untuk byte yang dibuang), dan `zix.Grpc` mengakhiri stream dengan trailer `RESOURCE_EXHAUSTED`. Sebelumnya body dipotong diam-diam ke kapasitas, yang bisa men-dispatch message korup. Frame DATA berikutnya untuk stream yang di-shed dijawab dengan RST_STREAM, dan stream lain pada koneksi tetap berjalan.

<br>

__*Fix:*__

- Drain body besar `zix.Http1` di bawah model thread:
    - Di bawah `.ASYNC` / `.POOL` / `.MIXED`, body request yang lebih besar dari receive buffer dipotong di batas buffer dan byte yang belum terbaca merusak request keep-alive berikutnya di koneksi itu. Jalur thread kini menguras sisanya sebelum melayani request berikutnya, cocok dengan perilaku `.EPOLL` / `.URING`.

    ---

- Truncation body request `zix.Http` di bawah `.EPOLL` / `.URING`:
    - Body request multi-segment (upload besar atau chunked yang terpecah lintas read) dipotong ketika `body()` / `readChunkedBody()` kena `EAGAIN` di tengah body. Reader kini mem-poll fd dan mencoba ulang hingga `body_read_timeout_ms` (default 30s), jadi upload terbaca penuh. Jalur GET hot kembali lebih awal dan tidak membayar apa pun.

<br>

## 0.4.0 (2026-06-19)

__*Ditambahkan:*__

- Penskalaan churn io_uring dan overflow response on-ring (ADR-041):
    - Teardown `.URING` `zix.Http1` kini me-ring close-nya (`prep_close`, ditag dengan `OpKind.close` bersama yang baru) alih-alih `linux.close` sinkron, mendaur ulang slot koneksi lebih dulu dan jatuh ke close sinkron hanya saat SQ sesaat penuh. Di bawah connection churn, close sinkron memblokir worker antar koneksi, jadi ring nyaris tidak mengaktifkan core-nya. Dengan ring close, worker terus memanen completion lintas teardown. Di mesin 64-core ini mengangkat cell churn (limited-conn, json) dari jauh di belakang `.EPOLL` ke paritas atau lebih baik, dengan memori jauh lebih sedikit, jadi `.URING` kini mencapai paritas atau lebih baik di setiap cell yang diukur.
    - `RespSink` (`tcp/http1/core.zig`) menumbuhkan buffer staging-nya saat overflow ketika didukung oleh allocator: loop `.URING` memasangnya di atas `send_buf` per-koneksi dengan cap 1 MiB (`URING_SEND_BUF_MAX`), jadi response yang lebih besar dari buffer ter-stage tumbuh di tempat (realloc power-of-two, tidak pernah menyusut, dipakai ulang oleh koneksi yang didaur ulang) dan tetap keluar sebagai satu on-ring send, alih-alih menahan worker di write off-ring yang memblokir. Jalur `.EPOLL` tidak memasang grow allocator dan tidak berubah (flush-on-overflow).
    - `OpKind` io_uring bersama dan helper ring dipindahkan dari `src/tcp/io_uring` ke `src/multiplexers/ring.zig`. Setiap engine io_uring membawa arm `.close => {}`. Hanya `zix.Http1` yang meng-arm ring close untuk saat ini.

    ---

- `io` server ke dalam config dan handler-at-init `zix.Uds` (ADR-039):
    - `zix.Tcp`, `zix.Udp`, dan `zix.Uds` kini membawa `io: std.Io` sebagai field config pertama, sehingga `run()` tidak menerima argumen, mengikuti lima engine server. Setiap server zix kini dikonstruksi dengan config yang membawa `io` dan dilayani dengan `run()` tanpa argumen.
    - `zix.Uds` mengadopsi bentuk factory ADR-038: `Server.init(comptime handler, config)` membakukan handler ke dalam tipe, dan `zix.Uds.echoHandler` bawaan dilewatkan secara eksplisit. Jalur `run(io, handler)` / `runWith` dihapus.
    - Breaking: setiap call site server `zix.Tcp` / `zix.Udp` / `zix.Uds` menambah `.io = process.io` dan menghapus argumen `run`. Client tetap menerima `io` sebagai parameter `connect()` (ditunda ke keputusan terpisah).

    ---

- Model dispatch io_uring (`.URING`, ADR-037):
    - Model dispatch shared-nothing baru `.URING = 4`: topologi thread-per-core yang sama dengan `.EPOLL` (satu `SO_REUSEPORT` listener dan satu completion ring per worker, tanpa queue bersama), tetapi completion-based, sehingga sebagian besar transisi syscall di-batch ke dalam ring. Khusus Linux, fallback ke `.POOL` di non-Linux.
    - Native di `zix.Http1` (engine referensi, plus pump WebSocket di atas `BufferGroup`), `zix.Http`, `zix.Grpc` (h2 multiplexed), dan `zix.Fix` (`core.processFixRing` resumable per batch readable). `zix.Http2` melipat ke `.POOL` dan handler per-connection `zix.Tcp` melipat ke `.EPOLL`.
    - Request body di ring (`zix.Http1`): body request chunked yang sepenuhnya ada di recv buffer di-decode di tempat, dan body yang lebih besar dari `max_recv_buf` dijawab lalu sisanya di-drain dari socket dengan satu recv `MSG_TRUNC` (kernel membuang byte di tempat, zero copy, dibatasi pada panjang yang dideklarasikan), mengikuti drain `.EPOLL`. Jadi `.URING` melayani upload besar dan request chunked, bukan hanya yang ter-buffer.
    - Di loopback `.URING` setara `.EPOLL` pada throughput dan total CPU, menang terutama pada cache locality per-request. Pilih `.EPOLL` sebagai default, `.URING` untuk beban sustained dan pipelined.

    ---

- Reshape API server `zix.Tcp` (ADR-038):
    - Handler dibakukan ke dalam tipe server pada `init`, sehingga `run` tidak menerima argumen handler, mengikuti `zix.Http1` / `zix.Grpc` (ADR-039 kemudian memindahkan `io` ke config, sehingga `run()` tidak menerima apa pun). `zix.Tcp.Server` kini namespace tanpa field dengan constructor comptime `init(handler, config)` / `initArgs(handler, config, args)` (per-connection) dan `initFramed(frame_fn, config)` / `initFramedArgs(frame_fn, config, args)` (ring per-frame).
    - Breaking: `runWith` dan `runFramed` dihapus. Default echo bawaan adalah `zix.Tcp.echoHandler` publik, dilewatkan secara eksplisit. Handler per-connection berjalan `.ASYNC` / `.POOL` / `.MIXED` / `.EPOLL` (`.URING` melipat ke `.EPOLL`). Callback `FrameFn` per-frame baru (`initFramed`) berjalan native di ring `.URING`.

    ---

- `Http2ServerConfig.logger`:
    - Field opsional baru `logger: ?*Logger` pada `Http2ServerConfig`, demi konsistensi dengan config server lain. Bila diset, baris lifecycle `zix.Http2` dirutekan melalui `logger.system(.INFO, "http2", ...)` alih-alih `std.debug.print` yang hanya Debug.

    ---

- Konstanta frame `zix.Http2`:
    - Byte frame-type HTTP/2 diganti nama dari `FT_*` menjadi `FRAME_TYPE_*` yang dieja penuh (`FT_DATA` -> `FRAME_TYPE_DATA`, dan seterusnya). Breaking untuk kode apa pun yang mereferensi `zix.Http2.FT_*`.
    - `pub const FRAME_HEADER_LEN` baru (9) di modul frame h2 (di-re-export dari `zix.Http2`) menamai panjang frame header 9-octet, menggantikan literal `9` inline di seluruh codec frame h2 dan gRPC.

    ---

- Response cache awareness (opt-in, ADR-036):
    - Modul bersama baru `src/utils/response_cache.zig`: precomputed-response cache per-worker yang lock-free (structure-of-arrays slab, open addressing, lazy on-access TTL). Mati secara default, dipasang di bawah `.EPOLL` dan `.URING`. Dispatch model lain membiarkannya tidak terpasang dan API menurun menjadi plain send.
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
    - Menghapus print mentah junk dan duplikat: `zix.Grpc` sebelumnya mencetak tiap baris listening mentah sekaligus me-log-nya. `zix.Http2`/`zix.Fix`/`zix.Tcp` mencetak baris lifecycle/fallback mentah tanpa syarat. Baris init `zix.Udp`/`zix.Uds` kini juga muncul pada Debug build tanpa logger (sebelumnya logger-only).
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
