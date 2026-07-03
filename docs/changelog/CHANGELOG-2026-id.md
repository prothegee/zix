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

## 0.5.0 (TBD)

__*Update:*__
- Zig 0.17 (eksperimental) support.

- Breaking: `dispatch_model` kini field config wajib tanpa default. Setiap config server (`Http1ServerConfig`, `HttpServerConfig`, `Http2ServerConfig`, `GrpcServerConfig`, `FixServerConfig`, `TcpServerConfig`, `UdpServerConfig`, `Http3ServerConfig`) melepas default `.ASYNC`, jadi pemanggil harus menyetel `dispatch_model` secara eksplisit.

- Jalur serve https `zix.Http` (ADR-053):
    - `zix.Http` (arena engine) memperoleh TLS opt-in (`config.tls`), engine HTTP ketiga yang melayani https/1.1. Setiap koneksi menjalankan handshake (TLS 1.3, dengan fallback 1.2 ECDSA) dan loop request keep-alive di worker thread-nya sendiri, response router ditangkap lewat response sink milik engine lalu dienkripsi, jadi handler menulis Response biasa dan jalur cleartext tidak menambah biaya hot-path. Response ter-buffer secara default (WebSocket adalah follow-up, SSE / streaming melalui TLS mendarat di ADR-054). Example baru `examples/tls/tls_http_basic.zig` (port 9071).
    - Worker TLS Http2 dan gRPC yang multipleks kini pin per-core dan menghitung worker count dari cpuset yang tersedia (paritas ADR-052 dengan `tls_mux` Http1), jadi cpuset yang di-pin cgroup tidak lagi meng-oversubscribe satu core di bawah handshake storm.

    ---

- SSE / streaming melalui TLS (ADR-054):
    - `zix.Http` dan `zix.Http1` melayani Server-Sent Events melalui TLS di jalur thread-per-koneksi (`.ASYNC` / `.POOL` / `.MIXED`). Stream sink per-koneksi (`TlsStreamSink`, type-erased atas koneksi TLS 1.3 / 1.2 hidup) mengenkripsi satu TLS record per write dan mengirimnya seketika, menggantikan buffered capture hanya ketika handler memilih streaming. `fdWriteAll` memeriksa buffered sink dulu, lalu stream sink, jadi response normal menjaga jalur cepat ter-buffer tetap utuh.
    - `zix.Http` memakai ulang `res.stream()` (tanpa simbol publik baru, kini menjaga stream sink aktif melalui TLS). `zix.Http1` memperoleh `beginStream()`, no-op di cleartext, jadi satu fd-handler melayani cleartext dan TLS. Jalur `tls_mux` multipleks (`.EPOLL` / `.URING`) tetap request / response saja.
    - Example baru `examples/tls/tls_http_sse.zig` (port 9072) dan `examples/tls/tls_http1_sse.zig` (port 9073), dengan runner step `test-runner-tls-http-sse` / `test-runner-tls-http1-sse` (client `zix.Tls` native, tanpa curl), dilipat ke `test-runner-all`. `examples/http1_sse.zig` kini memanggil `beginStream()`.

    ---

- WebSocket melalui TLS (ADR-055):
    - `zix.Http` dan `zix.Http1` melayani WebSocket melalui TLS (wss) di jalur thread-per-koneksi (`.ASYNC` / `.POOL` / `.MIXED`). Handler memanggil `WebSocket.serveTls(fd, key, on_frame)`: ia mengirim `101` terenkripsi lewat ADR-054 stream sink dan mendaftarkan handoff, lalu loop serve https menjalankan inline frame loop atas TLS session (dekripsi record, parse frame, `on_frame` untuk text / binary, ping di-auto-pong, close di-auto-echo). Frame keluar memakai ulang ADR-054 stream sink, jadi tiap pump pass mengenkripsi frame ter-coalesce sebagai satu record.
    - `zix.Http1` memakai ulang frame codec-nya (`parseFrame` / `pump` / `send`) dan handoff `requestWebSocket` / `takeWebSocket`. `zix.Http` memperoleh bagian engine-driven yang cocok (`WsFrameFn`, `send`, `pump`, handoff, `upgradeFd`), jadi `on_frame(fd, opcode, payload)` dan `serveTls` yang sama jalan di kedua engine. Rooms / broadcast tidak dilayani melalui TLS (enkripsi per-session), jadi wss bersifat per-koneksi / echo. Jalur `tls_mux` multipleks tetap request / response saja.
    - Example baru `examples/tls/tls_http1_ws.zig` (port 9074) dan `examples/tls/tls_http_ws.zig` (port 9075), dengan runner step `test-runner-tls-http1-ws` / `test-runner-tls-http-ws` (client `zix.Tls` native, tanpa websocat), dilipat ke `test-runner-all`.

    ---

