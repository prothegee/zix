# Catatan Keputusan Arsitektur: zix

Setiap ADR mencatat satu keputusan desain yang signifikan: konteks yang membuatnya diperlukan, keputusan yang diambil, dan konsekuensinya. ADR yang Diterima bersifat mengikat. Yang Diusulkan masih dalam pembahasan.

---

## ADR-001: `std.Io` sebagai abstraksi I/O

**Status:** Diterima

**Konteks:** Server harus menangani banyak koneksi konkuren tanpa memblokir pada I/O. Zig 0.16 menyediakan `std.Io` sebagai abstraksi event loop opaque di atas fasilitas OS (epoll, kqueue, io_uring, dll). Alternatifnya adalah thread OS mentah dengan sinkronisasi eksplisit.

**Keputusan:** Terima `std.Io` sebagai parameter di `zix.Http.Server` dan `zix.Udp.Server`. Pemanggil memiliki dan menyediakan backend (`process.io` untuk yang dikelola runtime atau `std.Io.Threaded` untuk cap eksplisit). Server memakai `io.concurrent()` pada model 1. Pada model 2, thread pool memanggil `handleConnection` langsung dengan `std.Io` yang diturunkan dari `std.Io.Threaded`.

**Konsekuensi:**
- Pemanggil mengendalikan model konkurensi. zix tidak memiliki atau melakukan deinit backend.
- `zix.Http.Server.run()` dan `zix.Udp.Server.run()` memblokir hingga terjadi error.
- `io.concurrent()` dipakai pada model 1 (satu accept, satu task per koneksi). Model 2 melewati `io.concurrent()` sepenuhnya: thread pool menangani koneksi dengan I/O sinkron yang memblokir.
- Kode yang butuh paralelisme sejati (misalnya UDP broadcast) dapat memanggil `io.concurrent()` dari dalam sebuah task.

---

## ADR-002: API Namespace (zix.Http.*, zix.Udp.*)

**Status:** Diterima

**Konteks:** API awal mengekspos export datar dari root zix (`zix.HttpServer`, `zix.Request`, dll). Ketika UDP ditambahkan, permukaan API menjadi tidak konsisten: tipe HTTP datar sementara tipe UDP sudah berada di bawah `zix.Udp.*`. Nama HTTP datar juga membawa prefiks redundan (`HttpServer`, `HttpHeader`) yang menjadi jelas begitu dinested.

**Keputusan:** Perkenalkan `zix.Http` dan `zix.Udp` sebagai agregator namespace yang didukung oleh `Http.zig` dan `Udp.zig`. Hapus semua export HTTP datar. Path kanonik:
- `zix.Http.Server`, `zix.Http.Request`, `zix.Http.WebSocket`, ...
- `zix.Udp.Server(Packet)`, `zix.Udp.Client(Packet)`, `zix.Udp.ServerConfig`, ...

`zix.Tcp.Http.*` tetap dapat diakses (Tcp.zig me-reekspor Http.zig) tetapi bukan path kanonik.
`zix.utils` tetap datar (tidak spesifik protokol).

**Konsekuensi:**
- Perubahan breaking: semua kode yang mereferensikan export datar harus diperbarui.
- Namespace membuat afiliasi protokol terlihat sendirinya di call site.
- Menambah protokol mendatang (UDS, QUIC) mengikuti pola yang sama tanpa dampak ke namespace yang ada.

---

## ADR-003: Allocator arena per koneksi, di-reset per request

**Status:** Diterima

**Konteks:** Kode handler butuh alokasi sementara (parsing body, segmen path, JSON, dll) yang hanya valid selama satu request. Allocator umum akan menuntut pemanggilan `free` eksplisit di setiap handler dan setiap jalur error.

**Keputusan:** Alokasikan satu `ArenaAllocator` per koneksi (didukung oleh `smp_allocator`). Reset di antara request dengan `.retain_capacity`. Ekspos allocator arena sebagai `ctx.allocator`. Deinit arena saat koneksi tertutup.

**Konsekuensi:**
- Handler tidak pernah memanggil `free`. Seluruh memori per request direklamasi otomatis di akhir request.
- Alokasi `ctx.allocator` tidak boleh lolos keluar request (misalnya disimpan di global). Nama `ctx.allocator` sengaja dibuat singkat, batasan masa hidup arena didokumentasikan alih-alih disandikan dalam nama. (Penggantian nama menjadi `ctx.request_arena` dipertimbangkan lalu ditolak: batasan masa hidup ditegakkan oleh dokumentasi dan konvensi.)
- Reset retain-capacity mengamortisasi pertumbuhan blok backing arena sepanjang masa hidup koneksi.

---

## ADR-004: Dispatch router 3 lintasan (exact > param > prefix)

**Status:** Diterima

**Konteks:** Router butuh aturan prioritas yang konsisten ketika beberapa pola dapat mencocokkan request yang sama. Opsinya: first-match-wins (urutan registrasi), longest-match, atau tier prioritas eksplisit.

**Keputusan:** Tiga lintasan dalam urutan prioritas tetap: route exact lebih dulu, lalu route param (first-registered wins di dalam lintasan 2), lalu route prefix (longest wins di dalam lintasan 3). Urutan registrasi tidak relevan untuk lintasan 1 dan 3.

**Konsekuensi:**
- Route exact dan prefix bersifat deterministik tanpa peduli urutan. Ini mencakup kasus umum (kebanyakan route adalah exact atau prefix).
- Route param butuh kehati-hatian: pola yang lebih literal harus diregistrasi sebelum pola serba-param dengan kedalaman yang sama. Ini didokumentasikan dan didemonstrasikan dalam contoh.
- Desain 3 lintasan sempat dipertimbangkan untuk diganti dengan first-match-wins. Ditangguhkan: perubahannya breaking dan manfaatnya marginal untuk jumlah route tipikal.

---

## ADR-005: Tipe paket UDP generik comptime

**Status:** Diterima

**Konteks:** UDP membawa struct biner yang didefinisikan aplikasi. Tipe paket bawaan yang tetap akan membatasi interoperabilitas. Slice `[]u8` runtime akan kehilangan keamanan tipe dan menuntut pengguna menangani serialisasi secara manual.

**Keputusan:** `UdpServer` dan `UdpClient` generik atas comptime `Packet: type`. Pengguna mendefinisikan `extern struct` sendiri dan memberikannya di titik instansiasi (`zix.Udp.Server(MyPacket)`). zix menangani endianness, validasi ukuran, dan framing. Aplikasi memiliki definisi paket dan logika identitasnya.

**Konsekuensi:**
- Server tidak menstempel atau memodifikasi field paket apa pun. Field `id` (jika ada) adalah tanggung jawab pengirim.
- Helper endianness (`toEndian`, `fromEndian`) sepenuhnya generik: bekerja pada `extern struct` mana pun.
- `@sizeOf(Packet)` diketahui saat comptime, memungkinkan assert ukuran RFC 768 dan buffer terima tetap `[@sizeOf(Packet)]u8`.

---

## ADR-006: Endianness LITTLE sebagai default untuk UDP

**Status:** Diterima

**Konteks:** Paket UDP yang ditransmisikan lintas mesin atau bahasa harus sepakat soal byte order. Dua pilihan umum: LITTLE (native x86/ARM, mayoritas perangkat keras modern) dan BIG (network byte order, konvensi RFC 791).

**Keputusan:** `Endianness.LITTLE` adalah default di `UdpServerConfig` maupun `UdpClientConfig`. BIG tersedia untuk interop dengan protokol legacy atau internet.

**Konsekuensi:**
- Pada x86 dan ARM (mayoritas target deployment), LITTLE adalah no-op (tidak ada swapping dilakukan).
- Klien lintas bahasa (Go, C++, Rust) pada keluarga perangkat keras yang sama juga default little-endian, sehingga tidak ada konversi yang diperlukan dalam kasus umum.
- Pengguna yang menarget network byte order (BIG) harus menyetel `endianness: .BIG` secara eksplisit di kedua sisi.

---

## ADR-007: Deteksi diskoneksi berbasis timeout untuk UDP

**Status:** Diterima

**Konteks:** UDP tidak punya state koneksi. Tidak ada padanan FIN TCP di tingkat OS. Satu-satunya cara andal mendeteksi bahwa klien berhenti mengirim adalah ketiadaan trafik selama periode yang dapat dikonfigurasi.

**Keputusan:** Lacak klien berdasarkan alamat remote dalam list `Managed(ClientRecord)`. Perbarui `last_seen` pada setiap paket. Saat `receiveTimeout` berakhir (interval poll) dan setelah tiap burst paket (cek dengan rate-limit), pindai klien yang `last_seen`-nya lebih tua dari `disconnect_timeout_ms` lalu hapus.

**Konsekuensi:**
- Penundaan deteksi kasus terburuk adalah `disconnect_timeout_ms + poll_timeout_ms`. Ini didokumentasikan dan dapat dikonfigurasi.
- Klien yang crash lalu restart dari port baru diperlakukan sebagai klien baru.
- Klien yang restart dari port yang sama diregistrasi ulang pada paket berikutnya.
- Positif palsu (klien yang sebentar diam) dibatasi oleh `disconnect_timeout_ms`.

---

## ADR-008: Snapshot peer dialokasikan di heap untuk broadcast UDP

**Status:** Diterima

**Konteks:** Broadcast menuntut pengiriman paket yang diterima ke semua klien yang sedang terhubung. List klien bersifat mutable (klien baru dapat bergabung di antara paket). Mewariskan pointer ke list mutable ke dalam task konkuren akan menciptakan data race.

**Keputusan:** Sebelum `io.concurrent(processPacket)`, snapshot alamat klien saat ini ke `[]IpAddress` yang dialokasikan di heap (`smp_allocator.alloc`). Task menerima snapshot by value dalam struct `Task`-nya. Task membebaskan snapshot via `defer` setelah semua send selesai.

**Konsekuensi:**
- Tidak ada state mutable bersama antara loop terima dan task konkuren.
- Alokasi hanya terjadi ketika `broadcast = true` dan list klien tidak kosong.
- Klien yang diskoneksi antara snapshot dan send broadcast akan menerima error send yang diabaikan diam-diam (perilaku yang benar).

---

## ADR-009: extra_buf sebagai []HttpHeader yang dialokasikan arena

**Status:** Diterima

**Konteks:** Desain awal menyimpan header respons kustom dalam buffer tetap `[32]HttpHeader`. Ini menyebabkan penulisan out-of-bounds ketika `max_response_headers = .LARGE` (64 slot) dan lebih dari 32 header ditambahkan. Cap saat compile-time tidak cukup karena cap dapat dikonfigurasi runtime per instansi server.

**Keputusan:** Di `Response.init()`, alokasikan `extra_buf = arena.alloc(HttpHeader, max_headers)` dari arena per request. `max_headers` berasal dari `ServerConfig.max_response_headers.value()`. Field `max_headers` pada `Response` dihapus, `extra_buf.len` adalah cap-nya.

**Konsekuensi:**
- Cap-nya tepat: tidak ada clamp `@min(..., 128)`, tidak ada slot terbuang.
- `Response.init()` kini fallible (`!Response`) karena `arena.alloc` dapat gagal.
- Masa hidup arena menjamin buffer valid selama request dan direklamasi otomatis.

---

## ADR-010: UDS (Unix Domain Socket)

**Status:** Diterima, Diimplementasikan (2026-05-13)

**Konteks:** Unix Domain Socket adalah mekanisme IPC standar di Linux dan macOS untuk komunikasi sesama host. Namespace `zix.Uds` yang mengikuti pola sama dengan `zix.Udp` akan melengkapi trilogi protokol transport.

**Keputusan:** Diimplementasikan di `src/uds/`. Agregator namespace di `src/uds/Uds.zig`, diekspos sebagai `pub const Uds = @import("uds/Uds.zig")` di `lib.zig`. Mode stream saja (datagram butuh `std.posix` mentah, tidak diekspos via `std.Io.net.UnixAddress`, dan ditangguhkan). Format frame: header panjang `u32` 4 byte (little-endian native) diikuti byte payload. `UdsClient.sendMsg`/`recvMsg` dan `echoHandler` semua memakai kontrak frame ini.

**API `std.Io.net` yang dipakai:** `std.Io.net.UnixAddress.init(path)`, `.listen(io, opts) !Server`, `.connect(io) !Stream`. `has_unix_sockets = false` di WASI: baik `Server.init()` maupun `Client.connect()` memunculkan `@compileError` di platform yang tidak didukung.

**Konsekuensi:**
- `zix.Uds.Server`, `zix.Uds.Client`, `zix.Uds.ServerConfig`, `zix.Uds.ClientConfig`, `zix.Uds.HandlerFn`, dan `zix.Uds.echoHandler` semua publik.
- Server memakai Model 1 (`io.concurrent()`): satu thread accept, satu task per koneksi.
- Path socket di-unlink sebelum bind (restart bersih) dan lagi saat `runWith()` kembali.
- `error.PathEmpty` dikembalikan oleh `Server.init()` ketika `config.path` kosong.
- Field `allocator` di `UdsServerConfig` dicadangkan untuk ekstensi mendatang. Implementasi saat ini bebas alokasi (buffer stack saja).

---

## ADR-011: Pola wrapper middleware comptime

**Status:** Diterima

**Konteks:** Handler HTTP butuh concern lintas-potong (auth, rate limiting, CORS, logging) yang berlaku pada sebagian route. Opsinya: runner rantai runtime (list fungsi middleware dialokasikan heap yang dipanggil berurutan), pola dekorator (fungsi wrapper), atau komposisi handler manual.

