# Pengujian: zix

---

## Cara Menjalankan

```sh
# hanya pengujian unit (tidak ada output saat berhasil)
zig build unit-test

# pengujian integrasi: komponen dihubungkan, tanpa server aktif
zig build integration-test

# pengujian perilaku: kontrak API yang dapat diamati
zig build behaviour-test

# pengujian edge: kondisi batas dan jalur error
zig build edge-test

# semua langkah di atas sekaligus
zig build test-all
```

`zig build` saja **tidak** menjalankan pengujian: langkah pengujian adalah langkah bernama tersendiri yang tidak terhubung ke langkah install default.

---

## Pengujian Unit

Sumber: `src/zix.zig`. Setiap modul diuji melalui `std.testing.refAllDecls`, yang memverifikasi bahwa setiap deklarasi publik berhasil dikompilasi dan setiap blok `test` inline lolos.

### zix.Tcp (raw)

| Modul | Cakupan |
| :- | :- |
| `tcp/config.zig` | `refAllDecls` + perilaku: default `TcpServerConfig` (dispatch_model=.POOL, kernel_backlog=4096, max_msg_len=4096, workers=0, pool_size=0), default `TcpClientConfig` (max_msg_len=4096) |
| `tcp/server.zig` | `refAllDecls` + perilaku: port nol menghasilkan `error.PortNotConfigured`, konfigurasi valid berhasil dan deinit aman, konfigurasi EPOLL valid berhasil dan deinit aman |
| `tcp/client.zig` | `refAllDecls` |

### zix.Http

| Modul | Cakupan |
| :- | :- |
| `tcp/http/method.zig` | `refAllDecls` |
| `tcp/http/status.zig` | `refAllDecls` |
| `tcp/http/content.zig` | `refAllDecls` + round-trip: `enumFromString` / `stringFromEnum` untuk setiap varian enum |
| `tcp/http/parser.zig` | `refAllDecls` + perilaku: input tidak lengkap menghasilkan null, offset GET minimal, pemisahan path+query, offset header, flag keep_alive, semua method, method tidak valid, flag chunked aktif/nonaktif, dechunk tunggal/ganda/terminal/extension/hex-tidak-valid/hex-kapital |
| `tcp/http/request.zig` | `refAllDecls` + perilaku: method, path, query string, queryParam (ada / tidak ada / flag), pathSegments, queryParams, pencarian header (case-insensitive) |
| `tcp/http/response.zig` | `refAllDecls` + perilaku: setStatus, setContentType, setKeepAlive, addHeader, `HeaderSize.value()`, penjaga injeksi (CR/LF), TooManyHeaders, format wire `SseWriter`, default `Response.streaming` |
| `tcp/http/router.zig` | `refAllDecls` + perilaku: matchParam, registrasi route (kind + path tersimpan) |
| `tcp/http/static.zig` | `refAllDecls` + perilaku: mimeType, parseRangeHeader |
| `tcp/http/upload.zig` | `refAllDecls` + perilaku: MultipartParser parse + getField |
| `tcp/http/websocket.zig` | `refAllDecls` + perilaku: vektor RFC acceptKey, round-trip buildFrame + parseFrame, frame bermasker |
| `tcp/http/context.zig` | `refAllDecls` + perilaku: `timedOut` dengan deadline null menghasilkan false, `isExpired` dengan deadline null menghasilkan false |

### zix.Udp

| Modul | Cakupan |
| :- | :- |
| `udp/config.zig` | `refAllDecls` + default: `UdpServerConfig`, `UdpClientConfig`, nilai backing enum `PortMode` dan `Endianness` |
| `udp/packet.zig` | `refAllDecls` + perilaku: NATIVE tanpa operasi, array u8 tidak ditukar, round-trip LITTLE/BIG, non-native menukar elemen integer dan float array, semua varian `FeedbackResult` |
| `udp/server.zig` | `refAllDecls` + perilaku: port nol menghasilkan `error.PortNotConfigured`, port bukan-nol berhasil, field konfigurasi tersimpan |
| `udp/client.zig` | `refAllDecls` |

### zix.Uds

| Modul | Cakupan |
| :- | :- |
| `uds/config.zig` | `refAllDecls` + default: `UdsServerConfig` (backlog=128, max_msg_len=4096), `UdsClientConfig` |
| `uds/server.zig` | `refAllDecls` + perilaku: path kosong menghasilkan `error.PathEmpty`, path valid berhasil dan deinit aman |
| `uds/client.zig` | `refAllDecls` |

### zix.Http.Client

| Modul | Cakupan |
| :- | :- |
| `tcp/http/client_config.zig` | `refAllDecls` + default: `HttpClientConfig` (connect_timeout_ms=0, response_timeout_ms=0, read_timeout_ms=0, max_response_body=4MB, follow_redirects=true, max_redirects=3, user_agent=`zon_options.user_agent`) |
| `tcp/http/client.zig` | `refAllDecls` |

### zix.Channel