- Dispatch `.EPOLL` / `.URING` native untuk `zix.Http2` (ADR-043):
    - `zix.Http2` h2c memperoleh loop multiplexed shared-nothing yang sebelumnya dilipat ke `.POOL`. Sebuah mux state machine h2 yang resumable (`src/tcp/http2/mux.zig`, satu `MuxConn` per fd, akumulator baca bertahan lintas event readable) digerakkan oleh `dispatch/epoll.zig` (satu listener `SO_REUSEPORT` plus epoll plus slab `ConnTable` per worker) dan `dispatch/uring.zig` (satu ring io_uring per worker, multishot accept, `user_data` ber-tag generation). Di ring, worker memegang accept plus recv dan handler menulis reply langsung ke fd non-blocking (tanpa cork per-stream). `.URING` memprobe ring saat startup dan jatuh ke `.EPOLL` ketika io_uring tidak tersedia, keduanya dilipat ke `.POOL` di luar Linux.
    - `zix.Http2.Router` memperoleh query-stripping dan `.kind = .PREFIX`, meniru `zix.Http1`: query di-strip sebelum matching, route EXACT memakai `StaticStringMap`, PREFIX mencocokkan prefix terdaftar terpanjang pada batas segment. `RouteKind` diekspor.
    - Keluarga example baru `examples/http2_basic_{1_async,2_pool,3_mixed,4_epoll,5_uring}.zig` (port 9065-9069) dengan step runner `test-runner-http2-{async,pool,mixed,epoll,uring}`, dilipat ke `test-runner-all`.

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
    - `std.compress.flate.Compress` berukuran sekitar 230 KB dan dibangun di stack frame handler, jadi worker yang mengompresi di-spawn dengan stack 2 MiB (demand-paged, RSS mendekati nol) alih-alih default 512 KB. Encoder brotli membangun index dictionary-nya di heap dan dictionary-nya sendiri adalah `@embedFile` `.rodata`, jadi tidak menambah tekanan stack.
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
    - Example baru `examples/udp_server_raw.zig` (port 9064) dengan runner step `test-runner-udp-raw`, dilipat ke `test-runner-all`. GSO / GRO / ECN dan jalur submission io_uring khusus di balik `.URING` ditunda (`.URING` di-fold ke loop per-core recvmmsg).

    ---

- Engine HTTP/3 melalui QUIC `zix.Http3`, pure-Zig di atas `std.crypto`, di substrate `zix.Udp`:
    - `zix.Http3.Http3(handler)` melayani HTTP/3 (RFC 9114) melalui QUIC (RFC 9000 / 9001 / 9002), dengan comptime `zix.Http3.Router` yang mengikuti `zix.Http1` / `zix.Http2` (EXACT / PARAM / PREFIX, query di-strip sebelum matching). TLS 1.3 wajib, dikonfigurasi oleh `Tls.Context` user-owned yang sama dengan engine TCP.
    - Layer QUIC / TLS / QPACK yang deterministik adalah pure-Zig dari RFC: packet protection (header protection plus AEAD), key schedule (Initial / Handshake / 1-RTT), handshake TLS 1.3 di atas CRYPTO-stream (ServerHello plus flight EE / Certificate / CertificateVerify / Finished), QPACK static-table field line, dan decoder Huffman RFC 7541 untuk request path.
    - Dispatch model (Linux-only): `.ASYNC` menjalankan satu recv loop single-worker dengan demux connection-id internal (migration-safe). `.POOL` / `.MIXED` menjalankan satu worker recvmmsg SO_REUSEPORT per core, dan `.EPOLL` / `.URING` menambah readiness epoll / completion io_uring pada bentuk per-core itu (`.URING` fold ke loop worker epoll saat io_uring tidak tersedia). Connection-id steering per-core ditunda (ADR-049 phase 3, ADR-050).
    - `zix.Http3` mengekspor primitive low-level-nya (`crypto`, `protection`, `keyschedule`, `qpack`, `huffman`, `packet`, `varint`, `frame`, plus `tls_key_schedule`), cara yang sama `zix.Http2` mengekspor primitive frame / HPACK-nya, sehingga sebuah peer bisa membangun sisi lain dari wire.
    - Example baru `examples/tls/http3_basic.zig` (port 9063). Runner menggerakkan client QUIC native yang hermetic, hand-rolled dari primitive itu (tanpa tool eksternal), dengan runner step `test-runner-http3` dilipat ke `test-runner-all`.
    - Docs: `docs/hld-http3-id.md` / `docs/lld-http3-id.md` (dan -en).

    ---