**Keputusan:** Fungsi wrapper comptime yang mengembalikan `HandlerFn`. Tiap wrapper menerima `comptime next: HandlerFn` dan mengembalikan `HandlerFn` baru. Pemanggilan `next` adalah pemanggilan fungsi langsung tanpa dispatch runtime, tanpa alokasi. Komposisi kiri-ke-kanan: wrapper terluar berjalan lebih dulu.

```zig
fn withAuth(comptime next: zix.Http.HandlerFn) zix.Http.HandlerFn {
    return struct {
        fn handle(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) anyerror!void {
            // guard ...
            return next(req, res, ctx);
        }
    }.handle;
}

var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/private", .handler = withAuth(withLogging(privateHandler)) },
}, .{ .io = process.io, .ip = "127.0.0.1", .port = 9000 });
```

**Konsekuensi:**
- Overhead runtime nol. Tiap nilai `next` unik menghasilkan fungsi berbeda saat comptime.
- Tidak ada alokasi heap. Tidak ada runner rantai middleware yang perlu di-deinit.
- Komposisi bersifat eksplisit di call site registrasi: pembaca melihat rantai penuh tanpa mengintip ke dalam fungsi mana pun.
- Tiap komposisi unik menghasilkan fungsi comptime baru, kombinasi berlebihan menambah ukuran biner.

---

## ADR-012: Field config perilaku server HTTP eksplisit

**Status:** Diusulkan

**Konteks:** Beberapa perilaku server HTTP tertanam di internal `server.zig` dan tidak terlihat di `HttpServerConfig`: auto-respons 404 saat tidak ada route cocok, loop keep-alive, dan perilaku fallback file statik. Pengguna tidak dapat menimpa ini tanpa memodifikasi sumber.

**Keputusan:** Tambahkan field bernama ke `HttpServerConfig` untuk setiap perilaku yang dapat dikonfigurasi. `null` menonaktifkan perilaku, nilai fungsi mengaktifkan timpaan pengguna. Tambahan yang diusulkan:

```zig
pub const HttpServerConfig = struct {
    // existing fields ...
    not_found:  ?HandlerFn = null,    // null = built-in 404 plain text
    keep_alive: bool       = true,    // false = close after each response
};
```

Field `public_dir` sudah ada tetapi perannya sebagai fitur opt-in (bukan fallback ajaib) sebaiknya dieksplisitkan dalam dokumentasi.

**Konsekuensi:**
- Struct config adalah kontrak lengkap: jika tidak ada di struct, ia tidak terjadi.
- Perubahan breaking bagi kode mana pun yang bergantung pada perilaku 404 implisit saat ini (dampak minimal dalam praktik).
- `not_found = null` mempertahankan perilaku default saat ini, tidak ada migrasi yang diperlukan kecuali pengguna ingin 404 kustom.
- Sihir fallback statik dihapus: `public_dir = ""` (sudah jadi default) menonaktifkannya, seperti sekarang.

---

## ADR-013: Allocator eksplisit di UdpServerConfig

**Status:** Diterima

**Konteks:** `UdpServer` memakai heap untuk dua keperluan: list klien `Managed(ClientRecord)` (masa hidup proses) dan snapshot broadcast `[]IpAddress` per paket (dibebaskan di dalam `processPacket`). Keduanya sebelumnya memakai `std.heap.smp_allocator` secara internal, tak terlihat oleh pemanggil. Prinsip "eksplisit lebih utama dari implisit" pada proyek berlaku setara untuk kepemilikan memori: menyembunyikan allocator membuat mustahil mensubstitusi allocator pendeteksi kebocoran dalam pengujian.

**Keputusan:** Tambahkan `allocator: std.mem.Allocator` sebagai field wajib (tanpa default) ke `UdpServerConfig`. Server memakai allocator ini untuk list klien dan snapshot peer broadcast. `UdpClientConfig` tidak menerima field allocator karena `UdpClient` tidak melakukan alokasi heap, semua buffer dialokasikan di stack (`[@sizeOf(Packet)]u8`).

**Mengapa `ArenaAllocator` ditolak secara eksplisit untuk UDP:** Tidak seperti HTTP (di mana allocator router bersifat append-only), server UDP mengalokasikan dan membebaskan snapshot peer pada setiap paket ketika `broadcast = true`. `ArenaAllocator.free()` adalah no-op: memori tidak direklamasi hingga `arena.deinit()`. Pada server broadcast yang sibuk ini menyebabkan pertumbuhan tak terbatas:

```
// PoC: what goes wrong with ArenaAllocator
var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
var server = try MyServer.init(.{
    .allocator = arena.allocator(), // WRONG for UDP
    .broadcast = true,
    ...
});
// Each received packet when broadcast = true:
//   alloc(IpAddress, N)  ->  real allocation, grows arena
//   free(peers)          ->  NO-OP, memory not reclaimed
// After M packets with N clients: M * N * @sizeOf(IpAddress) bytes permanently held
// arena.deinit() is never called while the server runs -> unbounded memory growth
```

`ArenaAllocator` benar untuk `HttpServerConfig.allocator` karena router bersifat append-only: route diregistrasi sekali saat startup dan dibebaskan bersama via `arena.deinit()` saat server dimatikan.

**Konsekuensi:**
- Perubahan breaking: semua inisialisasi `UdpServerConfig` yang ada harus menambahkan `.allocator = ...`
- Kode pengujian kini dapat memberikan `std.testing.allocator` untuk deteksi kebocoran, kode produksi memberikan `std.heap.smp_allocator`.
- `UdpServerConfig` dan `HttpServerConfig` kini konsisten: keduanya mengekspos field allocator eksplisit yang wajib.
- `UdpClient` tetap lebih sederhana secara desain: tanpa alokasi heap, tanpa field allocator yang diperlukan.

---

## ADR-014: `Server.init(comptime stack_threshold, config)`, ambang buffer stack eksplisit

**Status:** Diterima

**Konteks:** API awal memakai fungsi generik comptime sebagai entry point: `zix.Http.Server(4096).init(config)`. Ini memaksa pemanggil memperlakukan `HttpServer` sebagai fungsi pabrik alih-alih struct, yang tidak intuitif dan tidak konsisten dengan sisa API. Ambang stack mengendalikan apakah buffer I/O per koneksi (`read_buf`, `write_buf`) tinggal di stack atau heap: jika `max_recv_buf` dan `max_client_response` keduanya muat dalam `stack_threshold`, buffer dialokasikan di stack, jika tidak ia jatuh kembali ke `smp_allocator`.

**Keputusan:** Ekspos struct `pub const Server` dengan satu `pub fn init(comptime stack_threshold: usize, comptime routes: []const Route, config: Config) !HttpServerImpl(stack_threshold, routes)`. Generik `HttpServerImpl` tetap privat. Call site menjadi `zix.Http.Server.init(4096, &[_]zix.Http.Route{...}, .{...})`: `Server` terbaca sebagai tipe, `init` terbaca sebagai konstruktor.

**Konsekuensi:**
- Call site satu tingkat lebih sederhana: `Server.init(N, routes, config)` alih-alih `Server(N).init(config)`.
- Baik `stack_threshold` maupun `routes` harus tetap `comptime`: Zig menuntut ukuran yang diketahui comptime untuk array stack, dan tabel route berukuran nol saat runtime ketika comptime.
- `HttpServerImpl(stack_threshold, routes)` adalah tipe konkret yang dikembalikan, pemanggil memakai `var server = try ...` tanpa menamai tipe generik.
- Perubahan breaking: semua call site yang ada diperbarui.

---

## ADR-015: Arsitektur work-queue Model 2 (ConnQueue)

**Status:** Diterima

**Konteks:** Model 2 awal memakai `io.concurrent()` untuk mendispatch koneksi dari tiap thread worker. Ini menambah overhead scheduler (wakeup condvar per koneksi) yang menyebabkan latensi ~4x lebih tinggi daripada server HTTP berbasis blocking-thread yang sebanding (334 us vs ~88 us) meski throughput setara (~145K req/s). Arsitektur blocking-thread (thread accept khusus + thread pool OS + I/O sinkron) menghapus scheduler fiber dari hot path sepenuhnya.

**Keputusan:** Ganti dispatch `io.concurrent()` per worker dengan `ConnQueue` bersama (mutex + condvar + `ArrayListUnmanaged`). Thread accept (`worker_count`, default 2) hanya memanggil `accept()` dan `queue.push()` (tidak pernah menangani I/O). Thread pool (`pool_size`, default `max(10, cpu_count * 2)`) memanggil `queue.pop()` lalu menangani tiap koneksi secara sinkron dengan I/O memblokir. `std.Io.Mutex` dan `std.Io.Condition` dipakai (primitif sinkronisasi Zig 0.14. `std.Thread.Mutex` tidak ada di versi ini).

**Konsekuensi:**
- Thread pool menangani koneksi dengan I/O memblokir murni: tanpa overhead dispatch condvar per request, tanpa latensi wakeup fiber.
- Throughput ~143-144K req/s, latensi ~92 us rata-rata. Gap ~3-5K req/s dan gap latensi ~4 us vs server blocking-thread yang sebanding tetap ada, dikaitkan dengan overhead parsing `std.http.Server` dan arena per koneksi vs allocator POSIX langsung.
- `pool_size` kini field yang dapat dikonfigurasi di `HttpServerConfig` (`0` = auto `max(10, cpu_count * 2)`).
- Thread accept cukup cepat sehingga 2 sudah memadai untuk menjenuhkan antrian accept kernel, `workers = N` memungkinkan timpaan eksplisit.
- `io.concurrent()` masih dipakai di Model 1 (`workers = 1`) (tidak terpengaruh).

---

## ADR-017: Channel, Penyampaian Pesan Bertipe Dalam-Proses

**Status:** Diterima, Diimplementasikan (2026-05-13)

**Konteks:** Model server (Model 1 / Model 2) menangani konkurensi request. Tidak ada primitif untuk penyampaian pesan bertipe antar task konkuren dalam satu proses. Channel Go dan pipe POSIX menjawab pola ini, zix butuh padanan native-Zig sendiri yang bekerja berdampingan dengan task `io.concurrent()`.

**Keputusan:** Diimplementasikan sebagai `zix.Channel(comptime T: type)`. Buffered saja (kapasitas > 0, rendezvous unbuffered ditangguhkan). `send(io, value)` dan `recv(io)` memblokir. Diekspos sebagai `pub const Channel = @import("channel/Channel.zig").Channel` di `lib.zig`. Pertanyaan terbuka yang diselesaikan:

- **Locking:** `std.Io.Mutex` + `std.Io.Condition` (sadar-fiber, bekerja baik di task handler `io.concurrent()` maupun thread OS). `std.Thread.Mutex` ditolak karena memblokir thread OS.
- **Storage:** ring buffer dialokasikan heap (`allocator.alloc(T, capacity)`), kapasitas runtime, allocator wajib di `init()`.
- **Penamaan:** `Channel` (bukan `Chan`), dikunci pada contoh pertama.
- **Unbuffered:** belum diimplementasikan. `init()` mengassert `capacity > 0`.
- **`select`/multiplex:** ditangguhkan. Desain ring tidak menghalanginya.

**Konsekuensi:**
- `zix.Channel(T)` adalah generik yang mengembalikan struct. Pemakaian: `const MyChan = zix.Channel(u32)`.
- `init(allocator, capacity)` mengalokasikan ring buffer. `deinit()` membebaskannya.
- `close(io)` membuka blokir semua pemanggilan `recv()` yang menunggu: receiver menguras item tersisa lalu mendapat `error.Closed`.
- `send()` dan `recv()` butuh `io` yang valid pada thread pemanggil: tiap thread OS butuh `std.Io` sendiri (misalnya dari `std.Io.Threaded`).
- `trySend`/`tryRecv` non-blocking ditangguhkan. Semua contoh saat ini memakai varian memblokir.

---

## ADR-016: SSE via `res.stream()` + `SseWriter`, `.ASYNC` lebih dipilih

**Status:** Diterima (model dispatch diperbarui oleh ADR-021)

**Konteks:** SSE (Server-Sent Events) menuntut respons HTTP streaming: header dikirim sekali tanpa `Content-Length`, dan koneksi tetap terbuka sementara handler mendorong event. `Response.send()` yang ada mengasumsikan body lengkap dan selalu mengemisi `Content-Length`. Jalur kode baru diperlukan tanpa memecah API respons yang ada.

Koneksi SSE berumur panjang (detik hingga menit per stream). Thread pool memblokir `.POOL` menetapkan satu thread OS per koneksi terbuka selama durasi penuh stream. Dengan pool default `max(10, cpu_count * 2)`, segelintir klien SSE akan menghabiskan semua thread pool dan membuat request HTTP biasa kelaparan. `.ASYNC` (`dispatch_model = .ASYNC`) mendispatch tiap koneksi sebagai fiber konkuren via `io.async()`, memungkinkan ribuan stream SSE terbuka tanpa kehabisan thread.

**Keputusan:**

1. Tambahkan `res.stream() !SseWriter` ke `Response`. Ia mengirim `Content-Type: text/event-stream`, `Cache-Control: no-cache`, `Connection: keep-alive`, dan `Date` (tanpa `Content-Length`), lalu menyetel `res.streaming = true` dan mengembalikan `SseWriter`.

2. `SseWriter` memegang `*std.Io.Writer` (writer buffered koneksi). Tiap metode menulis format wire SSE dan mem-flush segera:
   - `writeEvent(data)` -> `data: <data>\n\n`
   - `writeNamedEvent(event, data)` -> `event: <event>\ndata: <data>\n\n`
   - `comment(text)` -> `: <text>\n`

