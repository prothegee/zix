# LLD: zix.Http1

Detail implementasi internal untuk engine HTTP/1.x ramping. Untuk alasan desain lihat [`docs/hld-http1-id.md`](hld-http1-id.md).

---

## Http1.zig: namespace

Modul re-export murni. Menarik `Server` + `ServerConfig` + `DispatchModel`, tipe-tipe core (`HandlerFn`, `RawFn`, `ParsedHead`, `ParseResult`, `Range`, `ServeOpts`, `ConnOutcome`, `WsFrameFn`), router (`Route`, `RouteKind`, `Router`, `PathParam`, `pathParam`), namespace `WebSocket`, dan fungsi-fungsi core (deadline, parse, write helper) menjadi satu permukaan publik.

---

## config.zig: Http1ServerConfig

Struct polos dengan default, tanpa alokasi saat konstruksi. Field yang dibaca saat runtime:

| Field | Dibaca oleh |
| :- | :- |
| `io`, `ip`, `port`, `kernel_backlog` | semua model (resolve + listen) |
| `dispatch_model` | switch di `run()` |
| `workers` | jumlah accept .POOL, jumlah worker .MIXED dan .EPOLL |
| `pool_size` | jumlah pool thread .POOL |
| `handler_timeout_ms` | dipasang sebelum setiap dispatch di semua model |
| `max_recv_buf` | ukuran buffer per-connection .EPOLL (`ConnTable.alloc`) |
| `large_body_rcvbuf` | `SO_RCVBUF` khusus jalur body besar (upload), semua model, 0 = default kernel |
| `ws_recv_buf` | ukuran buffer per-connection WebSocket, 0 jatuh ke `max_recv_buf`. .EPOLL menentukan ukuran buffer recv, .URING menentukan ukuran buffer frame-accumulation (`conn.buf`) dan scratch unmask |
| `send_date_header` | write helper terkelola: menyertakan atau membuang header `Date` |
| `tls` | memilih jalur serve TLS saat non-null (native https), selain itu cleartext |
| `logger` | baris lifecycle `logSystem` |

`compression`, `compression_min_size`, dan `compression_max_out` (yang terakhir di-rename dari `max_gzip_out`) dibaca saat runtime pada `.EPOLL` dan `.URING`, di mana handler opt-in dengan `core.sendNegotiateFD`. Helper lama `core.sendGzipFD` masih memakai konstanta compile-time `core.GZIP_OUT_SIZE` (256 KB), dan `max_headers` tidak dibaca saat runtime: ia no-op yang dipertahankan untuk kompatibilitas sumber (engine lazy tidak punya batas jumlah header).

---

## core.zig: parsing, penulisan, loop koneksi

### Konstanta

```
BUF_SIZE      = 16 * 1024   // receive buffer (stack serveConn, scratch worker EPOLL)
GZIP_OUT_SIZE = 256 * 1024  // buffer output sendGzipFD
```

### parseHead()

```
1. indexOf "\r\n\r\n"            -> error.IncompleteHeader bila tidak ada
2. request line: pecah pada ' ' pertama (method), ' ' terakhir (versi)
      versi harus "HTTP/1.1" (minor 1) atau "HTTP/1.0" (minor 0), selain itu error.InvalidRequest
3. target dipecah pada '?'       -> path, query
4. raw_headers = slice dari setelah CRLF request-line sampai CRLF header terakhir
      (tanpa batas jumlah, dipindai sesuai kebutuhan oleh getHeader, kosong saat tanpa header)
5. framing scan melipat header yang dikenali menjadi flag saat menelusuri blok
      (hanya baris yang huruf pertamanya c, t, atau e yang ditokenisasi, lainnya dilewati):
      content-length    -> parseInt u64 (gagal parse -> 0)
      connection        -> "close" mematikan keep_alive, "keep-alive" menyalakannya
      transfer-encoding -> mengandung "chunked" menyalakan chunked_request
      expect            -> "100-continue" menyalakan expect_continue
6. default keep_alive: version_minor == 1
```

Semua slice di `ParsedHead` yang dikembalikan menunjuk ke `buf` (zero copy). Mengembalikan `.{ head, body_offset }` dengan `body_offset` byte pertama setelah baris kosong. `getHeader(head, name)` melakukan pencarian case-insensitive sesuai kebutuhan atas `raw_headers`, jadi biaya scan per-header hanya dibayar oleh handler yang memang membaca sebuah header.