| Modul | Cakupan |
| :- | :- |
| `channel/channel.zig` | `refAllDecls` + perilaku: kapasitas dan jumlah init `Channel(u32)`, aritmetika tail ring buffer |

### zix.Fix

| Modul | Cakupan |
| :- | :- |
| `tcp/fix/config.zig` | `refAllDecls` + perilaku: field wajib `FixServerConfig` (ip, port, comp_id), dispatch_model default ASYNC, workers/pool_size default 0, kernel_backlog default 1024, heartbeat_timeout_ms default 0; field wajib `FixClientConfig` (ip, port, comp_id, target_comp_id) |
| `tcp/fix/core.zig` | `refAllDecls` + perilaku: round-trip `parseFields`, pencarian `getField` dan kasus null, vektor `computeChecksum` yang diketahui, `verifyChecksum` valid/terpotong/salah, `findMessageEnd` lengkap/parsial/tanpa-terminator, `buildMessage` menghasilkan checksum valid |
| `tcp/fix/server.zig` | `refAllDecls` + perilaku: port nol menghasilkan `error.PortNotConfigured`, konfigurasi valid berhasil, deinit aman |
| `tcp/fix/client.zig` | `refAllDecls` + perilaku: `FixClient.connect` port nol menghasilkan `error.PortNotConfigured` |

### zix.Http2

| Modul | Cakupan |
| :- | :- |
| `tcp/http2/frame.zig` | `refAllDecls` + perilaku: `FT_HEADERS=0x01`, `FLAG_END_STREAM=0x01`, `ERR_NO_ERROR=0`, round-trip `writeFrameHeader`/`readFrameHeader` melalui pipe, PREFACE dimulai dengan `PRI`, `sendSettings` menulis frame SETTINGS 9-byte valid melalui pipe |
| `tcp/http2/hpack.zig` | `refAllDecls` + perilaku: round-trip encode/decode Huffman, `HpackEncoder.writeHeader` menghasilkan entri terindeks dari static table, `HpackDecoder.decode` mendekode `:method GET` terindeks, eviksi dynamic table menghormati max_size, indeks `HPACK_STATIC` ke-8 adalah `:status 200` |
| `tcp/http2/core.zig` | `refAllDecls` + perilaku: default struct `ServeOpts`, `HandlerFn` adalah tipe function pointer |
| `tcp/http2/config.zig` | `refAllDecls` + perilaku: field wajib `Http2ServerConfig` berhasil dikompilasi, dispatch_model default ASYNC, workers/pool_size default 0, max_streams=16 dan max_frame_size=16384 |
| `tcp/http2/server.zig` | `refAllDecls` + perilaku: port nol menghasilkan `error.PortNotConfigured`, konfigurasi valid berhasil dan deinit aman |

### zix.Grpc

| Modul | Cakupan |
| :- | :- |
| `tcp/http2/grpc/status.zig` | `refAllDecls` + perilaku: OK=0, CANCELLED=1, UNIMPLEMENTED=12, UNAUTHENTICATED=16 |
| `tcp/http2/grpc/frame.zig` | `refAllDecls` + perilaku: round-trip `readGrpcPrefix` / `writeGrpcPrefix`, flag compress tersimpan, panjang pesan tersimpan |
| `tcp/http2/grpc/proto.zig` | `refAllDecls` + perilaku: round-trip `encodeVarint` / `decodeVarint`, `encodeString` menghasilkan wire type LEN, `encodeInt32` menghasilkan wire type VARINT, round-trip `encodeDouble` / `decodeDouble` (nilai positif dan negatif), `MessageReader` mengiterasi semua field |
| `tcp/http2/grpc/timeout.zig` | `refAllDecls` + perilaku: satuan H/M/S/m/u/n dikonversi dengan benar, karakter tunggal menghasilkan null, kosong menghasilkan null |
| `tcp/http2/grpc/core.zig` | `refAllDecls` + perilaku: `parsePath` input valid dan tidak valid, `detectContentType` proto/json/tidak diketahui, `GrpcContext.recvMessage` body kosong menghasilkan null, `Route.timeout_ms` default nol, `GrpcContext.isExpired` deadline null/lampau/mendatang, `GrpcServeOpts.handler_timeout_ms` default nol, Router mendispatch ke handler yang cocok |
| `tcp/http2/grpc/config.zig` | `refAllDecls` + perilaku: field wajib dan default `GrpcServerConfig` (handler_timeout_ms=0), field wajib `GrpcClientConfig` |
| `tcp/http2/grpc/server.zig` | `refAllDecls` + perilaku: port nol menghasilkan `error.PortNotConfigured`, konfigurasi valid berhasil, deinit aman |
| `tcp/http2/grpc/client.zig` | `refAllDecls` + perilaku: `GrpcClient.connect` port nol menghasilkan `error.PortNotConfigured` |

### zix.Logger

