# LLD: zix.Http

Detail implementasi internal untuk lapisan HTTP. Untuk dasar pertimbangan desain lihat [`docs/hld-http-id.md`](hld-http-id.md).

---

## server.zig: Server

### API Publik

`Server` adalah namespace struct dengan satu `pub fn init(comptime routes: []const Route, config: Config) HttpServerImpl(routes)`. `HttpServerImpl` adalah generik privat. Pemanggil menggunakan `var server = zix.Http.Server.init(&routes, .{...})` tanpa menyebutkan tipe generiknya.

`HttpServerImpl.init(config)` menyimpan config, tidak ada yang lain: `Router` dibaked comptime ke dalam tipe (berukuran nol saat runtime) dan tidak ada socket yang dibuka. Socket dibuka di `run()`.

### ConnQueue

Antrian kerja bersama antara accept thread (producer) dan pool thread (consumer). Didukung oleh `std.Io.Mutex` + `std.Io.Condition` + `std.ArrayListUnmanaged(std.Io.net.Stream)`.

```
push(stream): lock -> append -> unlock -> signal
pop():        lock -> while empty: wait -> orderedRemove(0) -> unlock -> return stream
close():      lock -> closed = true -> unlock -> broadcast   (membuka blokir semua pop() yang menunggu)
```

### run(): .POOL (dispatch_model = .POOL)

```
1. worker_count = if (workers == 0) cpu_count else workers
2. pool_size    = if (pool_size == 0) max(10, cpu_count * 2) else pool_size
3. std.Io.Threaded.init(smp_allocator, .{ .stack_size = 512 KB }) -> thread_io
4. ConnQueue{}
5. spawn timer thread  -> timerLoop(thread_io, &self.registry)
      setiap 500ms: updateDateCache + registry.evict (penjaga koneksi Layer D)
6. spawn pool_size pool threads  -> poolEntry(self, &queue, thread_io)
7. spawn worker_count accept threads -> workerEntry(self, &queue, thread_io)
8. join accept threads
9. queue.close(thread_io)
10. join pool threads
```

### run(): .ASYNC (dispatch_model = .ASYNC)

```
1. net.IpAddress.resolve(io, ip, port)
2. addr.listen(io, .{ .reuse_address = true, ... }) -> NetServer
3. accept loop:
      stream = net_server.accept(io)
      if (io.async(handleConnection, .{ stream, io, self })) |_| {}
      else |_| { handleConnection(stream, io, self); }  // fallback jika pool habis
```

### run(): .MIXED (dispatch_model = .MIXED)

```
1. worker_count = if (workers == 0) cpu_count else workers
2. spawn worker_count asyncWorkerEntry threads
3. setiap asyncWorkerEntry:
      resolve + listen dengan SO_REUSEPORT
      accept loop:
        stream = net_server.accept(io)
        if (io.async(handleConnection, .{ stream, io, self })) |_| {}
        else |_| { handleConnection(stream, io, self); }
```

### run(): .EPOLL (dispatch_model = .EPOLL, Linux-only)

```
1. worker_count = if (workers == 0) cpu_count else workers
2. spawn worker_count thread -> epollWorker(self, io)
3. join semua thread

epollWorker():
  1. resolve + listen dengan SO_REUSEPORT (reuse_address = true)
  2. setNonBlock(listener_fd)
  3. epoll_create1
  4. epoll_ctl(ADD, listener_fd, EPOLLIN)
  5. read buf + ArenaAllocator per-worker
  6. event loop (epoll_wait EPOLL_MAX_EVENTS = 1024):
       listener fd:
         loop: conn_fd = accept4(SOCK_CLOEXEC)  <- drain semua pending
               break on EAGAIN / EWOULDBLOCK
               tcp_nodelay(conn_fd)
               epoll_ctl(ADD, conn_fd, EPOLLIN | EPOLLRDHUP)
       conn fd (HUP | ERR | RDHUP):
               epoll_ctl(DEL, conn_fd)
               linux.close(conn_fd)
       conn fd (readable):
               result = handleOneRequest(conn_fd, buf, arena, self)
               .keep_alive -> tetap terdaftar (level-triggered, tidak perlu re-arm)
               .close      -> epoll_ctl(DEL, conn_fd) + linux.close(conn_fd)
```

Tidak ada state bersama antar worker. `handleOneRequest` dipanggil langsung di thread worker
yang melakukan recv/parse/dispatch/send secara blocking sinkron. Arena di-reset antar request.

