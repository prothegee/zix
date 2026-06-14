# README

<h1 align="center">
    <b><i>ZIX</i></b>
</h1>

<p align="center" style="color: #C3C3C3;font-color: #C3C3C3;">
    <b><i>Zero sIX; 06;</i></b>
</p>

<p align="center" style="color: #C3C3C3;font-color: #C3C3C3;">
    <i>Pustaka backend jaringan yang ditulis dalam zig.</i>
</p>

<div align="center">
    <img src="zix-logo.svg" alt="zix-logo" style="display: block; margin: auto;" align="center" width="512px">
</div>

<p align="center" style="color: #C3C3C3;font-color: #C3C3C3;">
    <i>Di mana penghubung bertemu kehendak.</i>
</p>

<p align="center" style="color: #C3C3C3;font-color: #C3C3C3;">
    <i>Setiap byte dimiliki, setiap thread dipertimbangkan, setiap rute eksplisit.</i>
</p>

<p align="center" style="color: #C3C3C3;font-color: #C3C3C3;">
    <i>Tanpa cost tersembunyi. Hanya clean-metal dan kode yang transparan - terprediksi berdasarkan prinsip</i>
</p>

---

<p align="center" style="color: #C3C3C3;font-color: #C3C3C3;">
    <i>Kamu adalah pemikir. Pengutak-atik.. Perakit... Pembangun, Bukan hanya pengguna/programmer....</i>
</p>

<br>

# Daftar Isi