| Modul | Cakupan |
| :- | :- |
| `logger/logger.zig` | `refAllDecls` + perilaku: init dan deinit tanpa save_path, system() di bawah save_min_level tidak menghasilkan output, access() di bawah save_min_level tidak menghasilkan output, pemetaan statusLevel (100=DEBUG 200=INFO 301=INFO 404=WARN 500=ERROR), conn/packet/frame/session/rpc di bawah save_min_level tidak menghasilkan output |

### zix.Utils

| Modul | Cakupan |
| :- | :- |
| `utils/file.zig` | `refAllDecls` + perilaku: extension, save |

---

## Pengujian Integrasi

Sumber: `tests/integration/`. Setiap berkas adalah executable pengujian mandiri yang dikompilasi dengan modul `zix` yang diimpor. Pengujian ini menguji komponen yang dihubungkan terhadap input tiruan, tanpa socket aktif, tanpa scheduler `std.Io`.

### tests/integration/tcp/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `TcpServer.init` konfigurasi valid | init dengan ip dan port nyata berhasil, deinit aman |
| `TcpServer.init` dispatch model EPOLL | init dengan dispatch model `.EPOLL` berhasil, deinit aman |
| `TcpServer.init` port nol | menghasilkan `error.PortNotConfigured` |
| Pemeriksaan tipe `HandlerFn` | `zix.Tcp.echoHandler` memenuhi `zix.Tcp.HandlerFn` |
| `TcpClient.connect` port nol | menghasilkan `error.PortNotConfigured` sebelum pemanggilan socket apa pun |

### tests/integration/http/

#### `request_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `pathParam()` satu param | segmen yang ditangkap dikembalikan berdasarkan nama (nama tidak ada menghasilkan null) |
| `pathParam()` nama dengan tanda hubung | `:tenant-id`, `:tenant-branch` (pola contoh http_paths) |
| `body()` chunk tunggal chunked didekode dengan benar | `"5\r\nhello\r\n0\r\n\r\n"` -> `"hello"` |
| `body()` beberapa chunk chunked dirakit | `"3\r\nfoo\r\n4\r\nbarr\r\n0\r\n\r\n"` -> `"foobarr"` |
| `body()` body chunked kosong menghasilkan string kosong | hanya chunk terminal -> `""` |
| `body()` mengembalikan body_cache tanpa menyentuh reader | `body_cache` yang sudah diset mempersingkat pembacaan; panggilan kedua mengembalikan pointer yang sama |

#### `router_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Pencocokan tepat | `dispatch` menghasilkan true, handler yang benar dipanggil |
| Param mengisi `path_params` | `req.path_params` diset setelah dispatch param. `req.pathParam()` mengembalikan nilainya. |
| Dua path param keduanya terisi | route multi-param menangkap kedua segmen |
| Prefix mengarah ke handler | pencocokan prefix menghasilkan true dan memanggil handler |

#### `context_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Penentuan waktu `withTimeout` / `withDeadline` | anggaran 60 detik belum habis. Anggaran 10ms terlampaui setelah sleep 50ms. |

#### `header_index_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Indeks kosong menghasilkan null | tidak ada header yang diindeks (semua pencarian menghasilkan null) |
| Pencarian case-insensitive | map yang sudah diisi: `Content-Type` ditemukan melalui `content-type` |

#### `sse_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Format wire `SseWriter.writeEvent` | `"data: ping\n\n"` melalui `std.Io.Writer.fixed` buffer |
| Format wire `SseWriter.writeNamedEvent` | `"event: update\ndata: 99\n\n"` |
| Format wire `SseWriter.comment` | `": keepalive\n"` |

### tests/integration/websocket/

#### `websocket_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `parseFrame` opcode binary | round-trip FIN, opcode, payload |
| `parseFrame` ping dengan payload | opcode, konten payload |
| `parseFrame` opcode pong | opcode |
| `parseFrame` close dengan payload kosong | opcode, payload panjang nol |
| Round-trip semua opcode | buildFrame -> parseFrame untuk text, binary, ping, pong, close |
| Init / deinit `RoomMap` | tanpa koneksi (tanpa crash atau leak) |

### tests/integration/udp/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `UdpServer.init` konfigurasi valid | init dengan ip dan port nyata berhasil |
| `UdpServer.init` port nol | menghasilkan `error.PortNotConfigured` |
| `UdpClient.init` bind_port nol | menghasilkan `error.PortNotConfigured` sebelum pemanggilan socket apa pun |

#### `packet_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Round-trip LITTLE | `toEndian` -> `fromEndian` memulihkan byte asli |
| Round-trip BIG | sama untuk endian BIG |
| Nilai `FeedbackResult.packet` | varian `.packet` menyimpan dan mengembalikan packet lengkap |

### tests/integration/http/ (client)

#### `client_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `HttpClient.init` dan `deinit` | tanpa request: init + deinit aman dengan io Threaded |
| `ClientResponse.header()` pada byte head tiruan | pencarian berdasarkan nama dan pencarian case-insensitive |
| `ClientResponse.iterateHeaders()` | menghitung semua header dari byte head mentah |
| Default `ClientRequestOpts` | `headers` kosong, `body` null, `connect_timeout_ms` null |