### workerEntry() (accept thread .POOL)

```
1. resolve + listen dengan SO_REUSEPORT (reuse_address = true)
2. loop:
      stream = net_server.accept(io)
      queue.push(stream, io)        // tidak pernah memblokir I/O
```

### poolEntry() (pool thread .POOL)

```
loop:
    stream = queue.pop(io)          // blokir sampai koneksi masuk
    handleConnection(stream, io, self)
```

### handleConnection()

```
1. setsockopt TCP_NODELAY           // nonaktifkan Nagle, kirim setiap respons langsung
2. Layer D: if conn_timeout_ms > 0:
      daftarkan ConnEntry{ stream, deadline = now + conn_timeout_ms } ke self.registry
      defer deregister saat return (tandai done=true, hapus dari registry)
3. stack_read [stack_read_buf_max]u8 pada stack (stack_read_buf_max = 4096, dispatch/common)
   read_buf  = if max_recv_buf <= stack_read_buf_max: slice stack
               else smp_allocator.alloc(u8, max_recv_buf)
4. defer: bebaskan heap jika dialokasi di heap, stream.close()
5. std.http.Server.init(&reader.interface, &writer.interface)
6. ArenaAllocator.init(smp_allocator), pre-warm dengan max_allocator_size, reset(.retain_capacity)
7. keep-alive loop:
      a. arena.reset(.retain_capacity)
      b. receiveHead() // break pada HttpConnectionClosing / ConnectionResetByPeer / ReadFailed
            ReadFailed: timer thread Layer D memanggil stream.shutdown(.both) -> koneksi kedaluwarsa
      c. bangun Request(inner, &reader, allocator)
         bangun Response(inner, io, allocator, max_response_headers.value())
         bangun Context(io, allocator, stream)  // ctx.stream = stream (TCP mentah, untuk WS/SSE)
      d. Layer B: if handler_timeout_ms > 0: ctx = ctx.withTimeout(handler_timeout_ms)
            mengatur ctx.deadline, handler memanggil ctx.timedOut() antar langkah untuk memeriksa sisa waktu
      e. muat atomic date cache global: idx = g_date_active.load(.acquire), res.date_cache = g_date_bufs[idx]
      f. router.dispatch(req, res, ctx)
      g. if res.streaming: break  // handler SSE membuka stream, koneksi tutup saat handler return
      h. if public_dir dan belum dispatched: static.serve(...)
      i. if belum dilayani: 404
      j. if cfg.logger: lg.access(method_str, req.path(), status_code, res.bytes_written, ua, origin)
            method_str: stringFromEnum(req.method())
            ua:     req.header("user-agent") orelse ""
            origin: req.header("origin") orelse ""
```

Buffer stack hidup di stack pool thread selama durasi koneksi. Buffer heap dibebaskan saat koneksi ditutup. Arena direset di antara request dan dideinisilisasi saat `handleConnection` return.

Layer D (ConnRegistry) aktif hanya di model 2: timer thread yang memanggil `registry.evict()` hanya ada di model 2. Layer B (`ctx.withTimeout`) aktif di kedua model.

---

## router.zig: Router

### Penyimpanan Route

Satu `routes: MultiArrayList(Route)` didukung oleh `config.allocator`, ditambah hash map O(1) khusus untuk path exact-match:

```
routes:    MultiArrayList(Route)             // SoA: array kind[], path[], handler[] terpisah
exact_map: StringHashMapUnmanaged(HandlerFn) // hanya key exact-path, dispatch O(1)
```

`MultiArrayList` menyimpan setiap field dalam array kontinu tersendiri. Pass 2 dispatch mengiterasi hanya slice `kind[]` sampai match PARAM ditemukan, lalu mengindeks ke `path[]` dan `handler[]`. Pass 3 menggabungkan `kind[]` dan `path[]` tanpa menyentuh `handler[]` sampai kandidat dikonfirmasi.

Setiap `Route`:
```zig
const RouteKind = enum { EXACT, PREFIX, PARAM };

const Route = struct {
    path:    []const u8,
    handler: HandlerFn,
    kind:    RouteKind = .EXACT,
};
```

`register()` memasukkan ke `routes` dan `exact_map`. `deinit()` membebaskan keduanya. `routes` di-scan untuk jenis param dan prefix saat dispatch, pencarian exact melewati scan sepenuhnya melalui `exact_map.get()`.

