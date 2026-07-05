# LLD: zix.Grpc (gRPC h2c)

Detail implementasi internal. Untuk rasional desain lihat [`docs/hld-grpc-id.md`](hld-grpc-id.md) dan ADR-031.

Model blocking (`.ASYNC`, `.POOL`, `.MIXED`) berbagi satu jalur koneksi (`serveGrpcConn` -> `serveGrpcLoop`). Model `.EPOLL` adalah jalur terpisah, multiplex, non-blocking (`grpcMuxOnReadable`) yang menjadi fokus utama dokumen ini.

---

## core.zig

### GrpcContext

Konteks handler per stream. Field yang relevan untuk keluaran:

```zig
fd: std.posix.fd_t,
stream_id: u31,
_hdr_sent: bool,
_write_mutex: ?*ConnMutex = null,   // hanya model streaming; null pada jalur mux
_out: ?*ReplyStage = null,          // diset pada jalur inline/mux: stage alih-alih write langsung
```

`sendMessage` / `sendHeaders` / `finish` bercabang pada `_out`: saat diset, mereka meng-append frame terenkode ke cork (tanpa lock per panggilan, tanpa `write` langsung). Saat null, mereka menulis langsung ke fd, mengambil `_write_mutex` jika ada task streaming konkuren yang mungkin menulis. Dispatch unary inline dan setiap dispatch mux memakai jalur staged. Server-streaming pada model blocking memakai jalur langsung.

### ReplyStage

Penulis cork untuk satu koneksi. Dipakai oleh dispatch unary inline (model blocking) dan oleh setiap dispatch pada jalur mux.

```zig
const ReplyStage = struct {
    fd: std.posix.fd_t,
    buf: []u8,                    // backing milik pemanggil, bukan array inline
    len: usize,

    fn append(self, bytes) void   // flush dulu jika akan overflow; payload > buf diteruskan langsung
    fn flush(self) void           // satu writeAllFD dari buf[0..len]; len = 0
};
```

`buf` adalah slice yang dipasok pemanggil. Jalur inline blocking (`dispatchGrpcInline`) menyokongnya dengan array stack 4096 byte (reply unary kecil). Jalur mux menyokongnya dengan `stage_buf` 64 KB milik koneksi (lihat `GrpcMuxConn`). Semua frame respons yang dihasilkan saat menangani satu event readable terkumpul di sini dan keluar dalam satu `write()`.

### ConnReader (model blocking)

Pembaca frame ber-buffer yang dipakai `serveGrpcLoop`. `ensure(n)` blocking sampai `n` byte ter-buffer (kompaksi bila perlu), `take(n)` mengembalikan dan memajukan. Mengganti pembacaan header 9-byte plus pembacaan payload per frame dengan pembacaan ter-batch.

### Stream

State parse per stream. `body` dan `header_scratch` adalah buffer berukuran `opts.max_body` / `opts.max_header_scratch`, bukan array inline. Pada path multiplex (`.EPOLL` / `.URING`) sebuah `Stream` dipinjam dari pool per-worker selama terbuka dan dikembalikan saat ditutup (`next_free` menautkannya ke freelist selagi idle), sehingga memori stream residen mengikuti stream konkuren pada worker, bukan `connections * max_streams`. Pada path blocking array-nya inline dan buffer-nya adalah slice ke backing per koneksi.

```zig
const Stream = struct {
    id: u31,
    state: StreamState,
    headers: [h2.MAX_HEADERS]h2.Header,
    header_count: usize,
    body: []u8,
    body_len: usize,
    header_scratch: []u8,
    end_headers: bool,
    end_stream: bool,
    next_free: ?*Stream,        // tautan freelist selagi idle di pool per-worker
};
```

Pada path mux `muxSlotFor(conn, stream_id)` meminjam `Stream` dari pool per-worker ke slot bebas pertama (`acquireGrpcStream` menumbuhkan freelist saat miss, `muxReleaseSlot` / `releaseGrpcStream` mengembalikannya saat ditutup), dan `muxFindSlot(stream_id, ...)` mencari stream terbuka berdasarkan id. Path blocking mempertahankan `slotFor` / `findSlot` array-inline. Semuanya scan linear atas `max_streams`.

### Konstanta flow-control

```zig
const STREAM_WINDOW_SIZE: u32 = 16 * 1024 * 1024;  // SETTINGS_INITIAL_WINDOW_SIZE yang diiklankan
const CONN_WINDOW_BUMP: u31 = 1 << 30;             // bump window koneksi sekali setelah handshake
const CONN_REPLENISH_THRESHOLD: usize = 1 << 29;   // titik replenish window koneksi secara bulk
```

Window stream cukup besar sehingga body request kecil tidak pernah butuh `WINDOW_UPDATE` stream per-DATA. Window koneksi di-bump sekali dan hanya di-replenish secara bulk melewati threshold.

