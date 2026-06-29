# HLD: zix.Http1

Engine server HTTP/1.x ramping di atas raw fd I/O. Parsing request dan penulisan response tanpa alokasi pada buffer milik pemanggil, tanpa dependensi `std.http`.

---

## Tujuan

- Nol alokasi heap pada hot path: parse dan write beroperasi pada buffer stack atau buffer yang dialokasikan di muka.
- Tanpa objek request/response: handler menerima head hasil parse plus slice body, lalu menulis langsung ke fd melalui write helper.
- Comptime untuk semuanya: handler dibakukan ke dalam tipe server, tabel route dipartisi saat kompilasi.
- Raw `std.posix` I/O pada jalur data: `std.Io` hanya dipakai untuk plumbing listen/accept.
- Permukaan API minimal: satu signature handler, sekumpulan kecil write helper, dan router comptime yang opsional.

---

## Posisi: zix.Http1 vs zix.Http

Keduanya server HTTP/1.1. `zix.Http` adalah lapisan berfitur lengkap, `zix.Http1` adalah engine ramping.

| Aspek | `zix.Http` | `zix.Http1` |
| :- | :- | :- |
| Signature handler | `fn(*Request, *Response, *Context) !void` | `fn(*const ParsedHead, []const u8, fd) void` |
| Parsing request | `std.http.Server` | `parseHead` zero-copy milik sendiri |
| Allocator per-request | arena per-connection | tidak ada (buffer milik pemanggil) |
| Penulisan response | objek `Response` ter-buffer | write helper langsung ke fd |
| Static files / multipart / SSE writer | built in | tidak built in (handler merangkai dari helper) |
| Routing | tabel route comptime | tabel route comptime (opsional, handler boleh polos) |
| WebSocket | frame loop milik handler | frame pump milik engine (.EPOLL) |
| Model dispatch | ASYNC, POOL, MIXED, EPOLL, URING | ASYNC, POOL, MIXED, EPOLL, URING |

Pakai `zix.Http` saat handler membutuhkan allocator, static file serving, atau API request/response yang lebih kaya. Pakai `zix.Http1` saat raw throughput dan biaya per-request yang terprediksi lebih penting daripada kenyamanan.

---

## Model Runtime

Lima model dispatch, dipilih melalui `config.dispatch_model` (enum `DispatchModel`). Wajib: pemanggil harus menyetelnya secara eksplisit (tidak ada default).

### .ASYNC: Accept Tunggal, Dispatch io.async()

```mermaid
flowchart TD
    MAIN["main()\nServer.run()"] --> ACC["srv.accept(io)\nsuspends until TCP connection"]
    ACC --> DISP["io.async(connEntry)"]
    DISP --> ACC
    DISP --> CONN["connEntry()\nextract raw fd"]
    CONN --> SERVE["core.serveConn(fd, handler, opts)"]
    SERVE --> LOOP["keep-alive loop\nrecvHead -> parseHead -> handler"]
    LOOP --> LOOP
    LOOP -->|close or error| Z["stream.close()"]
```

- Satu accept thread, setiap koneksi di-dispatch sebagai task konkuren melalui `io.async()`.
- `workers` dan `pool_size` diabaikan.

### .POOL: Work-Queue Thread Pool

```mermaid
flowchart TD
    MAIN["main()\nServer.run()"] --> SPAWN["spawn pool_size pool threads\nspawn worker_count accept threads"]
    SPAWN --> ACC["Accept thread\nlisten SO_REUSEPORT\naccept -> queue.push(stream)"]
    SPAWN --> POOL["Pool thread\nqueue.pop()"]
    ACC --> ACC
    POOL --> SERVE["core.serveConn(fd, handler, opts)"]
    SERVE --> LOOP["keep-alive loop\nrecvHead -> parseHead -> handler"]
    LOOP -->|close or error| Z["stream.close()\nback to queue.pop()"]
```

- Accept thread hanya mendorong stream hasil accept ke `ConnQueue` (ring buffer) yang dipakai bersama.
- Pool thread mengambil dan melayani setiap koneksi secara sinkron.
- Default: cpu_count accept thread, `max(10, cpu_count * 2)` pool thread.

### .MIXED: N Accept Thread, Dispatch io.async()

- N accept thread (default cpu_count, `SO_REUSEPORT`), masing-masing men-dispatch koneksi langsung melalui `io.async()`, tanpa `ConnQueue`.
- `pool_size` diabaikan. `workers` mengontrol jumlah accept thread.