`parseGetFastPath` (server.zig) adalah fast path keep-alive untuk request `GET` polos: ia memastikan prefix `"GET "` dan versi `"HTTP/1.1"` dengan integer load tunggal (`std.mem.readInt` satu `u32` dan satu `u64`, bukan `mem.eql`), mengekstrak path dan query secara aritmetika, dan hanya jatuh ke `parseHead` penuh bila `Connection: close` mungkin ada. Bentuk `ParsedHead` sama, tanpa scan per-header.

### recvHead()

Bulk-read ke `buf` sampai `\r\n\r\n` ditemukan. `pre_filled` byte sisa iterasi keep-alive sebelumnya dipindai lebih dulu. Setiap kali membaca, pemindaian diulang dari `filled - 3` sehingga CRLFCRLF yang terbelah antar read tetap ditemukan. `error.HeaderTooLarge` saat `buf` penuh tanpa baris kosong, `error.Closed` saat EOF atau read gagal.

### readChunkedBody()

Decoder chunked streaming (RFC 9112 7.1) untuk jalur blocking. Reader refill inline 16 KB di-seed dengan byte yang sudah terbaca melewati header. Per chunk: baca baris ukuran (ekstensi setelah `;` diabaikan), salin `chunk_size` byte ke `out` (dibatasi diam-diam di `out.len`, kelebihan dikonsumsi dan dibuang), harapkan CRLF. Chunk nol melompati bagian trailer sampai baris kosong terakhirnya. Mengembalikan jumlah byte hasil decode.

### Deadline handler thread-local

```
threadlocal tl_deadline_ns: u64 = 0   // 0 = tidak ada deadline terpasang

setTimeout(ms): tl_deadline_ns = (ms == 0) ? 0 : wallClockNs() + ms * 1e6
isExpired():    tl_deadline_ns != 0 dan wallClockNs() >= tl_deadline_ns
```

`wallClockNs()` adalah `clock_gettime(REALTIME)` mentah. Engine memanggil `setTimeout(opts.handler_timeout_ms)` sebelum setiap dispatch, sehingga deadline basi tidak pernah bocor ke request berikutnya.

### Handoff WebSocket thread-local

```
threadlocal tl_ws_pending: ?WsPending = null    // { fd, on_frame }

requestWebSocket(fd, cb): tl_ws_pending = .{ fd, cb }   // dipanggil WebSocket.serve
takeWebSocket():          baca + bersihkan              // dipanggil engine setelah setiap dispatch
```

`serveConn` / `serveConnOne` membersihkan handoff dan menutup koneksi (promosi hanya untuk EPOLL). Loop parse EPOLL menyimpan callback ke `conn.ws` dan mengalihkan koneksi ke pemompaan frame.

### RespSink: penggabungan response per-event

```zig
RespSink = { fd, buf, len, failed, grow_allocator, grow_cap }
threadlocal tl_resp_sink: ?*RespSink = null
```

Selama terpasang, `writeAllFD(fd, ...)` untuk fd yang cocok menambahkan ke `buf` alih-alih menyentuh socket:

```
append(bytes):
  bytes.len > buf.len        -> tumbuhkan agar muat bila growable, selain itu flush + tulis langsung
  len + bytes.len > buf.len  -> tumbuhkan agar muat bila growable, selain itu flush dulu
  selain itu                 -> memcpy ke buf
flush(): satu writeAllDirectFD(buf[0..len]), len = 0, failed lengket saat error
grow(need): realloc buf (power-of-two) hingga grow_cap, tidak pernah menyusut, false bila tak-growable
```

Loop request EPOLL (`serveEpollConn`) memasang sink tanpa `grow_allocator`, jadi burst pipelined N response berbiaya satu `write()` dan response oversized mem-flush batch lalu menulis langsung. Loop URING memasang sink di atas `send_buf` per-koneksi dengan `grow_allocator` diset dan `grow_cap = URING_SEND_BUF_MAX` (1 MiB): response yang lebih besar dari buffer ter-stage menumbuhkannya di tempat (realloc power-of-two) sehingga seluruh balasan tetap keluar sebagai satu on-ring send, alih-alih menahan worker di write off-ring yang memblokir (`writeAllDirectFD`). Buffer yang ditumbuhkan tidak pernah menyusut, jadi koneksi yang didaur ulang memakainya ulang untuk request berikutnya. `flushPending(fd)` memungkinkan handler yang melewati helper (sendfile, raw send) mem-flush byte yang tertahan lebih dulu agar urutan di kabel sama dengan urutan request.