### tests/integration/uds/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `UdsServer.init` path valid | berhasil dan `deinit` aman |
| Pemeriksaan tipe `HandlerFn` | `zix.Uds.echoHandler` memenuhi `zix.Uds.HandlerFn` |

### tests/integration/logger/

#### `logger_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `Logger.system()` menulis baris ke berkas | tag `[component]` dan teks pesan muncul di berkas log |
| `Logger.access()` menulis baris ke berkas | method, path, status, bytes semuanya muncul di berkas log |
| UA dan origin yang tidak ada dicatat sebagai strip | argumen `""` kosong menghasilkan `"-"` di field yang dikutip |
| UA yang ada muncul di berkas | string UA tidak kosong ditulis apa adanya |
| Status 5xx dipetakan ke level ERROR | `access()` dengan status 500 menulis label `ERROR` |
| Argumen `anyerror` diformat dengan benar | format `{}` dari nilai error menghasilkan nama error |

### tests/integration/fix/

#### `server_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `FixServer` init dan deinit tidak error | konfigurasi valid berhasil, deinit aman |
| `FixServer` init port nol | menghasilkan `error.PortNotConfigured` |
| Handshake Logon dan round-trip echo berhasil | kirim Logon, terima balasan Logon dengan MsgType=A; kirim NewOrderSingle, terima echo; kirim Logout, terima balasan Logout |
| Beberapa pesan berurutan semuanya di-echo | tiga pesan NewOrderSingle di-echo dengan ClOrdID tersimpan di semua |

### tests/integration/http2/

#### `server_test.zig`

Port: 18082-18085.

| Pengujian | Yang diverifikasi |
| :- | :- |
| `Http2Server.init` dan deinit tidak error | konfigurasi valid berhasil, deinit aman |
| `Http2Server.init` port nol | menghasilkan `error.PortNotConfigured` |
| Tipe `Http2 HandlerFn` adalah function pointer | penugasan `zix.Http2.HandlerFn` berhasil dikompilasi |
| Http2 GET / mengembalikan Hello World melalui h2c direct | round-trip h2c preface PRI + HEADERS + DATA mengembalikan body response |
| Http2 POST /echo mengembalikan body request | POST dengan frame DATA body; server meng-echo body kembali |
| Http2 dua stream berurutan pada koneksi yang sama | stream ID 1 dan 3 masing-masing menerima response yang benar |
| Http2 h2c upgrade GET / mengembalikan Hello World | HTTP/1.1 `Upgrade: h2c` -> 101 Switching Protocols -> response h2c |

### tests/integration/grpc/

#### `server_test.zig`

Port: 18200-18204.

| Pengujian | Yang diverifikasi |
| :- | :- |
| `GrpcServer.init` dan deinit tidak error | konfigurasi valid berhasil, deinit aman |
| `GrpcServer.init` port nol | menghasilkan `error.PortNotConfigured` |
| gRPC unary mengembalikan salam | `greetHandler` membaca satu pesan, membalas `"Hello, world!"` |
| gRPC server streaming mengirim beberapa response | `echoHandler` mengirim dua pesan; client menerima keduanya berurutan |
| gRPC client streaming mengumpulkan semua pesan | `collectHandler` menyangga tiga pesan, membalas dengan jumlah `"got 3"` |
| gRPC bidirectional meng-echo setiap pesan | `echoHandler` meng-echo `"ping"` lalu `"pong"` dari dua pesan client |
| gRPC method tidak dikenal mengembalikan UNIMPLEMENTED | `dispatchHandler` membalas dengan `GrpcStatus.UNIMPLEMENTED` untuk path tidak dikenal |

### tests/integration/channel/

#### `channel_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Kapasitas init `Channel(u32)` | `buf.len == 8`, `count == 0`, `head == 0` |
| `Channel([]const u8)` berhasil dikompilasi | tipe elemen slice diterima |
| `Channel(struct)` berhasil dikompilasi | tipe elemen struct diterima |
| Round-trip send dan recv `Channel(u32)` | send lalu recv mengembalikan nilai yang dikirim |
| `Channel(u32)` drain setelah close | kirim dua item, close, recv keduanya, recv ketiga menghasilkan `error.Closed` |

---

## Pengujian Perilaku

Sumber: `tests/behaviour/`. Setiap berkas memverifikasi kontrak API yang dapat diamati yang diandalkan oleh pemanggil: properti "apa yang selalu dilakukan ini".