### .EPOLL: Event Loop Shared-Nothing (khusus Linux)

```mermaid
flowchart TD
    MAIN["main()\nServer.run()"] --> SPAWN["spawn worker_count epollWorker threads"]
    SPAWN --> W["epollWorker\nprivate SO_REUSEPORT listener\nprivate epoll instance\nprivate ConnTable"]
    W --> WAIT["epoll_wait"]
    WAIT --> EV{"event fd?"}
    EV -->|listener| ACCEPT["acceptAll\naccept4 NONBLOCK to EAGAIN\nregister conn in epoll + table"]
    EV -->|draining oversize body| DRAIN["serveEpollDrain\nMSG_TRUNC discard"]
    EV -->|websocket conn| WS["serveEpollWs\nws.pump frames"]
    EV -->|http conn| HTTP["serveEpollConn\nread to EAGAIN\nparse + dispatch every\ncomplete pipelined request\ncoalesce responses, one write"]
    ACCEPT --> WAIT
    DRAIN --> WAIT
    WS --> WAIT
    HTTP --> WAIT
```

- Setiap worker memiliki listener pribadi, instance epoll pribadi, dan connection table pribadi. Kernel menyeimbangkan koneksi baru di antara listener per-worker (`SO_REUSEPORT`), sehingga tidak ada accept thread, tidak ada queue bersama, dan tidak ada perpindahan fd antar thread.
- Request pipelined yang tiba dalam satu readable event semuanya di-parse dan di-dispatch dalam satu pass, dan response-nya digabung menjadi satu `write()` melalui response sink per-event.
- Pada target non-Linux `.EPOLL` jatuh kembali ke `.POOL` dengan notice yang dicatat di log.
- Ini satu-satunya model yang menghormati promosi WebSocket milik engine (lihat bagian WebSocket).

### .URING: Event Loop io_uring Shared-Nothing (khusus Linux)

`zix.Http1` adalah engine referensi untuk jalur io_uring (ADR-037). Topologi shared-nothing, thread-per-core yang sama dengan `.EPOLL` (listener `SO_REUSEPORT` pribadi dan satu ring per worker), tetapi completion-based: accept, recv, send, dan close disubmit sebagai SQE dan dipanen sebagai CQE, sehingga sebagian besar transisi syscall di-batch ke dalam ring. Pump WebSocket juga berjalan native di ring (BufferGroup). Di non-Linux melipat ke `.POOL`. Di loopback setara `.EPOLL` pada throughput dan menang terutama pada cache locality per-request.

Teardown juga me-ring close-nya (`prep_close`, ADR-041) alih-alih `linux.close` sinkron, jadi worker terus memanen completion lintas teardown koneksi. Di mesin 64-core inilah pembedanya di bawah connection churn: dengan close sinkron ring nyaris tidak mengaktifkan core-nya di bawah reconnect storm, dengan ring close ia mengisinya dan mencapai paritas atau lebih baik di setiap cell dengan memori jauh lebih sedikit. `OpKind` io_uring bersama dan helper ring berada di `src/multiplexers/ring.zig`. Lihat ADR-041 untuk pengukurannya.

---

## Struktur Berkas

```mermaid
graph TD
    zix["src/lib.zig\npublic API root"] --> Http1["tcp/http1/Http1.zig\nzix.Http1 namespace"]

    Http1 --> core["core.zig\nparseHead + serveConn\nwrite helpers + RespSink"]
    Http1 --> server["server.zig\nServer + 5 dispatch models\nEPOLL + URING engines"]
    Http1 --> config["config.zig\nHttp1ServerConfig"]
    Http1 --> router["router.zig\ncomptime Router + pathParam"]
    Http1 --> websocket["websocket.zig\nRFC 6455 codec + pump"]

    server --> core
    server --> websocket
    router --> core
    websocket --> core
```

---

## API Publik

Diakses melalui `const zix = @import("zix");`