### writeAllFD() / writeAllDirectFD()

`writeAllFD` melewati sink yang terpasang saat fd cocok, selain itu memanggil jalur langsung. Loop jalur langsung:

```
write(fd, rem)
  SUCCESS -> maju (0 byte tertulis = error.BrokenPipe)
  INTR    -> ulangi
  AGAIN   -> poll(POLLOUT, tak terbatas) lalu ulangi   // socket non-blocking, send buffer penuh
  lainnya -> error.BrokenPipe
```

Semua error write diringkas menjadi `error.BrokenPipe`: satu-satunya penanganan pemanggil adalah menutup koneksi.

### buildSimpleHeader() dan date cache

Header tetap ditahapkan ke buffer 256 byte milik pemanggil dengan append manual (tanpa `std.fmt` di hot path):

```
"HTTP/1.1 " + status 3 digit + ' ' + statusPhrase
["Content-Type: {s}\r\n" saat content_type.len > 0]
"Content-Length: " + appendDec
"\r\nDate: " + cachedDate() + "\r\n\r\n"
```

Untuk status yang dikenal, seluruh baris `"HTTP/1.1 <code> <phrase>\r\n"` ditulis dalam satu `memcpy` dari tabel `statusLine` yang dibaked pada comptime, alih-alih merakitnya dari lima potongan (`"HTTP/1.1 "` + `appendStatusCode` + `' '` + `statusPhrase` + `"\r\n"`) per response. `statusLine` mengembalikan `""` untuk kode tak dikenal, di mana build jatuh ke jalur piecewise di atas, byte-identik dengan baris yang dibaked. `statusPhrase` mencakup kode umum yang sama (selain itu mencetak `Unknown`); `appendStatusCode` dan `appendDec` adalah penulis digit manual untuk fallback itu.

**Date cache per-thread:**

```
threadlocal tl_date: { secs, buf[40], len }
threadlocal tl_date_tick: u8

cachedDate():
  tick +%= 1
  hanya saat tick wrap (setiap 256 panggilan) atau pemakaian pertama:
      clock_gettime(REALTIME)
      format ulang hanya saat detiknya berubah
```

String IMF-fixdate diformat ulang paling banyak sekali per detik per thread, dan syscall clock-nya sendiri diamortisasi atas 256 response. `formatHttpDate` memakai dekomposisi `std.time.epoch`, hari-dalam-minggu dari `(epoch_day % 7 + 4) % 7`.

### sendSimpleFD()

```
1. buildSimpleHeader ke buffer stack 256 byte
2. body.len <= 3840:
      memcpy header + body ke satu buffer stack 4096 byte
      satu writeAllFD                          // satu syscall untuk mayoritas response
3. body lebih besar: loop writev dengan 2 iovec (sisa header, body)
      melacak sent antar partial write, INTR mengulang, AGAIN melakukan poll POLLOUT
```

### Write helper lainnya

| Helper | Perilaku di kabel |
| :- | :- |
| `sendSimpleNoBodyFD` | `buildSimpleHeader` saja, Content-Length diisi ukuran body seandainya ada (HEAD) |
| `sendJsonFD` | `sendSimpleFD` dengan `application/json` |
| `send100ContinueFD` | literal `HTTP/1.1 100 Continue\r\n\r\n` |
| `sendGzipFD` | alokasi heap 256 KB out + flate window + compressor (keamanan stack), kompresi `std.compress.flate` `.gzip`, lalu header (`Content-Encoding: gzip`) + byte terkompresi |
| `sendChunkedStartFD` | status line + `Transfer-Encoding: chunked`, tanpa Content-Length |
| `sendChunkFD` | `{x}\r\n` + data + `\r\n`, data kosong adalah no-op (akan mengakhiri body) |
| `sendChunkedEndFD` | `0\r\n\r\n` |
| `sendRangeFD` | `parseRange` terhadap `full_body.len`: valid menghasilkan `206` + `Content-Range` + slice, tidak valid menghasilkan `416` dengan `Content-Range: bytes */{total}` |

