# LLD: zix.Grpc (gRPC h2c)

Detail implementasi internal. Untuk rasional desain lihat [`docs/hld-grpc-id.md`](hld-grpc-id.md) dan ADR-031.

Model blocking (`.ASYNC`) memakai satu jalur koneksi (`serve.serveConn` -> `serveLoop`). Model `.EPOLL` adalah jalur terpisah, multiplex, non-blocking (`grpcMuxOnReadable`) yang menjadi fokus utama dokumen ini.

Setiap fungsi internal yang bergantung pada tabel route di bawah ini tetap menerima `comptime RouterType: type` (ADR-063), bukan `handler: HandlerFn` runtime yang diratakan seperti padanan Http2. Ini disengaja: engine membaca `Route.is_server_streaming` dari `RouterType.route_slice` sebelum memanggil handler, untuk memilih dispatch sync-inline vs task-spawn, dan pointer `HandlerFn` polos tidak bisa membawa metadata itu. Lihat bagian Pola Handler di `docs/hld-grpc-id.md` untuk biaya terukur kehilangan metadata itu.

---

## File inti

| File | Peran |
| :- | :- |
| `Context.zig` | state per call: pesan request, verb balasan, deadline, verb cache |
| `Request.zig`, `Response.zig` | view tipis di atas `Context` |
| `handler.zig` | `HandlerFn`, `invoke` (satu-satunya tempat handler dipanggil), `completeHandlerError`, `rpcStart` / `writeRpcRecord` |
| `router.zig` | `Route`, `Router`, `routeIsStreaming` |
| `serve.zig` | `serveConn`: preface atau upgrade h2c, lalu `serveLoop` |
| `stream_dispatch.zig` | `dispatchWhole` (cek content-length), `dispatchStream`, `dispatchInline` |
| `DispatchTask.zig` | satu call server-streaming di task sendiri |
| `ReplyStage.zig`, `ConnReader.zig`, `ConnMutex.zig` | cork buffer, pembaca frame ber-buffer, write lock koneksi |
| `Stream.zig`, `stream_slot.zig` | satu stream request, claim / find / in-flight tabel stream |
| `deadline.zig`, `encoding.zig`, `cache.zig`, `path.zig`, `content_type.zig`, `window.zig` | deadline, header gzip, key cache response, pemisahan path, content-type, ukuran window |

### Context

State handler per call. `Request` (`header`, `recvMessage`) dan `Response` (`sendHeaders` / `sendMessage` / `finish` / `serveCached` / `sendCached`) adalah wrapper tipis yang memegang pointer `*Context`, delegasi satu baris ke method di bawah: trio publik (ADR-063) tidak menambah logika baru di sini. Field yang relevan untuk keluaran:

```zig
fd: std.posix.fd_t,
stream_id: u31,
deadline: ?std.Io.Clock.Timestamp = null,
_hdr_sent: bool = false,
_write_mutex: ?*ConnMutex = null,   // hanya task streaming, null pada jalur inline dan mux
_out: ?*ReplyStage = null,          // diset pada jalur inline dan mux: stage alih-alih write
```

`sendMessage` / `sendHeaders` / `finish` bercabang pada `_out`: saat diset, mereka meng-append frame terenkode ke cork (tanpa lock per panggilan, tanpa `write` langsung). Saat null, mereka menulis langsung ke fd, mengambil `_write_mutex` bila diset. Frame DATA streaming sampai 4096 byte (head plus payload) keluar dalam satu write, yang lebih besar dalam dua.

Error-nya `ZixHttp2_GrpcContext_*` (`BrokenPipe`, `UnexpectedEOF`, `Overflow`, `BufferFull`), diterjemahkan ke `ZixHttp2_GrpcResponse_*` oleh `Response`. Reply staged yang sudah gagal menulis melaporkan `BrokenPipe` pada send berikutnya. Content-type atau grpc-message yang melewati scratch HPACK adalah `BufferFull`.

`finishIfOpen` menutup call yang dibiarkan terbuka oleh handler, dan membiarkan call yang sudah selesai. `handler.invoke` memanggilnya lewat `completeHandlerError` (INTERNAL, `handler error`) saat handler mengembalikan error.