### tests/behaviour/tcp/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Default dispatch_model `TcpServerConfig` | `.POOL` (nilai nol) |
| Default kernel_backlog `TcpServerConfig` | 4096 |
| Default max_msg_len `TcpServerConfig` | 4096 |
| Default workers `TcpServerConfig` | 0 (otomatis) |
| Default pool_size `TcpServerConfig` | 0 (otomatis) |
| Default max_msg_len `TcpClientConfig` | 4096 |
| Header panjang frame TCP | u32 big-endian 4-byte di-encode dan di-decode dengan benar |
| Payload panjang nol frame TCP | di-encode sebagai empat byte nol |
| Ukuran header frame TCP | selalu tepat 4 byte |
| `DispatchModel.POOL` adalah nilai nol | `@intFromEnum(.POOL) == 0` |

### tests/behaviour/http/

#### `request_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `path()` menghapus query string | `"/api/users?limit=10"` -> `"/api/users"` |
| `path()` mengembalikan target penuh jika tidak ada `?` | `"/api/users/alice"` tidak berubah |
| `path()` root path | `"/"` mengembalikan `"/"` |
| `query()` mengembalikan bagian setelah `?` | `"q=hello&lang=zig"` |
| `query()` mengembalikan kosong jika tidak ada `?` | `""` |
| `body()` chunked menghasilkan payload sama dengan Content-Length | chunked `"world"` cocok dengan `body_cache = "world"` |
| `body()` panggilan kedua mengembalikan hasil yang di-cache | `b1.ptr == b2.ptr` setelah dua pemanggilan body() |
| `method()` menyelesaikan setiap method | DELETE/PATCH/PUT/OPTIONS/HEAD/GET/POST semuanya diselesaikan |

#### `router_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Exact mengalahkan param terlepas dari urutan registrasi | exact yang didaftarkan setelah param tetap menang |
| Param mengalahkan prefix terlepas dari urutan registrasi | param yang didaftarkan setelah prefix tetap menang |
| Prefix: pencocokan terpanjang menang | `/api/users` mengalahkan `/api` untuk `/api/users/alice` |
| Prefix mencocokkan path-nya sendiri secara tepat | `/api` cocok dengan `/api` |
| Query string transparan untuk dispatch param | `"/users/bob?role=admin"` menangkap `bob` melalui `:id` |
| Query string transparan untuk dispatch exact | `"/about?ref=menu"` cocok dengan `/about` |

#### `content_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Ekstensi grup teks | html/htm/css/txt/csv |
| Ekstensi grup aplikasi | json/map/js/min.js/xml/pdf/wasm/zip/gz/tar/7z/rar/rtf |
| Ekstensi grup gambar | png/jpg/jpeg/gif/svg/webp/ico |
| Ekstensi grup audio | mp3/wav/flac/mid/midi |
| Ekstensi grup video | mp4/webm/ogg/mpeg/avi/mov/wmv/flv/mkv |
| Ekstensi grup font | ttf/otf/woff/woff2 |
| Pencocokan case-insensitive | HTML, PNG, JS, JSON, JPG, JPEG, CSS, WOFF2 |
| `fromExtension()` mengembalikan string MIME yang benar | kumpulan representatif |
| Pasangan alias menghasilkan string MIME identik | jpg==jpeg, mid==midi, html==htm, js==min.js, json==map |

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Default ukuran buffer | `max_kernel_backlog`, `max_client_request`, `max_allocator_size`, `max_client_response` semuanya 4096 |
| Default timeout dinonaktifkan | `conn_timeout_ms == 0`, `handler_timeout_ms == 0` |
| Penyajian static dinonaktifkan secara default | `public_dir == ""`, `public_dir_upload == "u"` |
| `dispatch_model` default ke `.POOL` | nilai enum sama dengan 0 |
| Default worker pool ukuran otomatis | `workers == 0`, `pool_size == 0` |
| `max_request_headers` default ke `.LARGE` | varian enum dan `.value()` == 64 |
| Nilai tier `RequestHeaderSize` | MINIMAL=16, COMMON=32, LARGE=64 |
| `RequestHeaderSize.CUSTOM(N)` dibatasi di 64 | nilai di atas 64 diam-diam mengembalikan 64 |
| `max_response_headers` default ke COMMON (32) | nilai enum dan `.value()` |
| Nilai tier `HeaderSize` | MINIMAL=16, COMMON=32, LARGE=64, EXTRA_LARGE=128 |
| `HeaderSize.CUSTOM(N)` mengembalikan N | 7 dan 100 |
| Status `Response` default ke OK | invarian `init()` |

#### `sse_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `ContentType.TEXT_EVENT_STREAM.asString()` | mengembalikan `"text/event-stream"` |
| `Response.streaming` default ke false | invarian `init()` |

### tests/behaviour/websocket/

#### `websocket_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Bit FIN selalu diset | byte[0] & 0x80 untuk text, binary, ping, pong, close |
| Frame server tidak bermasker | byte[1] & 0x80 == 0 untuk semua opcode (RFC 6455 5.1) |