### serveConn(): loop keep-alive blocking

Dipakai .ASYNC, .POOL, dan .MIXED. State stack: `recv_buf[16 KB]`, `body_buf[8 KB]`, `leftover: usize`.

```
0. TCP_NODELAY (opts.nodelay, dilewati di Windows)
loop:
  1. recvHead(fd, recv_buf, leftover)
        HeaderTooLarge -> tulis 431, return
  2. parseHead -> gagal: tulis 400, return
  3. expect_continue dan ada body -> send100ContinueFD
  4. body:
        chunked        -> readChunkedBody(peeked, body_buf)
        content_length -> salin byte peeked, baca sampai min(content_length, 8192)
  5. setTimeout(handler_timeout_ms), handler(head, body, fd)
  6. takeWebSocket() != null -> return   // promosi tidak dihormati di sini
  7. !keep_alive -> return
  8. pipelining: byte setelah request_end digeser ke depan recv_buf, leftover diperbarui
        request chunked me-reset leftover ke 0
```

Pemanggil (connEntry / poolEntry) yang menutup fd. Body Content-Length di atas `body_buf` (8 KB) memberi handler 8 KB pertama, lalu `serveConn` membuang sisanya dari socket (dan melebarkan receive window via `large_body_rcvbuf` / SO_RCVBUF) sehingga koneksi keep-alive tetap dapat dipakai. Handler body besar membaca `head.content_length`, bukan byte-nya.

### serveConnOne(): fallback one-shot EPOLL

Urutan parse + body + dispatch yang sama dengan satu iterasi `serveConn` di atas buffer milik pemanggil, mengembalikan `ConnOutcome` alih-alih melakukan loop. Dipertahankan untuk pemakaian dispatch one-shot, engine EPOLL sendiri memakai jalur `serveEpollConn` yang ter-buffer di server.zig.

---

## router.zig: Router comptime

### Partisi comptime

`Router(routes)` menghitung tiap kind dalam blok comptime, lalu membangun:

```
exact_pairs   [exact_count]{ path, handler }  -> StaticStringMap.initComptime
prefix_routes [prefix_count]Route             -> inline for saat dispatch
param_routes  [param_count]Route              -> inline for saat dispatch
```

Tipe yang dikembalikan punya satu decl, `dispatch`, dengan signature `HandlerFn` persis, sehingga router dapat dipasang di mana pun handler polos bisa.

### dispatch()

```
1. tl_param_count = 0
2. exact_map.get(path)                 -> panggil handler, return
3. inline for param_routes: matchParam -> panggil handler, return  (cocok pertama menang)
4. inline for prefix_routes: startsWith + cek batas (karakter berikutnya '/' atau akhir)
       lacak kecocokan terpanjang      -> panggil handler terbaik
5. tidak ada yang cocok                -> sendSimpleFD 404 text/plain
```

### matchParam() dan penyimpanan param

```
threadlocal tl_params: [8]PathParam
threadlocal tl_param_count: usize
```

Memecah pattern dan path pada `/` secara berpasangan. Segmen `:name` menangkap (segmen path kosong ditolak, lebih dari 8 tangkapan ditolak), segmen literal harus cocok persis, jumlah segmen harus sama. Tangkapan ditulis ke `tl_params` saat cocok, tetapi `tl_param_count` baru di-commit saat sukses penuh, sehingga kandidat yang gagal tidak pernah merusak kecocokan berikutnya. `pathParam(name)` adalah pemindaian linear atas entri yang ter-commit. Nilainya slice ke path request dan mati bersama pemanggilan dispatch.

---

## server.zig: model dispatch

### logSystem()

Baris lifecycle dirutekan melalui `config.logger.system(.INFO, "http1", ...)` bila ada. Tanpa logger, baris jatuh ke `std.debug.print` dengan prefix `zix: ` hanya pada Debug build (`builtin.mode == .Debug`), dan diam pada release. Setiap server zix memakai bentuk `logSystem` ter-gate yang sama (http, http2, grpc, fix, tcp, udp, uds), jadi release build tanpa logger tidak mengeluarkan init noise.