Cache response unary per-worker (ADR-036) hidup di `cache.zig`: `tl_cache`, dengan key `requestKey(path, body)` (Wyhash atas path gRPC plus raw request body). `Context.serveCached` melakukan lookup, replay lewat `sendMessage` dan `finish(.OK, "")` saat hit, dan mengembalikan false saat miss, tanpa cache, atau path kosong. `sendCached` mengirim lalu menyimpan, melewati penyimpanan pada kondisi yang sama. Jam TTL-nya `nowMillis(ctx.io)`.

### Deadline

`deadline.computeDeadline(io, handler_timeout_ms, headers)` mengambil yang paling ketat dari budget server dan header `grpc-timeout` yang valid. `grpc-timeout` yang tidak bisa di-parse diabaikan. `Router.dispatch` lalu memperketatnya dengan `Route.timeout_ms` (`tightenMs`), jadi budget route tidak pernah memperlunaknya.

### ReplyStage

Penulis cork untuk satu reply. Dipakai oleh dispatch unary inline dan oleh setiap dispatch pada jalur mux.

```zig
fd: std.posix.fd_t,
buf: []u8,                    // backing milik pemanggil, bukan array inline
len: usize = 0,
failed: bool = false,         // diset saat sebuah write gagal, dibaca oleh send berikutnya

fn append(self, bytes) void   // flush dulu bila akan overflow, chunk melewati buf diteruskan langsung
fn flush(self) void           // satu writeAllFD dari buf[0..len], len = 0
```

Jalur inline (`stream_dispatch.dispatchInline`) menyokong `buf` dengan array stack 4096 byte (reply unary kecil). Jalur mux menyokongnya dengan `stage_buf` 64 KB milik koneksi (lihat `GrpcMuxConn`).

### ConnReader (model blocking)

Pembaca frame ber-buffer yang dipakai `serveLoop`. `ensure(n)` blocking sampai `n` byte ter-buffer (kompaksi bila perlu), `take(n)` mengembalikan dan memajukan. `n` melewati buffer adalah `TooLarge`, peer yang menutup lebih dulu adalah `Closed`.

### ConnMutex

Spinlock ber-ref-count di heap, dipakai bersama oleh read loop dan setiap task streaming dari satu koneksi. `active_streaming` menghitung task yang sedang menulis. Jalur inline mengambil lock hanya selama nilainya di atas 0. `release` terakhir membebaskannya.

### DispatchTask

`spawn` menyalin penuh header stream (di-rebase ke scratch 4 KiB miliknya) dan body (64 KiB, di-gunzip dulu bila klien mengirim `grpc-encoding: gzip`), sehingga read loop langsung membebaskan slot. Task berjalan di `opts.io` bila diset, selain itu di thread terlepas. Call yang tidak bisa diterima langsung ditutup: INTERNAL saat task tidak bisa dibuat atau ada header melewati scratch, RESOURCE_EXHAUSTED saat body melewati 64 KiB.

### Stream

State parse per stream. `body` dan `header_scratch` adalah slice pinjaman berukuran `opts.max_body` / `opts.max_header_scratch`. Pada jalur multiplex (`.EPOLL` / `.URING`) sebuah `Stream` dipinjam dari pool per-worker selama terbuka (`next_free` menautkannya ke freelist selagi idle). Pada jalur blocking setiap entri tabel menunjuk ke backing per koneksi.

```zig
id: u31 = 0,
state: StreamState = .IDLE,
headers: [frame.MAX_HEADERS]Header = undefined,
header_count: usize = 0,
body: []u8 = &.{},
body_len: usize = 0,
header_scratch: []u8 = &.{},
end_headers: bool = false,
end_stream: bool = false,
next_free: ?*Self = null,     // tautan freelist selagi idle di pool per-worker
```

`open(sid)` me-reset-nya untuk stream baru, `appendBody` menolak chunk yang melewati body (tidak ada yang disalin). Jalur blocking meng-claim dan mencari entri dengan `stream_slot.claim` / `find`, keduanya scan linear atas `max_streams`.

### Konstanta flow-control (`window.zig`)

```zig
pub const STREAM_WINDOW_SIZE: u32 = 16 * 1024 * 1024;  // SETTINGS_INITIAL_WINDOW_SIZE yang diiklankan
pub const CONN_WINDOW_BUMP: u31 = 1 << 30;             // bump window koneksi sekali setelah handshake
pub const CONN_REPLENISH_THRESHOLD: usize = 1 << 29;   // titik replenish window koneksi secara bulk
```