| Simbol | Tipe | Deskripsi |
| :- | :- | :- |
| `zix.Http1.Server` | struct | `init(comptime handler, config)` mengembalikan server, lalu `run()` / `deinit()` |
| `zix.Http1.Server.initRaw` | fn | `initRaw(comptime raw, config)`: mendaftarkan `RawFn` yang memiliki fd koneksi secara langsung |
| `zix.Http1.ServerConfig` | struct | Konfigurasi server (lihat bagian Http1ServerConfig) |
| `zix.Http1.DispatchModel` | enum(u8) | `.ASYNC`(0) `.POOL`(1) `.MIXED`(2) `.EPOLL`(3, native hanya di Linux) `.URING`(4, native hanya di Linux) |
| `zix.Http1.HandlerFn` | type | `*const fn(head: *const ParsedHead, body: []const u8, fd: std.posix.fd_t) void` |
| `zix.Http1.RawFn` | type | Handler raw yang diberi fd dan head hasil parse, memiliki wire langsung (framing kustom, streaming) |
| `zix.Http1.ParsedHead` | struct | Head request hasil parse zero-copy (method, path, query, raw_headers, flags) |
| `zix.Http1.Range` | struct | `{ start: u64, end: u64 }` dari `parseRange` |
| `zix.Http1.ServeOpts` | struct | Opsi `serveConn`: `nodelay`, `handler_timeout_ms` |
| `zix.Http1.ConnOutcome` | enum | `.keep_alive` atau `.close` (hasil one-shot EPOLL) |
| `zix.Http1.Route` | struct | `{ path, handler, kind = .EXACT }` |
| `zix.Http1.RouteKind` | enum(u8) | `.EXACT` `.PREFIX` `.PARAM` |
| `zix.Http1.Router` | fn | `Router(comptime routes) type`, mengekspos `dispatch` yang dapat dipakai sebagai HandlerFn |
| `zix.Http1.PathParam` | struct | Satu `:param` yang tertangkap (name, value) |
| `zix.Http1.pathParam` | fn | Mencari param yang tertangkap dari dalam handler |
| `zix.Http1.WebSocket` | namespace | Codec RFC 6455: `parseFrame` / `buildFrame` / `acceptKey` / `upgrade` / `send` / `serve` / `pump` |
| `zix.Http1.WsFrameFn` | type | Callback per-frame untuk WebSocket milik engine |
| `zix.Http1.setTimeout` | fn | Memasang atau memperpendek deadline per-handler (thread-local) |
| `zix.Http1.isExpired` | fn | Apakah deadline handler saat ini sudah lewat |
| `zix.Http1.parseHead` | fn | Parse head request lengkap dari buffer (zero copy) |
| `zix.Http1.getHeader` | fn | Pencarian header case-insensitive pada ParsedHead |
| `zix.Http1.queryParam` | fn | Pemindaian linear satu query parameter berdasarkan nama persis |
| `zix.Http1.percentDecode` | fn | Percent-decode buffer secara in place |
| `zix.Http1.parseRange` | fn | Parse `bytes=start-end` menjadi `Range` |
| `zix.Http1.fdWriteAll` | fn | Menulis semua byte ke fd (sadar sink, menangani EINTR/EAGAIN) |
| `zix.Http1.flushPending` | fn | Flush byte response yang masih tertahan sebelum raw fd write (urutan pipelining) |
| `zix.Http1.beginStream` | fn | Memulai response streaming (SSE), melepas sink jadi write flush per event (cleartext + TLS) |
| `zix.Http1.writeSimple` | fn | Response lengkap dengan body Content-Length |
| `zix.Http1.writeSimpleNoBody` | fn | Response headers saja (method HEAD) |
| `zix.Http1.writeJson` | fn | Singkatan `writeSimple` dengan `application/json` |
| `zix.Http1.writeGzip` | fn | Response terkompresi gzip via `std.compress.flate` |
| `zix.Http1.writeChunkedStart` | fn | Memulai response `Transfer-Encoding: chunked` |
| `zix.Http1.writeChunk` | fn | Menulis satu chunk |
| `zix.Http1.writeChunkedEnd` | fn | Mengakhiri body chunked |
| `zix.Http1.writeRange` | fn | 206 Partial Content atau 416 berdasarkan nilai header Range |
| `zix.Http1.write100Continue` | fn | Mengirim `100 Continue` sebelum membaca body besar |

---

## Http1ServerConfig