### connEntry() (badan task .ASYNC / .MIXED)

```
defer stream.close(io)
core.serveConn(stream.socket.handle, handler, .{ .handler_timeout_ms })
```

### runAsync()

```
1. resolve + listen (reuse_address = true, kernel_backlog)
2. accept loop: srv.accept(io) catch continue
      io.async(connEntry, ...)        // handle dibuang, task memiliki stream
```

### ConnQueue (.POOL)

Ring buffer yang dapat tumbuh, dijaga `std.Io.Mutex` + `std.Io.Condition`:

```
push: lock -> tumbuh x2 saat penuh (gagal alloc menutup stream alih-alih mendorong)
      -> buf[(head + len) % cap] = stream -> unlock -> signal
pop:  lock -> while kosong: closed ? return null : waitUncancelable
      -> ambil buf[head], head maju modulo cap -> unlock
close: lock -> closed = true -> unlock -> broadcast
```

Penyimpanan memakai `std.heap.smp_allocator`. Entri yang ada dipadatkan ulang ke indeks 0 saat tumbuh.

### runPool()

```
1. worker_count = workers == 0 ? cpu_count : workers
2. pool_count   = pool_size == 0 ? max(10, cpu_count * 2) : pool_size
3. spawn pool_count thread poolEntry (stack 512 KB): pop -> serveConn -> close
4. spawn worker_count thread acceptEntry (stack 256 KB): listener SO_REUSEPORT sendiri -> accept -> push
5. join accept thread, queue.close(), join pool thread
```

### runMixed()

`worker_count` accept thread, masing-masing dengan listener `SO_REUSEPORT` sendiri, men-dispatch `connEntry` via `io.async()`. Thread sengaja di-spawn dengan ukuran stack default: stack eksplisit 256 KB meluap saat `io.async` jatuh kembali ke dispatch inline (serveConn butuh ~128 KB stack).

### Engine EPOLL

Hanya Linux (`run()` jatuh kembali ke `runPool` di tempat lain, dengan notice di log). Shared-nothing: setiap worker memiliki listener `SO_REUSEPORT` pribadi, instance epoll pribadi, dan `ConnTable` pribadi, sehingga tidak ada fd atau slot yang pernah disentuh dua thread.

#### Conn dan ConnTable

```zig
Conn = {
    fd, buf, filled,                  // buf: max_recv_buf byte, filled: jumlah byte hidup
    ws: ?WsFrameFn = null,            // diisi saat promosi WebSocket
    drain: usize = 0,                 // byte body oversize yang masih harus dibuang
    drain_close: bool = false,        // tutup setelah drain selesai
}
```

`ConnTable` adalah `[]?*Conn` datar yang diindeks fd, `MAX_FD = 1 << 16` slot. Linux memberikan fd bebas terendah sehingga tabel tetap padat di bagian bawah. `alloc` membuat Conn + buffer (gagal menutup fd), `free` melepas keduanya dan me-null slot. Koneksi dengan fd >= MAX_FD ditolak.

#### epollWorker()

```
1. listener pribadi (reuse_address) -> setNonBlock(listener_fd)
2. epoll_create1(CLOEXEC), CTL_ADD listener (EPOLLIN)
3. scratch per-worker: body_buf[16 KB] + out_buf[16 KB] (smp_allocator)
4. event loop, EPOLL_MAX_EVENTS = 4096 per epoll_wait:
      event listener       -> acceptAll
      HUP/ERR              -> close
      conn.drain > 0       -> serveEpollDrain
      conn.ws != null      -> serveEpollWs
      selain itu           -> serveEpollConn
      outcome == .close    -> CTL_DEL + table.free + close(fd)
```

#### acceptAll()

`accept4(NONBLOCK | CLOEXEC)` dikuras sampai EAGAIN (listener level-triggered, sehingga tidak ada accept yang terlewat). Setiap fd yang diterima: TCP_NODELAY, `table.alloc(fd, max_recv_buf)`, `CTL_ADD` dengan `EPOLLIN | EPOLLRDHUP`. Gagal registrasi menutup fd.

#### serveEpollConn() / serveEpollConnInner()