3. `handleConnection` memeriksa `if (res.streaming) break` setelah tiap dispatch. Ketika handler kembali, loop keep-alive keluar dan koneksi TCP tertutup. `EventSource` browser otomatis menyambung ulang setelah retry default 3 detik.

4. Contoh SSE harus memakai `dispatch_model = .ASYNC` (lihat ADR-021). Ini didokumentasikan dalam contoh, README, dan HLD.

**Konsekuensi:**
- Tidak ada perubahan pada `Response.send()`, handler yang ada tidak terpengaruh.
- `res.streaming` default `false`, hanya handler SSE yang menyetelnya `true`.
- Preferensi `.ASYNC` adalah batasan pemakaian, tidak ditegakkan saat compile time. Handler yang memanggil `res.stream()` di server `.POOL` akan bekerja tetapi memblokir thread pool selama durasi stream.
- `SseWriter` diekspos dari `zix.Http.SseWriter` bagi penulis handler yang ingin menganotasi tipe writer.

---

## ADR-018: Strategi timeout, B+D (ctx.timedOut + eviksi ConnRegistry)

**Status:** Diterima

**Konteks:** Field `HttpServerConfig.response_timeout_ms` awal tidak pernah dikaitkan ke `server.zig`. Ia ada sebagai placeholder. Dua kelas timeout diperlukan: guard tingkat jaringan untuk klien yang macet sebelum atau selama pengiriman header (menahan thread pool tanpa batas), dan budget tingkat handler untuk logika aplikasi yang lambat.

`SO_RCVTIMEO` diselidiki lalu ditolak: di Linux, `SO_RCVTIMEO` memicu `EAGAIN`, yang dipetakan `std.Io.Threaded.netReadPosix` ke `errnoBug` (panic di mode debug dan `error.Unexpected` di release). Ia tidak dapat dipakai pada socket memblokir di stack ini. `stream.shutdown(.both)` adalah mekanisme interupsi yang benar: di Linux ia menyebabkan `readv()` yang terblokir mengembalikan 0 (EOF), yang menyebar sebagai `error.HttpConnectionClosing` atau `error.ReadFailed` lewat `std.http.Server.receiveHead()`.

Empat opsi diprototipekan dan diuji.

**Opsi A: Max-age koneksi (ditolak):**
Deadline disetel sekali saat waktu accept dan diperiksa di puncak tiap iterasi loop keep-alive. Ini adalah cap masa hidup koneksi, bukan timeout per-celah-idle. Cek hanya memicu ketika `receiveHead()` kembali, sehingga tidak dapat menginterupsi klien yang menjadi idle permanen. Thread ditahan tanpa batas di dalam `receiveHead()` begitu klien berhenti mengirim. Opsi A tidak dikaitkan ke server.

**Opsi C: Thread watchdog per koneksi (ditolak):**
Menelurkan satu thread OS per koneksi yang diterima menghapus masalah idle permanen. Tiap watchdog tidur selama `timeout_ms` dan memanggil `stream.shutdown(.both)` jika koneksi belum selesai. Diuji dan bekerja: memicu tepat pada 5.006s. Ditolak karena menambah satu thread OS per koneksi aktif (masing-masing dengan stack virtual 64KB), yang melipatgandakan tekanan memori di bawah beban. Opsi D mencapai cakupan sama tanpa thread ekstra.

**Keputusan:** Adopsi B + D sebagai dua lapisan ortogonal yang independen. Hapus `response_timeout_ms` dan ganti dengan dua field config:

- `conn_timeout_ms: u32 = 0` (**Lapisan D**): `ConnRegistry` tertanam di `HttpServerImpl`. Pada tiap tick timer 500ms, `registry.evict()` memindai koneksi aktif dan memanggil `stream.shutdown(.both)` pada yang deadline-nya lewat. `handleConnection` meregistrasi `ConnEntry` saat accept dan menderegistrasi (via `defer`) saat tutup. Efektif hanya di model 2 (thread timer sudah ada). Presisi eviksi: `[deadline, deadline + 500ms]`.

- `handler_timeout_ms: u32 = 0` (**Lapisan B**): `ctx.deadline` disetel dari config sebelum tiap dispatch handler. Handler opt-in dengan memanggil `ctx.timedOut()` di antara langkah mahal dan merespons 408 lebih awal. Overhead nol saat dinonaktifkan (cek null pada deadline). Bekerja di model 1 maupun model 2.

Dua lapisan ini ortogonal: D memicu jika klien macet sebelum handler bahkan mulai, B memicu jika handler terlalu lama setelah mulai. Keduanya default 0 (nonaktif) sehingga kode yang ada tidak terpengaruh.

**Konsekuensi:**
- `response_timeout_ms` dihapus: pemanggil yang menyetelnya harus bermigrasi ke `conn_timeout_ms` dan/atau `handler_timeout_ms`.
- Lapisan D memicu `shutdown(.both)` yang menyebabkan `receiveHead()` mengembalikan `error.ReadFailed`. Kasus error ini kini ditangani di `handleConnection`.
- Lapisan B bersifat kooperatif: handler yang tidak memanggil `ctx.timedOut()` tidak pernah diinterupsi. Ini disengaja (pembatalan paksa di seberang kode Zig sembarang tidak aman).
- `conn_timeout_ms` sebaiknya >= `handler_timeout_ms`. Jika D memicu saat handler di tengah respons, koneksi tertutup mendadak alih-alih mengirim 408 bersih.
- Opsi C adalah pilihan yang benar untuk deployment di mana jitter per koneksi harus dibatasi ke milidetik tepat alih-alih `[deadline, deadline + 500ms]`.

---

## ADR-019: Route router, tata letak MultiArrayList (SoA)

**Status:** Diterima

**Konteks:** `Router.routes` adalah `ArrayList(Route)` di mana `Route = {path, handler, kind}`. Dispatch Lintasan 2 (PARAM) dan Lintasan 3 (PREFIX) mengiterasi list memfilter berdasarkan `kind` sebelum mengakses `path` atau `handler`. AoS menyelang-nyeling ketiga field di memori, sehingga mengiterasi `kind` menarik `path` dan `handler` ke cache bahkan ketika belum diperlukan.

**Keputusan:** Ganti `ArrayList(Route)` dengan `MultiArrayList(Route)`. Tiap field (`kind`, `path`, `handler`) disimpan dalam array kontigu sendiri. Lintasan 2 hanya mengiterasi `items(.kind)` dengan indeks, menyentuh `items(.path)[i]` dan `items(.handler)[i]` hanya saat ada match PARAM. Lintasan 3 menzip `items(.kind)` dan `items(.path)` tanpa memuat `items(.handler)` hingga kandidat prefix terkonfirmasi.

**Konsekuensi:**
- `routes.items.len` menjadi `routes.len`, akses field menjadi `routes.items(.field)[i]`
- `init()` disederhanakan: `routes` default-init ke `.{}`, tidak perlu `.empty` eksplisit
- Tanda tangan `append()` dan `deinit()` tidak berubah
- Unit test di `router.zig` diperbarui, test integrasi dan contoh tidak berubah (API publik tidak terpengaruh)
- Keuntungan praktis sebanding dengan jumlah route PARAM dan PREFIX, kebanyakan deployment produksi memilih route exact (O(1) via `exact_map`) sehingga perbaikannya adalah koherensi cache alih-alih algoritmik

---

## ADR-020: Http.Client, membungkus std.http.Client dengan respons bertipe dan error bernama

**Status:** Diterima

**Konteks:** zix punya server tetapi tidak punya client. Pemanggil yang menulis harness test integrasi, panggilan layanan-ke-layanan, atau pengirim webhook butuh menjangkau endpoint HTTP. Stdlib menyediakan `std.http.Client` tetapi API-nya tingkat rendah: pemanggil mengelola buffer redirect, reader body, invalidasi head, dan connection pooling sendiri. Tidak ada konsep respons ber-cap-ukuran, objek respons bertipe yang dimiliki pemanggil, atau set error bernama.

**Keputusan:** Implementasikan `zix.Http.Client` sebagai wrapper tipis di atas `std.http.Client` yang menambah:

1. **Config bertipe (`HttpClientConfig`)**: allocator, io, timeout connect/response/read, cap body, kebijakan redirect, user-agent. Semua field wajib dinamai. Semua field opsional punya default.

2. **Timeout connect**: diteruskan ke `std.http.Client.connectTcpOptions(.{ .timeout = Io.Timeout })`. Ini satu-satunya timeout yang ditegakkan di v1 karena `connectTcpOptions` mengekspos parameter timeout. Timeout response dan read butuh perkabelan tingkat-IO dan ditangguhkan.

3. **Cap ukuran body**: `body_reader.allocRemaining(gpa, .limited(max_response_body))` mengembalikan `error.StreamTooLong`, yang dipetakan ulang ke `error.BodyTooLarge`. Ini mencegah OOM diam-diam pada respons besar atau jahat.

4. **Salin byte head**: `std.http.Client.Response.head.bytes` menunjuk ke read buffer koneksi. Ia diinvalidasi oleh `response.reader()` dan menjadi dangling setelah `req.deinit()`. Client menyalin `head.bytes` via `gpa.dupe` sebelum memanggil `response.reader()`. Ini membuat `ClientResponse.header()` dan `iterateHeaders()` aman setelah request selesai.

5. **`ClientResponse` milik pemanggil**: memegang `status_code: u16`, `head_bytes: []u8`, `body_data: []u8`, semua dimiliki `config.allocator`. Pemanggil memanggil `deinit()` untuk membebaskan. Tidak ada kopling masa hidup tersembunyi ke instansi `HttpClient`.

6. **Error bernama**: `error.InvalidUrl` (gagal parse, skema tidak didukung, host hilang) dan `error.BodyTooLarge` muncul sebelum pemanggil perlu memeriksa set error stdlib. `error.Timeout` dari `std.Io` menyebar tanpa perubahan untuk timeout connect.

**Alternatif yang dipertimbangkan:**

- *Membangun di atas stream TCP mentah (seperti client UDS)*: akan menuntut reimplementasi framing HTTP/1.1, transfer chunked, parsing header, pengikutan redirect, dan connection pooling. Terlalu luas untuk v1. `std.http.Client` menyediakan semua ini dengan benar.

- *Mengembalikan `std.http.Client.Response` langsung*: pemanggil akan mewarisi semua batasan invalidasi head dan masa hidup buffer, plus perlu mengelola state connection pool. Mengalahkan tujuan "eksplisit lebih utama dari implisit".

- *Jalur panggilan `fetch()` tunggal*: `std.http.Client.fetch()` menyembunyikan detail tingkat koneksi. Ia tidak mengekspos cara menyuntikkan timeout connect per panggilan, membuat `connect_timeout_ms` tidak dapat diimplementasikan. Jalur `connectTcpOptions` + `request()` + `receiveHead()` tingkat lebih rendah dipilih sebagai gantinya.

**Konsekuensi:**
- Satu alokasi heap ekstra per request (salin byte head via `gpa.dupe`). Ukurannya adalah head mentah (status line + header), tipikal beberapa ratus byte.
- `ClientResponse` tidak aman dipakai setelah `deinit()`.
- TLS (HTTPS) di luar lingkup zix. Library ini adalah backend jaringan: terminasi TLS didelegasikan ke proxy hulu (nginx, HAProxy, Envoy). `std.http.Client` mendukung TLS secara internal, tetapi zix tidak mengekspos, mengonfigurasi, atau mengujinya. HTTP polos pada jaringan internal adalah pemakaian yang dituju.
- `response_timeout_ms` dan `read_timeout_ms` disimpan di config dan didokumentasikan sebagai "v1: belum ditegakkan" sehingga pemanggil dapat menyetelnya sekarang dan mendapat penegakan di rilis mendatang tanpa perubahan API.

---

## ADR-021: Enum DispatchModel (POOL / ASYNC / MIXED)

**Status:** Diterima

**Konteks:** `HttpServerConfig` awal memakai `workers: usize` untuk memilih antara dua mode konkurensi: `workers = 1` untuk dispatch `io.async()` single-accept dan `workers = 0` / `workers = N` untuk thread pool work-queue. Mode ketiga (N thread accept yang masing-masing mendispatch via `io.async()` tanpa ConnQueue) ada sebagai jalan tengah alami. Field `workers` kelebihan beban: nilai `1` mengubah strategi dispatch sepenuhnya alih-alih menyetel jumlah thread accept. Ini tidak jelas dan tidak swa-dokumentasi di call site.

**Keputusan:** Perkenalkan `DispatchModel = enum(u8) { POOL = 0, ASYNC = 1, MIXED = 2 }` sebagai field bernama `dispatch_model: DispatchModel = .POOL` di `HttpServerConfig`. Tiga model:

- `.POOL` (default): N thread accept mendorong ke `ConnQueue` bersama. M thread pool mengambil dan menangani koneksi dengan I/O sinkron memblokir. Throughput terbaik di bawah jumlah koneksi tinggi. `workers` mengendalikan jumlah thread accept, `pool_size` mengendalikan jumlah thread pool.
- `.ASYNC`: Satu thread accept mendispatch tiap koneksi via `io.async()`. Dipilih untuk SSE dan WebSocket, koneksi berumur panjang tidak menahan thread pool. `workers` dan `pool_size` diabaikan.
- `.MIXED`: N thread accept masing-masing mendispatch via `io.async()` langsung, tanpa `ConnQueue`. Throughput dan latensi seimbang. `pool_size` diabaikan.

Shorthand lama `workers = 1` untuk dispatch single-accept dihapus. Pemanggil yang menginginkan perilaku itu menyetel `dispatch_model = .ASYNC`.

