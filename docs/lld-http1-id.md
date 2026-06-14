# LLD: zix.Http1

Detail implementasi internal untuk engine HTTP/1.x ramping. Untuk alasan desain lihat [`docs/hld-http1-id.md`](hld-http1-id.md).

---

## Http1.zig: namespace

Modul re-export murni. Menarik `Server` + `ServerConfig` + `DispatchModel`, tipe-tipe core (`HandlerFn`, `RawFn`, `ParsedHead`, `Header`, `Range`, `ServeOpts`, `ConnOutcome`, `WsFrameFn`), router (`Route`, `RouteKind`, `Router`, `PathParam`, `pathParam`), namespace `WebSocket`, dan fungsi-fungsi core (deadline, parse, write helper) menjadi satu permukaan publik.

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
| `ws_recv_buf` | ukuran buffer per-connection WebSocket .EPOLL, 0 jatuh ke `max_recv_buf` |
| `send_date_header` | write helper terkelola: menyertakan atau membuang header `Date` |
| `logger` | baris lifecycle `logSystem` |

`max_gzip_out` dan `max_headers` tidak dibaca saat runtime: batas yang berlaku adalah konstanta compile-time `core.GZIP_OUT_SIZE` (256 KB) dan `core.MAX_HEADERS` (16).

---

## core.zig: parsing, penulisan, loop koneksi

### Konstanta

```
MAX_HEADERS   = 16          // ukuran array ParsedHead.headers
BUF_SIZE      = 16 * 1024   // receive buffer (stack serveConn, scratch worker EPOLL)
GZIP_OUT_SIZE = 256 * 1024  // buffer output writeGzip
```

### parseHead()

```
1. indexOf "\r\n\r\n"            -> error.IncompleteHeader bila tidak ada
2. request line: pecah pada ' ' pertama (method), ' ' terakhir (versi)
      versi harus "HTTP/1.1" (minor 1) atau "HTTP/1.0" (minor 0), selain itu error.InvalidRequest
3. target dipecah pada '?'       -> path, query
4. baris header sampai baris kosong:
      tanpa ':' di baris -> dilewati (toleran)
      melebihi MAX_HEADERS -> error.TooManyHeaders
      offset value melompati spasi setelah ':'
5. header yang dikenali dilipat menjadi flag saat pemindaian:
      content-length    -> parseInt u64 (gagal parse -> 0)
      connection        -> "close" mematikan keep_alive, "keep-alive" menyalakannya
      transfer-encoding -> mengandung "chunked" menyalakan chunked_request
      expect            -> "100-continue" menyalakan expect_continue
6. default keep_alive: version_minor == 1
```

Semua slice di `ParsedHead` yang dikembalikan menunjuk ke `buf` (zero copy). Mengembalikan `.{ head, body_offset }` dengan `body_offset` byte pertama setelah baris kosong.

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
RespSink = { fd, buf, len, failed }
threadlocal tl_resp_sink: ?*RespSink = null
```

Selama terpasang, `fdWriteAll(fd, ...)` untuk fd yang cocok menambahkan ke `buf` alih-alih menyentuh socket:

```
append(bytes):
  bytes.len > buf.len        -> flush, lalu tulis langsung (urutan terjaga)
  len + bytes.len > buf.len  -> flush dulu
  selain itu                 -> memcpy ke buf
flush(): satu fdWriteAllDirect(buf[0..len]), len = 0, failed lengket saat error
```

Hanya dipasang oleh loop request EPOLL (`serveEpollConn`), sehingga burst pipelined N response berbiaya satu `write()`. `flushPending(fd)` memungkinkan handler yang melewati helper (sendfile, raw send) mem-flush byte yang tertahan lebih dulu agar urutan di kabel sama dengan urutan request.

### fdWriteAll() / fdWriteAllDirect()

`fdWriteAll` melewati sink yang terpasang saat fd cocok, selain itu memanggil jalur langsung. Loop jalur langsung:

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

`statusPhrase` mencakup 20 kode umum, selain itu mencetak `Unknown`. `appendStatusCode` dan `appendDec` adalah penulis digit manual.

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

### writeSimple()

```
1. buildSimpleHeader ke buffer stack 256 byte
2. body.len <= 3840:
      memcpy header + body ke satu buffer stack 4096 byte
      satu fdWriteAll                          // satu syscall untuk mayoritas response