Fungsi luar memasang `RespSink` di atas `out_buf` di sekeliling pass parse, mem-flush setelahnya, dan langsung menyerahkan koneksi yang baru dipromosikan ke `serveEpollWs` (client bisa mem-pipeline frame pertamanya bersama request handshake, dan flush menjamin 101 mendahului echo pertama).

Pass dalam:

```
1. read ke conn.buf[filled..]:
      SUCCESS n=0 -> .close, AGAIN -> lanjut dengan yang ter-buffer, INTR -> ulangi
      filled == buf.len sebelum read -> 431, .close
2. loop parse atas conn.buf[consumed..filled]:
      tanpa "\r\n\r\n" -> break (head parsial, tunggu byte berikutnya)
      parseHead gagal -> 400, .close
      body:
        chunked        -> decodeChunkedInBuf (seluruh body harus ter-buffer, selain itu break)
        muat di rem    -> body = slice, request_len = need
        need > buf.len -> oversize: dispatch dengan body kosong, set conn.drain ke sisa
                          yang belum terbaca, conn.drain_close = !keep_alive,
                          reset filled, return .keep_alive
        selain itu     -> break (body masih berdatangan)
      setTimeout + handler(head, body, fd)
      takeWebSocket() -> conn.ws = callback, break  // byte setelah ini adalah frame
      !keep_alive -> break
3. geser byte yang belum dikonsumsi ke depan buffer (request parsial pipelined terjaga)
```

Satu readable event karenanya melayani setiap request pipelined lengkap yang dibawanya, dengan semua response keluar dalam satu write gabungan.

#### decodeChunkedInBuf()

Varian non-streaming dari decoder chunked untuk jalur ter-buffer: mensyaratkan seluruh body chunked (sampai CRLF terakhir trailer) ada di `src`, mengembalikan `{ panjang decode, consumed }` atau null untuk menunggu byte berikutnya. Kehabisan ruang juga mengembalikan null (diperlakukan sebagai belum lengkap, koneksi akhirnya 431 atau tertutup).

#### serveEpollWs()

Satu read (level-triggered, byte tersisa memicu ulang event), lalu `ws.pump` atas byte yang ter-buffer, lalu penggeseran standar byte yang belum dikonsumsi. Menutup saat EOF peer, close frame, write gagal, atau frame yang lebih lebar dari seluruh buffer (tidak pernah bisa lengkap, akan berputar tanpa kemajuan).

#### serveEpollDrain()

Membuang `conn.drain` byte dengan `recvfrom(MSG_TRUNC)`: kernel menjatuhkan byte di tempat, tanpa salinan ke `conn.buf`, ukuran per panggilan tidak dibatasi buffer (dibatasi 1 GB per panggilan). Membaca sampai EAGAIN, tidak pernah melewati `conn.drain`, sehingga byte request pipelined berikutnya tidak tersentuh. Saat drain mencapai nol: `.close` bila `drain_close`, selain itu kembali ke parsing HTTP normal.

### Engine URING

Hanya Linux (`run()` jatuh kembali ke `runPool` di tempat lain). Kembaran berbasis completion dari Engine EPOLL: topologi shared-nothing yang sama (satu `SO_REUSEPORT` listener dan satu ring `io_uring` per worker, tanpa queue bersama, tanpa handoff fd), tetapi digerakkan oleh completion alih-alih readiness, sehingga sebagian besar transisi syscall di-batch ke dalam ring (ADR-037).

#### UringConn dan slot table

```zig
UringConn = {
    fd, gen, buf, filled,             // gen: u24 generation tag terhadap reuse fd
    send_buf, staged, inflight,       // send_buf[0..inflight] dipegang kernel selama send in-flight
    closing,                          // bebaskan setelah send terakhir mendarat
    drain: usize = 0,                 // byte body oversize yang masih harus dibuang (mirror Conn.drain)
    drain_close: bool = false,
    ws: ?WsFrameFn = null,
}
```

`slots` adalah `[]?*UringConn` datar yang diindeks fd (`MAX_FD` entri). `user_data` setiap completion mengemas `{ op, gen, fd }`, dan `lookup` menolak CQE yang `gen`-nya tidak lagi cocok dengan slot, yang menutup race close-versus-recv pada fd yang digunakan ulang. Sebuah koneksi bersifat half-duplex (paling banyak satu recv atau satu send in-flight), sehingga flush sink yang blocking tidak pernah bisa menyela send yang sedang in-flight.