```zig
pub const Http1ServerConfig = struct {
    io:                 std.Io,                // dari process.io, hanya plumbing listen/accept
    ip:                 []const u8,
    port:               u16,                   // harus non-zero
    dispatch_model:     DispatchModel,
    kernel_backlog:     u31   = 1024,          // backlog listen() TCP
    max_recv_buf:       usize = 16 * 1024,     // buffer per-connection (.EPOLL saja, lihat catatan)
    large_body_rcvbuf:  usize = 256 * 1024,    // SO_RCVBUF khusus jalur body besar (upload), 0 = default kernel
    ws_recv_buf:        usize = 0,             // buffer WebSocket (.EPOLL recv, .URING frame-accumulation), 0 = max_recv_buf
    compression:          bool  = false,        // enable negosiasi gzip / deflate / brotli, opt-in via core.writeNegotiated (.EPOLL/.URING)
    compression_min_size: usize = 256,           // lewati body di bawah floor ini
    compression_max_out:  usize = 256 * 1024,    // cap output terkompresi codec-agnostic, dulu max_gzip_out
    max_headers:        u8    = 16,            // no-op, dipertahankan untuk kompatibilitas sumber
    workers:            usize = 0,             // 0 = cpu_count accept thread, diabaikan .ASYNC
    pool_size:          usize = 0,             // 0 = max(10, cpu_count * 2), .POOL saja
    handler_timeout_ms: u32   = 0,             // budget per-handler, 0 = nonaktif
    send_date_header:   bool  = true,          // kirim header Date, false hemat 37 byte/response
    tls:                ?*Tls.Context = null,  // non-null menyajikan HTTP/1.1 di atas TLS (native https), selain itu cleartext
    logger:             ?*Logger = null,       // baris lifecycle saja, lihat bagian Logging
};
```

Catatan: pada `.ASYNC` / `.POOL` / `.MIXED` loop koneksi memakai buffer stack berukuran tetap (`core.BUF_SIZE` = 16 KB untuk header, 8 KB untuk body). `max_recv_buf` menentukan ukuran buffer per-connection hanya pada `.EPOLL`. `large_body_rcvbuf` menyetel `SO_RCVBUF` hanya pada jalur body besar (upload), membiarkan cell request kecil pada default kernel. `tls` opt-in ke native https: saat non-null server menyajikan HTTP/1.1 di atas TLS pada jalur ter-gate, selain itu cleartext. Field `compression`, `compression_min_size`, dan `compression_max_out` (yang terakhir di-rename dari `max_gzip_out`) dibaca saat runtime pada `.EPOLL` dan `.URING`: handler opt-in dengan memanggil `core.writeNegotiated` alih-alih `writeSimple`. Helper lama `core.writeGzip` masih memakai konstanta compile-time `core.GZIP_OUT_SIZE`, dan `max_headers` adalah no-op yang dipertahankan untuk kompatibilitas sumber (engine lazy tidak punya batas jumlah header).

Catatan: `ws_recv_buf` menentukan ukuran buffer per-connection WebSocket. Pada `.EPOLL` menentukan ukuran buffer recv; pada `.URING` menentukan ukuran buffer frame-accumulation (`conn.buf`) dan scratch unmask, independen dari `max_recv_buf` request yang kecil. `0` jatuh ke `max_recv_buf`. Set lebih besar dari `max_recv_buf` untuk memberi koneksi WebSocket ruang lebih mengakumulasi burst pipelined yang dalam sebelum engine compact dan re-read saat fill.

Catatan: `send_date_header` default `true` untuk kepatuhan RFC 7231. Set `false` pada jalur panas di mana klien tidak mengonsumsi `Date` untuk membuang header (37 byte per response). Write helper terkelola menghormati flag ini.

### Timeout

`zix.Http1` mengekspos satu timeout, `handler_timeout_ms`, budget eksekusi per-handler. Saat non-zero, server memasang deadline thread-local sebelum setiap dispatch. Handler ikut serta dengan memanggil `zix.Http1.isExpired()` di antara langkah mahal dan merespons lebih awal, atau memperpendek budget-nya sendiri dengan `zix.Http1.setTimeout()`. Ini budget Layer B yang sama dengan `handler_timeout_ms` milik `zix.Http`.

`zix.Http1` tidak memiliki `conn_timeout_ms`. Ini disengaja, bukan kelalaian.