### dispatch()

```
1. exact_map.get(req.path()) -> panggil handler  (O(1))
2. scan routes untuk kind == .PARAM: matchParam(pattern, path) -> tulis params yang ditangkap ke req, panggil handler
3. scan routes untuk kind == .PREFIX: kumpulkan semua yang pathnya diawali prefix (boundary-safe) -> pilih yang terpanjang
```

### matchParam()

Memisah pattern dan path berdasarkan `/`. Untuk setiap pasang segmen:
- Segmen pattern diawali `:` -> tangkap: simpan name+value ke `req.path_params`
- Selain itu: harus sama persis, jika tidak maka tidak ada match
- Jumlah segmen harus sama

Hasil tangkapan ditulis ke `req.path_params` (slice dialokasi arena dari `PathParam { name, value }`).

### Pemeriksaan Batas Prefix

Prefix `/api` cocok dengan `/api`, `/api/foo`, `/api/foo/bar` tetapi TIDAK dengan `/apiv2`. Pemeriksaannya:
```
path diawali prefix DAN (path.len == prefix.len ATAU path[prefix.len] == '/')
```

---

## request.zig: Request

### Caching Body

```zig
body_cache: ?[]const u8 = null,
```

`body()` membaca byte `Content-Length` pada panggilan pertama dan menyimpannya di `body_cache`. Panggilan berikutnya langsung return `body_cache`. Pembacaan terjadi melalui `*std.Io.Reader` yang memegang referensi stream yang mendasarinya.

### Path Param

```zig
path_params: []PathParam = &.{},
```

Ditulis oleh `Router.matchParam()` saat dispatch. `pathParam(name)` melakukan scan linear atas `path_params`.

---

## response.zig: Response

### Field

`Response` menyimpan `io: std.Io` (dipertahankan untuk kemungkinan penggunaan di masa depan, header `Date` sekarang bersumber dari atomic date cache global melalui `date_cache: ?[]const u8`, bukan dari pemanggilan clock per request). `streaming: bool` diatur ke `true` oleh `sendStream()` agar `handleConnection` memutus keep-alive loop setelah handler keluar. `bytes_written: usize` diatur ke `body_data.len` di awal `send()` agar `handleConnection` dapat membaca ukuran body respons untuk access logging tanpa harus menginspeksi write buffer.

### extra_buf (slice arena yang tumbuh secara lazy)

`extra_buf: ?[]HttpHeader` awalnya null, dialokasi secara lazy pada panggilan `addHeader()` pertama. Request yang tidak menambahkan header kustom tidak menanggung biaya alokasi apa pun.

```
addHeader(name, value):
  1. CR/LF guard: scan name dan value untuk \r atau \n (return error jika ditemukan)
  2. if extra_buf == null:
       initial = min(4, max_response_headers); if 0 -> return error.TooManyHeaders
       extra_buf = allocator.alloc(HttpHeader, initial)
  3. else if extra_len >= extra_buf.len:
       if extra_buf.len >= max_response_headers -> return error.TooManyHeaders
       new_cap = min(extra_buf.len * 2, max_response_headers)
       new_buf = allocator.alloc(HttpHeader, new_cap)
       @memcpy(new_buf[0..extra_len], extra_buf[0..extra_len])
       extra_buf = new_buf
  4. extra_buf[extra_len] = .{ .name = name, .value = value }
  5. extra_len += 1
```

Dimulai dari 4 slot, berlipat ganda setiap overflow, dibatasi pada `max_response_headers` (dari `HeaderSize.value()`, ADR-062). `TooManyHeaders` hanya dikembalikan saat batas maksimum tercapai.

### send(): format penulisan header

```
1. Stage header tetap ke buffer stack 512 byte:
      baris status: Status.statusLine(code) -> @memcpy string pre-built untuk kode umum
                    kode tidak umum: bufPrint "HTTP/1.1 {d} {s}\r\n"
      if status != 204 No Content:
          if content_type diatur: "Content-Type: {ct}\r\n"  // @memcpy prefix + value, tanpa std.fmt
          "Content-Length: {N}\r\n"  // writeDecimal buatan tangan, tanpa std.fmt
      if keep_alive diatur: "Connection: keep-alive\r\n" atau "Connection: close\r\n"
      "Date: {date_cache}\r\n"  // @memcpy prefix + value, tanpa std.fmt
2. Fast path (tidak ada extra header DAN body muat di sisa ruang buffer):
      tambahkan "\r\n" + body ke buffer 512 byte yang sama
      satu writeAll + flush // satu syscall untuk sebagian besar respons
3. Slow path (ada extra header ATAU body terlalu besar untuk buffer stack):
      writeAll(header tetap)
      untuk setiap extra header: print "{name}: {value}\r\n"
      writeAll("\r\n")
      writeAll(body)
      flush()
```