Window stream cukup besar sehingga body request kecil tidak pernah butuh `WINDOW_UPDATE` stream per-DATA. Window koneksi di-bump sekali dan hanya di-replenish secara bulk melewati threshold.

### GrpcMuxConn (multiplex `.EPOLL`)

State per koneksi milik heap untuk model multiplex. Satu thread worker memiliki satu `GrpcMuxConn` sepanjang hidupnya.

```zig
pub const GrpcMuxConn = struct {
    fd: std.posix.fd_t,
    opts: GrpcServeOpts,
    io: std.Io,                 // dibawa untuk Context yang dibangun tiap muxDispatch, berlaku se-worker

    rbuf: []u8,                 // akumulator baca, persisten lintas event, menyimpan frame parsial
    rstart: usize,
    rend: usize,

    hpack_dec: h2.HpackDecoder,
    streams: []*Stream,         // tabel pointer selebar max_streams, slot dipinjam dari pool per-worker
    slots: []bool,
    last_stream_id: u31,
    conn_window_consumed: usize,
    phase: MuxPhase,            // await_preface | await_upgrade | await_preface2 | h2
    settings_frame: [33]u8,     // SETTINGS server pra-komputasi, dibangun sekali di init
    stage_buf: [65536]u8,       // backing 64 KB untuk stage
    stage: ReplyStage,          // stage.buf = &stage_buf

    pub fn init(fd, opts, io) ?*GrpcMuxConn   // satu alokasi per buffer; null saat OOM
    pub fn deinit(self) void
};
```

`rbuf` berukuran `max(32 KB, max_frame_size + 256 + 9)`.

`init` memanggil `buildSettingsFrame(&settings_frame, opts)` sekali untuk meng-encode blob SETTINGS server 33 byte (header 9 byte + 4 param), dan mengarahkan `stage.buf` ke `stage_buf` 64 KB. Handshake menambahkan `settings_frame` apa adanya (tanpa loop encode per koneksi). Stage 64 KB menggabungkan ~100 reply unary konkuren (~6 KB) menjadi satu write, dan reply server-streaming memadatkan pesan-pesannya menjadi DATA frame yang lebih sedikit dan lebih besar (lihat `muxDispatch`), sehingga reply ~5000 pesan pun tetap jauh di bawah stage dan keluar dalam satu write.

### grpcMuxOnReadable(comptime RouterType, conn) -> GrpcConnOutcome

Satu event readable. Mengembalikan `.close` (peer menutup, error protokol, atau handshake ditolak) atau `.keep_alive`.

```
1. conn.stage.len = 0                  // reset cork untuk event ini
2. loop:
     a. kompaksi rbuf bila penuh / reset bila kosong
     b. jika rbuf penuh dan tetap tak ada kemajuan -> flush, return .close (frame lebih besar dari buffer)
     c. got = read(fd, rbuf[rend..])
          WouldBlock -> flush, return .keep_alive
          error lain atau 0 -> flush, return .close
     d. rend += got
     e. jika muxProcess(RouterType, conn) == .close -> flush, return .close
```

Membaca satu chunk, memproses frame lengkap, mengulang sampai `EAGAIN`. Epoll level-triggered memicu ulang bila ada lagi.

### muxProcess(comptime RouterType, conn) -> GrpcConnOutcome

Mesin fase handshake, lalu loop frame.

- `await_preface`: butuh 3 byte. Jika bukan `"PRI"`, set `await_upgrade` dan panggil `muxHandleUpgrade`. Selain itu butuh 24 byte, validasi preface koneksi, stage SETTINGS server, set `h2`.
- `await_upgrade`: `muxHandleUpgrade`.
- `await_preface2`: setelah `101`, validasi preface, stage SETTINGS, set `h2`.
- `h2`: `muxFrameLoop`.

### muxHandleUpgrade(conn)

Akumulasi sampai `\r\n\r\n`. Tanpa header `Upgrade: h2c`, stage `400` dan return `.close` (jalur probe validate). Dengan header itu, stage `101`, konsumsi header request, set `await_preface2`, return `.keep_alive`. Request awal pada stream 1 dari upgrade tidak dilayani (client prior-knowledge tidak memakai jalur ini).

### muxFrameLoop(comptime RouterType, conn) -> GrpcConnOutcome