- Guard masa hidup koneksi pada `zix.Http` (`conn_timeout_ms`, Layer D) ditegakkan oleh `ConnRegistry` plus background timer thread yang menutup koneksi melebihi masa hidup terkonfigurasi. `zix.Http1` adalah engine ramping zero-alloc dan tidak membawa infrastruktur tetap itu: handler-nya `fn(head, body, fd) void` tanpa `Request` / `Response` / registry untuk melacak koneksi, dan tanpa receive timeout level-socket (`setNoDelay` dan `SO_BUSY_POLL` adalah satu-satunya opsi socket yang dipasang).
- Pada `.EPOLL`, model yang menjadi target tuning `zix.Http1`, koneksi keep-alive idle tidak menahan thread, hanya satu slot epoll dan buffernya. Alasan utama `conn_timeout_ms` ada pada `zix.Http` (mengklaim ulang pool thread yang tertahan pada koneksi lambat atau idle) tidak berlaku untuk loop level-triggered shared-nothing.

| Timeout | `zix.Http` | `zix.Http1` | Mekanisme |
| :- | :- | :- | :- |
| `handler_timeout_ms` | ya | ya | deadline thread-local dipasang per dispatch, opt-in handler |
| `conn_timeout_ms` | ya (`.POOL`) | tidak | `ConnRegistry` + background timer thread (Http saja) |

Jika penegakan masa hidup koneksi pada `.EPOLL` suatu saat dibutuhkan, yang paling cocok adalah sweep idle-deadline atas `ConnTable` per-worker (tanpa thread tambahan), bukan port `ConnRegistry` timer-thread milik Http.

---

## Model Handler

```zig
fn home(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;

    if (zix.Http1.queryParam(head, "name")) |name| {
        _ = name; // slice ke receive buffer, hanya valid selama pemanggilan ini
    }

    zix.Http1.writeSimple(fd, 200, "text/plain", "hello") catch {};
}

var server = zix.Http1.Server.init(home, .{
    .io = process.io,
    .ip = "0.0.0.0",
    .port = 8080,
});
try server.run();
```

- Handler adalah argumen comptime: dibakukan ke dalam tipe server, tidak ada registrasi dinamis setelah init.
- Semua slice di `head` dan `body` menunjuk ke receive buffer dan hanya valid selama pemanggilan berlangsung.
- Handler mengembalikan `void`: error ditangani di dalam handler (biasanya `catch {}` pada write helper, koneksi toh akan ditutup saat broken pipe).
- Handler boleh berupa fungsi polos, `Router(routes).dispatch`, atau rantai middleware yang dirangkai saat comptime.

### ParsedHead

| Field | Tipe | Catatan |
| :- | :- | :- |
| `method` | `[]const u8` | Verb apa adanya (`"GET"`, `"POST"`, ...) |
| `path` | `[]const u8` | Target tanpa query string |
| `query` | `[]const u8` | Query string mentah setelah `?`, `""` jika tidak ada |
| `raw_headers` | `[]const u8` | Blok header mentah, dipindai sesuai kebutuhan via `getHeader` (tanpa batas jumlah) |
| `version_minor` | `u8` | 1 untuk HTTP/1.1, 0 untuk HTTP/1.0 |
| `keep_alive` | `bool` | Default berdasarkan versi, ditimpa header `Connection` |
| `content_length` | `u64` | 0 saat tidak ada atau tidak bisa di-parse |
| `chunked_request` | `bool` | Ada `Transfer-Encoding: chunked` |
| `expect_continue` | `bool` | Ada `Expect: 100-continue` |

---

## Siklus Hidup Koneksi (.ASYNC / .POOL / .MIXED)

```mermaid
sequenceDiagram
    participant Client
    participant Serve as core.serveConn
    participant Handler as HandlerFn

    Client->>Serve: TCP connect (fd)
    Serve->>Serve: setsockopt TCP_NODELAY

    loop keep-alive
        Client->>Serve: HTTP request
        Serve->>Serve: recvHead (bulk read sampai CRLFCRLF)
        Serve->>Serve: parseHead (zero copy)
        opt Expect: 100-continue dengan body
            Serve->>Client: 100 Continue
        end
        Serve->>Serve: baca body (Content-Length atau decode chunked)
        Serve->>Serve: setTimeout(handler_timeout_ms)
        Serve->>Handler: handler(head, body, fd)
        Handler->>Client: response via write helpers
        Serve->>Serve: geser sisa pipelined ke depan buffer
    end

    Client->>Serve: close / Connection: close
    Serve->>Serve: return (pemanggil menutup fd)
```

Response error yang ditulis engine sendiri: `431` saat blok header melebihi receive buffer, `400` saat `parseHead` gagal. Keduanya menutup koneksi. Router (bila dipakai) menulis `404` untuk path yang tidak cocok.