#### initUringRing()

`IoUring.init_params` dengan `SINGLE_ISSUER | DEFER_TASKRUN | CQSIZE | CLAMP` (fast path single-issuer pada loop one-thread-per-ring, plus completion queue yang diperbesar), jatuh kembali ke `IoUring.init` tanpa flag pada kernel yang tidak memilikinya. SQ `URING_ENTRIES = 4096`, CQ `URING_CQ_ENTRIES = 16 K`.

#### run() loop

```
1. armAccept (multishot)
2. submit_and_wait(1), copy_cqes ke array stack 512-entri
3. per CQE, switch pada user_data.op:
      accept -> handleAccept   // re-arm saat !IORING_CQE_F_MORE, alloc conn, armRecv
      recv   -> handleRecv
      send   -> handleSend
```

#### armRecv() / handleRecv() / dispatch()

`armRecv` memposting SQE `recv` biasa ke `conn.buf[filled..]`, sehingga data mendarat di tempat tanpa salinan. `handleRecv` menambahkan `cqe.res` byte, lalu `dispatch` menjalankan loop parse, mencerminkan `serveEpollConnInner` tanpa pembacaan. Body chunked yang sepenuhnya ada di `conn.buf` di-decode di tempat via `decodeChunkedInBuf` ke `body_buf` per-worker. Body yang lebih besar dari `conn.buf` dijawab dengan body kosong, `conn.drain` di-set ke sisa yang belum dibaca, dan drain (di bawah) mengambil alih. Response di-stage ke `conn.send_buf` melalui `RespSink`, sehingga burst pipelined menyatu menjadi satu `submitSend`.

#### armDrainRecv()

Kembaran ring dari `serveEpollDrain`. Memposting SQE `recv` dengan `MSG_TRUNC` dan `sqe.len` ditimpa menjadi `min(conn.drain, 1 GB)`: kernel membuang byte body di tempat (tanpa salinan ke `conn.buf`, request tidak dibatasi panjang buffer), sehingga satu recv menguras seluruh sisa body alih-alih satu round-trip per `max_recv_buf`. `handleRecv` menghitung mundur byte yang dikuras dan re-arm sampai `conn.drain` mencapai nol, lalu kembali ke pembacaan normal (atau menutup saat `drain_close`). Membatasi request pada `conn.drain` membuat byte pipelined setelah body tetap tak tersentuh. Dicakup oleh runner `test-runner-http1-drain-{epoll,uring}`, yang mem-pipeline POST over-large lalu GET lanjutan pada satu koneksi keep-alive.

#### WebSocket di ring

`IoUring.BufferGroup` per-worker (provided-buffer ring) melayani recv WebSocket (Phase 4b): kernel menyerahkan buffer hanya saat sebuah frame tiba, sehingga koneksi idle tidak mengikat recv buffer apa pun, kemenangan memory-scaling pada jumlah koneksi tinggi. `wsHandleBuf` mem-parse satu batch whole-frame di tempat dari buffer yang dipilih (zero copy) dan hanya menyalin frame parsial yang tertinggal ke `conn.buf`. Kernel tanpa dukungan buffer-ring membiarkan `ws_bufs` null, dan WebSocket jatuh kembali ke jalur plain recv-into-`conn.buf`.

#### finishClose(): teardown ring (ADR-041)

Teardown menutup fd di ring, bukan secara sinkron. `finishClose` membaca fd, mendaur ulang slot koneksi lebih dulu (`destroyConn`, yang membersihkan slot dan mengembalikan koneksi ke free list), lalu mengirim SQE `prep_close` yang ditag dengan `OpKind.close`. Ia jatuh ke `linux.close` sinkron hanya saat SQ sesaat penuh. State per-koneksi half-duplex menjamin tidak ada op in-flight yang menyasar fd yang sedang ditutup, dan mendaur ulang slot sebelum close selesai aman karena tag generation menolak CQE telat apa pun terhadap fd yang dipakai ulang. Completion `close` adalah no-op (slot sudah bebas). Ini penting di bawah connection churn: `close` sinkron per teardown memblokir worker antar koneksi, jadi di mesin 64-core ring nyaris tidak mengaktifkan core-nya di bawah reconnect storm (limited-conn, json). Menjaga close di ring membuat worker terus memanen completion lintas teardown, sehingga core terisi. Lihat ADR-041 untuk pengukuran 64-core.