```
loop:
    jika ter-buffer < 9 -> return .keep_alive
    fh = parseFrameHeader(rbuf[rstart..][0..9])
    jika fh.length > max_payload -> stage GOAWAY, return .close
    jika ter-buffer < 9 + fh.length -> return .keep_alive
    majukan melewati header + payload
    switch fh.frame_type:
        SETTINGS  -> terapkan table size; stage SETTINGS ack + satu CONN_WINDOW_BUMP
        PING      -> stage PING ack
        HEADERS   -> slotFor, hpack decode ke stream.header_scratch; jika END_HEADERS+END_STREAM -> muxDispatch, bebaskan slot
        CONTINUATION -> append decode; dispatch saat END
        DATA      -> findSlot; replenish window koneksi bulk melewati threshold; salin ke stream.body; jika END_STREAM -> muxDispatch, bebaskan slot
        RST_STREAM-> bebaskan slot
        GOAWAY    -> return .close
```

Frame kontrol di-stage via `muxStageFrame` / `muxStageWindowUpdate` / `muxStageGoaway` / `muxStageRst` / `muxStageServerSettings`, sehingga keluar dalam write tergabung yang sama dengan reply. `muxStageServerSettings` menambahkan `conn.settings_frame` yang pra-komputasi (dibangun sekali di `init` oleh `buildSettingsFrame`), bukan encode parameter baru.

### muxDispatch(comptime RouterType, conn, stream)

Membangun `Context` dengan `_out = &conn.stage` dan `_write_mutex = null` (worker memiliki koneksi, jadi tidak ada penulis konkuren), membungkusnya dalam pasangan `Request` / `Response` (view delegasi tipis, tanpa logika tambahan), lalu memanggil `RouterType.dispatch(&req, &res, &ctx)`. Setiap route, unary dan streaming, berjalan inline. `logger.rpc` opsional membungkus pemanggilan untuk timing.

Reply server-streaming dipadatkan pada lapisan gRPC. `muxDispatch` memberi route streaming sebuah buffer coalesce per-call (`ctx._coal`), dan `sendMessage` memadatkan pesan-pesan yang sudah ber-frame gRPC ke dalamnya, mengeluarkan satu DATA frame HTTP/2 per `Context.STREAM_COALESCE_CAP` (16 KiB, max frame size default HTTP/2) alih-alih satu DATA frame per pesan. Reply `count = 5000` turun dari 5000 DATA frame kecil menjadi sekitar 3, memangkas byte header frame di wire dan biaya parse per-frame di sisi klien. Unary tetap satu frame per pesan (`_coal` null), jadi byte-nya persis sama.

Untuk route streaming (dideteksi oleh `routeIsStreaming(RouterType.route_slice, path)`), dispatch dibungkus dalam `setTcpCork(conn.fd, true)` / `setTcpCork(conn.fd, false)`: kernel menahan output hingga MSS penuh atau cork dilepas, menggabungkan beberapa flush stage perantara yang dihasilkan handler streaming menjadi lebih sedikit segmen TCP. Route unary tidak di-cork (sudah keluar dalam satu write). `setTcpCork` no-op pada target non-Linux.

### Jalur blocking (serveConn / serveLoop)

Dipakai oleh `.ASYNC`. `serveConn` mengeset `TCP_NODELAY`, lalu menangani preface h2c-direct atau upgrade h2c (`upgrade.accept` dari Http2, stream 1 dijawab inline sebelum loop), lalu `serveLoop`. Loop memakai `ConnReader` blocking dan satu switch frame. Setiap write lewat `ConnMutex` koneksi. Stream yang selesai masuk ke `stream_dispatch.dispatchWhole`: body yang kurang dari (atau melewati) content-length-nya di-reset dengan PROTOCOL_ERROR, route unary berjalan inline (`dispatchInline`, di-stage di `ReplyStage` stack), route server-streaming berjalan di `DispatchTask`. Body melewati `max_body` ditutup dengan RESOURCE_EXHAUSTED. Peer yang hang-up dengan request in flight mendapat GOAWAY PROTOCOL_ERROR, hang-up idle tidak mendapat apa pun.

---

## proto/

### varint.zig

7 bit nilai per byte, bit rendah lebih dulu, bit teratas menyala selama masih ada byte berikutnya. Sebuah u64 paling banyak memakai `MAX_LEN` (10) byte.