---

## Router

### Registrasi: tabel route comptime

```zig
const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/",          .handler = home },
    .{ .path = "/api",       .handler = api,  .kind = .PREFIX },
    .{ .path = "/users/:id", .handler = user, .kind = .PARAM },
});

var server = zix.Http1.Server.init(Routes.dispatch, .{ .io = process.io, .ip = "0.0.0.0", .port = 8080 });
```

| `kind` | Contoh pattern | Perilaku |
| :- | :- | :- |
| `.EXACT` (default) | `"/about"` | Cocok hanya jika path penuh sama dengan `path` |
| `.PREFIX` | `"/api"` | Cocok dengan `path` dan sub-path apa pun pada batas `/` |
| `.PARAM` | `"/users/:id"` | Segmen `:name` ditangkap, literal harus cocok persis |

### Dispatch: aturan prioritas

```
Pass 1: exact routes   StaticStringMap comptime O(1)     (urutan registrasi tidak berpengaruh)
Pass 2: param routes   pattern pertama yang cocok menang  (urutan registrasi berpengaruh)
Pass 3: prefix routes  prefix terpanjang yang cocok menang (urutan registrasi tidak berpengaruh)

exact > param > prefix (prefix lebih panjang mengalahkan yang lebih pendek)
```

Route dipartisi berdasarkan kind saat kompilasi: path exact masuk `StaticStringMap`, route param dan prefix masuk array comptime yang ditelusuri dengan `inline for`. Path yang tidak cocok mendapat `404 text/plain` dari `dispatch` sendiri.

### Path params

`pathParam("id")` di dalam handler mengembalikan segmen yang tertangkap. Hasil tangkapan hidup di penyimpanan thread-local (maksimum 8 per route) dan hanya valid selama pemanggilan dispatch, sama dengan masa hidup slice request.

---

## Budget Handler: setTimeout / isExpired

Saat `config.handler_timeout_ms > 0` engine memasang deadline thread-local sebelum setiap dispatch. Handler ikut serta dengan memanggil `zix.Http1.isExpired()` di antara langkah-langkah yang mahal:

```zig
fn slow(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;

    doStep1();
    if (zix.Http1.isExpired()) {
        zix.Http1.writeJson(fd, 408, "{\"error\":\"timeout\"}") catch {};
        return;
    }

    doStep2();
    zix.Http1.writeJson(fd, 200, "{\"result\":\"ok\"}") catch {};
}
```

- `isExpired()` selalu aman dipanggil: mengembalikan `false` saat tidak ada deadline terpasang. Pengecekannya satu `clock_gettime` plus satu perbandingan.
- `setTimeout(ms)` memasang ulang deadline untuk handler saat ini (memperpendek atau memperpanjang), `setTimeout(0)` menghapusnya.
- Deadline bersifat thread-local, mengikuti model eksekusi satu-request-per-worker. Tidak ada objek Context yang membawanya.

---

## WebSocket: Koneksi Milik Engine

`zix.Http1.WebSocket` adalah codec RFC 6455 plus model koneksi milik engine. Handler menyelesaikan handshake dan mendaftarkan callback per-frame, lalu return. Engine menggerakkan frame loop dari event loop-nya, sehingga tidak pernah ada worker yang terparkir pada satu koneksi.

```mermaid
sequenceDiagram
    participant C as Client
    participant E as EPOLL engine
    participant H as HTTP handler
    participant F as on_frame callback

    C->>E: GET /ws (Upgrade: websocket)
    E->>H: handler(head, body, fd)
    H->>H: WebSocket.serve(fd, key, on_frame)
    Note over H: 101 ditulis, promosi diminta
    H->>E: handler return
    E->>E: koneksi ditandai ws di ConnTable

    loop per readable event
        C->>E: frame masked (mungkin pipelined)
        E->>E: ws.pump: parse setiap frame lengkap
        E->>F: on_frame(fd, opcode, payload) untuk text/binary
        F->>E: WebSocket.send(fd, opcode, reply) ditahan di sink
        E->>C: semua balasan digabung, satu write()
    end

    C->>E: close frame
    E->>C: close digema, fd ditutup
```