3. body lebih besar: loop writev dengan 2 iovec (sisa header, body)
      melacak sent antar partial write, INTR mengulang, AGAIN melakukan poll POLLOUT
```

### Write helper lainnya

| Helper | Perilaku di kabel |
| :- | :- |
| `writeSimpleNoBody` | `buildSimpleHeader` saja, Content-Length diisi ukuran body seandainya ada (HEAD) |
| `writeJson` | `writeSimple` dengan `application/json` |
| `write100Continue` | literal `HTTP/1.1 100 Continue\r\n\r\n` |
| `writeGzip` | alokasi heap 256 KB out + flate window + compressor (keamanan stack), kompresi `std.compress.flate` `.gzip`, lalu header (`Content-Encoding: gzip`) + byte terkompresi |
| `writeChunkedStart` | status line + `Transfer-Encoding: chunked`, tanpa Content-Length |
| `writeChunk` | `{x}\r\n` + data + `\r\n`, data kosong adalah no-op (akan mengakhiri body) |
| `writeChunkedEnd` | `0\r\n\r\n` |
| `writeRange` | `parseRange` terhadap `full_body.len`: valid menghasilkan `206` + `Content-Range` + slice, tidak valid menghasilkan `416` dengan `Content-Range: bytes */{total}` |

### serveConn(): loop keep-alive blocking

Dipakai .ASYNC, .POOL, dan .MIXED. State stack: `recv_buf[16 KB]`, `body_buf[8 KB]`, `leftover: usize`.

```
0. TCP_NODELAY (opts.nodelay, dilewati di Windows)
loop:
  1. recvHead(fd, recv_buf, leftover)
        HeaderTooLarge -> tulis 431, return
  2. parseHead -> gagal: tulis 400, return
  3. expect_continue dan ada body -> write100Continue
  4. body:
        chunked        -> readChunkedBody(peeked, body_buf)
        content_length -> salin byte peeked, baca sampai min(content_length, 8192)
  5. setTimeout(handler_timeout_ms), handler(head, body, fd)
  6. takeWebSocket() != null -> return   // promosi tidak dihormati di sini
  7. !keep_alive -> return
  8. pipelining: byte setelah request_end digeser ke depan recv_buf, leftover diperbarui
        request chunked me-reset leftover ke 0
```

Pemanggil (connEntry / poolEntry) yang menutup fd. Batas di langkah 4 berarti body Content-Length di atas 8 KB hanya dibaca sampai 8 KB dan sisa byte body kemudian salah di-parse sebagai head request berikutnya (batasan terdokumentasi, panduan oversize di HLD berlaku).

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
5. tidak ada yang cocok                -> writeSimple 404 text/plain
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

`acceptKey` menyambung key client dengan GUID RFC 6455, SHA-1, base64 ke `[64]u8` milik pemanggil (`error.KeyTooLong` melewati 128 byte input). `upgrade` menulis blok `101 Switching Protocols` penuh melalui `core.fdWriteAll` (sadar sink, sehingga pada EPOLL ditahapkan bersama response lain).

### send() dan SendSink

`SendSink` adalah kembaran WebSocket dari `RespSink` core (aturan append / flush / write-through yang sama), dipasang thread-local oleh `pump` selama satu pass.

```
send(fd, opcode, payload):
  sink aktif -> tahapkan header lalu payload       (error.BrokenPipe bila sink gagal)
  payload + header <= 4096 -> bangun satu buffer, satu fdWriteAll
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