- `zix.utils.multipart` (parser multipart dipindah):
    - Parser `multipart/form-data` dipindah dari `src/tcp/http/upload.zig` ke `src/utils/multipart.zig`, byte parsing yang protocol-agnostic dan dibagikan oleh `zix.Http` dan `zix.Http1`. Type di-rename `MultipartParser` menjadi `Parser` dan `MultipartField` menjadi `Field`, jadi path kanonikalnya `zix.utils.multipart.Parser` / `zix.utils.multipart.Field`. `zix.Http.Multipart` / `zix.Http.MultipartField` tetap ada sebagai thin alias (tanpa break). `examples/http_static.zig` dan `examples/http1_static.zig` memanggil path kanonikal, dan `examples/http1_static.zig` mendapat route upload kedua (`/upload-multipart`) yang mendemokannya pada `zix.Http1`.

    ---

- Server config (knob) ditambahkan:
    - `compression` (bool), `compression_min_size` (usize), dan `compression_max_out` (usize) pada `zix.Http1` dan `zix.Http`. Field gzip-spesifik `max_gzip_out` di-rename menjadi `compression_max_out` yang codec-agnostic.
    - `tls` (`?*Tls.Context`) pada `zix.Http1`, `zix.Http2`, dan `zix.Grpc`, gate opt-in https. Menggantikan field flat `tls_cert_path` / `tls_key_path` / `tls_alpn` / `hsts_max_age_s` Http1 (ADR-047).
    - `dispatch_model`, `workers`, `reuse_address`, `recv_batch`, `send_batch`, `max_recv_buf` pada `zix.Udp` (`UdpServerConfig`), dipakai jalur raw (`zix.Udp.Raw`, ADR-049). Additive, typed `Server(Packet)` tidak berubah.
    - `public_dir` dan `public_dir_upload` pada `zix.Http1` (`Http1ServerConfig`), static file serving untuk route yang tidak match, meniru `zix.Http`. `public_dir` yang non-empty divalidasi saat `run()` dan menghasilkan `error.PublicDirNotFound` jika tidak ada.

    ---

- DATA-frame coalescing untuk gRPC server-streaming (ADR-057):
    - Server-streaming `zix.Grpc` memadatkan pesan berurutan menjadi DATA frame HTTP/2 yang lebih sedikit dan lebih besar (hingga max frame size default 16 KiB) alih-alih satu DATA frame per pesan. Reply `count = 5000` turun dari 5000 DATA frame kecil menjadi sekitar 3, memangkas byte header frame di wire dan biaya parse per-frame di klien. Perbaikan ini ada di `muxDispatch` bersama, jadi `.URING`, `.EPOLL`, dan kedua jalur mux TLS mewarisinya. Unary tetap satu frame per pesan dan byte-nya persis sama. Jalur thread (`.ASYNC` / `.POOL` / `.MIXED`) belum dipadatkan.

    ---

- Negosiasi content-encoding HTTP/3:
    - `zix.Http3` mendapat content-negotiation pada response. `req.accept_encoding` mengekspos Accept-Encoding klien (didekode dari QPACK static entry 31 atau literal, Huffman diperluas), dan handler memanggil `res.setContentEncoding(.br)` / `.gzip`, yang memancarkan header response `content-encoding` sebagai satu QPACK indexed line (indeks static 42 br / 43 gzip). Engine tidak pernah mengompresi di jalur kirim: handler menyajikan body yang sudah ter-compressed (file `.br` / `.gz` yang sudah jadi), jadi tidak ada biaya codec per-request dan aturan perf / memory tetap terpenuhi. Menyajikan varian pre-compressed yang lebih kecil berarti lebih sedikit packet per response, lever untuk static-serving.
    - Static table QPACK diperluas dari indeks 0..28 ke 0..43 (RFC 9204 Appendix A), mencakup `accept-encoding` (31) dan `content-encoding` br / gzip (42 / 43). Decoder request menelusuri melewati pseudo-header untuk menangkap `accept-encoding`, dan `buildRequestStreamContent` / `buildStreamPrefix` memancarkan line `content-encoding` (`SendStream` menyimpan coding-nya agar body multi-packet yang di-resume tetap membawa header-nya). Perubahan ini ada di `dispatch/common.zig` bersama, jadi setiap dispatch model mewarisinya.
    - `zix.Http3.ContentEncoding` diekspor. `examples/tls/http3_basic.zig` mendapat route `/negotiated` yang menyajikan body brotli-precompressed dengan `content-encoding: br` saat klien menerima br. Docs `hld-http3`, `lld-http3` (en dan -id) diperbarui.

<br>

__*Fix:*__

- n/a

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