`workers = 0` kini berarti thread accept sejumlah cpu_count untuk `.POOL` dan `.MIXED`. Default lama yaitu 2 adalah hitungan kurang pada mesin dengan banyak core.

**Konsekuensi:**
- Perubahan breaking: pemanggil yang memakai `workers = 1` harus bermigrasi ke `dispatch_model = .ASYNC`.
- `dispatch_model` swa-dokumentasi di call site. Tiga strategi adalah varian enum eksplisit, bukan nilai `usize` ajaib.
- `pool_size` diabaikan diam-diam untuk `.ASYNC` dan `.MIXED`, tanpa error, didokumentasikan di `HttpServerConfig`.
- Tipe backing enum `u8` mengikuti konvensi proyek untuk semua enum bernama.

---

## ADR-022: Server dan client stream mentah zix.Tcp

**Status:** Diterima

**Konteks:** Setelah engine HTTP rampung, lapisan protokol berikutnya adalah server stream TCP mentah generik, tanpa framing HTTP, tanpa router, handler yang didefinisikan pengguna memiliki stream. PoC HTTP di `rnd/` membuktikan ketiga model dispatch (POOL, ASYNC, MIXED) bekerja untuk TCP. Pertanyaannya adalah bagaimana mengeksposnya sebagai API library tanpa menggandakan internal HTTP.

**Keputusan:**

- `zix.Tcp.Server` dan `zix.Tcp.Client` adalah tipe mandiri di `src/tcp/server.zig` dan `src/tcp/client.zig`. Tidak ada basis bersama dengan `zix.Http.Server`, prinsip mandiri-per-protokol yang sama dengan `zix.Uds.Server`.
- `HandlerFn = *const fn(stream: std.Io.net.Stream, io: std.Io) void`, tanda tangan identik dengan `zix.Uds.HandlerFn`. Handler memiliki stream dan harus menutupnya sebelum kembali.
- `TcpServer.run(io)` / `runWith(io, handler)`, io diteruskan sebagai parameter (tidak disimpan di config). Pemanggil mengendalikan masa hidup backend `std.Io`.
- Ketiga model dispatch (POOL, ASYNC, MIXED) berlaku dengan pola `ConnQueue` + spawn thread yang sama dari `zix.Http.Server`. `DispatchModel` didefinisikan sekali di `src/tcp/config.zig` dan diimpor oleh `src/tcp/http/config.zig`, satu sumber kebenaran untuk semua protokol berbasis TCP.
- Format frame: `[u32 big-endian payload_len][payload bytes]`. Big-endian (network byte order) dipilih untuk TCP karena itu konvensi jaringan dan cocok dengan ekspektasi library protokol lain. `zix.Uds` memakai little-endian sebagai kontras (lokal saja, tanpa kebutuhan interop).
- `initArgs()` pada server dan `connectArgs()` pada client mem-parse `--ip` dan `--port` dari arg CLI, mengikuti pola `zix.Udp.Server.initArgs()`.

**Konsekuensi:**
- `zix.Tcp.Http.*` dan `zix.Tcp.Server`/`Client` berdampingan di bawah namespace `zix.Tcp` yang sama, HTTP adalah protokol tingkat tinggi, TCP mentah adalah lapisan stream tingkat rendah.
- `zix.Tcp.Server` tidak mengalokasikan dari allocator yang disediakan pengguna. `ConnQueue` memakai `smp_allocator` langsung, pendekatan yang sama dengan server HTTP.
- `echoHandler` bawaan memakai `takeVarInt(u32, .big, 4)` dan `readSliceAll` (vs loop `readSliceShort` di `zix.Uds.echoHandler`), konsisten dengan pola PoC yang dikonfirmasi selama fase RnD TCP.
- Protokol Fix mendatang (`zix.Tcp.Fix.*`) mengikuti pola mandiri-per-protokol yang sama dan tidak akan dibangun di atas `zix.Tcp.Server`.

---

## ADR-023: zix.Logger, logger event terstruktur yang aman-thread

**Status:** Diterima, Diimplementasikan (2026-05-23)

**Konteks:** Tiap implementasi server (HTTP, TCP, UDP, UDS, FIX, gRPC) butuh lapisan logging. `std.debug.print` tidak aman pada thread OS latar belakang karena ia melewati `std.Options.debug_io`, singleton `Io.Threaded` global, memanggilnya dari thread spawn mana pun balapan dengan channel IPC test runner dan menyebabkan panic. Primitif logging yang aman pada thread OS latar belakang tanpa dependensi `std.Io` diperlukan.

**Keputusan:** Implementasikan `zix.Logger` sebagai struct dengan spinlock per instansi (CAS atomik) yang melindungi write buffer 64 KB dan file descriptor. Semua I/O memakai `std.posix.write` mentah, tanpa `std.Io`, tanpa `std.debug.print`. Metode log spesifik protokol menyediakan baris yang dapat di-parse mesin tanpa pasca-pemrosesan: `system()`, `access()` (HTTP), `conn()` (TCP), `packet()` (UDP), `frame()` (UDS), `session()` (FIX), `rpc()` (gRPC). Tiap config server menerima `logger: ?*Logger = null`, logger bersifat opsional dan server senyap saat null.

**Konsekuensi:**
- Semua metode log aman dipanggil bersamaan dari thread OS mana pun termasuk worker thread-pool, thread accept, dan handler koneksi.
- Tidak ada alokasi `std.Io` per panggilan log. Write buffer di-flush pada pergantian tanggal, rotasi sekuens, `logger.flush()` eksplisit, atau `logger.deinit()`.
- Rotasi file harian (subdirektori `YYYY-MM-DD/`) dengan penomoran sekuens per file. `save_path` harus ada sebelum `Logger.init`, logger tidak membuatnya.
- Output konsol dikendalikan oleh `ConsoleMode` (`.OFF`, `.DEBUG_ONLY`, `.ALWAYS`). Jalur file maupun konsol dijaga oleh `save_min_level` / `console_min_level`.
- `access()` menurunkan level log dari status HTTP: 2xx/3xx=INFO, 4xx=WARN, 5xx=ERROR. `rpc()` menurunkan dari kode grpc-status.

---

## ADR-024: zix.Fix, lapisan sesi FIX 4.x sebagai server mandiri

**Status:** Diterima, Diimplementasikan (2026-05-23)

**Konteks:** Protokol FIX (Financial Information eXchange) adalah standar pesan dominan untuk sistem trading finansial. Ia memakai SOH (0x01) sebagai delimiter field, bukan prefiks panjang, yang membuatnya tidak kompatibel dengan pola recv `readSliceShort` yang dipakai HTTP. Server mandiri yang mengikuti pola config dan model-dispatch yang sama dengan `zix.Tcp` diperlukan, dengan lapisan sesi (penanganan Logon/Logout/Heartbeat) terbangun di dalam sehingga pemanggil tidak mengimplementasikannya sendiri.

**Keputusan:** Implementasikan `zix.Fix` di `src/tcp/fix/`. `serveConn` adalah loop inti: ia mengakumulasi byte via `takeByte` hingga `findMessageEnd` mendeteksi pesan lengkap, lalu mendispatch secara internal berdasarkan MsgType (tag 35). Logon/Logout/Heartbeat/TestRequest ditangani otomatis, semua pesan lain di-echo. Tidak ada callback handler yang dibutuhkan. State sesi (comp_id, seq_num) bersifat stack-lokal terhadap `serveConn`, tanpa alokasi heap dalam loop pesan. Keempat model dispatch berlaku. `.ASYNC` adalah default karena sesi FIX berumur panjang. `.EPOLL` berjalan native di Linux (loop accept epoll tunggal, ring buffer `FdQueue`, worker pool menahan tiap koneksi selama masa hidup penuhnya, pola sama dengan `zix.Grpc`). Non-Linux jatuh kembali ke `.POOL`.

**Konsekuensi:**
- `takeByte` dalam loop menghindari deadlock `readSliceShort`: buffer internal reader menyerap segmen TCP penuh, panggilan `takeByte` berikutnya mengurasnya tanpa syscall ekstra.
- `serveConn` hanya memakai buffer stack (`recv_buf[MAX_MSG_SIZE * 2]`, `fields[MAX_FIELDS]`). Tanpa alokasi per request.
- `buildMessage` menghitung dan menyematkan checksum. `verifyChecksum` memvalidasi pesan masuk. Checksum buruk menutup koneksi tanpa balasan.
- `std.debug.print` absen dari semua fungsi entry thread, dipelajari dari panic IPC test runner `std.Options.debug_io` yang dijelaskan di CLAUDE.md.
- `FixClient` menyediakan client bertipe (`logon`, `logout`, `sendMessage`, `recvMessage`) untuk test dan contoh.

---

## ADR-025: `reuse_address = true` pada semua model dispatch (SO_REUSEADDR + SO_REUSEPORT)

**Status:** Diterima

**Konteks:** Tiap server di zix (Http, Http2, Grpc, Tcp, Fix) memanggil `addr.listen(io, .{ .reuse_address = true })`. Di `std.Io.Threaded` Zig, `reuse_address = true` menyetel `SO_REUSEADDR` sekaligus `SO_REUSEPORT` pada POSIX. `SO_REUSEPORT` mutlak diperlukan oleh model dispatch POOL: tiap thread accept memanggil `addr.listen()` pada port yang sama secara independen, tanpa itu bind kedua gagal dengan `EADDRINUSE`. Pilihannya adalah menyetelnya secara kondisional (POOL saja) atau tanpa syarat (semua model).

**Keputusan:** Terapkan `reuse_address = true` tanpa syarat pada tiap pemanggilan `addr.listen()` tanpa peduli model dispatch. Semua model berbagi jalur setup socket yang sama, tanpa percabangan pada `dispatch_model` di tingkat socket. Ini perilaku tingkat socket, didokumentasikan di sini dan inline dalam sumber, tidak diekspos sebagai field config.

**Konsekuensi:**
- POOL bekerja benar: semua thread accept bind ke port yang sama dan kernel menyeimbangkan beban koneksi masuk di antara mereka.
- ASYNC, MIXED, dan EPOLL juga menerima `SO_REUSEPORT` sebagai efek samping. Banyak instansi server pada port yang sama tidak crash, kernel diam-diam mendistribusikan koneksi di antara mereka.
- Ini disengaja. Berbagi port antar proses adalah pola deployment yang valid (restart bergulir, peluncuran bertahap). Contoh yang berbagi nomor port berdampingan tanpa error saat dijalankan bersamaan karena alasan yang sama.
- Tidak ada field `ServerConfig` ditambahkan untuk mengekspos atau menyetel perilaku ini.

---

## ADR-026: zix.Http1 writeSimple, buffer gabungan mengalahkan writev untuk body kecil

**Status:** Diterima

**Konteks:** `zix.Http1.writeSimple` (hot path EPOLL) mengirim status line, header, dan body. Dua strategi diprofil dalam ReleaseFast. Strategi A (`writev` dengan dua entri `iovec`) bersifat zero-copy: buffer header dan slice body diteruskan sebagai segmen terpisah, tanpa konkatenasi. Strategi B menyalin header dan body ke satu buffer stack kontigu, lalu mengeluarkan satu `write()`. Teori mengunggulkan A (tanpa salin), pengukuran tidak.

**Keputusan:** Pakai buffer kontigu plus satu `write()` untuk body hingga 3840 byte (buffer header adalah array stack 256 byte, total muat buffer stack 4096 byte). Untuk body di atas 3840 byte, jatuh kembali ke `writev` inline untuk menghindari penyalinan payload besar. Header Date diisi oleh `cachedDate()`, yang memanggil `clock_gettime` hanya setiap 256 request via penghitung tick thread-lokal. Header respons itu sendiri dibangun oleh `buildSimpleHeader`, encoder byte langsung (`appendStatusCode` / `appendDec` / `appendBytes`) yang menggantikan `std.fmt.bufPrint`.

**Konsekuensi:**
- Throughput body kecil naik dari ~450k ke ~612k req/s di c128 pada mesin acuan. Satu `write()` kontigu mengungguli `writev` dengan dua segmen kecil karena setup `iovec` per-syscall dan biaya gather kernel melebihi biaya menyalin ~100 byte di stack.
- Body besar (di atas 3840 byte) mempertahankan semantik zero-copy lewat fallback `writev`, sehingga respons besar tidak membayar penalti salin-stack 4KB.
- Catatan benchmark: `wrk` loopback pada konkurensi tinggi kira-kira 85 persen kernel-bound dan sangat rawan varians. Perbandingan harus dijalankan beruntun dalam satu skrip pada kondisi identik, jangan pernah dari tangkapan terpisah. Lihat komentar docs dan catatan memori proyek.

---

## ADR-027: Default header respons diturunkan ke `.MINIMAL` (16)

**Status:** Diterima

**Konteks:** `HttpServerConfig.max_response_headers` mengendalikan jumlah slot arena per request untuk header respons kustom (ADR-009). Default-nya `.COMMON` (32). Kebanyakan handler dalam praktik mengemisi jauh lebih sedikit dari 16 header kustom (layanan polos menambah 2 hingga 6), sehingga default 32 slot over-provisioning arena per request untuk kasus umum. Engine `zix.Http1` melakukan langkah sama di tingkat compile-time (`MAX_HEADERS` 32 ke 16, plus `Http1ServerConfig.max_headers: u8 = 16` runtime).

**Keputusan:** Turunkan default ke `.MINIMAL` (16) untuk `zix.Http` (`max_response_headers`) maupun `zix.Http1` (`max_headers` dan cap `MAX_HEADERS`). Pemanggil yang butuh lebih menaikkan tier secara eksplisit (`.COMMON`, `.LARGE`, `.EXTRA_LARGE`, atau `.{ .CUSTOM = N }`).

