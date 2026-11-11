# LLD: zix.Grpc (gRPC h2c)

Detail implementasi internal. Untuk rasional desain lihat [`docs/hld-grpc-id.md`](hld-grpc-id.md) dan ADR-031.

Model blocking (`.ASYNC`) memakai satu jalur koneksi (`serve.serveConn` -> `serveLoop`). Model multiplex (`.EPOLL`, `.URING`) memakai jalur terpisah yang non-blocking di bawah `mux/` (`process.onReadable`, `process.processRing`). `dispatch/epoll.zig` dan `dispatch/uring.zig` yang menjalankannya.

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

Jalur inline (`stream_dispatch.dispatchInline`) menyokong `buf` dengan array stack 4096 byte (reply unary kecil). Jalur mux menyokongnya dengan `stage_buf` 64 KB milik koneksi (lihat `MuxConn`).

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

### Berkas mux (`mux/`)

| Berkas | Peran |
| :- | :- |
| `MuxConn.zig` | state per fd: read buffer, slot, reply stage, SETTINGS server |
| `stream_pool.zig` | freelist `Stream` per worker |
| `settings_frame.zig` | `build`: frame SETTINGS server 33 byte |
| `stage_frame.zig` | `append`, `windowUpdate`, `goaway`, `rstStream` ke reply stage |
| `tcp_cork.zig` | `set`: TCP_CORK nyala atau mati, best effort |
| `mux_dispatch.zig` | `dispatch`, `dispatchWhole`, `hangupGoaway` |
| `mux_upgrade.zig` | `handleUpgrade`: 101 atau 400 |
| `frame_loop.zig` | `run`: satu frame tiap kali |
| `process.zig` | `onReadable`, `processRing` |

`ConnOutcome` (`keep_alive`, `close`) dan `MuxPhase` (`await_preface`, `await_upgrade`, `await_preface2`, `h2`) dipakai ulang dari mux http2.

### MuxConn

State per koneksi milik heap. Satu thread worker memiliki satu `MuxConn` sepanjang hidupnya, jadi tidak ada write lock.

```zig
fd: std.posix.fd_t,
opts: ServeOpts,
io: std.Io,                      // dibawa ke Context tiap call
rbuf: []u8,                      // akumulator baca, menahan frame parsial antar event
rstart: usize,
rend: usize,
hpack_dec: HpackDecoder,
streams: []*Stream,              // dipinjam dari pool, valid hanya saat slots true
slots: []bool,
last_stream_id: u31,
conn_window_consumed: usize,
phase: MuxPhase,
settings: [SETTINGS_FRAME_LEN]u8,    // SETTINGS server, dibangun sekali di init
stage_buf: [STAGE_BUF_LEN]u8,        // 64 KiB
stage: ReplyStage,                   // stage.buf = &stage_buf

pub fn init(fd, opts, io) Error!*Self      // ZixHttp2_GrpcMuxConn_OutOfMemory
pub fn deinit(self) void                   // mengembalikan stream terbuka ke pool
pub fn buffered(self) []u8
pub fn compact(self) void
pub fn claimSlot(self, sid) ?usize
pub fn findSlot(self, sid) ?usize
pub fn releaseSlot(self, slot) void
pub fn requestInFlight(self) bool
```

`rbuf` berukuran `max(opts.conn_read_buf_min, max_frame_size + 256 + 9)`. `stage` menunjuk ke dalam struct, jadi `MuxConn` hanya di heap dan tidak pernah dipindah.

Stage 64 KiB menampung sekitar 100 reply unary konkuren dalam satu write, dan reply server-streaming memadatkan pesannya ke DATA frame yang lebih sedikit dan lebih besar (lihat `mux_dispatch.dispatch`).

### stream_pool

`acquire(opts)` mengambil stream yang terakhir dilepas, atau mengalokasikan satu dengan buffer `max_body` dan `max_header_scratch`. `release(stream)` me-reset stream dan menyimpan buffernya. Freelist bersifat threadlocal, jadi memori stream mengikuti stream konkuren di satu worker, bukan koneksi kali `max_streams`. Stream di pool yang lebih kecil dari permintaan `opts` dibuang dan diganti.

### process.onReadable(comptime RouterType, conn) -> ConnOutcome

Satu event readable.

```
1. conn.stage.len = 0, flush stage di setiap return
2. loop:
     a. compact rbuf
     b. rbuf masih penuh -> return .close (frame lebih besar dari buffer)
     c. got = read(fd, rbuf[rend..])
          WouldBlock -> return .keep_alive
          error lain -> return .close
          0 -> hangupGoaway, return .close
     d. rend += got
     e. process(RouterType, conn) == .close -> return .close
```

### process.processRing(comptime RouterType, conn) -> ConnOutcome