- [Alasan & Motivasi](./README-id.md#alasan--motivasi)
- [Fitur Utama](./README-id.md#fitur-utama)
- [Persyaratan](./README-id.md#persyaratan)
- [Repositori](./README-id.md#repositori)
- [Catatan Kontribusi Penting](./README-id.md#catatan-kontribusi-penting)
- [Dokumentasi](./README-id.md#dokumentasi)
- [Memulai](./README-id.md#memulai)
- [Build](./README-id.md#build)
- [HTTP/1](./README-en.md#http1)
- [Contoh](./README-id.md#contoh)
- [Minimal](./README-id.md#contoh-minimal)
- [Routing](./README-id.md#routing)
- [Model Konkurensi](./README-id.md#model-konkurensi)
- [Timeout](./README-id.md#timeout)
- [Middleware](./README-id.md#middleware)
- [WebSocket](./README-id.md#websocket)
- [SSE](./README-id.md#sse-server-sent-events)
- [HTTP Client](./README-id.md#http-client)
- [File Statis & Unggah](./README-id.md#file-statis--unggah)
- [Kapasitas Header Respons](./README-id.md#kapasitas-header-respons-headersize)
- [Kapasitas Header Permintaan](./README-id.md#kapasitas-header-permintaan-requestheadersize)
- [Kesadaran Cache Respons](./README-id.md#kesadaran-cache-respons-response_cache)
- [HTTP/2](./README-id.md#http2)
- [gRPC h2c](./README-id.md#grpc-h2c)
- [Raw TCP](./README-id.md#raw-tcp)
- [FIX 4.x](./README-id.md#fix-4x)
- [UDS (Unix Domain Sockets)](./README-id.md#uds-unix-domain-sockets)
- [Channel](./README-id.md#channel)
- [UDP](./README-id.md#udp)
- [Logger](./README-id.md#logger)
- [Pengujian](./README-id.md#pengujian)
- [Model Memori](./README-id.md#model-memori)
- [Catatan Penting](./README-id.md#catatan-penting)
- [Benchmark](./README-id.md#benchmark)

<br>

## Alasan.. Sebuah Motivasi...

<details close>
<summary>Pola Pikir:</summary>

```
Cara kita berpikir, adalah bagaimana sistem dimulai.
Waktu untuk membaca dan berpikir dari baris-baris yang ada,
membuat "kita" berpikir ulang, berdebat, dan mendekati alur program.

Ketika "generasi berikutnya" tidak mau belajar masa lalu dan masa kini. Apa yang akan terjadi?
Jika mereka tidak mau menggunakan/belajar/antusias tentang bahasa dan sistem build, mereka akan..?

Untuk menjadi modern dengan sedikit kerumitan, "keajaiban" harus lebih atau kurang?

Zig (juga bahasa pemrograman lain) dapat melengkapi program yang ada
dan mampu membuat program yang baik, tetapi ketika performa kritis pilihan kita sedikit/sulit.

Pekerjaan saya sebagian besar 80% backend dan 20% frontend.
Jadi sistem jaringan/komunikasi sangat penting di bagian saya.
Dari monolith, micro-service, hingga modular micro-service.

Di awal Zig (sebelum 0.16.x), saya menikmati bahasanya.
Zig fleksibel dan sebagian besar logikanya ada.
Tetapi "varian warna" membuat saya kembali ke Go & C++.
Jadi pada pertengahan 2025 rencananya hanya ide dan beberapa desain arsitektur.

Jadi ketika Zig 0.16.x dirilis, dan awal Maret 2026. Saya memulai langkah.
Sekarang saya bisa mendapatkan kembali transparansi, kendali yang lebih, dan pendekatan yang lebih eksplisit.
```

<!--
Mengapa bukan rust:
- Terlalu banyak "gunakan saja tokio/smol" membuat saya berpikir ulang.
- Kode Rust saya sebagai profesional masih 70% sync, sedikit async.
- Rust dalam kasus saya untuk melengkapi sistem yang ada, pembaca/penulis QR & Barcode menggantikan C++.
-->

</details>

<br>

<details open>

<summary>Prinsip-prinsip motivasi:</summary>

__*1. Eksplisit Daripada Implisit.*__

__*2. Modular & Dapat Dirawat.*__

__*3. Arsitektur Mengutamakan Performa.*__

__*4. Fitur Praktis, Siap Digunakan.*__

__*5. Model Konkurensi Modern yang Efisien.*__

__*6. Manajemen Memori yang Dapat Diprediksi dan Transparan.*__

> Kami mengutamakan kejelasan, kontrol, dan performa.

</details>

<br>

# Fitur Utama

__*1. Stack protokol lengkap dalam satu tempat:*__

Tcp (raw), Udp, Uds (Unix domain sockets), Http (HTTP/1.1), Http1 (varian
hot-path-optimized), Http2 (h2c), Grpc (gRPC melalui h2c), Fix (FIX 4.x), plus Channel dan Logger.

> Satu model memori/threading yang koheren untuk backend monolith, micro-service, dan
modular-micro-service, alih-alih menggabungkan banyak library terpisah dengan
konvensi yang berbeda.

<br>

__*2. Empat model dispatch yang dapat dipilih:*__

- ASYNC (satu accept thread, io.async() per koneksi): latensi terendah pada beban moderat.
- POOL (N acceptor mendorong ke shared queue, M worker menangani secara sinkron): throughput mentah terbaik pada jumlah koneksi tinggi.
- MIXED (N acceptor masing-masing dispatch via io.async(), tanpa queue): seimbang.
- EPOLL (shared-nothing: setiap worker memiliki SO_REUSEPORT listener + epoll instance, level-triggered, tanpa antrian bersama): khusus Linux, terbaik untuk jumlah koneksi tinggi di HTTP/1.

> strategi konkurensi adalah pilihan konfigurasi yang disengaja, bukan default implementasi. Http, Grpc, Fix, dan Tcp mengimplementasikan keempatnya.

<br>

__*3. Konfigurasi eksplisit dan flat:*__

Tanpa sub-config bertingkat: setiap field (mis. dispatch_model, max_response_headers: .MINIMAL, pool_size) berada di level teratas dan eksplisit.

> dapat diprediksi sebagai prinsip. Kamu melihat persis apa yang server lakukan tanpa
menelusuri default yang diwariskan.

<br>

__*4. HTTP/1 zix.Http1 yang dioptimasi pada hot-path:*__

- Menghapus HeadParser, header Date yang di-cache secara thread-local, writeSimple yang dikonsolidasi, serveConn(fd, handler, opts).
- WebSocket yang dikelola engine dengan write coalescing per-event di EPOLL, plus SSE dan kapasitas response-header yang dapat dikonfigurasi.

> Memangkas jalur request umum tanpa mengorbankan API yang eksplisit.

<br>

__*5. gRPC kelas produksi:*__

Multiplexed async epoll dengan resumable HTTP/2 state machine, blok reply HPACK yang di-cache saat comptime, initial window besar, buffered reads, max_streams=128 untuk menghindari REFUSED_STREAM burst. Context timeout (handler_timeout_ms, Route.timeout_ms, ctx.isExpired()).

> Keempat tipe RPC (unary, server streaming, client streaming, bidirectional)
dimultipleks melalui satu koneksi h2c tanpa thread per stream, dengan deadline client
dihormati end-to-end. Service internal berbicara gRPC secara langsung, tanpa TLS
terminator atau sidecar.

<br>

__*6. FIX 4.x:*__

FixContext, sebuah struct MsgType (47 konstanta), routing berbasis session, contoh trading.

> Pesan finansial domain-specific sebagai warga kelas satu, bukan ditempelkan ke raw
TCP.

<br>

__*7. Logger yang sadar protokol:*__

Tipe log per protokol: conn (TCP), packet (UDP), frame (UDS), session (FIX), rpc (gRPC), access() khusus HTTP, Channel khusus system.

> Kosakata log cocok dengan unit kerja aktual pada setiap protokol.

<br>

__*8. Dokumentasi multi-bahasa:*__

Setiap dokumen punya variannya sendiri.

> Dukungan: en - English, id - Bahasa

<br>

## Persyaratan

- Zig >= 0.16.x

<br>

## Repositori

- [Codeberg sebagai Utama](https://codeberg.org/prothegee/zix)
- [Github sebagai Mirror #1](https://github.com/prothegee/zix)

<br>

## Catatan Kontribusi Penting

- Membantu Zig, membantu Zix.
- Zig harus menjadi ekosistemnya.
- Satu file, satu tanggung jawab.
- Selalu gunakan dan dorong penggunaan Zig dan std-nya.
- Setiap perubahan signifikan memerlukan RnD/PoC.
- Mencakup pengujian yang belum tercakup adalah kontribusi yang baik.
- Persempit pemikiran sistem lalu bersikap eksplisit.
- "Nice to have" dan "mungkin kita perlu ini" bersifat tersier.
- Selalu perbaiki dari sisi kita terlebih dahulu daripada dari sisi fitur Zig.
- Jika bias/ambigu, coba diskusikan. Minimal libatkan 1-2 entitas lain.
- Kamu dan timmu (Junior/Mid/Senior) menggunakan bahasa selain Inggris, kamu bisa berkontribusi dalam bahasa tersebut.

<br>

[Milestones.](https://codeberg.org/prothegee/zix/milestones)

[Buka isu.](https://codeberg.org/prothegee/zix/issues/new)

[Buka diskusi.](https://github.com/prothegee/zix/discussions)

<br>

## Dokumentasi

| Dokumen | Keterangan |
| :- | :- |
| [`docs/hld-http-id.md`](docs/hld-http-id.md) | HTTP: tujuan, model runtime, API, router, WebSocket, SSE, model memori |
| [`docs/hld-http1-id.md`](docs/hld-http1-id.md) | HTTP/1: tujuan engine ramping, model dispatch, model handler, router, WebSocket, model memori |
| [`docs/hld-tcp-id.md`](docs/hld-tcp-id.md) | TCP stream mentah: tujuan, API, format frame, model dispatch |
| [`docs/hld-udp-id.md`](docs/hld-udp-id.md) | UDP: tujuan, model runtime, API, model paket, endianness, disconnect |
| [`docs/hld-uds-id.md`](docs/hld-uds-id.md) | UDS: tujuan, API, format frame, siklus hidup server/client |
| [`docs/hld-channel-id.md`](docs/hld-channel-id.md) | Channel: tujuan, model, API, persyaratan konkurensi, contoh |
| [`docs/hld-fix-id.md`](docs/hld-fix-id.md) | FIX 4.x: tujuan, gambaran protokol, lapisan sesi, model dispatch, konfigurasi |
| [`docs/hld-grpc-id.md`](docs/hld-grpc-id.md) | gRPC h2c: tujuan, arsitektur, API, 4 tipe RPC, codec, model dispatch |
| [`docs/hld-grpc-proxy-id.md`](docs/hld-grpc-proxy-id.md) | gRPC terminasi TLS via nginx dan haproxy |
| [`docs/hld-logger-id.md`](docs/hld-logger-id.md) | Logger: tujuan, API, metode log, format, rotasi file, pemasangan protokol |
| [`docs/lld-http-id.md`](docs/lld-http-id.md) | HTTP: struktur data internal dan algoritma |
| [`docs/lld-http1-id.md`](docs/lld-http1-id.md) | HTTP/1: parsing internal, write helper, router, engine EPOLL, codec WebSocket |
| [`docs/lld-tcp-id.md`](docs/lld-tcp-id.md) | TCP: struktur data internal dan algoritma |
| [`docs/lld-udp-id.md`](docs/lld-udp-id.md) | UDP: struktur data internal dan algoritma |
| [`docs/lld-uds-id.md`](docs/lld-uds-id.md) | UDS: struktur server/client internal dan penanganan frame |
| [`docs/lld-fix-id.md`](docs/lld-fix-id.md) | FIX: struktur data internal dan algoritma serveConn |
| [`docs/lld-channel-id.md`](docs/lld-channel-id.md) | Channel: internal ring buffer, locking, algoritma send/recv |
| [`docs/lld-logger-id.md`](docs/lld-logger-id.md) | Logger: buffer tulis internal, spinlock, algoritma rotasi |
| [`docs/concurrency-id.md`](docs/concurrency-id.md) | Model dispatch: POOL, ASYNC, MIXED, EPOLL. Jumlah thread, kecocokan protokol. |
| [`docs/adr-id.md`](docs/adr-id.md) | Architecture Decision Records |
| [`docs/headers-id.md`](docs/headers-id.md) | Kapasitas header respons: tingkatan, keamanan, penanganan error |
| [`docs/tests-id.md`](docs/tests-id.md) | Tingkatan pengujian (unit / integration / behaviour / edge) dan cara menjalankan |

<br>

## Memulai

Ambil zix ke proyekmu:

Tambahkan ke `build.zig.zon`:
```zig
.{
    .name = .backend_api,
    .version = "0.1.0",
    .dependencies = .{
        .zix = .{
            .url = "https://codeberg.org/prothegee/zix/archive/0.3.x.tar.gz",
            // .hash will be filled in by `zig fetch --save`
        },
    },
    .paths = .{""},
}
```

Lalu lakukan `zig fetch --save`.

<br>

Atau,

gunakan zig fetch langsung dengan source repo dan versi:
```sh
zig fetch --save "git+https://codeberg.org/prothegee/zix#main" # upstream
```

atau

```sh
zig fetch --save "git+https://codeberg.org/prothegee/zix#0.2.x" # upstream v0.2.x
```

> Kamu juga bisa menggunakan mirror di `github.com/prothegee/zix`
>
> Untuk versi tertentu, gunakan `MAJOR.MINOR.x`, misalnya `#0.2.x` dan ganti `#main`

<br>

Tambahkan ke proyekmu (file `build.zig`):

```sh
const zix = b.dependency("zix", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zix", zix.module("zix"));
```

<br>

## Build

zix dikonsumsi sebagai Zig module (source), bukan dikirim sebagai library prebuilt. Repositori mendefinisikan module `zix` dengan `b.addModule`, jadi tidak ada artifact `addStaticLibrary` atau `addSharedLibrary`. Menjalankan `zig build` sendirian menjalankan step `install` default tanpa ada yang diinstal: tidak ada `.a`, tidak ada `.so`, tidak ada apa pun di bawah `zig-out/lib`. Ia meng-compile module graph dan hanya berguna sebagai pengecekan cepat "apakah masih compile".

Entry point yang sebenarnya adalah step bernama. Daftarkan kapan saja dengan `zig build -l`:

| Step | Fungsinya |
| :- | :- |
| `zig build` | Hanya meng-compile module graph. Tidak ada artifact yang dihasilkan, karena zix adalah source module. |
| `zig build test-all` | Menjalankan tes unit, integration, behaviour, dan edge. |
| `zig build unit-test` | Menjalankan tes unit saja. Juga `integration-test`, `behaviour-test`, `edge-test`. |
| `zig build examples` | Membangun setiap example ke `zig-out/bin/`. |
| `zig build example-<group>` | Membangun satu grup example, misalnya `example-http1` atau `example-grpc`. |
| `zig build example-<name>` | Membangun dan menjalankan satu example, misalnya `example-http1_websocket`. |
| `zig build test-runner-<name>` | Menjalankan pengecekan integrasi server plus client, misalnya `test-runner-http1-epoll`. |
| `zig build test-runner-all` | Menjalankan setiap runner integrasi server plus client. |

Binary example yang dibangun ada di `zig-out/bin/`. Untuk membangun semua example, lalu menjalankan satu di background dan menghentikannya:

```sh
zig build examples                      # bangun setiap example ke zig-out/bin/
zig-out/bin/example-http1_websocket &   # jalankan satu di background
kill %1                                 # hentikan
```

Tidak ada output library `zig build install` dan tidak ada `-Doptimize` yang diperlukan untuk pengecekan compile biasa. Untuk mengonsumsi zix di proyek lain, ikuti Memulai di atas: ia ditambahkan sebagai dependency `build.zig.zon` dan diimpor dengan `exe.root_module.addImport("zix", zix.module("zix"))`, tidak pernah di-link sebagai system library.

<br>

## HTTP/1

Zix memiliki dua model API untuk HTTP/1, `zix.Http` dan `zix.Http1`.

`zix.Http` bergantung pada `std.http` Zix dan berfungsi sebagai pendekatan yang mudah, sedangkan `zix.Http1` tidak.

<br>

## Contoh

Untuk contoh lebih lengkap lihat direktori `examples`.

Jalankan `zig build examples` untuk membangun semua contoh (baca `build.zig` untuk detail lebih lanjut).

### Contoh Minimal

Auto I/O (work-queue thread pool, default):
```zig
const std = @import("std");
const zix = @import("zix");

pub fn homeHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req; _ = ctx;
    try res.send("hello from zix");
}

pub fn main(process: std.process.Init) !void {
    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/", .handler = homeHandler },
    }, .{
        .io   = process.io,
        .ip   = "127.0.0.1",
        .port = 9000,
    });
    defer server.deinit();
    try server.run();
}
```

Manual I/O (batas konkurensi eksplisit via `concurrent_limit`, dispatch `.ASYNC`):
```zig
pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{
        .concurrent_limit = std.Io.Limit.limited(4), // pin ke 4 tugas concurrent
        // .concurrent_limit = .unlimited             // biarkan runtime memutuskan
    });
    defer threaded.deinit();

    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/", .handler = homeHandler },
    }, .{
        .io             = threaded.io(),
        .ip             = "127.0.0.1",
        .port           = 9000,
        .dispatch_model = .ASYNC, // .ASYNC menggunakan io pemanggil secara langsung
    });
    defer server.deinit();
    try server.run();
}
```

Lihat `examples/http_basic_1_async.zig`, `examples/http_basic_2_pool.zig`, `examples/http_basic_3_mixed.zig`, dan `examples/http_basic_4_epoll.zig` untuk varian server minimal per model dispatch. Lihat `examples/http_manual_concurrent.zig` untuk kontrol konkurensi eksplisit via `Io.Threaded`. Engine `zix.Http1` mentah punya contoh paralel, termasuk `examples/http1_manual_concurrent.zig`.

<br>

### Routing

Rute didaftarkan pada waktu kompilasi via tabel rute yang diteruskan ke `Server.init`. Setiap entri `Route` memiliki `path`, `handler`, dan `kind` opsional (`.EXACT` secara default):

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/about",           .handler = aboutHandler },
    // exact (default): hanya cocok dengan /about

    .{ .path = "/api",             .handler = apiHandler,    .kind = .PREFIX },
    // prefix: cocok dengan /api, /api/foo, /api/foo/bar, TIDAK /apiv2

    .{ .path = "/users/:id",       .handler = userHandler,   .kind = .PARAM },
    // param: cocok dengan /users/alice, menangkap id="alice"
    // baca di dalam handler: req.pathParam("id")

    .{ .path = "/:tenant/:branch", .handler = branchHandler, .kind = .PARAM },
    // multi-param: req.pathParam("tenant"), req.pathParam("branch")
}, .{ .ip = "127.0.0.1", .port = 9000 });
```

**Prioritas:**

```
exact  >  param  >  prefix (prefix lebih panjang mengalahkan yang lebih pendek)
```

Prioritas exact dan prefix tidak bergantung pada urutan pendaftaran. **Rute param adalah pengecualian**: ketika dua pola memiliki jumlah segmen yang sama dan keduanya cocok, entri pertama dalam tabel rute yang menang. Daftarkan pola yang lebih literal sebelum pola all-param dengan kedalaman yang sama:

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    // Urutan yang benar: /path/user/:id menang untuk /path/user/alice
    .{ .path = "/path/user/:id",        .handler = userHandler,   .kind = .PARAM },
    .{ .path = "/path/:tenant/:branch", .handler = tenantHandler, .kind = .PARAM },
}, .{ ... });
```

| Terdaftar | Permintaan | Pemenang | Alasan |
| :- | :- | :- | :- |
| `/path/info` (exact) + `/path/:id` (param) | `/path/info` | `/path/info` | exact mengalahkan param |
| `/path/:id` (param) + `/path` (prefix) | `/path/alice` | `/path/:id` | param mengalahkan prefix |
| `/api/v2` + `/api` (keduanya prefix) | `/api/v2/foo` | `/api/v2` | prefix lebih panjang menang |
| `/path/user/:id` (ke-1) + `/path/:a/:b` (ke-2) | `/path/user/alice` | `/path/user/:id` | literal lebih banyak didaftarkan pertama |

**Pencocokan seperti Regex**: zix tidak memiliki mesin regex. Rute prefix (`.kind = .PREFIX`) mencakup path yang terdaftar dan sub-path di bawahnya. Pemfilteran tambahan dilakukan di dalam handler dengan operasi string biasa pada `req.path()`:

```zig
// Dalam tabel rute:
.{ .path = "/secret", .handler = secretHandler, .kind = .PREFIX },

// Di dalam secretHandler: ekstrak sub-path dan terapkan logika kustom
const sub = req.path()["/secret/".len..];  // misalnya "file.txt"
// cek ekstensi, kedalaman, query params, header, dll.
```

Lihat `examples/http_params.zig` untuk penanganan parameter query dan form. Lihat `examples/http_paths.zig` untuk pola routing parameter path. Lihat `examples/http_json.zig` untuk penanganan respons JSON.

**Mesin `zix.Http1` mentah**: mesin tingkat rendah menyediakan `Router` comptime yang sama dengan jenis `.EXACT` / `.PREFIX` / `.PARAM` yang identik dan prioritas `exact > param > prefix` yang sama. Satu perbedaannya adalah penangkapan param: handler Http1 adalah `fn(head: *const ParsedHead, body, fd) void` tanpa `Request`, jadi param yang ditangkap dibaca dengan fungsi bebas `zix.Http1.pathParam("id")` (sebuah thread-local per-handler, model yang sama dengan `zix.Http1.setTimeout`, lihat ADR-029) alih-alih `req.pathParam("id")`:

```zig
const Router = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/",          .handler = homeHandler },
    .{ .path = "/secret",    .handler = secretHandler, .kind = .PREFIX },
    .{ .path = "/users/:id", .handler = userHandler,   .kind = .PARAM },
});

var server = zix.Http1.Server.init(Router.dispatch, .{ .ip = "0.0.0.0", .port = 9100 });

// di dalam userHandler:
const id = zix.Http1.pathParam("id") orelse return;
```

Lihat `examples/http1_static.zig` untuk rute prefix yang digunakan. Penangkapan param per-rute dibatasi 8 param per pencocokan. Lihat ADR-033.

<br>

### Model Konkurensi

Empat model dispatch, dipilih via `config.dispatch_model` (enum `DispatchModel`, default `.ASYNC`):

**`.POOL` (work-queue thread pool):**

N accept thread mendorong koneksi ke `ConnQueue` bersama. M pool thread mengambil dan menangani setiap koneksi secara sinkron dengan blocking I/O, tanpa overhead scheduler. Throughput terbaik di bawah jumlah koneksi tinggi. `SO_REUSEPORT` memungkinkan semua accept thread mendengarkan di port yang sama.

```zig
pub fn main(process: std.process.Init) !void {
    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/", .handler = homeHandler },
    }, .{
        .io = process.io,
        // dispatch_model = .ASYNC (default, bisa dihilangkan)
        // workers        = 0  -> cpu_count (accept thread untuk .POOL/.MIXED; worker untuk .EPOLL)
        // pool_size      = 0  -> max(10, cpu_count * 2) pool thread (.POOL only; diabaikan oleh .EPOLL)
    });
```

**`.ASYNC` (accept tunggal, dispatch `io.async()`):**

Satu accept thread mendispatch setiap koneksi via `io.async()`. `workers` dan `pool_size` diabaikan. Diutamakan untuk SSE dan WebSocket (koneksi long-lived tidak menahan pool thread). Cocok juga untuk `concurrent_limit` eksplisit.

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .ASYNC,
});
```

**`.MIXED` (N accept thread, dispatch `io.async()`):**

N accept thread masing-masing mendispatch koneksi via `io.async()` secara langsung, tanpa `ConnQueue`. Throughput dan latensi seimbang. `pool_size` diabaikan.

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .MIXED,
});
```

**`.EPOLL` (shared-nothing epoll worker, khusus Linux):**

Setiap worker memiliki `SO_REUSEPORT` listener dan satu `epoll` instance tersendiri. Kernel mendistribusikan koneksi baru ke worker. Tidak ada antrian bersama, tidak ada mutex, tidak ada handoff fd antar thread. Level-triggered `EPOLLIN` menjaga koneksi tetap terdaftar setelah setiap request tanpa re-arm eksplisit. Koneksi keep-alive yang idle tidak menahan thread. Terbaik untuk request berumur pendek throughput tinggi di Linux. Build non-Linux otomatis fallback ke `.POOL`.

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .EPOLL,
    .workers        = 0, // 0 = cpu_count worker (default); pool_size diabaikan
});
```

__*In the nutshell:*__
- Looking for high throughput? Use `.EPOLL`.
- Looking for consistent latency? Use `.ASYNC`.
- For non-linux user and looking for high throughput? Use `.POOL` or `.MIXED`.

Lihat [`docs/concurrency-id.md`](docs/concurrency-id.md) untuk detail arsitektur, jumlah thread, dan kapan sebaiknya memilih masing-masing model.

<br>

### Timeout

Dua lapisan timeout independen, keduanya dinonaktifkan secara default (`0`):

**`conn_timeout_ms`**: penjaga koneksi tingkat jaringan (Layer D). Thread timer menutup koneksi yang telah terbuka lebih lama dari ini tanpa selesai. Melindungi pool thread dari klien yang macet sebelum atau saat mengirim header. Efektif hanya di `.POOL`.

**`handler_timeout_ms`**: anggaran eksekusi per-handler (Layer B). Mengatur `ctx.deadline` sebelum setiap dispatch. Handler ikut serta dengan memanggil `ctx.isExpired()` di antara langkah-langkah yang mahal.

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/slow", .handler = slowHandler },
}, .{
    .io                 = process.io,
    .ip                 = "127.0.0.1",
    .port               = 9000,
    .conn_timeout_ms    = 30_000, // tutup koneksi macet setelah 30 detik
    .handler_timeout_ms = 5_000,  // anggaran handler: 5 detik
});
```

Handler yang menggunakan anggaran:

```zig
pub fn slowHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;

    doStep1(ctx.io);
    if (ctx.isExpired()) {
        res.setStatus(.REQUEST_TIMEOUT);
        return res.sendJson("{\"error\":\"timeout\"}");
    }

    doStep2(ctx.io);
    if (ctx.isExpired()) {
        res.setStatus(.REQUEST_TIMEOUT);
        return res.sendJson("{\"error\":\"timeout\"}");
    }

    try res.sendJson("{\"result\":\"ok\"}");
}
```

Untuk menimpa deadline di dalam handler (jendela lebih pendek atau lebih panjang dari anggaran global):

```zig
ctx.setTimeout(2_000); // timpa ke 2 detik dari sekarang terlepas dari cap global
```

`ctx.isExpired()` adalah no-op (selalu mengembalikan `false`) ketika `handler_timeout_ms == 0`. `ctx.timedOut()` adalah alias untuk `ctx.isExpired()`. `conn_timeout_ms` harus >= `handler_timeout_ms` agar koneksi tidak terputus sebelum handler dapat mengirim 408. Lihat `examples/http_timeout_resp.zig` dan `docs/adr-id.md` (ADR-018) untuk alasan desain. Untuk engine `zix.Http1` mentah lihat `examples/http1_timeout_resp.zig`, yang memakai `zix.Http1.isExpired()` dan `zix.Http1.setTimeout()` (tanpa ctx, lihat ADR-029).

<br>

### Middleware

Middleware disusun pada waktu kompilasi menggunakan fungsi wrapper. Setiap wrapper menerima `comptime next: zix.Http.HandlerFn` dan mengembalikan `HandlerFn` baru (tanpa alokasi heap, tanpa chain runner runtime).

```zig
fn withOriginCheck(comptime next: zix.Http.HandlerFn) zix.Http.HandlerFn {
    return struct {
        fn handle(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) anyerror!void {
            const origin = req.header("origin") orelse "";
            if (!isAllowedOrigin(origin)) {
                res.setStatus(.FORBIDDEN);
                try res.sendJson("{\"error\":\"forbidden origin\"}");
                return;
            }
            return next(req, res, ctx);
        }
    }.handle;
}

fn withBasicAuth(comptime next: zix.Http.HandlerFn) zix.Http.HandlerFn {
    return struct {
        fn handle(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) anyerror!void {
            // validasi Authorization: Basic <base64(user:pass)>
            // ...
            return next(req, res, ctx);
        }
    }.handle;
}
```

Susun dari kiri ke kanan, wrapper paling luar dijalankan pertama:

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    // hanya pengecekan origin
    .{ .path = "/public",  .handler = withOriginCheck(publicHandler) },
    // pengecekan origin -> basic auth -> handler
    .{ .path = "/private", .handler = withOriginCheck(withBasicAuth(privateHandler)) },
}, .{ .io = process.io, .ip = "127.0.0.1", .port = 9008 });
```

```
# contoh curl
curl -H "Origin: http://localhost" "http://localhost:9008/public"                         # 200
curl "http://localhost:9008/public"                                                       # 403

curl -H "Origin: http://localhost" -u "admin:secret" "http://localhost:9008/private"      # 200
curl -H "Origin: http://localhost" "http://localhost:9008/private"                        # 401
curl "http://localhost:9008/private"                                                      # 403
```

Untuk contoh lengkap yang berfungsi lihat `examples/http_middleware.zig`.

<br>

### WebSocket

Broadcast berbasis ruang melalui RFC 6455. Handler param mengupgrade koneksi dan memasuki loop frame per-task, tidak perlu thread terpisah.

```zig
var ws_rooms: zix.Http.WebSocket.RoomMap = undefined;

pub fn wsHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    const room_id = req.pathParam("room-id") orelse return;

    // Baca query param SEBELUM upgrade() (tidak tersedia setelah handshake 101).
    const display_name = req.queryParam("name") orelse "anonymous";

    // ekstrak Sec-WebSocket-Key dari header, lalu handshake
    var accept_buf: [64]u8 = undefined;
    const accept = try zix.Http.WebSocket.acceptKey(ws_key, &accept_buf);
    try zix.Http.WebSocket.upgrade(ctx.stream, ctx.io, accept); // menulis 101 secara langsung

    // heap-alokasi conn, bergabung ke ruang, keduanya dibersihkan via defer (LIFO)
    const conn = try std.heap.smp_allocator.create(zix.Http.WebSocket.Conn);
    conn.* = .{ .stream = ctx.stream, .io = ctx.io };
    defer std.heap.smp_allocator.destroy(conn);
    ws_rooms.join(room_id, conn, ctx.io);
    defer ws_rooms.leave(room_id, conn, ctx.io);  // berjalan sebelum destroy

    // loop frame:
    //   text/binary -> broadcast "[display_name] payload" ke ruang
    //   ping        -> pong
    //   close       -> echo frame close + break
    //   EOF / error -> frame close best-effort + break
    _ = display_name;
}

pub fn main(process: std.process.Init) !void {
    ws_rooms = zix.Http.WebSocket.RoomMap.init(std.heap.smp_allocator);
    defer ws_rooms.deinit();

    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/ws/:room-id", .handler = wsHandler, .kind = .PARAM },
    }, .{ .io = process.io, .ip = "127.0.0.1", .port = 9008 });
    defer server.deinit();
    try server.run();
}
```

```
# Sambungkan dengan wscat atau websocat, ?name mengatur nama display broadcast
wscat    -c "ws://localhost:9008/ws/lobby?name=alice"
websocat    "ws://localhost:9008/ws/lobby?name=alice"

# ?name opsional, hilangkan untuk "anonymous"
wscat    -c "ws://localhost:9008/ws/lobby"
```

**Prioritas:** exact > param > prefix. `/ws/:room-id` adalah rute param, jadi `/ws/lobby` menangkap `room-id = "lobby"`.

`ctx.stream` adalah TCP stream mentah yang diekspos via `Context`. Server menetapkannya untuk **setiap** koneksi sebelum memanggil handler mana pun: handler HTTP mengabaikannya, handler WebSocket menggunakannya setelah upgrade 101.

**Menggabungkan HTTP, static, dan WebSocket dalam satu server**: daftarkan semua tipe handler bersamaan, routing menangani dispatch. Rute yang tidak cocok diteruskan ke static serving:

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/",          .handler = homeHandler },
    .{ .path = "/api",       .handler = apiHandler,  .kind = .PREFIX },
    .{ .path = "/ws/:room-id", .handler = wsHandler, .kind = .PARAM },
}, .{
    .io         = process.io,
    .ip         = "127.0.0.1",
    .port       = 9008,
    .public_dir = "./public", // file statis untuk rute yang tidak cocok
});
```

Lihat `examples/http_websocket.zig` untuk contoh lengkap yang berfungsi. Untuk engine `zix.Http1` mentah lihat `examples/http1_websocket.zig` (`zix.Http1.WebSocket`, echo raw-fd).

**Build-once broadcast fanout**: pada jalur `zix.Http1` yang dikelola engine, `zix.Http1.WebSocket.broadcast(conns, opcode, payload)` men-serialize frame satu kali saja dan menulis byte yang sama ke setiap fd dalam room yang dikelola pemanggil, sehingga sebuah broadcast hanya berbiaya satu serialization tidak peduli berapa banyak member yang dijangkau. Write yang gagal ke peer mati dilewati (engine EPOLL memanen fd itu pada event berikutnya), dan jalur payload besar membangun header sekali dan menulis payload tanpa menyalinnya ke staging buffer. `zix.Http.WebSocket.RoomMap.broadcast` tingkat tinggi mengikuti bentuk build-once, fan-out yang sama dengan room registry yang dikelola server.

<br>

### SSE (Server-Sent Events)

Push satu arah dari server melalui HTTP/1.1: tanpa handshake WebSocket, reconnect `EventSource` native browser.

```zig
// GET /events: streaming "tick N" sekali per detik
pub fn eventsHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    const sse = try res.stream(); // mengirim header SSE, mengembalikan SseWriter
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "tick {d}", .{i}) catch break;
        sse.writeEvent(msg) catch break;                                       // data: tick N\n\n
        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(1000), .awake) catch break;
    }
    // handler selesai -> koneksi ditutup -> EventSource reconnect otomatis
}
```

| Metode `SseWriter` | Format wire |
| :- | :- |
| `writeEvent(data)` | `data: <data>\n\n` |
| `writeNamedEvent(event, data)` | `event: <event>\ndata: <data>\n\n` |
| `comment(text)` | `: <text>\n` (keepalive) |

**Model dispatch:** gunakan `.ASYNC`. Koneksi SSE bersifat long-lived: mereka akan menghabiskan blocking pool (`.POOL`) satu thread per stream yang terbuka. `.ASYNC` mendispatch setiap koneksi via `io.async()`, menjaga pool thread tetap bebas.

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/events", .handler = eventsHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .ASYNC, // diutamakan untuk SSE: koneksi long-lived tidak menahan pool thread
});
```

```sh
curl -N http://localhost:9010/events
```

Lihat `examples/http_sse.zig` untuk contoh lengkap dengan halaman HTML yang kompatibel dengan browser. Untuk engine `zix.Http1` mentah lihat `examples/http1_sse.zig`.

<br>

### HTTP Client

`zix.Http.Client` membuat permintaan HTTP keluar. Setiap panggilan mengembalikan `ClientResponse` yang dimiliki pemanggil dan harus dilepas dengan `deinit()`.

```zig
var client = zix.Http.Client.init(.{
    .allocator         = arena.allocator(),
    .io                = process.io,
    .connect_timeout_ms = 5000,       // error.Timeout jika koneksi TCP memakan waktu > 5 detik
    .max_response_body  = 64 * 1024,  // error.BodyTooLarge jika body melebihi 64 KB
});
defer client.deinit();

// GET
var resp = try client.get("http://127.0.0.1:9000/", .{});
defer resp.deinit();
std.debug.print("{d}: {s}\n", .{ resp.status(), resp.body() });

// GET dengan inspeksi header
if (resp.header("content-type")) |ct| {
    std.debug.print("content-type: {s}\n", .{ct});
}

// POST dengan body dan header kustom
const extra = [_]std.http.Header{
    .{ .name = "X-Trace-Id", .value = "abc-123" },
};
var post_resp = try client.post("http://127.0.0.1:9000/api/items", .{
    .headers = &extra,
    .body    = "{\"name\":\"widget\"}",
});
defer post_resp.deinit();

// Timpa timeout koneksi per-permintaan
var fast = try client.get("http://127.0.0.1:9000/health", .{
    .connect_timeout_ms = 500,
});
defer fast.deinit();
```

| Shorthand metode | Mengirim body? |
| :- | :- |
| `client.get(url, opts)` | tidak |
| `client.head(url, opts)` | tidak |
| `client.post(url, opts)` | ya (Content-Length: 0 jika opts.body null) |
| `client.put(url, opts)` | ya |
| `client.patch(url, opts)` | ya |
| `client.delete(url, opts)` | tidak |
| `client.request(method, url, opts)` | tergantung metode |

| Error | Kondisi |
| :- | :- |
| `error.InvalidUrl` | URL tidak valid, skema tidak didukung, atau host tidak ada |
| `error.BodyTooLarge` | body respons melebihi `max_response_body` |
| `error.Timeout` | koneksi TCP melebihi `connect_timeout_ms` |

Redirect diikuti secara otomatis hingga `max_redirects` (default 3). Atur `follow_redirects = false` untuk menerima respons 3xx secara langsung.

Lihat `examples/http_client.zig` dan [`docs/hld-http-id.md`](docs/hld-http-id.md) untuk detail. `zix.Http.Client` yang sama bekerja terhadap server `zix.Http1` mentah: lihat `examples/http1_client.zig`, yang menyetel `.version = .HTTP_1` (selector versi, dengan `HTTP_2` dan `HTTP_3` direservasi, lihat ADR-028).

<br>

### File Statis & Unggah

Atur `public_dir` di `HttpServerConfig` untuk mengaktifkan static file serving. `server.run()` mengembalikan `error.PublicDirNotFound` jika direktori tidak ada. Gunakan helper `createInitDirs` untuk membuat semua direktori yang diperlukan sebelum `Server.init`:

```zig
fn createInitDirs(io: std.Io) void {
    std.Io.Dir.cwd().createDirPath(io, "./public") catch {};
    std.Io.Dir.cwd().createDirPath(io, "./public/u") catch {};
}

pub fn main(process: std.process.Init) !void {
    createInitDirs(process.io); // idempoten, aman dipanggil setiap start

    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/upload", .handler = uploadHandler },
    }, .{
        .io                = process.io,
        .ip                = "127.0.0.1",
        .port              = 9005,
        .public_dir        = "./public", // divalidasi saat run(); "" = dinonaktifkan
        .public_dir_upload = "u",
    });
```

- Rute yang tidak cocok diteruskan ke static serving dari `public_dir`.
- Range request (`Range: bytes=...`) -> `206 Partial Content` (RFC 7233).
- Directory traversal (`..`) ditolak.

**Unggah**: parse body multipart di dalam handler, opsional ganti nama sebelum menyimpan:

```zig
var parser = zix.Http.Multipart.init(ctx.allocator, boundary);
defer parser.deinit();
try parser.parse(try req.body());

if (parser.getField("file")) |f| {
    // kamu bisa mengganti nama file sebelum menyimpan dengan mengganti string filename, misalnya:
    //   const filename = "custom_name.txt"
    // atau membuatnya secara dinamis:
    //   const filename = try std.fmt.allocPrint(ctx.allocator, "{s}_{s}", .{ sessionid, f.filename orelse "upload" });
    const filename = f.filename orelse "upload";
    const path = try zix.utils.file.save(ctx.io, ctx.allocator, "./public/u", filename, f.data);
    _ = path; // dialokasikan arena, valid untuk permintaan ini
}
```

`zix.utils.file.save` membuat direktori tujuan jika diperlukan dan mengembalikan salinan path milik pemanggil.

```
# contoh curl: unggah file dengan metadata JSON
curl -X POST "http://localhost:9005/upload" \
  -F "file=@/path/to/file.txt" \
  -F 'data={"userid":0,"sessionid":"01944f5a-0000-7000-8000-000000000000"}'
```

Lihat `examples/http_static.zig` untuk contoh lengkap yang berfungsi termasuk static serving, range request, dan unggah multipart.

<br>

## Kapasitas Header Respons (`HeaderSize`)

`HttpServerConfig.max_response_headers` mengontrol berapa banyak header kustom yang akan diterima `res.addHeader()` per respons. Pilih tingkatan yang sesuai dengan deployment-mu:

| Varian | Cap | Penggunaan umum |
| :- | :- | :- |
| `.MINIMAL` | 16 | **Default.** API internal sederhana, lingkungan terkontrol, handler polos |
| `.COMMON` | 32 | Sebagian besar aplikasi web, single proxy |
| `.LARGE` | 64 | CDN + proxy, load balancer, API berat CORS |
| `.EXTRA_LARGE` | 128 | k8s, service mesh, stack forwarding berat |
| `.{ .CUSTOM = N }` | N | Cap eksplisit, dialokasikan arena tepat N slot per permintaan |

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .max_response_headers = .LARGE,                // 64 header
    // .max_response_headers = .{ .CUSTOM = 48 },  // eksplisit
});
```

`addHeader()` mengembalikan `error.TooManyHeaders` ketika cap tercapai dan `error.InvalidHeaderName` / `error.InvalidHeaderValue` jika nama atau nilai mengandung CR atau LF (penjaga injeksi header).

`.{ .CUSTOM = N }` mengalokasikan tepat N slot dari arena per-permintaan (tanpa ceiling, tanpa clamping).

Untuk panduan keamanan dan pemilihan tingkatan lihat [`docs/headers-id.md`](docs/headers-id.md). Untuk demonstrasi yang berfungsi lihat `examples/http_xtra_headers.zig`. Untuk engine `zix.Http1` mentah lihat `examples/http1_xtra_headers.zig`, yang membangun header secara manual dengan penjaga injeksi CR/LF.

<br>

## Kapasitas Header Permintaan (`RequestHeaderSize`)

`HttpServerConfig.max_request_headers` mengontrol berapa banyak header yang diterima server per permintaan. Permintaan yang melebihi cap ditolak dengan `431 Request Header Fields Too Large`.

| Varian | Cap | Catatan |
| :- | :- | :- |
| `.MINIMAL` | 16 | API ketat, layanan internal |
| `.COMMON` | 32 | Sebagian besar aplikasi web |
| `.LARGE` | 64 | **Default.** Batas penyimpanan parser. CDN, proxy, API berat CORS |
| `.{ .CUSTOM = N }` | N (dibatasi 64) | Cap eksplisit nilai di atas 64 secara diam-diam dibatasi ke batas parser |

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .max_request_headers = .COMMON,                // 32 header
    // .max_request_headers = .{ .CUSTOM = 24 },   // eksplisit
});
```

Batas penyimpanan parser adalah 64: nilai `CUSTOM` di atas 64 secara diam-diam dibatasi. Lihat `zix.Http.RequestHeaderSize`.

<br>

## Kesadaran Cache Respons (`response_cache`)

`zix.Http1`, `zix.Http`, dan `zix.Grpc` berbagi response cache per-worker yang opt-in (ADR-036). Handler membangun responnya sekali, engine menyimpannya di bawah sebuah key yang diturunkan dari request, dan request berikutnya yang cocok memutar ulang byte tersimpan tanpa membangun ulang. Sebuah hit melewati pembangunan body handler sekaligus serialization. Cache ini data oriented (structure of arrays plus satu payload slab datar), lock-free by ownership (satu instance per worker, tidak pernah dibagi), dan freshness memakai lazy on-access TTL.

Apa yang menjadi key dan nilai yang di-cache bergantung pada engine:

| Engine | Cache key | Nilai yang di-cache |
| :- | :- | :- |
| `zix.Http1`, `zix.Http` | method, path, query | respons HTTP yang sudah di-serialize penuh, ditulis verbatim |
| `zix.Grpc` (unary) | path, pesan request | pesan respons, di-frame ulang per stream (HPACK dan stream id tetap benar) |

Secara default fitur ini mati. Aktifkan pada dispatch model `.EPOLL`:

```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/report", .handler = reportHandler },
}, .{
    .ip = "0.0.0.0",
    .port = 8080,
    .dispatch_model = .EPOLL,
    .response_cache = true,                  // aktifkan cache per-worker
    .cache_max_entries = 256,                // slot, dibulatkan turun ke pangkat dua
    .cache_max_value_bytes = 16 * 1024,      // batas respons per-slot
    .cache_ttl_ms = 1000,                    // freshness default
    // .cache_max_total_bytes = 4 * 1024 * 1024, // batas memori cache per-worker opsional
});
```

Sebuah miss membangun dan menyimpan respons, sebuah hit yang fresh disajikan verbatim:

```zig
fn reportHandler(req: *zix.Http.Request, res: *zix.Http.Response, _: *zix.Http.Context) !void {
    if (res.serveCached(req)) return;            // hit fresh: byte cache sudah ditulis

    const body = try buildExpensiveReport(req);  // hanya berjalan saat miss
    res.setContentType(.APPLICATION_JSON);
    try res.sendCached(req, body, 0);            // ttl 0 memakai cache_ttl_ms
}
```

Engine `zix.Http1` mentah mengekspos ide yang sama lewat `cacheLookup` dan `writeWithCache`.

Untuk handler gRPC unary, opt-in berada di call context. `ctx.serveCached` memutar ulang pesan reply tersimpan (di-frame ulang untuk stream saat ini dan diselesaikan dengan OK), dan `ctx.sendCached` mengirim sekaligus menyimpan reply. Aktifkan dengan nama field yang sama pada `GrpcServerConfig` (`response_cache`, `cache_max_entries`, dan seterusnya) di bawah `.EPOLL`:

```zig
fn sayHello(_: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    if (ctx.serveCached("application/grpc")) return; // hit fresh: reply terkirim, stream selesai

    const reply = buildExpensiveReply(ctx.recvMessage()); // hanya berjalan saat miss
    ctx.sendCached("application/grpc", reply, 0);          // ttl 0 memakai cache_ttl_ms
    ctx.finish(.OK, "");
}
```

### Kapan menguntungkan

Crossover yang terukur di loopback berkisar 4 KiB body respons. Di bawah itu biaya didominasi kernel dan cache impas. Di atasnya kerja yang dihemat tumbuh seiring ukuran body.

| Bentuk respons | Efek cache |
| :- | :- |
| Serialization yang berat komputasi (JSON besar, output yang dirender) di atas ~4 KiB | Kasus terbaik, gain besar (JSON berat ~32 KiB terukur +34% throughput) |
| Respons kecil di bawah ~2 KiB | Impas, terikat kernel, tanpa regresi |
| File statis yang dibaca dari disk | Marginal: OS page cache sudah menyajikan file dengan murah, lebih baik pakai sendfile atau splice |
| Body unik per-request (tanpa pengulangan key) | Tidak ada manfaat, setiap request miss |

### Aturan dan kondisi

- Opt-in saja. Mati secara default, dan handler harus memanggil `res.serveCached` lalu `res.sendCached` (HTTP), `ctx.serveCached` lalu `ctx.sendCached` (gRPC), atau `cacheLookup` / `writeWithCache` milik `zix.Http1`.
- Hanya `.EPOLL` di rilis ini. Dispatch model lain membiarkan cache tidak terpasang dan API menurun menjadi plain send.
- Untuk HTTP key adalah method, path, dan query: dua request yang hanya berbeda query string adalah entri yang berbeda, dan Anda tidak boleh mem-cache respons yang bervariasi pada header atau cookie. Untuk gRPC key adalah path plus pesan request, sehingga hanya request yang identik yang hit.
- Cache hanya yang aman diputar ulang selama jendela TTL. Untuk HTTP byte yang sama (termasuk `Date` yang ditangkap) disajikan sampai entri kedaluwarsa, jadi jaga `cache_ttl_ms` tetap pendek untuk konten yang sensitif waktu.
- Respons lebih besar dari `cache_max_value_bytes` melewati cache dan jatuh kembali ke plain send. Untuk gRPC batas ini berlaku pada pesan respons. Jaga tetap ramping agar hanya respons di atas crossover yang menempati slot.
- Memori per-worker adalah `cache_max_entries * cache_max_value_bytes`, dikali jumlah worker, secara opsional dibatasi oleh `cache_max_total_bytes`.

**Mengapa hanya `.EPOLL`:** cache adalah instance thread-local, tidak pernah dibagi dan tidak pernah dikunci (lock-free by ownership). Invariant itu hanya berlaku saat satu thread milik zix memasang cache (alokasi, set, free saat keluar) dan menjadi satu-satunya thread yang menyentuhnya.

| Model | Menjalankan handler di | Status cache |
| :- | :- | :- |
| `.EPOLL` | worker thread shared-nothing milik zix, satu per core | terpasang: lifecycle bersih, satu thread pemilik, jalur yang di-benchmark |
| `.POOL` | pool thread milik zix | layak dan aman, tetapi setiap thread akan memegang cache-nya sendiri (hit rate lebih rendah, N kali memori), sehingga ditunda, tidak dipasang |
| `.ASYNC`, `.MIXED` | task `io.async()` di executor pool `std.Io`, bukan milik zix | tidak terpasang: tidak ada hook pasang per-thread, dan task tidak ditambatkan ke satu thread, sehingga cache bersama akan butuh lock dan merusak desain lock-free |

Di model mana pun perilakunya aman, hanya tidak aktif: saat cache tidak terpasang, `response_cache = true` dan pemanggilan `serveCached` / `sendCached` menurun menjadi plain send (tanpa error, tanpa caching).

```mermaid
flowchart TD
    A[Request masuk] --> B{response_cache dan EPOLL?}
    B -- tidak --> P[Plain send]
    B -- ya --> C{serveCached hit dan fresh?}
    C -- ya --> W[Tulis byte cache, tanpa bangun ulang]
    C -- tidak --> D[Bangun respons]
    D --> E{body lebih besar dari cache_max_value_bytes?}
    E -- ya --> P
    E -- tidak --> S[sendCached: tulis lalu simpan di bawah key]
```

Lihat ADR-036 untuk rasional desain dan angka terukur.

<br>

## HTTP/2 h2c

HTTP/2 hanya sebagai persyaratan untuk pendekatan gRPC h2c.

<br>

## gRPC h2c

`zix.Grpc` adalah server dan client gRPC melalui h2c. Rute didaftarkan pada waktu kompilasi. Semua 4 tipe RPC didukung (unary, server streaming, client streaming, bidirectional).

```zig
const std = @import("std");
const zix = @import("zix");

fn sayHelloHandler(
    headers: []const zix.Http2.Header,
    ctx:     *zix.Grpc.Context,
) void {
    _ = headers;
    const req = ctx.recvMessage() orelse {
        ctx.finish(.INVALID_ARGUMENT, "no message");
        return;
    };
    // decode req (proto3), encode balasan
    var reply: [256]u8 = undefined;
    const n = zix.Grpc.encodeString(1, "Hello!", &reply);
    ctx.sendMessage("application/grpc+proto", reply[0..n]);
    ctx.finish(.OK, "");
}

pub fn main(process: std.process.Init) !void {
    var server = try zix.Grpc.Server.init(
        &[_]zix.Grpc.Route{
            .{ .path = "/helloworld.Greeter/SayHello", .handler = sayHelloHandler },
        },
        .{
            .io   = process.io,
            .ip   = "127.0.0.1",
            .port = 8083,
        },
    );
    defer server.deinit();
    try server.run();
}
```

```sh
# Uji dengan grpcurl
grpcurl -plaintext -d '{"name":"world"}' 127.0.0.1:8083 helloworld.Greeter/SayHello
```

**HandlerFn:** `fn(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void`

- Path diselesaikan oleh tabel rute sebelum handler dipanggil.
- `ctx.recvMessage()` mengembalikan setiap pesan client yang di-buffer atau `null` jika selesai.
- `ctx.sendMessage(content_type, data)` mengirim frame DATA respons (panggilan pertama juga mengirim HEADERS).
- `ctx.finish(status, message)` mengirim trailer grpc-status. Harus dipanggil tepat sekali.
- Route unary (`is_server_streaming = false`, default) di-dispatch secara sinkron pada connection thread. Route server-streaming memerlukan `is_server_streaming = true` pada entri `Route` dan masing-masing berjalan pada thread tersendiri.

**GrpcClient:**

```zig
var client = try zix.Grpc.Client.connect(.{
    .ip   = "127.0.0.1",
    .port = 8083,
}, process.io);
defer client.deinit();

// Unary convenience
var buf: [4096]u8 = undefined;
const resp = try client.unary(
    "/helloworld.Greeter/SayHello",
    "application/grpc+proto",
    request_bytes,
    &buf,
);
```

**Codec protobuf minimal** (tidak memerlukan codegen untuk skema sederhana):

```zig
var out: [256]u8 = undefined;
var pos: usize = 0;
pos += zix.Grpc.encodeString(1, "world",  out[pos..]); // field 1: string
pos += zix.Grpc.encodeInt32( 2, 42,       out[pos..]); // field 2: int32
pos += zix.Grpc.encodeDouble(3, 1.5,      out[pos..]); // field 3: double
// kirim out[0..pos] sebagai payload pesan gRPC
```

**Model dispatch:** `.ASYNC` (default), `.POOL`, `.MIXED`, `.EPOLL` (khusus Linux). Model gRPC EPOLL adalah multiplexed event loop shared-nothing: setiap worker memiliki `SO_REUSEPORT` listener dan satu epoll instance tersendiri, dan menjalankan banyak koneksi h2 non-blocking melalui resumable HTTP/2 state machine. `pool_size` adalah jumlah worker (0 = cpu_count). Non-Linux otomatis fallback ke `.POOL`. Lihat [`docs/concurrency-id.md`](docs/concurrency-id.md) untuk detail.

**Timeout context:** Tiga input, yang paling ketat menang:

```zig
var server = try zix.Grpc.Server.init(
    &[_]zix.Grpc.Route{
        // cap per-rute 3 detik, memperketat cap global 5 detik
        .{ .path = "/helloworld.Greeter/SayHello", .handler = sayHelloHandler, .timeout_ms = 3_000 },
        // cap per-rute 10 detik, cap global 5 detik tetap menang. Echo mengirim N respons sehingga is_server_streaming = true
        .{ .path = "/helloworld.Greeter/Echo", .handler = echoHandler, .timeout_ms = 10_000, .is_server_streaming = true },
    },
    .{
        .io                = process.io,
        .ip                = "127.0.0.1",
        .port              = 8083,
        .handler_timeout_ms = 5_000, // cap global, juga digabungkan dengan Route.timeout_ms dan header grpc-timeout
    },
);
```

Handler memeriksa `ctx.isExpired()` di antara langkah-langkah. Timpa `ctx.deadline_ns` secara langsung untuk perpanjangan per-panggilan: `ctx.deadline_ns = zix.Grpc.wallClockNs() + 30 * std.time.ns_per_s`. Lihat `examples/grpc_timeout.zig` untuk demo lengkap.

| Contoh | Pola |
| :- | :- |
| `examples/grpc_server_1_async.zig` | Server gRPC: dispatch ASYNC |
| `examples/grpc_server_2_pool.zig` | Server gRPC: dispatch POOL |
| `examples/grpc_server_3_mixed.zig` | Server gRPC: dispatch MIXED |
| `examples/grpc_server_4_epoll.zig` | Server gRPC: dispatch EPOLL (Linux-only) |
| `examples/grpc_client.zig` | Client gRPC: unary dan streaming |
| `examples/grpc_multi_server.zig` + `grpc_multi_client.zig` | Satu port, dua layanan |
| `examples/grpc_location_server_1_async.zig` | Layanan lokasi: dispatch ASYNC |
| `examples/grpc_location_server_2_pool.zig` | Layanan lokasi: dispatch POOL |
| `examples/grpc_location_server_3_mixed.zig` | Layanan lokasi: dispatch MIXED |
| `examples/grpc_location_server_4_epoll.zig` | Layanan lokasi: dispatch EPOLL (Linux-only) |
| `examples/grpc_location_client.zig` | Client layanan lokasi |
| `examples/grpc_timeout.zig` | Timeout konteks: global, per-rute, override |

Lihat [`docs/hld-grpc-id.md`](docs/hld-grpc-id.md) untuk dokumentasi lengkap termasuk semua 4 pola tipe RPC dan setup proxy TLS.

<br>

## Raw TCP

`zix.Tcp` adalah server dan client TCP stream mentah. Handler yang didefinisikan pengguna memiliki stream. Tiga model dispatch. Format frame default: length prefix big-endian 4 byte.

```zig
const std = @import("std");
const zix = @import("zix");

fn myHandler(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);
    var rbuf: [4100]u8 = undefined;
    var rdr = stream.reader(io, &rbuf);
    var buf: [4096]u8 = undefined;
    while (true) {
        const len = rdr.interface.takeVarInt(u32, .big, 4) catch return;
        if (len == 0 or len > buf.len) return;
        rdr.interface.readSliceAll(buf[0..len]) catch return;
        const msg = buf[0..len];
        _ = msg; // proses msg
        // tulis respons dengan stream.writer()
    }
}

pub fn main(process: std.process.Init) !void {
    var server = try zix.Tcp.Server.init(.{
        .ip   = "127.0.0.1",
        .port = 9300,
        .dispatch_model = .ASYNC,
    });
    defer server.deinit();
    try server.runWith(process.io, myHandler);
    // atau: try server.run(process.io);  // menggunakan echoHandler bawaan
}
```

**Format frame:** `[u32 big-endian payload_len][payload bytes]`. Baik `echoHandler` bawaan maupun `TcpClient.sendMsg`/`recvMsg` menggunakan format ini.

**TcpClient:**

```zig
var client = try zix.Tcp.Client.connect(.{
    .ip   = "127.0.0.1",
    .port = 9300,
}, io);
defer client.deinit(io);

try client.sendMsg(io, "hello");
var buf: [4096]u8 = undefined;
const reply = try client.recvMsg(io, &buf);
```

**Override argumen CLI** (tanpa rebuild):

```zig
var server = try zix.Tcp.Server.initArgs(.{ .ip = "127.0.0.1", .port = 9300 }, process.minimal.args);
var client = try zix.Tcp.Client.connectArgs(.{ .ip = "127.0.0.1", .port = 9300 }, io, process.minimal.args);
```

Lihat `examples/tcp_server_1_async.zig`, `examples/tcp_server_2_pool.zig`, `examples/tcp_server_3_mixed.zig`, `examples/tcp_server_4_epoll.zig`, `examples/tcp_client.zig`, dan [`docs/hld-tcp-id.md`](docs/hld-tcp-id.md) untuk detail.

<br>

## FIX 4.x

`zix.Fix` adalah server dan client lapisan sesi FIX 4.x. Framing SOH-delimited (0x01). Penanganan sesi (Logon/Logout/Heartbeat) sudah built-in. Pesan aplikasi didispatch ke router comptime atau di-echo ketika tidak ada rute yang terdaftar.

Mode echo (tanpa routing):

```zig
const std = @import("std");
const zix = @import("zix");

pub fn main(process: std.process.Init) !void {
    var server = try zix.Fix.Server.init(&.{}, .{
        .io                   = process.io,
        .ip                   = "127.0.0.1",
        .port                 = 9500,
        .comp_id              = "SERVER",
        .dispatch_model       = .ASYNC,
        .heartbeat_timeout_ms = 30_000, // 0 = dinonaktifkan (default)
    });
    defer server.deinit();
    try server.run();
}
```

Mode router (dispatch pesan aplikasi):

```zig
fn handleNewOrder(fields: []const zix.Fix.Field, ctx: *zix.Fix.Context) void {
    if (ctx.isExpired()) return;
    const symbol = zix.Fix.getField(fields, .Symbol) orelse return;
    ctx.sendMessage(zix.Fix.MsgType.ExecutionReport, &[_]zix.Fix.BuildField{
        .{ .tag = .Symbol, .value = symbol },
        .{ .tag = .OrdStatus, .value = "0" },
    });
}

var server = try zix.Fix.Server.init(
    &[_]zix.Fix.Route{
        .{ .msg_type = zix.Fix.MsgType.NewOrderSingle, .handler = handleNewOrder, .timeout_ms = 500 },
    },
    .{
        .io                    = process.io,
        .ip                    = "0.0.0.0",
        .port                  = 9500,
        .comp_id               = "BROKER",
        .dispatch_model        = .ASYNC,
        .handler_timeout_ms    = 200,
        .connection_timeout_ms = 60_000,
    },
);
```

`FixClient`:

```zig
var client = try zix.Fix.Client.connect(.{
    .ip             = "127.0.0.1",
    .port           = 9500,
    .comp_id        = "CLIENT",
    .target_comp_id = "SERVER",
}, io);
defer client.deinit(io);

try client.logon(io, 30);
try client.sendMessage(io, zix.Fix.MsgType.NewOrderSingle, &[_]zix.Fix.BuildField{
    .{ .tag = .ClOrdID,  .value = "order-001" },
    .{ .tag = .Symbol,   .value = "AAPL" },
    .{ .tag = .Side,     .value = "1" },
    .{ .tag = .OrderQty, .value = "100" },
});
const msg = try client.recvMessage(io);
_ = msg;
try client.logout(io);
```

**Pesan sesi ditangani otomatis:**

| MsgType (tag 35) | Aksi server |
| :- | :- |
| `A` (Logon) | Balas dengan Logon, CompID ditukar |
| `5` (Logout) | Balas dengan Logout, lalu tutup |
| `0` (Heartbeat) | Balas dengan Heartbeat |
| `1` (TestRequest) | Balas dengan Heartbeat |
| lainnya (routes non-kosong) | Dispatch ke handler rute yang sesuai |
| lainnya (routes kosong) | Echo tanpa perubahan |

**`zix.Fix.MsgType`**: namespace struct berisi 47 konstanta string compile-time untuk nilai MsgType FIX (FIX 4.0-4.4). Gunakan konstanta bernama daripada string mentah: `MsgType.NewOrderSingle` (`"D"`), `MsgType.ExecutionReport` (`"8"`), `MsgType.Logon` (`"A"`), dll.

**Model dispatch:** `.ASYNC` (default, sesi FIX bersifat long-lived), `.POOL`, `.MIXED`, `.EPOLL` (khusus Linux: satu epoll accept loop, pool worker menahan setiap koneksi untuk seluruh hidupnya). Non-Linux otomatis fallback ke `.POOL`.

Lihat `examples/fix_server_1_async.zig`, `examples/fix_server_2_pool.zig`, `examples/fix_server_3_mixed.zig`, `examples/fix_server_4_epoll.zig`, `examples/fix_server_trading.zig`, `examples/fix_client.zig`, `examples/fix_client_raw.zig`, `examples/fix_client_trading.zig`, dan [`docs/hld-fix-id.md`](docs/hld-fix-id.md) untuk detail.

<br>

## UDS (Unix Domain Sockets)

IPC dalam host yang sama melalui Unix stream socket. Server menerima koneksi dan mendispatch masing-masing sebagai tugas concurrent. Kedua sisi menggunakan format frame dengan length prefix 4 byte.

```zig
// Proses A: server UDS (penyedia data)
pub fn main(process: std.process.Init) !void {
    var server = try zix.Uds.Server.init(.{
        .path      = "/tmp/app.sock",
        .allocator = std.heap.smp_allocator,
    });
    defer server.deinit();
    try server.run(process.io);        // echo handler bawaan
    // try server.runWith(process.io, myHandler); // handler kustom
}
```

```zig
// Proses B: client UDS (konsumer)
var client = try zix.Uds.Client.connect(.{ .path = "/tmp/app.sock" }, io);
defer client.deinit(io);

try client.sendMsg(io, "get");              // mengirim [u32 len][payload]
var buf: [4096]u8 = undefined;
const reply = try client.recvMsg(io, &buf); // membaca [u32 len][payload]
```

Handler kustom: menerima stream mentah secara langsung:

```zig
fn myHandler(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);
    // baca/tulis frame menggunakan stream.reader() dan stream.writer()
}

try server.runWith(process.io, myHandler);
```

**Format frame:** `[u32 payload_len, native LE, 4 bytes][payload bytes]`. Frame dengan payload > `max_msg_len` (default 4096) menutup koneksi.

Lihat `examples/uds_server.zig` dan `examples/uds_http.zig` untuk contoh lengkap yang berfungsi. Untuk detail desain lihat [`docs/hld-uds-id.md`](docs/hld-uds-id.md).

<br>

## Channel

Pengiriman pesan dalam proses yang aman untuk fiber dan bertipe. Antrian ring buffer yang menghubungkan tugas producer dan consumer (OS thread atau fiber `io.concurrent`) dalam proses yang sama.

```zig
const MyChan = zix.Channel(u32);

// kapasitas 8: send memblokir saat penuh, recv memblokir saat kosong
var ch = try MyChan.init(std.heap.smp_allocator, 8);
defer ch.deinit();

// producer (berjalan di thread/task-nya sendiri)
try ch.send(io, 42);
ch.close(io); // sinyal selesai: receiver menguras, lalu mendapatkan error.Closed

// consumer (berjalan di thread/task-nya sendiri)
while (true) {
    const v = ch.recv(io) catch break; // error.Closed ketika channel dikuras dan ditutup
    // proses v
}
```

`send` dan `recv` memerlukan `io` yang valid di thread pemanggil. Setiap OS thread memerlukan `std.Io`-nya sendiri (misalnya dari `std.Io.Threaded`):

```zig
var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
defer threaded.deinit();
const io = threaded.io();

const t = try std.Thread.spawn(.{}, workerFn, .{ &ch, io });
t.join();
```

| Contoh | Pola |
| :- | :- |
| `examples/channel_basic.zig` | Producer/consumer: dua OS thread, Channel(u32) |
| `examples/channel_worker_pool.zig` | Fan-out: satu producer, banyak consumer worker |
| `examples/channel_pipeline.zig` | Pipeline multi-tahap: backpressure mengalir ke hulu |
| `examples/channel_ipc_a.zig` + `ipc_b.zig` | Pasangan koordinasi antar-proses |
| `examples/uds_http.zig` | HTTP + UDS + Channel: pola integrasi penuh |

Untuk detail desain lihat [`docs/hld-channel-id.md`](docs/hld-channel-id.md).

<br>

## UDP

Server dan client UDP yang aman tipe. Pengguna mendefinisikan `extern struct` paket mereka sendiri. Zix menangani endianness, validasi ukuran, dan konkurensi.

```zig
const std = @import("std");
const zix = @import("zix");

const Packet = extern struct {
    id:       [16]u8,
    kind:     i32,
    register: u32,
    position: [3]f64,
};

const MyServer = zix.Udp.Server(Packet);

pub fn main(process: std.process.Init) !void {
    var server = try MyServer.init(.{
        .allocator  = std.heap.smp_allocator,
        .ip         = "127.0.0.1",
        .port       = 9100,
        .port_mode  = .REQUIRED,
        .endianness = .LITTLE,
        .broadcast  = true,   // relay setiap paket ke semua client yang terhubung
        .auto_ack   = false,
        .disconnect_timeout_ms = 5000,
        .poll_timeout_ms       = 2000,
    });
    defer server.deinit();
    try server.run(process.io);
}
```

Client (send + receive concurrent):

```zig
const MyClient = zix.Udp.Client(Packet);

pub fn main(process: std.process.Init) !void {
    const io = process.io;
    var client = try MyClient.init(.{
        .server_ip   = "127.0.0.1",
        .server_port = 9100,
        .bind_port   = 9101,
        .port_mode   = .REQUIRED,
        .endianness  = .LITTLE,
        .send_every  = 1000,
    }, io);
    defer client.deinit();

    // spawn tugas receive bersamaan dengan loop send
    _ = io.concurrent(receiveLoop, .{&client}) catch {};

    const p = Packet{ .id = [_]u8{0} ** 16, .kind = 1, .register = 0, .position = .{ 0.0, 0.0, 0.0 } };
    while (true) {
        client.send(p) catch {};
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .awake);
    }
}
```

Lihat `examples/udp_server.zig` dan `examples/udp_client.zig` untuk contoh lengkap yang berfungsi dengan broadcast dan port yang dapat dikonfigurasi. Untuk detail desain lihat [`docs/hld-udp-id.md`](docs/hld-udp-id.md).

<br>

## Logger

Logger file terstruktur dengan logging event per-protokol otomatis. Thread-safe: aman dipanggil dari OS thread latar belakang.

```zig
const std = @import("std");
const zix = @import("zix");

// Logger tidak membuat save_path secara otomatis, tanggung jawab pemanggil.
// Mengabaikan "already exists" secara diam-diam, aman dipanggil setiap start.
fn createLogDir(io: std.Io) void {
    std.Io.Dir.cwd().createDirPath(io, "./logs") catch {};
}

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    createLogDir(process.io);

    var logger = try zix.Logger.init(arena.allocator(), .{
        .save_path      = "./logs",
        .save_file      = "app",
        .save_min_level = .INFO,
        .console        = .ALWAYS,
    });
    defer logger.deinit();

    // Event sistem: komponen mana saja, level mana saja
    logger.system(.INFO,  "startup", "listening on {d}", .{9000});
    logger.system(.ERROR, "db",      "connect failed: {}", .{error.ConnectionRefused});

    // Pasangkan ke server HTTP untuk logging akses per-permintaan otomatis
    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/", .handler = homeHandler },
    }, .{
        .io     = process.io,
        .ip     = "127.0.0.1",
        .port   = 9000,
        .logger = &logger,
    });
    defer server.deinit();
    try server.run();
}
```

File log ditulis ke `save_path/YYYY-MM-DD/save_file-NNNNNN.log`. Setiap baris adalah rekaman yang diakhiri newline:

```
# Format event sistem:
2026-05-16 12:34:56.789 INFO   [startup] listening on 9000
2026-05-16 12:34:56.789 ERROR  [db] connect failed: ConnectionRefused

# Format akses HTTP (2xx/3xx=INFO, 4xx=WARN, 5xx=ERROR, lainnya=DEBUG):
2026-05-16 12:34:56.789 INFO   GET /api/users 200 512 "MyBot/2.0" "http://example.com"
2026-05-16 12:34:56.789 WARN   GET /missing 404 0 "-" "-"
2026-05-16 12:34:56.789 ERROR  POST /crash 500 0 "-" "-"

# Penutupan stream gRPC:
2026-05-25 10:15:33.201 INFO   [grpc:rpc] 127.0.0.1:56789 /helloworld.Greeter/SayHello status=0 recv=16 sent=22 dur=1ms
```

| Field config | Default | Keterangan |
| :- | :- | :- |
| `console` | `.OFF` | Mode konsol: `.OFF`, `.DEBUG_ONLY` (hanya debug build), `.ALWAYS` |
| `console_min_level` | `.INFO` | Level minimum untuk output konsol |
| `save_path` | `""` | Root direktori untuk file log. Harus sudah ada. `""` menonaktifkan file logging |
| `save_file` | `"log"` | Nama file dasar. `"log"` menulis `log-000000.log`, `log-000001.log`, ... |
| `save_min_level` | `.INFO` | Level minimum untuk output file |
| `max_lines` | 1.000.000 | Baris per file sebelum berotasi ke nomor urut berikutnya |

**Metode log per-protokol:**

| Metode | Dipanggil otomatis oleh | Format baris |
| :- | :- | :- |
| `system(level, component, fmt, args)` | semua server (lifecycle) | `DATE TIME LEVEL  [component] message` |
| `access(method, path, status, bytes, ua, origin)` | server HTTP | `DATE TIME LEVEL  METHOD PATH STATUS BYTES "UA" "ORIGIN"` |
| `conn(peer, dur_ms, err)` | server TCP | `DATE TIME LEVEL  [tcp:conn] PEER dur=NNNms ERR` |
| `packet(dir, peer, size, err)` | server UDP | `DATE TIME LEVEL  [udp:pkt] DIRECTION PEER size=N ERR` |
| `frame(dir, sock_path, size, err)` | UDS (manual) | `DATE TIME LEVEL  [uds:frame] DIRECTION SOCKPATH size=N ERR` |
| `session(msg_type, sender, target, seq, state)` | server FIX | `DATE TIME LEVEL  [fix:sess] 35=TYPE sender=S target=T seq=N STATE` |
| `rpc(peer, path, grpc_status, recv, sent, dur_ms)` | server gRPC | `DATE TIME LEVEL  [grpc:rpc] PEER PATH status=N recv=N sent=N dur=Nms` |

Level: `.DEBUG`(0) `.INFO`(1) `.WARN`(2) `.ERROR`(3). Backend file menggunakan write buffer 64 KB yang di-flush saat rollover tanggal, rotasi urutan, `logger.flush()` eksplisit, atau `logger.deinit()`.

Pasangkan logger ke server mana saja dengan mengatur `logger: &logger` di konfigurasinya. Lihat [`docs/hld-logger-id.md`](docs/hld-logger-id.md) untuk dokumentasi lengkap.

<br>

## Pengujian

```sh
zig build unit-test        # pengujian unit (tes inline src/)
zig build integration-test # pengujian integrasi (komponen terhubung)
zig build behaviour-test   # pengujian behaviour (kontrak API yang dapat diamati)
zig build edge-test        # pengujian edge (kondisi batas dan jalur error)
zig build test-all         # semua di atas
```

`zig build` saja tidak menjalankan tes. Lihat [`docs/tests-id.md`](docs/tests-id.md) untuk detail cakupan lengkap.

<br>

## Model Memori

### HTTP

| Cakupan | Allocator | Masa hidup |
| :- | :- | :- |
| Tabel rute | comptime (tanpa biaya heap) | N/A |
| Buffer I/O baca/tulis | `smp_allocator` | Koneksi |
| Alokasi per-permintaan (`ctx.allocator`) | `ArenaAllocator` per-koneksi, direset setiap permintaan | Permintaan |

Handler menerima `ctx.allocator`, sebuah arena yang direset di antara permintaan. Alokasi apa pun yang dibuat di dalam handler secara otomatis direklamasi di akhir permintaan tanpa panggilan `free`.

Rute dibuat dalam tipe server pada waktu kompilasi: tidak diperlukan allocator untuk penyimpanan rute.

### UDP

| Cakupan | Allocator | Masa hidup |
| :- | :- | :- |
| Daftar rekaman client | `config.allocator` (milik pemanggil) | Masa hidup proses server |
| Snapshot peer (broadcast) | `config.allocator` | Dispatch satu paket |
| Buffer terima | Stack | Satu iterasi loop terima |

`config.allocator` harus berupa general-purpose allocator (misalnya `std.heap.smp_allocator`). `ArenaAllocator` tidak cocok: snapshot peer broadcast dialokasikan dan dibebaskan per paket: `ArenaAllocator.free()` adalah no-op, sehingga snapshot menumpuk tanpa batas hingga server berhenti. Lihat [`docs/hld-udp-id.md`](docs/hld-udp-id.md) untuk penjelasan lengkap dan PoC.

### HTTP/2 dan gRPC

Keduanya menggunakan array stream per-koneksi yang dialokasikan heap (alokasi stack dari `max_streams` struct `Stream` akan meluap stack thread). Tidak ada allocator per-permintaan yang diekspos: handler menerima I/O frame mentah via `GrpcContext` (gRPC) atau `fd`/`sid` (HTTP/2).

Untuk detail memori lengkap lihat [`docs/hld-http-id.md`](docs/hld-http-id.md) dan [`docs/hld-udp-id.md`](docs/hld-udp-id.md). Untuk model threading lihat [`docs/concurrency-id.md`](docs/concurrency-id.md).

<br>

## Important Notes

Saat ini Zix berfokus pada Linux.

Dalam kondisi saat ini, zix tidak akan:
- Implementasi TLS.
- Implementasi database driver.
- Implementasi Http2 (hanya sebagai gRPC dependency).
- Implementasi Http3.

Lihat [swerver](https://github.com/justinGrosvenor/swerver) untuk TLS, HTTP/2, HTTP/3 untuk pendekatan lengkap terkait topik tersebut.

<br>

## Benchmark

__*HttpArena*__ <br>
Website: https://www.http-arena.com <br>
Project repo: https://github.com/MDA2AV/HttpArena <br>

<details open>
<summary>zix 0.3.x</summary>

Http/1.1 <br>
[PR](https://github.com/MDA2AV/HttpArena/pull/852) <br>
[Implementasi](https://github.com/MDA2AV/HttpArena/tree/main/frameworks/zix) <br>
| Test | Conn | RPS | CPU | Mem |
| :- | :- | :- | :- | :- |
| baseline | 512 | 3,717,345 | 6397.5% | 84MiB |
| baseline | 4096 | 3,720,118 | 6592.6% | 127MiB |
| pipelined | 512 | 34,397,468 | 6645.7% | 82MiB |
| pipelined | 4096 | 34,429,158  | 6731.0% | 125MiB |
| limited-conn | 512 | 2,509,394 | 5408.3% | 104MiB |
| limited-conn | 4096 | 2,759,549 | 6109.7% | 172MiB |
| json | 4096 | 2,355,180 | 6153.5% | 146MiB |
| upload | 32 | 7,889 | 1186.0% | 71MiB |
| upload | 256 | 6,490 | 1004.0% | 79MiB |
| static | 1024  | 2,024,603 | 5471.0% | 89MiB |
| static | 4096 | 1,999,691 | 5292.6% | 138MiB |
| static | 6800 | 1,922,451  | 5014.4% | 188MiB |
| echo-ws | 512 | 3,772,118 | 6428.6% | 82MiB |
| echo-ws | 4096 | 3,818,104 | 6572.2% | 124MiB |
| echo-ws | 16384 | 3,703,042 | 6476.4% | 278MiB |
| echo-ws-pipeline | 512 | 58,349,772 | 6566.9% | 81MiB |
| echo-ws-pipeline | 4096 | 58,360,489 | 6585.4% | 126MiB |
| echo-ws-pipeline | 16384 | 57,239,628 | 6453.2% | 273MiB |

gRPC <br>
[PR](https://github.com/MDA2AV/HttpArena/pull/865) <br>
[Implementasi](https://github.com/MDA2AV/HttpArena/tree/main/frameworks/zix-grpc) <br>
| Test | Conn | RPS | CPU | Mem |
| :- | :- | :- | :- | :- |
| unary-grpc | 256 | 7,145,739 | 3859.3% | 347MiB |
| unary-grpc | 1024 | 7,046,038 | 4066.4% | 1.1GiB |
| stream-grpc | 64 | 8,472,000 | 45.8% | 89MiB |

<details>

<br>

---

###### end of readme