**Konsekuensi:**
- Footprint arena header per respons kasus terburuk turun dari ~1 KB (32 slot) ke ~512 byte (16 slot), mengetatkan batas DoS untuk handler yang melooping `addHeader()`.
- Perubahan perilaku bagi deployment mana pun yang mengandalkan cap 32 slot implisit dan menambah 17 hingga 32 header kustom. Handler semacam itu kini terkena `error.TooManyHeaders` hingga tier dinaikkan. Didokumentasikan di `docs/headers-en.md` dan `docs/headers-id.md`.
- Strategi alokasi pertumbuhan dinamis (ADR-009) tidak berubah. Hanya nilai cap default yang bergeser.

---

## ADR-028: Pemilih versi pada `zix.Http.Client` bersama

**Status:** Diterima

**Konteks:** Engine `zix.Http1` butuh contoh client (`examples/http1_client.zig`). `zix.Http1.Client` mentah terpisah akan menggandakan parsing URL, TLS, penanganan redirect, dan connection pooling yang sudah disediakan `zix.Http.Client` dengan membungkus `std.http.Client`. Roadmap std Zig menambah HTTP/2 ke `std.http.Client` yang sama, sehingga satu client adalah jalur alami menuju dukungan multi-versi. Pertanyaan terbukanya adalah bagaimana menyatakan versi protokol tanpa client terpisah per versi.

**Keputusan:** Tambahkan field `version` ke `HttpClientConfig`, bertipe `Version` (`HTTP_1`, `HTTP_2`, `HTTP_3`, varian KAPITAL, tanpa `auto`, default `.HTTP_1`), diekspos sebagai `zix.Http.ClientVersion`. `request()` menjaganya: `HTTP_1` berlanjut (HTTP/1.1 di atas `std.http.Client`), `HTTP_2` dan `HTTP_3` mengembalikan `error.UnsupportedVersion`. Jangan bangun `zix.Http1.Client` terpisah.

**Konsekuensi:**
- Satu permukaan client berbicara HTTP/1.1 hari ini dan bekerja terhadap server HTTP/1.1 mana pun, termasuk server `zix.Http1` mentah. Contoh `http1_client` memakainya dengan `.version = .HTTP_1`.
- API berbentuk maju: ketika backend h2 (atau h3) mendarat, ia masuk di belakang nilai enum yang ada tanpa perubahan tanda tangan yang menghadap pemanggil.
- Pemanggil yang memilih `HTTP_2` atau `HTTP_3` gagal cepat dan eksplisit alih-alih menurunkan diam-diam.

---

## ADR-029: Deadline per-handler `zix.Http1` via thread-local, bukan objek ctx

**Status:** Diterima

**Konteks:** `zix.Http` menegakkan budget per-handler lewat `ctx.isExpired()`, di mana server menyetel `ctx.deadline` sebelum dispatch (ADR-018). Tanda tangan handler `zix.Http1` adalah `fn(head, body, fd) void` tanpa parameter konteks, sengaja dijaga ramping untuk hot path zero-alloc. Menambah parameter `ctx` akan merembet melalui `Router`, tiap contoh, dan loop dispatch, dan akan melebarkan pemanggilan hot-path.

**Keputusan:** Tambahkan `Http1ServerConfig.handler_timeout_ms`. Simpan deadline dalam `threadlocal` di `core.zig`, diarmkan oleh server (`setTimeout(config.handler_timeout_ms)`) sebelum tiap dispatch di keempat model (`serveConn` via `ServeOpts`, `serveEpollConn` via parameter). Ekspos `zix.Http1.isExpired()` dan `zix.Http1.setTimeout()` sebagai fungsi bebas sehingga handler mengkueri dan menimpa budget-nya tanpa objek ctx. Tambahkan `408 Request Timeout` ke `statusPhrase`.

**Konsekuensi:**
- Tanda tangan handler tetap `fn(head, body, fd) void`. Tidak ada perubahan breaking pada `Router` atau contoh yang ada.
- Deadline bersifat per-worker-thread, yang cocok dengan model dispatch shared-nothing (tiap koneksi dilayani satu thread selama durasi panggilan).
- `handler_timeout_ms == 0` membiarkan thread-local di 0, sehingga `isExpired()` adalah cek murah yang selalu-false tanpa syscall clock pada jalur nonaktif.
- `serveConnOne` (helper publik niche) dibiarkan tanpa diarm. Pemanggil yang memakainya langsung mengarm deadline sendiri via `setTimeout()`.

---

## ADR-030: Loop frame WebSocket milik-engine `zix.Http1` dengan koalesensi write per-event

**Status:** Diterima

**Konteks:** Contoh WebSocket `zix.Http1` pertama melakukan handshake di handler lalu menjalankan loop `while (true)` `std.posix.read` memblokir sendiri untuk meng-echo frame. Di bawah `.EPOLL`, engine menerima dengan `accept4(SOCK.NONBLOCK)`, sehingga read itu mengembalikan `EAGAIN` pada poll kosong pertama dan handler langsung kembali: handshake sukses tetapi tidak ada frame yang pernah di-echo (0 frame). Bahkan di tempat loop bekerja (socket `.ASYNC` yang memblokir), ia memarkir satu worker thread pada satu koneksi selama seluruh masa hidup koneksi itu, yang membatasi konkurensi pada jumlah worker. Server echo io_uring acuan menjaga tiap koneksi dalam loop completion sebagai gantinya, sehingga semua koneksi maju bersamaan.

**Keputusan:** Jadikan loop frame WebSocket milik-engine di bawah `.EPOLL`. Handler memanggil `WebSocket.serve(fd, key, on_frame)`, yang melakukan handshake dan mencatat handoff thread-local (`core.requestWebSocket`). Tepat setelah handler kembali, loop epoll membaca handoff (`core.takeWebSocket`), membalik koneksi ke mode WebSocket (`Conn.ws`), dan sejak itu merutekan fd tersebut ke `serveEpollWs`. Tiap event readable membaca sekali (loop bersifat level-triggered, sehingga byte lebih lanjut memicu ulang) dan `WebSocket.pump` mem-parse tiap frame lengkap, memanggil `on_frame` untuk text dan binary, otomatis mem-pong ping, dan otomatis meng-echo close. Callback-nya `fn(fd, opcode: u8, payload) void`: `opcode` adalah nilai RFC 6455 mentah untuk menjaga tipe di `core.zig` dan menghindari siklus impor `core` ke `websocket`. Semua frame yang dihasilkan selama satu event readable distaging dalam `SendSink` per-event dan di-flush dalam satu `write()`, sehingga burst pipelined berbiaya satu syscall alih-alih satu per frame. `buildHeader` dipisah dari `buildFrame` untuk jalur staging. Pada `.ASYNC` dan `.POOL`, handoff dibersihkan dan koneksi berakhir setelah handler kembali: WebSocket milik-engine hanya `.EPOLL`.

**Konsekuensi:**
- Tanda tangan handler tetap `fn(head, body, fd) void`. Dukungan WebSocket tidak menambah ctx dan tidak mengubah router, handler cukup memanggil `WebSocket.serve` alih-alih melooping.
- Tidak ada worker yang diparkir per koneksi. Satu worker epoll menggerakkan banyak koneksi WebSocket, meng-echo masing-masing saat siap.
- Koalesensi write adalah kemenangan pipelined yang dominan. Tanpa itu, burst pipelined sedalam 16 mengeluarkan 16 write per event.
- Frame yang lebih besar dari read buffer koneksi tidak pernah dapat selesai: `serveEpollWs` menutup koneksi semacam itu alih-alih berputar. Untuk beban kerja echo (frame kecil) ini tidak pernah terpicu.
- WebSocket loop-memblokir manual masih mungkin di bawah `.ASYNC` atau `.POOL` (socket itu memblokir), tetapi membawa cap satu-worker-per-koneksi lama dan tidak memakai handoff.

---

## ADR-031: Event loop multipleks `.EPOLL` `zix.Grpc`, dispatch inline, dan koalesensi hot-path

**Status:** Diterima

**Konteks:** Model `.EPOLL` `zix.Grpc` pertama tidak multipleks-event. Satu loop accept memberi makan `FdQueue`, dan pool `max(10, cpu*2)` worker thread masing-masing mengambil satu koneksi dan menjalankan masa hidup koneksi h2c penuh dengan read memblokir. Konkurensi karenanya dibatasi pada jumlah worker: di bawah beban 256 atau 1024 koneksi hanya ~24 yang pernah dilayani sekaligus. Biaya per-request juga tinggi: balasan unary mengeluarkan tujuh panggilan `write()` (HEADERS, DATA, trailer, masing-masing write frame-header terpisah plus write payload), plus dua write `WINDOW_UPDATE` per frame DATA masuk, plus read frame-header 9 byte lalu read payload per frame, dengan `TCP_NODELAY` aktif. Tiap koneksi juga mengalokasikan tabel stream 16 slot dengan body inline 64 KB per slot (~1.1 MB per koneksi). Route server-streaming menelurkan satu thread per stream. Di bawah beban benchmark, throughput unary mendatar di ~110k req/s tanpa peduli jumlah koneksi dan streaming duduk di ~2.6k panggilan/s.

**Keputusan:** Arsitektur ulang model `.EPOLL` menjadi event loop multipleks shared-nothing dan pangkas kerja per-request ke jumlah syscall mendekati-minimum.

- Multiplexing: tiap worker memiliki listener `SO_REUSEPORT` privat, instansi epoll sendiri, dan `GrpcConnTable` ber-indeks-fd privat. Kernel menyeimbangkan beban koneksi baru di seberang listener per-worker. `worker_count = pool_size` (0 memilih jumlah cpu). Loop koneksi h2 menjadi state machine yang dapat dilanjutkan (`GrpcMuxConn`): akumulator read per-koneksi bertahan di seberang event readable dan menahan frame parsial mana pun, mesin fase handshake (`await_preface` / `await_upgrade` / `await_preface2` / `h2`) menggantikan read preface memblokir, dan `muxFrameLoop` memproses tiap frame buffered lengkap lalu kembali ke epoll pada `EAGAIN`.
- Dispatch inline: dalam model `.EPOLL` tiap route, termasuk server-streaming, didispatch inline pada worker (tanpa thread per-stream, tanpa mutex write koneksi), karena worker memiliki koneksi. Handler streaming berjalan di event loop dan harus tetap terbatas.
- Koalesensi write per-event: semua frame respons yang dihasilkan saat menangani satu event readable (HEADERS awal, tiap DATA, trailer, dan frame kontrol apa pun) distaging dalam cork `ReplyStage` per-koneksi dan di-flush dalam satu `write()`. Balasan unary adalah satu write alih-alih tujuh.
- Kontrol aliran: `SETTINGS_INITIAL_WINDOW_SIZE` dinaikkan ke 16 MB dan window terima koneksi dinaikkan sekali setelah handshake, sehingga body request kecil tidak pernah memicu `WINDOW_UPDATE` per-DATA. Window koneksi diisi ulang secara borongan hanya melewati ambang.
- Read buffered: header frame dan payload dilayani dari read buffer koneksi, sehingga pasangan HEADERS plus DATA berbiaya satu `read()` alih-alih empat.
- Buffer berukuran tepat: `body` dan `header_scratch` per-stream adalah slice ke buffer backing per-koneksi yang diukur ke `max_body` / `max_header_scratch`, bukan array inline tetap.
- Blok balasan tercache: header balasan konstan untuk kasus umum di-encode HPACK sekali saat comptime, `:status 200` plus `content-type: application/grpc+proto` untuk HEADERS awal, dan `grpc-status: 0` untuk trailer OK. `buildGrpcHeaders` dan `buildGrpcTrailer` mem-memcpy blok tercache dan menstempel header frame 9 byte alih-alih menjalankan ulang encoder HPACK (dua pindai linear 61 entri plus Huffman per header). Encoder dinamis adalah fallback untuk content-type atau status lain.

`serveGrpcConn` dan `serveGrpcLoop` yang memblokir dipertahankan tanpa perubahan untuk `.ASYNC`, `.POOL`, dan `.MIXED`.

**Konsekuensi:**
- Throughput unary naik dari ~110k ke ~420k req/s pada 256 koneksi. Streaming naik dari ~2.6k ke ~28k panggilan/s. Pada core terisolasi (cpuset terpisah) server jenuh CPU dan menskala mendekati-linear di ~38-39k req/s per core. Hasil lebih rendah sebelumnya pada 1024 koneksi adalah artefak pengukuran shared-core di mana generator beban dan server berebut core yang sama.
- `pool_size` berubah makna untuk `.EPOLL`: kini adalah jumlah worker multiplexing (0 = cpu), bukan ukuran pool memblokir. Nilai besar tidak lagi membantu dan oversubscribe scheduler.
- `max_streams` yang diiklankan harus minimal sebesar jumlah concurrent-stream klien, atau stream yang dibuka optimistis oleh klien mendapat `REFUSED_STREAM` saat awal koneksi. Entri HttpArena menyetel `max_streams = 128` (h2load memakai `-m 100`).
- Handler streaming `.EPOLL` harus terbatas: stream berjalan-lama memblokir koneksi lain pada worker itu. Streaming tak-terbatas sebaiknya memakai `.ASYNC`.
- Write non-blocking memakai flush staging. `EAGAIN` diperlakukan sebagai pipa rusak dan menjatuhkan koneksi. Ini tidak pernah terpicu untuk balasan kecil pada benchmark, tetapi klien lambat dengan balasan besar bisa dijatuhkan: antrian backpressure `EPOLLOUT` mendatang akan menghapus tepi itu.
- Jalur upgrade h2c di loop multipleks minimal: ia mengembalikan `400` tanpa header `Upgrade: h2c` (jalur probe validate) dan `101` lalu preface koneksi dengan satu, tetapi tidak melayani request awal yang dibawa pada stream 1 dari upgrade. Klien prior-knowledge tidak terpengaruh.
- Perubahan satu baris di `HpackEncoder.writeString` (menganotasi hasil Huffman sebagai `?usize`) membuat encoder berjalan saat comptime sehingga blok tercache dapat dibangun di sana.