Content-Type dan Date ditulis dengan `@memcpy` prefix literal plus value (bukan `bufPrint`), sehingga `send()` per-response tidak lagi memasuki jalur formatting `std.Io.Writer`. `buildResponse` (serializer zero-copy yang dipakai sink `.EPOLL` / `.URING`) menghasilkan output byte-identik dengan cara yang sama.

### sendStream(): format penulisan header SSE

```
1. Stage ke buffer stack 256 byte:
      "HTTP/1.1 200 OK\r\n"
      "Content-Type: text/event-stream\r\n"
      "Cache-Control: no-cache\r\n"
      "Connection: keep-alive\r\n"
      "Date: {IMF-fixdate}\r\n"  (jika date_cache tidak kosong)
2. writeAll(header tetap)
3. untuk setiap extra header: print "{name}: {value}\r\n"
4. writeAll("\r\n")
5. flush()
6. atur res.streaming = true
7. return SseWriter{ .fd = fd }
```

`SseWriter` menyimpan fd koneksi. Setiap metode penulisan memanggil `writeAllFD` agar event sampai ke client tanpa buffering. Melalui TLS (ADR-054) stream sink per-koneksi terpasang: langkah 1 melepas buffered capture sink alih-alih mem-flush-nya (byte-nya digantikan oleh stream), dan `writeAllFD` merutekan tiap header dan event lewat stream sink, mengenkripsi satu TLS record per write. Di cleartext write langsung ke socket.

```
writeEvent(data):      writeAll("data: ") + writeAll(data) + writeAll("\n\n") + flush
writeNamedEvent(e, d): print("event: {e}\ndata: {d}\n\n") + flush
comment(text):         writeAll(": ") + writeAll(text) + writeAll("\n") + flush
```

### Logika header Connection

```
dihilangkan   jika keep_alive == null (setKeepAlive() tidak pernah dipanggil)
keep-alive    jika keep_alive == true  DAN  req.head.keep_alive == true
close         jika keep_alive == false ATAU req.head.keep_alive == false
```

`keep_alive: ?bool = null` secara default. `req.head.keep_alive` di-parse oleh `std.http` dari header request yang masuk (tanpa scan manual). Header Connection hanya ditulis saat handler mengaktifkannya melalui `setKeepAlive()`.

### Logika header Date

```
1. handleConnection mengatur res.date_cache dari atomic date cache global (satu atomic load)
2. handleConnection kemudian men-scan req.iterateHeaders() sekali untuk header "date" yang diteruskan proxy
      ditemukan -> timpa res.date_cache dengan nilai proxy
3. send() membaca res.date_cache langsung // tanpa scan header saat send
      date_cache = g_date_bufs[g_date_active.load(.acquire)][0..g_date_lens[idx]]
```

**Global date cache** (level modul `server.zig`):

```
g_date_bufs:   [2][40]u8      // string IMF-fixdate double-buffered
g_date_lens:   [2]usize       // panjang valid setiap buffer
g_date_active: atomic(usize)  // indeks (0 atau 1) buffer aktif saat ini
g_date_secs:   atomic(u64)    // detik wall-clock terakhir yang ditulis

.POOL: timer thread memanggil updateDateCache setiap 500 ms (std.Io.sleep)
.ASYNC: accept loop memanggil updateDateCache sebelum setiap accept()

updateDateCache():
  cur_secs = std.Io.Clock.real.now(io).toSeconds()
  if cur_secs == g_date_secs: return  (no-op dalam detik yang sama)
  next_idx = 1 - g_date_active.load(.monotonic)
  formatHttpDate(cur_secs) -> g_date_bufs[next_idx]
  g_date_active.store(next_idx, .release)  // publikasi secara atomik
  g_date_secs.store(cur_secs, .release)
```

`formatHttpDate` menggunakan `std.time.epoch.EpochSeconds` untuk dekomposisi kalender. Hari dalam minggu diturunkan dari `(epoch_day.day % 7 + 4) % 7` (1 Jan 1970 = Kamis = hari 0).

---