### tests/behaviour/udp/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `UdpServerConfig` disconnect_timeout_ms | default 5000 |
| `UdpServerConfig` poll_timeout_ms | default 2000 |
| `UdpServerConfig` auto_ack | default false |
| `UdpServerConfig` broadcast | default false |
| `UdpServerConfig` endianness | default LITTLE |
| `UdpServerConfig` port_mode | default REQUIRED |
| `UdpClientConfig` send_once | default false |
| `UdpClientConfig` send_every | default 99 |
| `UdpClientConfig` endianness | default LITTLE |

#### `packet_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `toEndian` NATIVE adalah operasi tanpa efek | byte tidak berubah pada host apa pun |
| Field array u8 tidak pernah ditukar | `id [4]u8` tidak disentuh oleh LITTLE dan BIG |
| Non-native menukar field integer | field `i32` di-byte-swap |
| Non-native menukar elemen float array | elemen `[2]f64` masing-masing ditukar |

### tests/behaviour/http/ (client)

#### `client_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Default timeout connect/response/read `ClientConfig` | semuanya 0 (dinonaktifkan) |
| Default max_response_body `ClientConfig` | 4 MB (1024 * 1024 * 4) |
| Default follow_redirects `ClientConfig` | true |
| Default max_redirects `ClientConfig` | 3 |
| Default user_agent `ClientConfig` | cocok dengan `zix.Http.default_user_agent` (string versi library dari `build.zig.zon`) |
| `ClientResponse.status()` | mengembalikan field status_code |
| `ClientResponse.body()` | mengembalikan slice body_data |
| `ClientResponse.header()` case-insensitive | cocok terlepas dari casing nama header |
| `ClientResponse.deinit()` body panjang nol | aman, tanpa crash atau leak |

### tests/behaviour/uds/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Default backlog `UdsServerConfig` | 128 |
| Default max_msg_len `UdsServerConfig` | 4096 |
| `UdsClientConfig` menyimpan path | field path tersimpan |
| Header panjang frame UDS | u32 little-endian 4-byte di-encode dan di-decode dengan benar |
| Payload panjang nol frame UDS | di-encode sebagai empat byte nol |
| Ukuran header frame UDS | selalu tepat 4 byte |

### tests/behaviour/fix/

#### `session_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Response Logon memiliki MsgType=A dan CompID ditukar | balasan tag-35="A", tag-49=SERVER, tag-56=CLIENT, tag-34=1 |
| Field body NewOrderSingle tersimpan dalam echo | tag-11 (ClOrdID), tag-55 (Symbol), tag-54 (Side), tag-38 (Qty) semuanya ada dalam echo |
| Logout bersih tidak menyebabkan error di sisi server | field error server adalah null setelah pertukaran Logout |

### tests/behaviour/logger/

#### `logger_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Nilai backing `Level` | DEBUG=0 INFO=1 WARN=2 ERROR=3 |
| Nilai backing `ConsoleMode` | OFF=0 DEBUG_ONLY=1 ALWAYS=2 |
| Default `Config` | console=OFF, console_min_level=INFO, save_path="", save_file="log", save_min_level=INFO, max_lines=1_000_000 |
| `Logger` init dan deinit tanpa save_path | tanpa crash atau leak |
| `Logger` flush tanpa save_path adalah operasi tanpa efek | tanpa crash |
| `Http.ServerConfig.logger` default ke null | invarian `cfg.logger == null` |
| `Http.Context.logger` default ke null | invarian `ctx.logger == null` |
| `Http.Response.bytes_written` default ke 0 | `res.bytes_written == 0` setelah `init()` |

### tests/behaviour/http2/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `Http2ServerConfig` dispatch_model default ke ASYNC | `.ASYNC` adalah default nilai-nol |
| `Http2ServerConfig` max_streams default ke 16 | invarian `max_streams == 16` |
| `Http2ServerConfig` max_frame_size default ke 16384 | invarian `max_frame_size == 16384` |
| `Http2` HandlerFn dapat ditugaskan ke variabel lokal | penugasan tipe `zix.Http2.HandlerFn` berhasil dikompilasi |
| Panjang `Http2` PREFACE adalah 24 | `zix.Http2.PREFACE.len == 24` |
| `Http2` ERR_NO_ERROR adalah nol | `zix.Http2.ERR_NO_ERROR == 0` |
| `Http2` FLAG_END_STREAM dan FLAG_END_HEADERS berbeda | `FLAG_END_STREAM != FLAG_END_HEADERS` |

### tests/behaviour/grpc/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Default `GrpcServerConfig` | dispatch_model=ASYNC, kernel_backlog=1024, workers=0, pool_size=0, max_streams=16, max_frame_size=16384, max_body=65536 |
| Field dasar `GrpcClientConfig` | field ip dan port tersimpan |
| Nilai enum `GrpcStatus` | OK=0, CANCELLED=1, UNIMPLEMENTED=12, UNAUTHENTICATED=16 |
| `GrpcContext.recvMessage` body kosong | menghasilkan null segera |
| Round-trip `GrpcPrefix` | writePrefix -> readPrefix mempertahankan flag compress dan panjang pesan |
| `parsePath` path valid | `/helloworld.Greeter/SayHello` -> `package_service="helloworld.Greeter"`, `method="SayHello"` |
| `parseTimeout` detik | `"2S"` -> 2.000.000.000 nanodetik |