- `WebSocket.serve(fd, key, on_frame)` menghitung accept key, menulis `101 Switching Protocols`, dan meminta promosi melalui slot handoff thread-local yang dibaca engine tepat setelah handler return.
- Ping otomatis dibalas pong dan close otomatis digema oleh engine. Callback hanya pernah menerima frame text dan binary.
- Frame yang dikirim dalam satu pass pump digabung menjadi satu `write()`.
- Promosi hanya dihormati pada `.EPOLL`. Pada `.ASYNC` / `.POOL` / `.MIXED` handoff dibersihkan dan koneksi berakhir setelah handler return (pakai `zix.Http` untuk loop WebSocket milik handler pada model-model itu).
- Melalui TLS (`config.tls`, jalur thread-per-koneksi), panggil `WebSocket.serveTls(fd, key, on_frame)` (ADR-055): `101` dan tiap frame dienkripsi lewat ADR-054 stream sink, dan thread https menjalankan frame loop inline atas TLS session. Rooms / broadcast hanya cleartext (enkripsi per-session), jadi wss bersifat per-koneksi.

Lihat `examples/http1_websocket.zig` (cleartext) dan `examples/tls/tls_http1_ws.zig` (wss).

---

## Logging

`config.logger` hanya menerima baris lifecycle server (notice listening, fallback EPOLL). Saat null, baris lifecycle dicetak ke stderr hanya pada Debug build dan diam pada release build (server release tanpa logger tidak mengeluarkan output lifecycle).

Access logging per-request adalah tanggung jawab handler: handler Http1 menulis langsung ke fd dan mengembalikan `void`, sehingga engine tidak dapat mengamati status response atau jumlah byte. Panggil `logger.access()` di dalam handler di titik status akhir dan ukurannya diketahui.

---

## Model Memori

| Lingkup | Penyimpanan | Masa hidup |
| :- | :- | :- |
| Tabel route | comptime (nol biaya heap) | Proses |
| Buffer receive + body (.ASYNC/.POOL/.MIXED) | stack thread/task yang melayani (16 KB + 8 KB) | Koneksi |
| Buffer per-connection (.EPOLL) | `smp_allocator`, `max_recv_buf` byte | Koneksi |
| Staging body + output (.EPOLL) | `smp_allocator`, masing-masing 16 KB, per worker | Worker thread |
| Scratch gzip (`writeGzip`) | `smp_allocator` (256 KB out + flate window + compressor) | Satu pemanggilan |
| Alokasi handler | tidak disediakan (bawa allocator sendiri bila perlu) | n/a |

---

## Batasan yang Diketahui

| Batas | Perilaku |
| :- | :- |
| Ukuran blok header | Maksimum 16 KB (`core.BUF_SIZE`, atau `max_recv_buf` pada .EPOLL). Melebihi mengembalikan `431` dan menutup |
| Body pada .ASYNC/.POOL/.MIXED | Handler melihat sampai 8 KB (`ASYNC_BODY_CHUNK`). Body Content-Length yang lebih besar sisanya dibuang dari socket agar koneksi keep-alive tetap dapat dipakai (handler membaca `head.content_length`, bukan byte-nya) |
| Body pada .EPOLL / .URING | Harus muat di `max_recv_buf` dikurangi head. Body yang lebih besar men-dispatch handler dengan slice body kosong, lalu engine membuang sisanya dari socket (`MSG_TRUNC`) sehingga koneksi tetap dapat dipakai |
| Body request besar (upload) | Drain melebarkan receive window via `large_body_rcvbuf` (SO_RCVBUF), lihat [`docs/zix-config-id.md`](zix-config-id.md) |
| Body request chunked | Di-decode ke body buffer, kelebihan dibuang |
| Versi HTTP | Hanya HTTP/1.0 dan HTTP/1.1, selain itu `400` |
| TLS | https/1.1 native (TLS 1.3 + 1.2), opt-in via `config.tls`, pada perf band-nya sendiri. `.ASYNC` / `.POOL` / `.MIXED` melakukan terminasi per koneksi di worker thread, `.EPOLL` / `.URING` di worker epoll-mux event-driven. Lihat [`docs/hld-tls-id.md`](hld-tls-id.md) |

Endpoint yang menerima upload besar mengandalkan `head.content_length` (byte-nya dibuang, tidak di-buffer).

Untuk lapisan HTTP berfitur lengkap lihat [`docs/hld-http-id.md`](hld-http-id.md). Untuk detail implementasi lihat [`docs/lld-http1-id.md`](lld-http1-id.md).

---

###### end of hld-http1