### GrpcMuxConn (multiplex `.EPOLL`)

State per koneksi milik heap untuk model multiplex. Satu thread worker memiliki satu `GrpcMuxConn` sepanjang hidupnya.

```zig
pub const GrpcMuxConn = struct {
    fd: std.posix.fd_t,
    opts: GrpcServeOpts,

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

    pub fn init(fd, opts) ?*GrpcMuxConn   // satu alokasi per buffer; null saat OOM
    pub fn deinit(self) void
};
```

`rbuf` berukuran `max(32 KB, max_frame_size + 256 + 9)`.

`init` memanggil `buildSettingsFrame(&settings_frame, opts)` sekali untuk meng-encode blob SETTINGS server 33 byte (header 9 byte + 4 param), dan mengarahkan `stage.buf` ke `stage_buf` 64 KB. Handshake menambahkan `settings_frame` apa adanya (tanpa loop encode per koneksi). Stage 64 KB menggabungkan ~100 reply unary konkuren (~6 KB) menjadi satu write, dan reply server-streaming memadatkan pesan-pesannya menjadi DATA frame yang lebih sedikit dan lebih besar (lihat `muxDispatch`), sehingga reply ~5000 pesan pun tetap jauh di bawah stage dan keluar dalam satu write.

### grpcMuxOnReadable(comptime routes, conn) -> GrpcConnOutcome

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
     e. jika muxProcess(routes, conn) == .close -> flush, return .close