`OpKind` bersama (dengan varian `close`) berada di `src/multiplexers/ring.zig` (dipindahkan dari `src/tcp/io_uring`), sehingga setiap engine io_uring membawa arm `.close => {}`. Hanya `zix.Http1` yang meng-arm-nya untuk saat ini.

### Http1ServerImpl / Server

```zig
fn Http1ServerImpl(comptime handler: HandlerFn) type
    init(config) -> .{ .config = config }   // tidak ada socket dibuka, tidak ada alokasi
    deinit()     -> no-op
    run()        -> switch dispatch_model (.EPOLL dipagari Linux saat comptime)

Server.init(comptime handler, config) -> Http1ServerImpl(handler).init(config)
```

Handler dibakukan ke dalam tipe sehingga `run()` tidak menerima argumen dan dispatch adalah panggilan langsung, bukan pemuatan function pointer dari config.

---

## websocket.zig: codec RFC 6455 + pump engine

### Konstanta format frame

```
panjang 7-bit maksimum 125, 126 = extended 16-bit, 127 = extended 64-bit
mask key 4 byte (frame client selalu masked)
header frame server maksimum 10 byte
```

### parseFrame()

```
1. minimal butuh 2 byte
2. byte 0: FIN + opcode, byte 1: MASK + panjang 7-bit
3. panjang extended (2 atau 8 byte) saat ditandai
4. mask key saat MASK terpasang
5. payload dibatasi payload_buf.len:
      masked   -> XOR-unmask ke payload_buf
      unmasked -> slice zero-copy ke buf
6. mengembalikan { frame, consumed } atau null saat byte masih kurang
```

Jalur masked meng-unmask dengan XOR `@Vector(16, u8)` selebar 16 byte terhadap mask 4 byte yang direplikasi empat kali, memproses 16 byte per iterasi, dengan ekor skalar `i % 4` untuk byte sisa. Ini menggantikan loop per-byte dan cocok bit-per-bit dengannya (tercakup oleh tes unmask 32 byte dan 17 byte).

### buildHeader() / buildFrame()

`buildHeader` menulis FIN | opcode lalu bentuk panjang 7-bit / 16-bit / 64-bit ke buffer >= 10 byte, mengembalikan panjang header. `buildFrame` menambahkan payload setelah header (buffer harus memuat payload + 10). Frame server unmasked sesuai RFC 6455 5.1.

### acceptKey() / upgrade()

`acceptKey` menyambung key client dengan GUID RFC 6455, SHA-1, base64 ke `[64]u8` milik pemanggil (`error.KeyTooLong` melewati 128 byte input). `upgrade` menulis blok `101 Switching Protocols` penuh melalui `core.writeAllFD` (sadar sink, sehingga pada EPOLL ditahapkan bersama response lain).

### send() dan SendSink

`SendSink` adalah kembaran WebSocket dari `RespSink` core (aturan append / flush / write-through yang sama), dipasang thread-local oleh `pump` selama satu pass.

```
send(fd, opcode, payload):
  sink aktif -> tahapkan header lalu payload       (error.BrokenPipe bila sink gagal)
  payload + header <= 4096 -> bangun satu buffer, satu writeAllFD
  lebih besar -> tulis header lalu payload terpisah (menghindari salinan stack besar)
```

### serve()

`acceptKey` + `upgrade` + `core.requestWebSocket(fd, on_frame)`. Dipanggil dari dalam handler http1. Engine menghormati promosi hanya pada `.EPOLL`.

### pump()

```
pasang SendSink(out_buf)
loop atas data:
  parseFrame orelse break        // frame parsial di ekor disisakan untuk read berikutnya
  text/binary -> on_frame(fd, opcode, payload)
  ping        -> kirim pong (payload digema)
  close       -> kirim close, konsumsi, berhenti dengan close = true
  pong/continuation/lainnya -> diabaikan
flush sink
return { consumed, close: close atau sink.failed }
```

`consumed` hanya menghitung frame utuh, sehingga penggeseran buffer engine menjaga frame parsial tetap utuh.

---

###### end of lld-http1