## static.zig: Penyajian Berkas Statis

### Penjaga Traversal

```
if std.mem.indexOf(u8, path, "..") != null -> return false
```

### Parsing Header Range

Mem-parse `Range: bytes=start-end`. Memvalidasi `start <= end < file_size`. Mengembalikan:
- `206 Partial Content` dengan `Content-Range: bytes start-end/total`
- `416 Range Not Satisfiable` untuk range tidak valid

### Chunk Streaming

Berkas dibaca dan ditulis dalam chunk 8 KB yang dialokasi di stack. Tidak ada buffering berkas penuh.

```
var chunk_buf: [8192]u8 = undefined;
var reader = file.reader(io, &chunk_buf);
loop: baca chunk -> writer.writeAll(chunk) -> flush
```

### Resolusi MIME

`Content.typeFromExtension(ext)` memetakan string ekstensi berkas ke nilai enum `Content.Type`. Kembali ke `.APPLICATION_OCTET_STREAM` untuk ekstensi yang tidak dikenal. Perbandingan tidak membedakan huruf besar/kecil.

---

## websocket.zig: WebSocket

### Format Frame (RFC 6455)

```
Byte 0: FIN(1) + RSV(3) + Opcode(4)
Byte 1: MASK(1) + Payload length(7)
  if len == 126: 2 byte berikutnya adalah panjang 16-bit
  if len == 127: 8 byte berikutnya adalah panjang 64-bit
Mask key: 4 byte (ada jika bit MASK diatur, selalu diatur untuk frame client)
Payload: XOR setiap byte dengan mask_key[i % 4]
```

### parseFrame()

```
1. Periksa minimal 2 byte tersedia
2. Baca FIN, opcode dari byte 0
3. Baca bit MASK, panjang dasar dari byte 1
4. Baca panjang diperluas jika diperlukan (2 atau 8 byte)
5. Baca mask key jika bit MASK diatur
6. Unmask payload ke payload_buf yang disediakan pemanggil
7. Return ParseResult { frame, consumed } atau null jika byte tidak cukup
```

### Internal RoomMap

```zig
rooms: std.StringHashMap(std.array_list.Managed(*Conn))
```

- `join(room, conn, io)`: `getOrPut(room)` -> tambahkan `conn` ke list
- `leave(room, conn, io)`: temukan `conn` dalam list berdasarkan pointer, `swapRemove`, lalu kirim close frame ke conn yang dihapus
- `broadcast(room, msg, io)`: iterasi list, bangun dan tulis frame ke stream setiap conn, lewati kegagalan penulisan secara diam-diam (koneksi mati dihapus saat leave handler miliknya dipicu)

---

## multipart.zig: Parser

Parser berada di `src/utils/multipart.zig` (`zix.utils.multipart`), dibagikan oleh `zix.Http` dan `zix.Http1`. `zix.Http.Multipart` tetap ada sebagai thin alias.

### Algoritma Parsing

```
1. Scan untuk baris delimiter boundary ("--{boundary}")
2. Di antara delimiter: parse blok header (Content-Disposition, Content-Type)
3. Ekstrak name, filename dari Content-Disposition
4. Slice data antara akhir-header dan delimiter berikutnya
5. Tambahkan multipart.Field ke slice fields
```

Semua slice merujuk byte body asli (tanpa salinan). `deinit()` hanya membebaskan slice fields.

---

## client_config.zig: HttpClientConfig

Struct biasa dengan nilai default. Semua field terlihat oleh pemanggil. Tidak ada alokasi internal saat konstruksi config. `io` disimpan dan digunakan sepanjang masa hidup client (init, pemanggilan request, deinit). `allocator` digunakan untuk body dan salinan head respons.

Nilai default:

| Field | Default | Diterapkan di v1? |
| :- | :- | :- |
| `connect_timeout_ms` | 0 | Ya, melalui `connectTcpOptions` |
| `response_timeout_ms` | 0 | Tidak, hanya disimpan |
| `read_timeout_ms` | 0 | Tidak, hanya disimpan |
| `max_response_body` | 4 MB | Ya, melalui `allocRemaining` |
| `follow_redirects` | true | Ya |
| `max_redirects` | 3 | Ya |
| `h2_max_read_rounds` | 4096 | Ya, membatasi read-loop client HTTP/2 |
| `user_agent` | "zix/1" | Ya, melalui `Request.Headers.user_agent` |
| `version` | `.HTTP_1` | Ya. `.HTTP_2` melewati jalur native h2-over-TLS (`requestHttp2` / `h2_client.zig`) |
| `tls_ca_path` | null | Ya, pada jalur https (CA PEM tambahan, null = system roots) |
| `tls_verify` | true | Ya, pada jalur native `.HTTP_2` |