```

Membaca satu chunk, memproses frame lengkap, mengulang sampai `EAGAIN`. Epoll level-triggered memicu ulang bila ada lagi.

### muxProcess(comptime routes, conn) -> GrpcConnOutcome

Mesin fase handshake, lalu loop frame.

- `await_preface`: butuh 3 byte. Jika bukan `"PRI"`, set `await_upgrade` dan panggil `muxHandleUpgrade`. Selain itu butuh 24 byte, validasi preface koneksi, stage SETTINGS server, set `h2`.
- `await_upgrade`: `muxHandleUpgrade`.
- `await_preface2`: setelah `101`, validasi preface, stage SETTINGS, set `h2`.
- `h2`: `muxFrameLoop`.

### muxHandleUpgrade(conn)

Akumulasi sampai `\r\n\r\n`. Tanpa header `Upgrade: h2c`, stage `400` dan return `.close` (jalur probe validate). Dengan header itu, stage `101`, konsumsi header request, set `await_preface2`, return `.keep_alive`. Request awal pada stream 1 dari upgrade tidak dilayani (client prior-knowledge tidak memakai jalur ini).

### muxFrameLoop(comptime routes, conn) -> GrpcConnOutcome

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

### muxDispatch(comptime routes, conn, stream)

Membangun `GrpcContext` dengan `_out = &conn.stage` dan `_write_mutex = null` (worker memiliki koneksi, jadi tidak ada penulis konkuren), lalu `Router(routes).dispatch`. Setiap route, unary dan streaming, berjalan inline. `logger.rpc` opsional membungkus pemanggilan untuk timing.

Reply server-streaming dipadatkan pada lapisan gRPC. `muxDispatch` memberi route streaming sebuah buffer coalesce per-call (`ctx._coal`), dan `sendMessage` memadatkan pesan-pesan yang sudah ber-frame gRPC ke dalamnya, mengeluarkan satu DATA frame HTTP/2 per `grpc_stream_coalesce_cap` (16 KiB, max frame size default HTTP/2) alih-alih satu DATA frame per pesan. Reply `count = 5000` turun dari 5000 DATA frame kecil menjadi sekitar 3, memangkas byte header frame di wire dan biaya parse per-frame di sisi klien. Unary tetap satu frame per pesan (`_coal` null), jadi byte-nya persis sama.

Untuk route streaming (dideteksi oleh `routeIsStreaming(routes, path)`), dispatch dibungkus dalam `setTcpCork(conn.fd, true)` / `setTcpCork(conn.fd, false)`: kernel menahan output hingga MSS penuh atau cork dilepas, menggabungkan beberapa flush stage perantara yang dihasilkan handler streaming menjadi lebih sedikit segmen TCP. Route unary tidak di-cork (sudah keluar dalam satu write). `setTcpCork` no-op pada target non-Linux.

### Jalur blocking (serveGrpcConn / serveGrpcLoop)

Tidak berubah untuk `.ASYNC`, `.POOL`, `.MIXED`. `serveGrpcConn` mengeset `TCP_NODELAY` dan memanggil `serveGrpcConnInner`, yang menangani preface h2c-direct atau upgrade h2c, lalu `serveGrpcLoop`. Loop memakai `ConnReader` blocking dan switch frame yang sama, dispatch via `dispatchStream`: unary inline (`dispatchGrpcInline`, di-stage via `ReplyStage` di stack), server-streaming via `spawnGrpcStream` (satu thread terlepas, menyalin header dan body, menulis di bawah `ConnMutex` bersama).

---

## frame.zig

### build* / send*

Fungsi `build*` mengenkode frame ke buffer pemanggil dan mengembalikan jumlah byte, `send*` membungkusnya dengan `writeAllFD`.

```zig
pub fn buildGrpcHeaders(out, stream_id, content_type) usize     // HEADERS awal, tanpa END_STREAM
pub fn buildGrpcDataHeader(out, stream_id, msg_len) usize       // header DATA 9-byte + prefix gRPC 5-byte (pemanggil append payload)
pub fn buildGrpcTrailer(out, stream_id, grpc_status, msg) usize // trailer HEADERS, END_STREAM
pub fn buildGrpcError(out, stream_id, grpc_status, msg) usize   // HEADERS trailers-only, END_STREAM
```

### Blok reply cache

Dua blok header jalur panas yang konstan dienkode HPACK sekali di comptime:

```zig
pub const GRPC_CONTENT_TYPE = "application/grpc+proto";
const HEADERS_PROTO_BLOCK = ...;  // :status 200 + content-type application/grpc+proto
const TRAILER_OK_BLOCK = ...;     // grpc-status 0
```

`buildGrpcHeaders` memakai `HEADERS_PROTO_BLOCK` saat `content_type == GRPC_CONTENT_TYPE`, dan `buildGrpcTrailer` memakai `TRAILER_OK_BLOCK` saat `grpc_status == 0` dan pesan kosong. Keduanya lewat `emitCachedHeaders`, yang men-stamp header frame 9-byte (dengan stream id dan flags) dan `memcpy` blok cache - tanpa menjalankan encoder HPACK. Content-type atau status lain jatuh kembali ke encoder dinamis.

Blok diproduksi dengan menjalankan `HpackEncoder` asli di comptime, jadi byte-nya identik dengan keluaran dinamis. Ini menuntut `HpackEncoder.writeString` menandai hasil Huffman sebagai `?usize` (kalau tidak, comptime meruntuhkan optional saat cabang error secara statik tak terjangkau).

---

## server.zig dan dispatch/

### Dispatch (run)

`server.zig` memuat tipe publik `GrpcServer` dan `run()` switch tipis pada `dispatch_model`. Implementasi per-model berada di `dispatch/` (`async.zig`, `pool.zig`, `mixed.zig`, `epoll.zig`, `uring.zig`). `.ASYNC` / `.POOL` / `.MIXED` mempertahankan struktur accept-thread + pool `io.async` / `ConnQueue` dan memanggil `serveGrpcConn`. `.EPOLL` memanggil `epoll.runEpoll`. `.URING` memanggil `uring.runUring` (bentuk berbasis completion io_uring dari `.EPOLL`). Saat `cfg.tls != null`, `run()` justru bercabang ke `tls_mux.runTlsMux` (multiplex) atau `tls_serve.runTls` (blocking per koneksi).

Simbol `GrpcConnTable`, `acceptAll`, `epollMuxWorkerFn`, dan `runEpoll` di bawah semuanya berada di `dispatch/epoll.zig`.

### GrpcConnTable

Map fd ke `*GrpcMuxConn` privat per worker, ber-indeks langsung berdasarkan fd (sparse, `MAX_FD = 1 << 16`). `alloc` membangun `GrpcMuxConn`, `free`/`deinit` melepasnya. Tidak dibagi antar worker.

### acceptAll(table, epfd, listener_fd, opts)

Menguras `accept4(SOCK.NONBLOCK | SOCK.CLOEXEC)` sampai `EAGAIN` (level-triggered). Tiap fd yang diterima mendapat `TCP_NODELAY`, sebuah `GrpcMuxConn`, dan registrasi `EPOLL.IN | RDHUP`. Saat alokasi atau registrasi gagal, fd ditutup.

### epollMuxWorkerFn(routes)(ctx)

`epollMuxWorkerFn(comptime routes)` mengembalikan fungsi entry worker. Satu thread worker:

```
1. listener SO_REUSEPORT privat pada ip:port; setNonBlock
2. epoll_create1; tambah listener (EPOLL.IN)
3. GrpcConnTable.init
4. loop epoll_wait (hingga EPOLL_MAX_EVENTS = 512 event per pemanggilan):
     untuk tiap event:
       fd listener -> acceptAll
       fd koneksi  -> outcome = (HUP|ERR) ? .close : grpcMuxOnReadable(routes, conn)
                      jika .close -> epoll_ctl DEL, table.free, close
```

### runEpoll(comptime routes, cfg)

`worker_count = pool_size` (0 = jumlah cpu). Men-spawn `worker_count` thread `epollMuxWorkerFn(routes)` (stack 512 KB) dan join. Kernel menyeimbangkan koneksi lintas listener `SO_REUSEPORT` tiap worker.

---

###### end of lld-grpc