### tests/behaviour/channel/

#### `channel_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Field `closed` default ke false | invarian `init()` |
| `head` dimulai dari nol | invarian `init()` |
| Rumus tail ring adalah `(head + count) % buf.len` | state yang diset secara manual memverifikasi aritmetika |
| `send` menaikkan count | count naik dari 0 ke 1 setelah satu send |
| `recv` menurunkan count | count kembali ke 0 setelah recv |
| `close` mengeset field closed | `ch.closed == true` setelah close |

---

## Pengujian Edge

Sumber: `tests/edge/`. Setiap berkas memverifikasi kondisi batas dan jalur error.

### tests/edge/tcp/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `TcpServer.init` port nol | menghasilkan `error.PortNotConfigured` |
| Nilai backing `DispatchModel` stabil | POOL=0, ASYNC=1, MIXED=2, EPOLL=3 |
| Panjang frame TCP maksimum u32 | `maxInt(u32)` di-encode dan di-decode dengan benar melalui big-endian |

### tests/edge/http/

#### `request_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `queryParam` key ada dengan nilai kosong | `"?k="` -> `""` (bukan null) |
| `queryParam` key tidak ada menghasilkan null | key tidak ada dalam query string |
| `queryParam` tidak ada query string sama sekali menghasilkan null | target tidak memiliki `?` |
| `body()` chunked hex tidak valid menghasilkan string kosong | ukuran chunk `"zz"` -> `""` (error dechunk -> 0 byte) |
| `body()` chunked chunk terminal yang hilang mengembalikan data parsial | tidak ada `0\r\n\r\n` -> data parsial dikembalikan |
| `body()` chunked chunk satu-byte | `1\r\na\r\n1\r\nb\r\n1\r\nc\r\n0\r\n\r\n` -> `"abc"` |

#### `router_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Tidak ada route yang terdaftar menghasilkan false | router kosong, `dispatch` menghasilkan false |
| Prefix `/api` TIDAK cocok dengan `/apiv2` | karakter berikutnya setelah prefix harus `/` atau akhir-path |

#### `response_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| CR dalam nama header menghasilkan `InvalidHeaderName` | penjaga injeksi |
| LF dalam nama header menghasilkan `InvalidHeaderName` | penjaga injeksi |
| CR dalam nilai header menghasilkan `InvalidHeaderValue` | penjaga injeksi |
| LF dalam nilai header menghasilkan `InvalidHeaderValue` | penjaga injeksi |
| Buffer tumbuh dari 4 ke 5 pada header ke-5 | kapasitas awal=4, pertumbuhan ke min(8, max_headers) |
| `max_headers=1` menolak header kedua | tanpa pertumbuhan: `TooManyHeaders` segera |
| `HeaderSize.CUSTOM(0).value()` | menghasilkan 0 |

#### `content_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Ekstensi tidak dikenal menghasilkan `APPLICATION_OCTET_STREAM` | xyz, bin, dat, unknown |
| String kosong menghasilkan `APPLICATION_OCTET_STREAM` | `typeFromExtension("")` |
| `fromExtension` tidak dikenal menghasilkan `"application/octet-stream"` | bentuk string dari fallback |

### tests/edge/websocket/

#### `websocket_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| 0 byte menghasilkan null | kurang dari 2 byte (tidak dapat membaca header) |
| 1 byte menghasilkan null | kurang dari 2 byte |
| Payload terpotong menghasilkan null | header menyatakan 5 byte tetapi hanya 3 yang ada |
| Panjang 16-bit extended (tier 126) | payload 130-byte: byte[1] membawa marker 126 |
| `acceptKey` key terlalu panjang menghasilkan `error.KeyTooLong` | key >= 93 byte melebihi hash_input 128-byte |

### tests/edge/udp/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Nilai backing `PortMode.CONFIGURABLE` | sama dengan 0 |
| Nilai backing `PortMode.REQUIRED` | sama dengan 1 |
| Port nol dengan mode `REQUIRED` | `UdpServer.init` menghasilkan `error.PortNotConfigured` |
| Port bukan-nol dengan mode `REQUIRED` | `UdpServer.init` berhasil |

#### `packet_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Nilai backing enum `Endianness` stabil | NATIVE=0, LITTLE=1, BIG=2 |
| `FeedbackResult` ack/nack hanya tag | tag aktif cocok dengan .ack dan .nack |

### tests/edge/http/ (client)

#### `client_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Skema tidak didukung menghasilkan `error.InvalidUrl` | skema `ftp://` tidak diterima |
| Host tidak ada menghasilkan `error.InvalidUrl` | `http://` tanpa host |
| URL tidak valid menghasilkan `error.InvalidUrl` | `:::bad` gagal saat parse |
| `ClientResponse.header()` nama tidak ada | menghasilkan null |
| Override `RequestOpts.connect_timeout_ms` | null, 0, dan bukan-nol adalah nilai yang berbeda |