---

## client.zig: HttpClient

### init()

```
HttpClient{
    config: HttpClientConfig,                         // disimpan apa adanya
    inner:  std.http.Client{ allocator, io },         // tidak ada koneksi yang dibuka
}
```

Tidak ada alokasi. Socket tidak dibuka sampai pemanggilan `request()` pertama.

### deinit()

```
inner.deinit()
    connection_pool.deinit(io)   // tutup semua koneksi bebas + yang sedang digunakan
    ca_bundle.deinit(allocator)  // bundel sertifikat TLS (no-op saat TLS dinonaktifkan)
```

Memastikan semua request selesai (pool yang digunakan kosong) sebelum menutup.

### request()

```
1. Uri.parse(url)               -> error.InvalidUrl jika gagal
2. Protocol.fromUri(uri)        -> error.InvalidUrl jika skema bukan http atau https
3. uri.getHost(&host_buf)       -> error.InvalidUrl jika komponen host tidak ada
4. uri.port orelse port default (80 untuk plain, 443 untuk tls)
5. Bangun Io.Timeout:
      connect_ms = opts.connect_timeout_ms orelse config.connect_timeout_ms
      if connect_ms > 0: .{ .duration = .{ .raw = Duration.fromMilliseconds(connect_ms), .clock = .real } }
      else .none
6. inner.connectTcpOptions(.{ host, port, protocol, timeout })
      gunakan kembali koneksi dari pool jika ada yang cocok, buka koneksi TCP baru jika tidak
7. Bangun RedirectBehavior:
      follow_redirects = false -> .unhandled  (pemanggil menerima 3xx apa adanya)
      max_redirects = 0        -> .not_allowed (error.TooManyHttpRedirects pada redirect apa pun)
      selain itu               -> @enumFromInt(max_redirects) (ikuti otomatis hingga N hop)
8. inner.request(std_method, uri, .{ connection, redirect_behavior, extra_headers, headers.user_agent })
9. Kirim:
      if std_method.requestHasBody():
          req.transfer_encoding = .{ .content_length = body.len }
          sendBodyUnflushed(&write_buf[8192]) -> BodyWriter
          bw.writer.writeAll(body)
          bw.end()  // flush body writer + koneksi
      else:
          req.sendBodiless()  // tulis head + flush
10. receiveHead(&redirect_buf[8192])
      tangani redirect secara internal jika redirect_behavior != .unhandled
11. gpa.dupe(response.head.bytes)
      salin byte head mentah (baris status + header) ke memori yang dimiliki
      HARUS terjadi sebelum response.reader() yang memanggil invalidateStrings()
12. @intFromEnum(response.head.status) -> status_code: u16
13. response.reader(&transfer_buf[4096]) -> *Io.Reader
14. body_reader.allocRemaining(gpa, .limited(max_response_body))
      baca body ke dalam []u8 milik gpa
      error.StreamTooLong -> return error.BodyTooLarge
15. return ClientResponse{ status_code, body_data, head_bytes, allocator }
    defer req.deinit() melepaskan koneksi kembali ke pool
```

### ClientResponse.header()

```
std.http.HeaderIterator.init(head_bytes)
    indeks dimulai setelah \r\n pertama (melewati baris status)
    mengiterasi pasangan name: value
    scan linear sampai nama cocok (case-insensitive) atau habis
```

### ClientResponse.deinit()

```
if body_data.len > 0: allocator.free(body_data)
if head_bytes.len > 0: allocator.free(head_bytes)
```

Kedua slice dimiliki oleh `config.allocator`. Body dengan panjang nol (misalnya 204 No Content) tidak dibebaskan (allocRemaining dapat mengembalikan slice kosong yang tidak dialokasi dari ArrayList kosong).

---

## utils/file.zig: save

```
1. std.Io.Dir.cwd().makePath(io, dir) // buat pohon direktori jika belum ada
2. dir.createFile(io, filename, .{}) -> file
3. file.writeAll(io, data)
4. file.close(io)
5. return allocator.dupe(u8, dir ++ "/" ++ filename)  // path milik pemanggil
```

---

###### end of lld-http