- `decodeVarint`: byte ke-10 hanya boleh membawa bit 0. Lebih dari itu, atau byte ke-11, adalah `Overflow`. Input yang habis di tengah varint adalah `UnexpectedEOF`.
- `encodeVarint`: memeriksa ruang sebelum setiap byte. Saat `BufferFull`, buf bisa berisi varint yang belum lengkap.

### field.zig

Tag = `(field_number << 3) | wire_type`. Setiap encoder menulis tag, lalu nilainya, dan memeriksa ruang sebelum payload. int32 negatif di-sign-extend ke 64 bit, sehingga di-encode sebagai varint 10 byte (sama seperti protobuf). Error varint diterjemahkan ke `ZixHttp2_GrpcField_*` di setiap fungsi publik.

### MessageReader.zig

`{ buf, pos }`. `next` membaca satu tag, lalu nilai sesuai tipe wire-nya, dan memajukan `pos` melewatinya. Setiap `payload` adalah slice dari `buf`, tidak ada yang disalin.

- Panjang LEN dibandingkan dengan `buf.len - pos`, sehingga panjang yang sangat besar menjadi `UnexpectedEOF`, tidak pernah overflow pada `pos + len`.
- Nomor field yang melewati u32 adalah `FieldNumberTooLarge`.
- Tipe wire 3, 4 (group yang sudah deprecated), 6, dan 7 adalah `UnknownWireType`.

---

## frame/

### prefix.zig

`[compress: 1 byte][msg_len: 4 byte, big-endian]`, `PREFIX_LEN` = 5. Byte compress yang bukan nol dibaca sebagai terkompresi. Body yang lebih pendek dari 5 byte adalah `TooShort`.

### build.zig / send.zig

Fungsi `build*` mengenkode frame ke buffer pemanggil dan mengembalikan jumlah byte. Fungsi `send*` membangun frame di buffer stack lalu menulisnya dengan `writeAllFD`.

```zig
pub fn buildGrpcHeaders(out, stream_id, content_type) Error!usize            // HEADERS awal, tanpa END_STREAM
pub fn buildGrpcHeadersGzip(out, stream_id, content_type) Error!usize        // sama, plus grpc-encoding: gzip
pub fn buildGrpcDataHeader(out, stream_id, msg_len, compress) Error!usize    // DATA_HEAD_LEN: header DATA 9-byte + prefix 5-byte (pemanggil append payload)
pub fn buildGrpcTrailer(out, stream_id, grpc_status, msg) Error!usize        // trailer HEADERS, END_STREAM
pub fn buildGrpcError(out, stream_id, grpc_status, msg) Error!usize          // HEADERS trailers-only, END_STREAM
```

- `HEADERS_FRAME_SCRATCH` (header frame + `HPACK_ENCODE_SCRATCH`) selalu muat untuk frame HEADERS yang dibangun di sini.
- Blok yang melewati scratch HPACK, atau `out` yang terlalu kecil, adalah `BufferFull`. `msg_len` yang melewati `MAX_DATA_MSG_LEN` (u24 maksimum dikurangi prefix) adalah `Overflow`.
- Error `send*` diterjemahkan ke `ZixHttp2_GrpcSend_*` di setiap fungsi publik.

### reply_block.zig

Dua blok header jalur panas yang konstan dienkode HPACK sekali di comptime:

```zig
pub const GRPC_CONTENT_TYPE = "application/grpc+proto";
pub const HEADERS_PROTO_BLOCK: []const u8 = ...;  // :status 200 + content-type application/grpc+proto
pub const TRAILER_OK_BLOCK: []const u8 = ...;     // grpc-status 0
```

`buildGrpcHeaders` memakai `HEADERS_PROTO_BLOCK` saat `content_type == GRPC_CONTENT_TYPE`, dan `buildGrpcTrailer` memakai `TRAILER_OK_BLOCK` saat `grpc_status == 0` dan pesan kosong. Keduanya men-stamp header frame 9-byte dan menyalin blok cache, tanpa menjalankan encoder HPACK. Content-type atau status lain menjalankan encoder.

Blok berasal dari `HpackEncoder` asli yang dijalankan di comptime, jadi byte-nya identik dengan keluaran dinamis.

### gzip.zig

- `decompressGrpcBody`: menelusuri setiap prefix + pesan. Pesan dengan flag 1 di-gunzip penuh (`streamRemaining`), flag 0 disalin. Setiap prefix keluaran ber-flag 0. Sisa kurang dari 5 byte setelah pesan terakhir diabaikan.
- `compressGrpcMessage`: gzip pada `level_1`. Window dan state compressor diambil dari `std.heap.smp_allocator`. `out_buf` sebesar `data.len + GZIP_FRAMING_HEADROOM` selalu muat.