### tests/edge/uds/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Path kosong menghasilkan `error.PathEmpty` | `UdsServer.init(.{ .path = "" })` menghasilkan PathEmpty |

### tests/edge/logger/

#### `logger_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Batas `statusLevel` 2xx | `access()` tidak crash untuk setiap kelas status (100-599) |
| Pengurutan enum `Level` | DEBUG < INFO < WARN < ERROR melalui `@intFromEnum` |
| `system()` di bawah `save_min_level` tidak menghasilkan output | pemanggilan di bawah ambang tidak membuka berkas (`file_fd == -1`) |
| `access()` di bawah `save_min_level` tidak menghasilkan output | sama: `file_fd == -1` setelah pemanggilan yang difilter |
| `system()` dengan component kosong tidak panic | `component = ""` aman |
| `system()` dengan format kosong tidak panic | `fmt = ""` aman |
| `access()` dengan method dan path kosong tidak panic | string kosong aman |
| `init` dengan `save_path` kosong, `file_fd` tetap tidak valid | `file_fd == -1` dengan `save_path = ""` |
| Console OFF: tidak ada output atau panic untuk semua level | keempat level tidak menghasilkan crash dengan `console = .OFF` |

### tests/edge/fix/

#### `session_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `parseFields` menangani jumlah field maksimum tanpa panic | `MAX_FIELDS - 1` pasang tag=value di-parse tanpa overflow atau crash |
| `verifyChecksum` menghasilkan false untuk pesan terpotong | pesan yang tidak memiliki delimiter checksum SOH akhir |
| `findMessageEnd` menghasilkan null untuk pesan dengan nilai tag-10 tetapi tanpa SOH akhir | field checksum parsial menghasilkan null |
| `buildMessage` dengan nol field extra menghasilkan pesan valid | output lolos `verifyChecksum` dan round-trip `parseFields` |
| Pesan yang datang dalam dua segmen TCP dirakit dengan benar | Logon terpecah di dua flush; server tetap membalas dengan MsgType=A |
| Checksum yang buruk menyebabkan server menutup tanpa propagasi error di sisi server | byte pesan yang rusak menutup koneksi; `ctx.err == null` |

### tests/edge/http2/

#### `server_test.zig`

Port: 18100.

| Pengujian | Yang diverifikasi |
| :- | :- |
| Preface PRI yang buruk menyebabkan server menutup koneksi | byte preface tidak valid -> server menutup koneksi dengan bersih |
| Client mengirim GOAWAY dan loop koneksi server keluar | frame GOAWAY -> server keluar dari frame loop tanpa error |
| `Http2Server.init` menolak port nol | menghasilkan `error.PortNotConfigured` |
| Dekode `HpackDecoder` dari blok kosong menghasilkan nol header | `decode(&.{}, ...)` menghasilkan 0 header tanpa error |
| `writeFrameHeader` bit tinggi stream_id dihapus saat dibaca | `stream_id = 0x7FFF_FFFF` di-roundtrip dengan benar melalui pipe |

### tests/edge/grpc/

#### `server_test.zig`

Port: 18220.

| Pengujian | Yang diverifikasi |
| :- | :- |
| `readGrpcPrefix` dengan 4 byte | menghasilkan `error.TooShort` |
| `readGrpcPrefix` dengan slice kosong | menghasilkan `error.TooShort` |
| `GrpcContext.recvMessage` body lebih pendek dari prefix | body memiliki 3 byte (butuh 5 untuk prefix): menghasilkan null |
| `GrpcContext.recvMessage` msg_len melebihi body | prefix mengklaim 100 byte tetapi body hanya memiliki 5: menghasilkan null |
| `parsePath` string kosong | menghasilkan null |
| `parsePath` tanpa slash awal | menghasilkan null |
| `parsePath` hanya slash | menghasilkan null |
| `detectContentType` tanpa header | menghasilkan UNKNOWN |
| `detectContentType` text/plain | menghasilkan UNKNOWN |
| `parseTimeout` karakter tunggal | menghasilkan null |
| `GrpcClient.connect` port nol | menghasilkan `error.PortNotConfigured` |
| `serveConn` menutup dengan bersih saat client langsung memutus koneksi | server menerima, client memutus koneksi segera; tanpa crash atau error |

### tests/edge/channel/

#### `channel_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Kapasitas 1 mengalokasikan tepat satu slot | `buf.len == 1`, `count == 0` |
| Head ring membungkus di `buf.len` | `(3+1) % 4 == 0` |
| Batas penuh: `count == buf.len` | indeks tail membungkus kembali ke head |
| `send` setelah close | menghasilkan `error.Closed` |
| `recv` pada channel tertutup yang kosong | menghasilkan `error.Closed` |

---

###### akhir pengujian