---

## ADR-032: `EPOLL_MAX_EVENTS = 512`, satu konstanta batch epoll bernama lintas semua server

**Status:** Diterima

**Konteks:** Tiap worker epoll native (`zix.Tcp`, `zix.Http`, `zix.Fix`, `zix.Grpc`, `zix.Http1`) memanggil `epoll_wait` dengan array `epoll_event` berukuran tetap. Ukuran itu adalah jumlah maksimum event siap yang diuras worker dalam satu syscall. Nilainya `256` di mana-mana, diekspresikan dalam tiga cara berbeda: `epoll_max_events` bernama tingkat-file di `tcp` dan `http`, dan literal `const max_events` inline di `fix`, `grpc`, dan `http1`. Dengan satu listener `SO_REUSEPORT` dan satu instansi epoll per worker, worker pada box 12-core di 4096 koneksi menahan kira-kira 341 fd, sehingga lebih dari 256 bisa readable dalam satu tick. Cap 256 lalu memaksa `epoll_wait` kedua untuk menguras sisanya, satu syscall ekstra per loop yang muncul hanya begitu set siap melebihi cap.

**Keputusan:** Naikkan batch ke `512` dan ekspresikan sebagai satu konstanta tingkat-file bernama yang didokumentasikan `EPOLL_MAX_EVENTS: usize = 512` di tiap dari lima file server, dipakai untuk ukuran array `[N]epoll_event` maupun argumen count `epoll_wait`. Literal `256` inline dan const `epoll_max_events` huruf-kecil dihapus, dan tipenya diunifikasi ke `usize`. 512 mencakup set ready-fd worker dalam satu syscall pada jumlah koneksi tinggi tempat cap lama mengikat.

**Konsekuensi:**
- Perf A/B (`EPOLL_MAX_EVENTS` 256 vs 512 pada build release yang sama, handler respons-tetap, diprofil dengan `perf stat` pada counter userspace) menunjukkan perubahan ini netral di c128 dan c1024, di mana set siap per worker jauh di bawah 256 sehingga cap tidak pernah mengikat, dan keuntungan kecil di c4096, di mana throughput naik ~8% dan siklus userspace per request turun. Itu cocok dengan mekanisme yang diprediksi: lebih sedikit syscall `epoll_wait` hanya di tempat set siap melebihi 256.
- Biayanya adalah satu array `epoll_event` per worker tumbuh dari ~6 KB ke ~12 KB stack. Diabaikan terhadap stack worker 512 KB.
- Tidak ada perubahan API publik. Konstanta bersifat privat dan tidak dapat dikonfigurasi. Nilainya adalah default tertala, bukan knob.
- Keruntuhan throughput c2048+ yang terlihat pada box loopback shared-core bersifat lingkungan (generator beban dan server berebut core yang sama). Ia tidak disebabkan maupun ditangani oleh konstanta ini.

---

## ADR-033: Router `zix.Http1` memperoleh `.PREFIX` dan `.PARAM`, param via thread-local

**Status:** Diterima

**Konteks:** Router comptime `zix.Http1` hanya exact-match (`std.mem.eql` atas tabel route), sementara router `zix.Http` tingkat lebih tinggi telah mendukung `.EXACT` / `.PREFIX` / `.PARAM` sejak ADR-004. Routing prefix atau path-param apa pun di server Http1 harus ditulis tangan dalam fungsi dispatch dengan `startsWith` dan `splitScalar` (seperti dilakukan `examples/http1_paths.zig`). Masalah penangkapan adalah alasan gap ini bertahan: matcher `zix.Http` menulis param tertangkap ke `req.path_params`, tetapi handler Http1 adalah `fn(head: *const ParsedHead, body, fd) void` tanpa `Request` dan tanpa state mutable per-panggilan untuk ditulisi (tanda tangan ramping zero-alloc yang sama yang dibela di ADR-029).

**Keputusan:** Bawa router Http1 ke paritas dengan router Http. Tambahkan `RouteKind { EXACT, PREFIX, PARAM }` dan field `kind` (default `.EXACT`) ke `zix.Http1.Route`, dan partisi tabel route saat comptime menjadi `StaticStringMap` (exact), array PARAM, dan array PREFIX. Dispatch menjaga prioritas ADR-004: exact (hash O(1)) > param (first-registered wins) > prefix (longest wins). Penangkapan param memakai ulang model ADR-029: segmen `:name` yang cocok ditulis ke penyimpanan `threadlocal` per-handler di `router.zig`, dibaca kembali lewat fungsi bebas baru `zix.Http1.pathParam(name)` alih-alih ctx atau `Request`. Penyimpanan adalah array tetap ber-cap `MAX_PATH_PARAMS = 8`, sehingga penangkapan zero-alloc. Lintasan prefix menjaga indeks boundary di belakang `startsWith` (`p[route.path.len]` hanya dibaca begitu `p.len >= route.path.len`), dan guard yang sama diterapkan balik ke router `zix.Http`, yang sebelumnya mengurutkan indeks sebelum cek `startsWith`.

**Konsekuensi:**
- Tanda tangan handler tidak berubah dan `.kind` default ke `.EXACT`, sehingga tiap tabel route Http1 exact-only yang ada terkompilasi dan berperilaku identik. Tidak ada perubahan breaking.
- Nilai param bersifat thread-local dan valid hanya untuk panggilan dispatch (mereka meminjam path request), yang cocok dengan model shared-nothing tempat satu worker melayani satu koneksi sekali waktu. Handler yang butuh param melewati kembaliannya sendiri harus menyalinnya.
- Penangkapan ber-cap 8 param per match. Pola dengan lebih banyak `:segments` dari itu gagal cocok alih-alih meluap.
- Lintasan prefix `zix.Http` tidak lagi membaca satu byte melewati path request yang pendek. Di ReleaseFast ini adalah read out-of-bounds tak berbahaya yang ditutupi oleh `and`, di Debug atau ReleaseSafe ia adalah panic pada path request mana pun yang lebih pendek dari prefix terdaftar.
- `examples/http1_paths.zig` masih mendemonstrasikan routing `startsWith` / `splitScalar` manual dengan sengaja (pencocokan kustom di luar tiga jenis). Komentar sebelumnya yang mengklaim router exact-only telah dikoreksi.

---

## ADR-034: Arsitektur shared-nothing `.EPOLL` `zix.Http`

**Status:** Diterima

**Konteks:** Model `.EPOLL` `zix.Http` awal menggunakan desain terpusat: satu accept thread mendorong stream koneksi yang diterima ke `ConnQueue` bersama (mutex + condvar + ring buffer), dan pool berisi `max(10, cpu_count * 2)` worker thread pop dari antrian dan memanggil `handleOneRequest`. Pada beban benchmark di c1000, mutex `ConnQueue` menjadi bottleneck. Throughput 428k req/s vs 480k milik `zix.Http1` (arsitektur shared-nothing yang sama, gap 11%). `pool_size` adalah field config yang relevan.

**Keputusan:** Ganti model terpusat dengan arsitektur shared-nothing yang cocok dengan `zix.Http1`. Setiap worker mengikat `SO_REUSEPORT` listener tersendiri, membuat `epoll` instance tersendiri, dan menjalankan event loop level-triggered tersendiri. Kernel mendistribusikan koneksi baru ke listener per-worker. Tidak ada `ConnQueue`, tidak ada mutex, tidak ada condvar, tidak ada handoff fd antar thread.

- `workers` (bukan `pool_size`) sekarang adalah jumlah worker EPOLL untuk `zix.Http`. `0` memilih cpu_count.
- `pool_size` diabaikan untuk `.EPOLL` `zix.Http` (masih berlaku untuk `.POOL`).
- Level-triggered `EPOLLIN` menggantikan `EPOLLONESHOT`: koneksi tetap terdaftar setelah setiap request dan re-fires saat data baru tiba. Tidak perlu re-arm eksplisit.
- Fd yang diterima bersifat blocking: `handleOneRequest` melakukan recv/parse/dispatch/send secara sinkron, lalu worker kembali ke `epoll_wait`.
- `handleOneRequest` tidak berubah: tanpa logik non-blocking baru, tanpa tabel state per-koneksi.

**Konsekuensi:**
- Throughput: 428k menjadi 451k req/s di c1000 (`wrk -c1000 -t4 -d10s`), mempersempit gap vs `zix.Http1` dari 11% menjadi 6,8%.
- Gap 6,8% yang tersisa bersifat struktural: `zix.Http` mengalokasi `ArenaAllocator` per koneksi dan membangun `Request` / `Response` / `ParsedHead` (array header 64 entri) per request. `zix.Http1` menggunakan parsing stack-local zero-alloc. Gap ini tidak bisa ditutup hanya dengan arsitektur.
- Field `pool_size` diabaikan secara diam untuk `.EPOLL` (perilaku yang sama seperti `.ASYNC` dan `.MIXED` yang sudah mengabaikannya). Pemanggil yang menetapkan `.pool_size = N` dengan `.EPOLL` harus migrasi ke `.workers = N`.
- SSE dan WebSocket masih tidak cocok untuk `.EPOLL`: blocking read akan menahan worker selama masa hidup koneksi. Gunakan `.ASYNC`.

---

## ADR-035: Staging per-koneksi gRPC mux, SETTINGS ter-cache, dan TCP_CORK

**Status:** Diterima

**Konteks:** Event loop gRPC EPOLL multiplexed (ADR-031) men-stage reply (HEADERS + DATA + trailer) ke buffer `ReplyStage` dan flush dalam satu `write()`. Buffer berupa `[4096]u8` inline pada `GrpcMuxConn`. Handler streaming yang memancarkan ribuan pesan meluap 4096 byte berulang kali, memaksa satu `write()` per luapan (~85 KB streaming dalam ~21 flush). Frame SETTINGS server di-encode ulang dari loop parameter pada setiap koneksi baru. Handler streaming menghasilkan banyak flush perantara kecil, masing-masing menjadi segmen TCP tersendiri.

**Keputusan:** Jadikan backing stage milik pemanggil dan beri koneksi mux buffer lebih besar plus handshake terkomputasi, serta cork output streaming.

- `ReplyStage.buf` kini slice `[]u8` yang dipasok pemanggil. Jalur inline blocking (`dispatchGrpcInline`) memberi array stack 4096 byte (reply unary kecil). Jalur mux memberi buffer milik koneksi sendiri.
- `GrpcMuxConn` memiliki `stage_buf` 64 KB. Panggilan streaming ~5000 pesan (~85 KB puncak) flush dalam dua write, dan ~100 reply unary konkuren (~6 KB) digabung menjadi satu write.
- `GrpcMuxConn.init` memanggil `buildSettingsFrame` sekali untuk mengisi `settings_frame` 33 byte (header 9 byte + 4 param). Handshake menambahkan blob itu apa adanya alih-alih menjalankan ulang loop encode per koneksi.
- `muxDispatch` mendeteksi route streaming (`routeIsStreaming`) dan membungkus handler dalam `setTcpCork(fd, true)` / `setTcpCork(fd, false)`: kernel menahan output hingga MSS penuh atau cork dilepas, menggabungkan flush stage perantara menjadi lebih sedikit segmen. Route unary tidak di-cork (sudah single-write). `setTcpCork` no-op pada target non-Linux.

**Konsekuensi:**
- Lebih sedikit syscall per panggilan streaming (write turun dari ~21 ke ~2 untuk reply 5000 pesan) dan lebih sedikit segmen TCP di wire saat cork.
- `GrpcMuxConn` membesar ~64 KB per koneksi. Ini biaya memori per-koneksi yang disengaja ditukar demi pengurangan syscall dan segmen. Model mux menahan satu `GrpcMuxConn` per koneksi h2 aktif, bukan per stream.
- Perbaikan write stream terkait: `fdWriteAll` kini poll dan ulang pada `EAGAIN` alih-alih melaporkan `BrokenPipe`, sehingga buffer kirim penuh pada socket EPOLL non-blocking tidak lagi memotong reply yang ter-stage. Lihat changelog 0.4.0.

---

## ADR-036: ResponseCache per-worker yang opt-in (modul bersama `utils`) di `zix.Http1`, `zix.Http`, dan `zix.Grpc`, plus WebSocket build-once broadcast

**Status:** Diterima

**Konteks:** Sebuah handler menjalankan ulang dan men-serialize ulang responsnya pada setiap request. Untuk panggilan idempoten berulang yang responsnya mahal dibangun, kerja itu mendominasi biaya userspace, sementara jalur kernel dibagi oleh setiap pendekatan. Engine sudah membuktikan pola precompute-then-write di tempat lain (blok reply gRPC comptime, frame SETTINGS yang di-cache, Date thread-local yang di-cache). Sebuah PoC mengukur apakah memperluas itu ke handler pengguna, sebagai per-key precomputed response cache, menguntungkan. Loopback, AMD Ryzen 5 5600H (12 core logis), zig 0.16.0, wrk 4.2.0, threads 6, durasi 5s, c512 dan c4096, dua kali masing-masing, rata-rata Requests/sec:

| Respons | c512 nocache -> cache | c4096 nocache -> cache |
| :- | :- | :- |
| trivial (13 B) | 614,551 -> 611,758 (-0.5%) | 453,328 -> 449,565 (-0.8%) |
| built (~32 KiB JSON) | 171,821 -> 230,844 (+34.4%) | 137,516 -> 163,116 (+18.6%) |
| file-backed (~32 KiB) | 209,590 -> 225,058 (+7.4%) | 158,803 -> 163,997 (+3.3%) |

Sebuah sweep ukuran body (c512) menempatkan crossover dekat 4 KiB: delta tetap di dalam noise antar-run di bawah ~2 KiB (256 B +0.2%, 1 KiB +1.9%, 2 KiB +3.7%), lalu melonjak pada 4 KiB (+12.6%) dan naik ke +37% pada 64 KiB. Kasus file-backed hanya menang tipis karena OS page cache sudah menyajikan file dengan murah.

**Keputusan:** Tambahkan ResponseCache per-worker yang opt-in sebagai modul bersama, mati secara default dan diarahkan ke respons yang berat komputasi, lalu pasang ke `zix.Http1`, `zix.Http`, dan `zix.Grpc`. Pakai prinsip build-once yang sama untuk WebSocket broadcast.

- Struktur bersama di `src/utils/response_cache.zig`: structure-of-arrays slab (`keys: []u64` open addressing dengan 0 sebagai empty sentinel, `meta: []Meta` berisi `insert_tick_ms` / `len` / `ttl_ms`, dan satu payload slab datar). Jumlah slot adalah pangkat dua yang diindeks dengan mask. Sebuah arena mengalokasikan slab sekali saat init dan membebaskannya utuh saat deinit. Cache yang terus berganti memakai ulang slot tetap di tempat, jadi arena tidak pernah tumbuh. Lazy on-access TTL: sebuah entri kedaluwarsa tepat pada `insert_tick_ms + ttl_ms`, sehingga `ttl_ms = 0` tidak pernah fresh. Slot kedaluwarsa dipakai ulang di tempat oleh store berikutnya, tidak pernah di-nol-kan, karena meng-nol-kan akan memotong probe chain open-addressing. Tidak ada timer thread yang diperkenalkan.
- Satu cache per worker, tidak pernah dibagi, tidak pernah dikunci (lock-free by ownership). Invariant itu hanya berlaku saat satu thread milik zix memasang cache (alokasi, set, free saat keluar) dan menjadi satu-satunya thread yang menyentuhnya. Di bawah `.EPOLL` shared-nothing setiap worker persis seperti itu, jadi cache dipasang di sana. `.POOL` juga milik zix dan bisa dipasang dengan aman, tetapi setiap pool thread akan memegang cache independen (hit rate lebih rendah, N kali memori), sehingga ditunda. `.ASYNC` dan `.MIXED` menjalankan handler di executor pool `std.Io` yang bukan milik zix, di mana sebuah task tidak ditambatkan ke satu thread, sehingga cache bersama akan butuh lock dan merusak desain lock-free. Di rilis ini cache dipasang di bawah `.EPOLL` saja, model lain membiarkannya tidak terpasang dan API menurun menjadi plain send.
- HTTP (`zix.Http1`, `zix.Http`): key adalah method, path, dan query, dan nilai yang di-cache adalah respons HTTP yang sudah di-serialize penuh, ditulis verbatim saat hit. `zix.Http1` mengekspos pasangan eksplisit `cacheLookup` / `cacheStore` plus `writeWithCache` yang menyatu. `zix.Http` mengekspos `res.serveCached` (lookup lalu tulis verbatim) dan `res.sendCached` (serialize, tulis, simpan), menghasilkan byte yang identik dengan plain `send`.
- gRPC (`zix.Grpc`, unary): key adalah path plus body request, dan nilai yang di-cache adalah pesan respons, bukan reply yang sudah di-frame, karena HEADERS bersifat stateful terhadap HPACK dan stream-id. Saat hit pesan di-frame ulang untuk stream saat ini sehingga HPACK dan stream id tetap benar. `ctx.serveCached` memutar ulang pesan tersimpan dan menyelesaikan dengan OK, `ctx.sendCached` mengirim dan menyimpan.
- WebSocket broadcast memakai prinsip build-once yang sama alih-alih TTL cache: `zix.Http1.WebSocket.broadcast(conns, opcode, payload)` men-serialize frame sekali dan menyebarkan byte yang sama ke setiap fd dalam room yang dikelola pemanggil, melewati write yang gagal ke peer mati. Ini adalah bentuk follow-up yang berbentuk WS, bukan keyed cache.
- Config bersifat flat dan nama field-nya identik di `Http1ServerConfig`, `HttpServerConfig`, dan `GrpcServerConfig`: `response_cache: bool = false`, `cache_max_entries: u32` (dibulatkan turun ke pangkat dua), `cache_max_value_bytes: u32` (respons yang melewatinya di-bypass, default ramping sekitar 16 KiB), `cache_ttl_ms: u32`, dan `cache_max_total_bytes: usize = 0` (ceiling opsional yang divalidasi terhadap `entries * value_bytes`).

**Konsekuensi:**
- Kemenangan jelas untuk serialization mahal melewati crossover ~4 KiB (+12.6% pada 4 KiB, naik ke +37% pada 64 KiB, c512) dan tanpa regresi di bawahnya, itulah mengapa opt-in wajib alih-alih default.
- Memori per-worker adalah `cache_max_entries * cache_max_value_bytes`, dikali jumlah worker. Terbatas dan dapat diprediksi, trade yang disengaja untuk lock-free per-worker ownership.
- Sengaja tidak ditujukan untuk respons file-backed atau static: OS page cache sudah menyajikan itu dengan murah, jadi `sendfile` / `splice` adalah tuas yang lebih baik di sana.
- Kebenaran bertumpu pada opt-in: engine tidak pernah auto-cache output handler. Handler memutuskan cacheability dan TTL. Respons dinamis atau berbasis database menyetel `cache_ttl_ms` yang pendek (menerima staleness sebesar itu) atau tidak mem-cache dan menulis langsung. Key HTTP hanya mencakup method, path, dan query, jadi respons yang bervariasi pada header atau cookie tidak boleh di-cache.
- Struktur cache bersifat engine-agnostic di `src/utils`, sehingga glue per-engine (cache thread-local plus penurunan key) adalah satu-satunya bagian yang spesifik protokol.

---

## ADR-037: Model dispatch `.URING` di atas surface io_uring linux mentah, ring shared-nothing thread-per-core

**Status:** Diterima

**Konteks:** zix menawarkan empat opsi dispatch model readiness (`.POOL`, `.ASYNC`, `.MIXED`, `.EPOLL`), semuanya model level-triggered atau thread-per-task yang dibangun di atas interface readiness `epoll`. Jalur `.EPOLL` bersifat shared-nothing dan kompetitif pada throughput loopback mentah, tetapi di bawah beban pipelined ia menghabiskan porsi besar siklus userspace pada transisi syscall (satu `recv`, satu `send`, dan bookkeeping `epoll_wait` per event yang siap). Dispatch io_uring berbasis completion mem-batch submission dan menuai completion, menghapus sebagian besar transisi itu. Sebuah PoC mengukur efeknya (loopback, ReleaseFast, hanya dua build zix, engine `.EPOLL` versus hello server io_uring buatan tangan):

| Metrik | zix-epoll | zix-uring (PoC) |
| :- | :- | :- |
| p1 cycles/req (userspace) | 1627 | 818 |
| p1 L1-miss/req | 73.5 | 22.9 |
| p16 cycles/req (userspace) | 710 | 240 |
| p16 server CPU (t4 c128, 10s) | ~45.1s | ~37.25s |

io_uring kira-kira memangkas separuh siklus userspace per request pada pipeline depth 1 dan memotong CPU server sekitar 21 persen pada throughput setara di bawah depth 16. Throughput loopback puncak setara pada depth 1 (terikat kernel dan client), jadi keuntungannya adalah headroom efisiensi, bukan req/s puncak. Penurunan cyc/req userspace dan L1-miss/req mereproduksi mekanisme syscall exception-less, batched-submission yang sudah mapan (FlexSC, OSDI 2010), jadi ini verifikasi efek yang dikenal, bukan asumsi lokal. PoC membuktikan keuntungannya. Pertanyaan terbuka yang diselesaikan ADR ini, sebelum pekerjaan `src/` dimulai, adalah fondasi io_uring mana yang dipakai membangun `.URING`, karena pilihan itu menggerakkan seluruh port. Dua pre-win engine independen yang menguntungkan `.EPOLL` terlepas dari ini sudah mendarat di `zix.Http1` (lazy `parseHead` dan re-arm `EPOLLOUT`), diverifikasi oleh `zig build test-all`. Keduanya masih pending untuk `zix.Http`.

**Keputusan:** Bangun model dispatch `.URING` di atas surface io_uring linux mentah (`std.os.linux.IoUring`, ring low-level yang stabil), bukan `std.Io.Uring` berbasis fiber. Kedua fondasi ditimbang sebagai:

| Aspek | A. std posix io_uring (`std.Io.Uring`) | B. raw linux io_uring (`std.os.linux.IoUring`) |
| :- | :- | :- |
| Source | backend `Evented` berbasis fiber dari std, drop-in `std.Io` | ring per-worker buatan tangan di atas ring API low-level yang stabil |
| Coupling | menumpang field config `io: std.Io` yang ada, satu jalur kode untuk semua backend | runtime khusus `.URING` baru, terpisah dari abstraksi `std.Io` |
| Control | submission dan reaping dimiliki std, opaque ke zix | kontrol penuh: ring flags, buffer rings, multishot ops, kebijakan batching |
| Features used | apa pun yang std ekspos lewat `std.Io` | multishot accept dan recv, provided buffer ring, satu send terkoalesensi per completion yang readable, `user_data` gen-tagged, deferred close saat send sedang in-flight |
| Shared-nothing | bergantung pada topologi executor std | native: satu ring per worker, tanpa handoff lintas-thread, cocok dengan desain `.EPOLL` |
| Stability risk | mengikuti internal std (surface io_uring berubah lintas 0.16.x) | hanya bergantung pada ABI kernel io_uring yang stabil, bukan internal std |
| Maintenance | rendah (std memelihara engine) | lebih tinggi (zix memiliki lifecycle ring dan kasus tepinya) |

Alasan untuk B: kemenangan terukur datang dari fitur yang std saat ini tidak ekspos lewat `std.Io` (multishot accept dan recv, provided buffer ring), jadi pendekatan A tidak bisa mencapai angka PoC. Model ring per-worker shared-nothing (satu ring, satu listener `SO_REUSEPORT`, tanpa accept queue bersama) sudah menjadi topologi yang dipakai jalur `.EPOLL`, jadi pendekatan B mempertahankannya utuh, sementara pendekatan A memperkenalkan kembali topologi executor milik std yang tidak dikontrol zix (masalah ownership yang sama yang membatasi response cache ke `.EPOLL`, ADR-036). Pendekatan B hanya bergantung pada ABI kernel yang stabil, jadi surface io_uring std yang berubah tidak menghalanginya dan pekerjaan dimulai pada Zig saat ini (0.16.x).

Cakupan keputusan:
- Topologi dipertahankan dari `.EPOLL`: thread-per-core, satu ring per worker, satu listener `SO_REUSEPORT` per worker, tanpa accept queue bersama, tanpa handoff fd lintas-thread. Process-per-core (fork-per-core) ditolak karena akan memisahkan route table per-worker dan response cache keluar dari satu address space.
- Core minimal yang benar lebih dulu: multishot accept yang di-re-arm pada `!IORING_CQE_F_MORE`, slot table ter-index fd (index langsung, tanpa hashmap) yang dijaga terhadap race completion close-versus-recv dengan generation tag di `user_data` melawan fd reuse, recv buffer per-koneksi tetap dengan `recv` SQE biasa, dan CQE drain ter-batch ke stack array. Setup listener memakai `linux.*` mentah (atau `std.Io.net`) karena `std.posix.socket` / `bind` / `listen` / `close` dihapus di 0.16.x.
- Ring flags adalah optimisasi, bukan prasyarat: ring yang diinisialisasi tanpa flag sudah benar. `SINGLE_ISSUER`, `COOP_TASKRUN`, dan `DEFER_TASKRUN` (yang terakhir butuh kernel 6.1 atau lebih baru) ditambahkan dan diukur satu per satu.
- Strategi buffer bertahap: mulai dengan recv buffer per-koneksi tetap plus `recv` SQE biasa (sudah cukup untuk bersaing), dan pindah ke provided buffer ring teregistrasi dengan multishot recv hanya jika penghematan syscall terukur membenarkan lifecycle buffer yang lebih sulit.
- Tuas bertahap lain (masing-masing di balik A/B sendiri, diselesaikan oleh perf counter): registered atau direct files (`IOSQE_FIXED_FILE`, `accept_direct`), send buffer teregistrasi yang memegang payload response-cache (`send_fixed` saat hit), membaca clock sekali per batch CQE untuk TTL cache, dan `SEND_ZC` untuk respons melewati size gate.
- Urutan implementasi: `zix.Http1` lebih dulu (membuktikan ring core), lalu WebSocket (memakai ulang upgrade path, koalesensi readable-burst memetakan ke satu batched send), lalu `zix.Grpc` (framing h2, HPACK, dan multipleks stream bersifat stateful), lalu `zix.Http` (memakai ulang ring core Http1, paling murah terakhir).
- `DispatchModel.URING` ditambahkan ke setiap `config.zig` server, dengan fallback non-Linux compile-time atau run-time ke `.EPOLL` (mencerminkan fallback non-Linux `.EPOLL` ke `.POOL` yang ada).