Sama dengan satu putaran `process`, tanpa read dan tanpa flush. Worker `.URING` mengisi `rbuf` dan mengirim `conn.stage.buf[0..conn.stage.len]` setelah fungsi ini kembali. Reply yang melewati stage sudah langsung ditulis ke fd.

### process (fase handshake)

Fase-fase berlanjut ke fase berikutnya, jadi byte yang terbaca bersamaan diproses dalam satu putaran.

- `await_preface`: butuh 3 byte. Bukan `"PRI"` -> `await_upgrade`. Selain itu terima preface (24 byte): stage `conn.settings`, set `h2`. Preface salah men-stage GOAWAY PROTOCOL_ERROR lalu menutup.
- `await_upgrade`: `mux_upgrade.handleUpgrade`.
- `await_preface2`: setelah `101`, terima preface dengan cara yang sama.
- `h2`: `frame_loop.run`.

### mux_upgrade.handleUpgrade(conn)

Kumpulkan sampai `\r\n\r\n`. Head yang memenuhi `rbuf` menutup koneksi. Tanpa `Upgrade: h2c`, stage `400` lalu tutup. Dengan itu, stage `101`, buang head, set `await_preface2`. Request pada stream 1 dari upgrade tidak dilayani (klien gRPC memakai prior knowledge).

### frame_loop.run(comptime RouterType, conn) -> ConnOutcome

```
loop:
    buffered < 9 -> return .keep_alive
    header = parseFrameHeader
    header.length > max_frame_size + 256 -> stage GOAWAY FRAME_SIZE_ERROR, return .close
    buffered < 9 + length -> return .keep_alive
    maju melewati header + payload
    switch frame_type:
        SETTINGS     -> peer_settings.apply, stage SETTINGS ACK + WINDOW_UPDATE(0, CONN_WINDOW_BUMP)
        PING         -> stage PING ACK (payload bukan 8 byte: GOAWAY FRAME_SIZE_ERROR, tutup)
        HEADERS      -> stream 0: GOAWAY, tutup. Id ganjil dipakai ulang: RST STREAM_CLOSED.
                        claimSlot (tidak ada: RST REFUSED_STREAM), decode hpack (gagal: RST COMPRESSION_ERROR)
        CONTINUATION -> stream tak dikenal: GOAWAY, tutup. Selain itu decode header lanjutan
        DATA         -> stream 0: GOAWAY, tutup. Stream tak dikenal: RST STREAM_CLOSED.
                        replenish window koneksi melewati CONN_REPLENISH_THRESHOLD.
                        body melewati opts.max_body: stage trailer RESOURCE_EXHAUSTED, bebaskan slot
        RST_STREAM   -> bebaskan slot
        GOAWAY       -> return .close
    END_HEADERS dan END_STREAM sama-sama ada -> mux_dispatch.dispatchWhole, bebaskan slot
```

Setiap frame kontrol di-stage (`stage_frame`), jadi keluar dalam write yang sama dengan reply.

Batas body adalah `opts.max_body`, bukan panjang buffer pool, karena buffer pool bisa lebih besar.

### mux_dispatch

- `dispatchWhole(RouterType, conn, stream)`: body yang kurang dari (atau melewati) content-length-nya men-stage RST_STREAM PROTOCOL_ERROR (RFC 9113 section 8.1.1), selain itu `dispatch`.
- `dispatch(RouterType, conn, stream)`: membangun `Context` dengan `_out = &conn.stage` tanpa write lock, lalu memanggil handler lewat `handler.invoke`. Setiap route, unary dan streaming, berjalan inline di worker. Logger yang terpasang mendapat satu baris `rpc`.
- `hangupGoaway(conn)`: men-stage GOAWAY PROTOCOL_ERROR hanya saat masih ada request in flight.

Route server-streaming mendapat buffer coalesce per call (`ctx._coal`, `Context.STREAM_COALESCE_CAP`, 16 KiB), jadi pesan-pesannya berbagi DATA frame, bukan satu frame per pesan. Unary tetap satu frame per pesan. Route streaming juga berjalan di bawah `tcp_cork.set(fd, true)` / `set(fd, false)`, jadi flush stage yang dihasilkannya keluar dalam lebih sedikit segmen TCP. `tcp_cork.set` no-op di luar Linux dan pada socket tanpa TCP_CORK.

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

### builder.zig / send.zig

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

### server.zig

Hanya fungsi. `init(comptime RouterType, config)` mengembalikan `GrpcServer(RouterType)`, struct yang menyimpan config. `deinit` no-op.

`run` mengecek, berurutan:

1. `config.port == 0` -> `ZixHttp2_GrpcServer_PortNotConfigured`.
2. model dispatch: `.ASYNC` berjalan di semua platform, `.EPOLL` dan `.URING` berjalan di Linux. `.EPOLL` / `.URING` di luar Linux, `.IOCP`, dan `.KQUEUE` -> `ZixHttp2_GrpcServer_DispatchModel_NotSupported`.
3. `run(RouterType, config)` milik model itu. Error-nya diterjemahkan ke set server:
   - `dispatchError` (`.ASYNC`): `ResolveFailed`, `ListenFailed`, `AcceptFailed` tetap bernama sama.
   - `dispatchEpollError` / `dispatchUringError`: `ResolveFailed` dan `ListenFailed` tetap bernama sama. `OutOfMemory`, `SpawnFailed`, `SetupFailed`, `Unsupported` (dan `WaitFailed` untuk `.URING`) -> `ZixHttp2_GrpcServer_EpollSetupFailed` / `UringSetupFailed`.

### dispatch/async.zig

`run(comptime RouterType, config) Error!void` me-resolve `config.ip`, listen dengan `reuse_address` dan `config.kernel_backlog`, mencatat satu baris `listening on` lewat `log.logSystem`, lalu accept terus-menerus. Tiap koneksi masuk ke `io.async(ConnEntry(RouterType).serveOne, ...)`. `ConnEntry` mengikat Router comptime, karena `io.async` menerima fungsi biasa.

`serveOne` memasang response cache thread pool ini (`installCache`, ukurannya dari `effectiveCacheEntries` milik cache http2), menjalankan `serve.serveConn`, lalu menutup stream dan melepas cache. `ConnectionAborted` dilewati, kegagalan accept lainnya mengakhiri loop dengan `AcceptFailed`.

### log.zig

`logSystem(config, level, fmt, args)`: ke `config.logger.system` dengan tag `grpc`, atau ke `std.log` tanpa logger.

### dispatch/epoll.zig dan dispatch/uring.zig

Struktur sama dengan `dispatch/epoll.zig` / `uring.zig` milik http2. Keduanya `run(comptime RouterType, config)`:

1. me-resolve `config.ip`, lalu bind satu listener `reuse_address` per worker di thread pemanggil, berurutan sesuai worker (`workers`, 0 = jumlah CPU yang tersedia). Bind yang gagal kembali sebelum apa pun melayani.
2. memasang CPU steering `reuseport_cbpf` ke grup bila diminta. Kernel yang menolaknya mencatat warning dan memakai hash default.
3. spawn satu worker per listener dengan `worker_stack_size_bytes`. Router diikat oleh `WorkerEntry(RouterType)` (epoll) atau `Worker(RouterType)` (uring), karena `std.Thread.spawn` menerima fungsi biasa.
4. join semua worker. Worker yang tidak bisa memulai loop-nya menyetel `failed` dan `stop`, jadi seluruh grup berhenti dan `run` mengembalikan `SetupFailed`.

Tiap worker mem-pin dirinya ke satu CPU (`cpu_affinity.pinToCpu`), memasang response cache sendiri (`cache.installWorker`, dibebaskan saat kembali), dan menyimpan tabel slot ber-indeks fd (`slab.mapZeroedSlots`, `MAX_FD` = 65536). Fd di luar tabel ditutup. Fd yang di-accept mendapat TCP_NODELAY dan, bila `busy_poll_us` diisi, SO_BUSY_POLL. Loop menunggu paling lama 1 detik tiap kali, jadi ia melihat `stop`.

`.EPOLL` (level-triggered):

- event listener menjalankan `acceptAll`: `accept4` sampai EAGAIN, satu `MuxConn` per fd, didaftarkan untuk `EPOLLIN | EPOLLRDHUP`.
- event koneksi menjalankan `serveEvent`: `EPOLLHUP` / `EPOLLERR` menutupnya, selain itu `process.onReadable` membaca, memproses, dan mem-flush stage dalam satu write. `.close` membatalkan pendaftaran, membebaskan, dan menutup fd.

`.URING`:

- satu ring per worker (single issuer, deferred task run, 16 Ki entry CQ, turun ke ring polos). Tidak ada fallback ke `.EPOLL`.
- multishot accept. Re-arm yang hilang karena SQ penuh diulang di putaran berikutnya (`accept_pending`).
- `user_data` membawa op (`accept`, `recv`, `send`), generation 24-bit, dan fd, jadi completion untuk koneksi lama di fd yang dipakai ulang dibuang.
- completion recv menjalankan `process.processRing`, lalu mengirim `conn.stage` lewat ring. Hanya satu recv atau satu send yang berjalan per koneksi, jadi read buffer dan stage tidak pernah disentuh selama kernel memegangnya. Send parsial mengirim ulang sisanya.
- hang-up di tengah request men-stage GOAWAY (`mux_dispatch.hangupGoaway`) dan koneksi ditutup setelah send itu selesai (`closing`). Error send langsung menutup.
- saat berhenti, ring dibongkar sebelum koneksi, jadi tidak ada send yang masih membaca stage yang sudah dibebaskan.

---

###### end of lld-grpc