---

## timeout.zig

`parseTimeout` membaca `<digits><unit>` dan mengembalikan nanodetik. Satuan: `H`, `M`, `S`, `m`, `u`, `n` (case-sensitive).

- Kurang dari 2 byte adalah `InvalidFormat`. Lebih dari `MAX_DIGITS` (8) digit adalah `TooManyDigits` (spec gRPC over HTTP/2).
- Digit hanya ASCII 0-9, jadi `+5S`, `-5S`, dan `1_0S` adalah `InvalidNumber`. Nol adalah `NotPositive` (spec meminta positive integer). Satuan tak dikenal adalah `InvalidUnit`.
- Perkalian dicek, jadi `99999999H` adalah `Overflow`, tidak pernah panic.

---

## Config.zig

Record config server. `io`, `ip`, `port`, dan `dispatch_model` wajib, field lain punya default (lihat tabel field di hld).

- `max_recv_buf` default 64 KiB (Http2 memakai 32 KiB).
- `compress` dan `handler_timeout_ms` hanya untuk gRPC. Http2 tidak punya `compress`.
- `serveOpts()` membangun `ServeOpts` untuk satu koneksi. `io` menjadi pool yang menjalankan call server-streaming.
- `tls` dan `tls_port` belum di-port.

---

## server.zig dan dispatch/

### Dispatch (run)

`server.zig` memuat tipe publik `GrpcServer` dan `run()` switch tipis pada `dispatch_model`. Implementasi per-model berada di `dispatch/` (`async.zig`, `epoll.zig`, `uring.zig`). `.ASYNC` mempertahankan struktur accept-thread + `io.async` dan memanggil `serve.serveConn`. `.EPOLL` memanggil `epoll.runEpoll`. `.URING` memanggil `uring.runUring` (bentuk berbasis completion io_uring dari `.EPOLL`). Saat `cfg.tls != null`, `run()` justru bercabang ke `tls_mux.runTlsMux` (multiplex) atau `tls_serve.runTls` (blocking per koneksi). Sebelum semua itu, `run()` menolak `.EPOLL` / `.URING` di luar Linux dengan `error.ZixDispatchModelUnsupported` (ADR-065).

Simbol `GrpcConnTable`, `acceptAll`, `epollMuxWorkerFn`, dan `runEpoll` di bawah semuanya berada di `dispatch/epoll.zig`.

### GrpcConnTable

Map fd ke `*GrpcMuxConn` privat per worker, ber-indeks langsung berdasarkan fd (sparse, `MAX_FD = 1 << 16`). `alloc` membangun `GrpcMuxConn`, `free`/`deinit` melepasnya. Tidak dibagi antar worker.

### acceptAll(table, epfd, listener_fd, opts, io)

Menguras `accept4(SOCK.NONBLOCK | SOCK.CLOEXEC)` sampai `EAGAIN` (level-triggered). Tiap fd yang diterima mendapat `TCP_NODELAY`, sebuah `GrpcMuxConn`, dan registrasi `EPOLL.IN | RDHUP`. Saat alokasi atau registrasi gagal, fd ditutup.

### epollMuxWorkerFn(RouterType)(ctx)

`epollMuxWorkerFn(comptime RouterType: type)` mengembalikan fungsi entry worker. Satu thread worker:

```
1. listener SO_REUSEPORT privat pada ip:port; setNonBlock
2. epoll_create1; tambah listener (EPOLL.IN)
3. GrpcConnTable.init
4. loop epoll_wait (hingga EPOLL_MAX_EVENTS = 512 event per pemanggilan):
     untuk tiap event:
       fd listener -> acceptAll
       fd koneksi  -> outcome = (HUP|ERR) ? .close : grpcMuxOnReadable(RouterType, conn)
                      jika .close -> epoll_ctl DEL, table.free, close
```

### runEpoll(comptime RouterType: type, cfg)

`worker_count = workers` (0 = jumlah cpu). Men-spawn `worker_count` thread `epollMuxWorkerFn(RouterType)` (stack 512 KB) dan join. Kernel menyeimbangkan koneksi lintas listener `SO_REUSEPORT` tiap worker.

---

###### end of lld-grpc