**Konsekuensi:**
- Hasil akhirnya adalah CPU per request dan koneksi per core, bukan angka req/s loopback yang lebih besar. Throughput loopback puncak tetap setara pada depth 1 karena beban itu terikat kernel dan client. Penerimaan diukur dengan `cycles:u` dan `L1-miss/req` di bawah beban pipelined, back to back melawan `.EPOLL` pada mesin yang sama, server segar per run (ring mem-pin halaman memlock, jadi memakai ulang instance server lintas run menghabiskan budget memlock per-user).
- zix memiliki lifecycle ring dan kasus tepinya: race completion close-versus-recv, fd reuse (ditangani generation tag), dan budget memlock per-user yang dikonsumsi ring. Ini biaya pemeliharaan yang ditukar untuk kontrol yang dibutuhkan kemenangan terukur.
- Pendekatan A tetap menjadi fallback jika surface raw-syscall terbukti terlalu mahal dipelihara, atau jika `std.Io` masa depan mengekspos multishot dan provided buffer sebagai operasi kelas-satu.
- Dua pre-win engine (lazy `parseHead`, re-arm `EPOLLOUT`) ada di `zix.Http1` dan menguntungkan `.EPOLL` terlepas dari keputusan ini. Keduanya kini di-port ke `zix.Http` juga: `ParsedHead`-nya membuang array header 64-entry per-request dan mencatat blok header mentah sebagai offset untuk di-rescan `getHeader` sesuai kebutuhan, dan worker `.EPOLL`-nya men-stage tail respons yang belum tertulis pada partial write lalu mengarm `EPOLLOUT` untuk men-drain-nya pada writable event berikutnya alih-alih membuang koneksi. Sink coalescing di-bypass untuk SSE, yang draining-nya tetap handler-side (blocking write memarkir handler, bukan event loop library).
- Tuas spesifik-io_uring di atas bertumpu pada mekanisme kernel yang terdokumentasi tetapi belum punya bukti spesifik-beban kerja, jadi masing-masing diselesaikan secara lokal oleh A/B dengan sinyal perf-counter bernama alih-alih diasumsikan. Bukti io_uring yang peer-reviewed kebanyakan storage, jadi untuk networking landasannya adalah mekanisme FlexSC plus catatan desain maintainer kernel.

**Ekstensi ke `zix.Tcp` dan `zix.Fix` (callback ring):**
- Dua engine ini tidak bisa langsung di-port ke ring: handler-nya adalah `fn(stream, io)` blocking yang memiliki koneksi dan loop pada read dan write sinkron, yang tidak bisa dijalankan loop completion single-threaded. Jadi masing-masing memperoleh API callback baru yang digerakkan engine berdampingan dengan API blocking yang ada. `zix.Tcp` menambah `runFramed` dengan `FrameFn` per-frame di atas length prefix 4-byte, dan `zix.Fix` menambah path `.URING` yang menjalankan session processor resumable (`core.processFixRing`) per batch readable. Path blocking `runWith` dan `serveConn` tidak berubah, dan `.URING`-nya tetap melipat ke `.EPOLL`.
- Heartbeat FIX di ring memakai timer periodik per-worker, bukan per-koneksi. Satu SQE `prep_timeout` per worker (di-re-arm tiap kali fire, ditandai `OpKind` `.timeout` baru yang diperlakukan engine lain sebagai no-op) berdetak tiap `heartbeat_timeout_ms`. Pada tiap fire worker memindai slot table-nya dan, untuk tiap session yang sudah login dan idle melewati interval, mengirim TestRequest pada tick pertama lalu Logout pada tick berikutnya, ditulis langsung ke fd. Satu SQE per worker plus scan O(n) per tick mengalahkan timeout per-koneksi yang akan cancel dan re-arm pada tiap pesan masuk. Memanen session idle aman-close: satu-satunya op in-flight-nya adalah recv idle tanpa data ter-buffer, jadi menutupnya menyisakan completion recv basi untuk dijatuhkan generation tag. Ini melengkapi session: `processFixRing` menjawab Heartbeat/TestRequest peer secara reaktif, dan timer menambah paruh yang diinisiasi-server.

## ADR-038: server `zix.Tcp` membakar handler pada comptime, `run` tunggal, mengikuti bentuk server engine

**Status:** Diterima

**Konteks:** Setiap engine server zix kecuali `zix.Tcp` membakar handler-nya (atau route table) ke dalam tipe server pada `init`, sehingga handler diketahui pada comptime dan `run` tidak menerima argumen handler (`zix.Http1`, `zix.Http2`, `zix.Grpc`). `zix.Tcp` adalah pengecualian: ia menerima handler sebagai runtime function pointer lewat `runWith(io, handler)`, dengan `run(io)` sebagai entry terpisah yang memakai echo handler bawaan, plus `runFramed(io, frame_fn)` untuk callback per-frame. Pemisahan `run` versus `runWith` dan pointer runtime itu tidak konsisten dengan engine lain dan dengan prinsip explicit-over-implicit serta comptime-where-structural milik proyek. Catatan, asimetri itu sudah separuh teratasi: `FrameFn` per-frame (`runFramed`) sudah comptime, hanya `HandlerFn` per-connection yang runtime. Perubahan ini dibenarkan atas dasar konsistensi dan kejelasan, bukan pengukuran. Handler blocking per-connection berjalan sekali per koneksi yang diterima (titik dispatch yang dingin), jadi men-devirtualize-nya dapat diabaikan, berbeda dengan handler per-request `zix.Http1` atau `FrameFn` per-frame, itulah sebabnya keduanya sudah comptime.

**Keputusan:** Ikuti bentuk server `zix.Http1` / `zix.Grpc`. Bakar handler (atau callback per-frame) ke dalam tipe server pada `init` sehingga `run` hanya menerima `io`. `zix.Tcp.Server` menjadi namespace tanpa field dengan constructor comptime di atas dua factory type privat:

| Constructor | Mengembalikan | Kontrak |
| :- | :- | :- |
| `Server.init(comptime handler, config)` / `initArgs(..., args)` | `TcpServerImpl(handler)` | `HandlerFn` per-connection (memiliki stream) |
| `Server.initFramed(comptime frame_fn, config)` / `initFramedArgs(..., args)` | `TcpFramedServerImpl(frame_fn)` | `FrameFn` per-frame (engine memiliki koneksi) |

Kedua factory type hanya menyimpan `config` dan mengekspos `init`, `deinit`, dan `run(io)`. Echo handler bawaan tidak lagi menjadi default tersembunyi di balik `run`: ia adalah `zix.Tcp.echoHandler` publik, dilewatkan secara eksplisit (`Server.init(zix.Tcp.echoHandler, config)`), sesuai explicit-over-implicit. Method `runWith` dan `runFramed` dihapus.

Dua factory type (bukan satu tipe dengan parameter comptime kedua opsional, seperti `zix.Http1` untuk `(handler, raw_fn)`) mengikuti aturan compose-versus-alternative. Pada `zix.Http1` raw interceptor menyatu (compose) dengan handler (koneksi sama, sebuah hook pra-parse), jadi satu impl membawa keduanya. Pada `zix.Tcp`, `HandlerFn` (memiliki koneksi, blocking) dan `FrameFn` (engine-owned, tidak pernah blocking, berjalan di ring `.URING`) adalah kontrak yang saling eksklusif: sebuah koneksi tidak bisa sekaligus hand-owned dan engine-deframed. Dua factory type menjaga state mustahil itu tidak terwakili. Kontrak `FrameFn` dari ADR-037 tidak berubah, hanya entry point-nya yang berpindah.

`io` tetap argumen `run(io)` alih-alih field config (berbeda dari `zix.Http1` / `zix.Grpc`, yang `io`-nya ada di config). Memindahkan `io` ke `TcpServerConfig` demi paritas bentuk penuh (yang sekaligus menyelesaikan inkonsistensi penempatan io lintas server config) adalah perubahan terpisah yang lebih besar, mencakup struct config dan setiap call site, ditunda ke keputusannya sendiri.

**Konsekuensi:**
- Perubahan API yang breaking: `runWith` dan `runFramed` hilang, `run(io)` menjadi satu-satunya jalur run, dan constructor membawa handler. Fungsi worker internal (`serveDispatch`, `runEpoll`, dan entry pool / async / epoll) tetap menyimpan handler sebagai nilai runtime, persis seperti `runAsync` / `runPool` / `runMixed` milik `zix.Http1`. Ikatan comptime berada di batas tipe (tanpa registrasi runtime), bukan devirtualization hot-loop.
- Handler harus diketahui pada comptime. Handler yang dipilih saat runtime (`const h = pick(cfg)`) kini bercabang di call site (`if (...) Server.init(handlerA, ...) else ...`). Inilah satu-satunya biaya ekspresivitas, diterima atas prinsip untuk engine raw-TCP.
- Menggantikan (supersede) nama API ekstensi pada ADR-037: jalur blocking adalah `Server.init(handler, config)` lalu `run(io)` (dahulu `runWith`), jalur framed ring adalah `Server.initFramed(frame_fn, config)` lalu `run(io)` (dahulu `runFramed`). `.URING` tetap melipat (fold) ke `.EPOLL` untuk handler per-connection dan berjalan native untuk callback framed.
- Terverifikasi: library kompilasi, kelima contoh `tcp_server_*` kompilasi, suite unit / integration / edge / behaviour lulus, dan kelima end-to-end runner (async, pool, mixed, epoll, uring) lulus.

---

## ADR-039: `zix.Tcp` / `zix.Udp` / `zix.Uds` memindahkan `io` ke dalam config server dan `zix.Uds` membakukan handler pada comptime, menyatukan bentuk server pada `run()`

**Status:** Diterima

**Konteks:** Lima engine server (`zix.Http`, `zix.Http1`, `zix.Http2`, `zix.Grpc`, `zix.Fix`) membawa `io: std.Io` di config-nya, sehingga `run()` tidak menerima argumen. Tiga server sisanya menyimpang: `zix.Tcp` dan `zix.Udp` menerima `io` sebagai parameter `run(io)`, dan `zix.Uds` menerima `io` dan handler sekaligus pada run (`run(io, handler)`). Ini adalah inkonsistensi bentuk server terakhir di library: memindahkan server antar protokol berarti harus mengingat mana yang meneruskan `io` lewat `run`. ADR-038 sudah membakukan handler `zix.Tcp` ke dalam tipe pada `init`, tetapi sengaja menunda penempatan `io` sebagai perubahan terpisah yang lebih besar. Tidak ada yang menghalangi pemindahan: engine server membuktikan polanya, dan fungsi worker internal sudah menerima `io` sebagai nilai biasa.

**Keputusan:** Pindahkan `io` ke dalam config dan bakukan handler `zix.Uds` pada `init`, sehingga setiap server dikonstruksi dengan cara yang sama dan `run()` tidak menerima argumen.

- Tambahkan `io: std.Io` sebagai field pertama yang wajib pada `TcpServerConfig`, `UdpServerConfig`, dan `UdsServerConfig`.
- `run()` tidak menerima argumen pada ketiganya. Ia membaca `self.config.io` dan meneruskan nilai itu ke worker internal yang sudah ada (`serveDispatch`, `runEpoll`, receive loop Udp, accept loop Uds), sehingga tidak ada perubahan hot-path atau ownership.
- `zix.Uds` mengadopsi bentuk factory ADR-038: `Server.init(comptime handler, config)` mengembalikan tipe terspesialisasi yang `run()`-nya tidak menerima apa pun. Default echo bawaan adalah `zix.Uds.echoHandler` publik, dilewatkan secara eksplisit. Jalur `run(io, handler)` / `runWith` lama dihapus.

Peta constructor server kini seragam:

| Server | Konstruksi | Run |
| :- | :- | :- |
| `zix.Http` / `zix.Http1` / `zix.Http2` / `zix.Grpc` / `zix.Fix` | `Server.init(routes_or_handler, config)` | `run()` |
| `zix.Tcp` | `Server.init(handler, config)` / `initFramed(frame_fn, config)` | `run()` |
| `zix.Udp` | `Server(Packet).init(config)` | `run()` |
| `zix.Uds` | `Server.init(handler, config)` | `run()` |

Client (`zix.Tcp.Client`, `zix.Udp.Client`, `zix.Uds.Client`) tetap menerima `io` sebagai parameter `connect()` / `init()`. Penempatan `io` client adalah axis terpisah (`zix.Grpc.Client` juga menerima `io` sebagai parameter sementara `zix.Http.Client` membawanya di config), ditunda ke keputusannya sendiri.

**Konsekuensi:**
- Perubahan API breaking: setiap call site server `zix.Tcp` / `zix.Udp` / `zix.Uds` menambah `.io = process.io` ke literal config dan menghapus argumen `run`. Pemanggil `zix.Uds` juga melewatkan handler ke `init` (jalur `runWith` hilang).
- `io` harus hidup lebih lama dari server, kontrak sama yang sudah didokumentasikan config engine.
- Menggantikan (supersede) penempatan `io` pada ADR-038: jalur run `zix.Tcp` kini `run()` (dahulu `run(io)`). Keputusan handler-at-`init` dari ADR-038 tidak berubah dan diperluas ke `zix.Uds`.
- Paritas bentuk server penuh: kedelapan server dikonstruksi dengan config yang membawa `io` dan dilayani dengan `run()` tanpa argumen. Memindahkan server antar protokol bersifat mekanis.
- Terverifikasi: library kompilasi, setiap contoh `tcp_server_*` / `udp_server` / `uds_server` kompilasi, suite unit / integration / edge / behaviour lulus, dan runner `tcp` (kelima model), `udp`, dan `uds` lulus.

---

###### end of adr
