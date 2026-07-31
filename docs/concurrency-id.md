# Model Konkurensi: zix

Tiga model dispatch untuk HTTP dan raw TCP. Pilih melalui `config.dispatch_model` (enum `DispatchModel`) di `HttpServerConfig` atau `TcpServerConfig`. Wajib: setel secara eksplisit (tidak ada default).

---

## DispatchModel

```zig
pub const DispatchModel = enum(u8) {
    ASYNC = 0, // single accept, io.async() dispatch, satu-satunya model portabel
    EPOLL = 1, // shared-nothing epoll workers, Linux-only
    URING = 2, // shared-nothing io_uring workers, Linux-only
};
```

Didefinisikan sekali di `src/tcp/config.zig`. Diekspor ulang oleh `src/tcp/http/config.zig` (untuk `zix.Http`) dan diimpor oleh `src/tcp/http2/grpc/config.zig` (untuk `zix.Grpc`). Ketiga nilai tersedia di setiap konfigurasi.

`.EPOLL = 1` hanya tersedia di Linux. `zix.Http` (HTTP/1), `zix.Http1`, `zix.Http2`, `zix.Grpc`, `zix.Fix`, dan `zix.Tcp` mengimplementasikannya secara native di Linux. `.URING = 2` juga hanya tersedia di Linux dan native di `zix.Http1`, `zix.Http`, `zix.Http2`, `zix.Grpc`, dan `zix.Fix`. Handler per-connection `zix.Tcp` melipat ke `.EPOLL` (callback framed `zix.Tcp` menjalankan ring secara native). Lihat tabel Perbandingan Model Dispatch di bawah.

Di luar Linux tidak ada penurunan diam-diam: `run()` mengembalikan `error.DispatchModelUnsupported` saat model-nya `.EPOLL` atau `.URING`, jadi pemanggil tidak pernah mengira mendapat model yang tidak ia dapatkan (ADR-065). Pemanggil portabel memilih model per target saat comptime:

```zig
const builtin = @import("builtin");

const DISPATCH_MODEL: zix.Http1.DispatchModel = if (builtin.os.tag == .linux) .URING else .ASYNC;
```

Gate-nya satu predikat bersama, `zix.utils.dispatch_support.isSupported`, yang dikonsultasi oleh `run()` setiap engine sebelum ia mem-bind listener atau men-spawn thread TLS. Jadi config yang ditolak tidak meninggalkan apa pun.

---

## .ASYNC: Single Accept, Dispatch io.async()

Satu accept thread mendispatch setiap koneksi yang diterima sebagai concurrent task melalui `io.async()` (non-blocking). Pemanggil memiliki backend `std.Io`. Paling baik untuk beban kerja latensi rendah dan koneksi yang berumur panjang (SSE, WebSocket), dan satu-satunya model yang tersedia di semua platform.

```
Main thread:
  bind -> listen
  loop:
    stream = accept(io)
    io.async(handleConnection, stream)   <- suspends, OS event loop schedules task

Handler tasks (one per active connection):
  handleConnection(stream)  // keep-alive loop until client closes
  task exits when connection closes
```

**Kapan menggunakan:**
- Target non-Linux apa pun: `.EPOLL` dan `.URING` ditolak di sana, jadi ini model yang dipilih.
- SSE dan WebSocket: satu stream terbuka hanya memakai satu task, bukan slot worker event loop.
- Perlu `concurrent_limit` eksplisit (deployment dengan sumber daya terbatas).
- `dispatch_model = .ASYNC` di `HttpServerConfig`.
- `workers` diabaikan (selalu tepat satu accept thread).

**Contoh** (`examples/http_sse.zig`, `examples/http_websocket.zig`):
```zig
var server = zix.Http.Server.init(zix.Http.Router(&[_]zix.Http.Route{
    .{ .path = "/events", .handler = eventsHandler },
}).dispatch, .{
    .io             = process.io,
    .dispatch_model = .ASYNC,
});
```

**Batas konkurensi manual** (`examples/http_manual_concurrent.zig`):
```zig
var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{
    .concurrent_limit = std.Io.Limit.limited(4),
});
defer threaded.deinit();

var server = zix.Http.Server.init(zix.Http.Router(&[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}).dispatch, .{
    .io             = threaded.io(),
    .dispatch_model = .ASYNC,
});
```

---

## .EPOLL: Shared-Nothing epoll Event Loop (Linux-only)

Setiap worker memiliki `SO_REUSEPORT` listener dan `epoll` instance tersendiri. Kernel
mendistribusikan koneksi baru ke listener per-worker. Tidak ada queue bersama, tidak ada
handoff fd antar thread. Setiap worker menerima, mendaftarkan, membaca, dan merespons
koneksinya sendiri tanpa menyentuh state worker lain.

**Mengapa ini ada:** `.ASYNC` membayar biaya wakeup lintas thread pada setiap koneksi yang
diterima (melalui fiber scheduler `io.async()`), dan hanya satu thread yang menerima. Pada
jumlah koneksi sangat tinggi di mana koneksi cepat namun banyak yang tumpang tindih, jalur
accept tunggal itu dan hand-off scheduler-nya sama-sama menjadi bottleneck. Dengan
shared-nothing, setiap worker menerima langsung di listenernya sendiri dan menangani semua I/O
secara inline: tanpa mutex, tanpa condvar, tanpa handoff fd.

```
Worker (workers, default cpu_count):
  resolve + listen pada port yang sama dengan SO_REUSEPORT
  epoll_create1
  epoll_ctl(ADD, listener_fd, EPOLLIN)        <- pemicu accept loop

  event loop:
    epoll_wait(events, EPOLL_MAX_EVENTS)        <- Http: 1024, Http1: 4096
    untuk setiap event:
      if listener_fd:
        loop: fd = accept4(SOCK_CLOEXEC)
              setNoDelay(fd)
              epoll_ctl(ADD, fd, EPOLLIN | EPOLLRDHUP)
      else:   // fd koneksi
        if HUP atau ERR atau RDHUP:
          epoll_ctl(DEL, fd)
          close(fd)
        else:
          handleOneRequest(fd)   <- blocking read/write, tanpa fiber
          if keep-alive: tetap terdaftar (level-triggered, re-fires saat data baru tiba)
          if close: epoll_ctl(DEL, fd) + close(fd)
```

Koneksi tetap terdaftar setelah setiap request. Tidak perlu re-arm eksplisit: level-triggered
`EPOLLIN` re-fires setiap kali data baru tiba. Koneksi keep-alive idle tidak menahan thread
dan hanya menempati satu entri di epoll set per-worker.

**Kapan menggunakan:**
- Deployment produksi Linux untuk `zix.Http` atau `zix.Http1` dengan jumlah koneksi tinggi.
- Request berumur pendek (REST, API) di mana `handleOneRequest` selesai cepat dan mengembalikan
  worker ke `epoll_wait`.
- Ingin menghindari overhead fiber scheduler `io.async()` sepenuhnya.
- `dispatch_model = .EPOLL` di `HttpServerConfig` atau `Http1ServerConfig`.
- `workers` mengontrol jumlah worker (0 = cpu_count) di setiap engine.

**Contoh (`zix.Http`):**
```zig
var server = zix.Http.Server.init(zix.Http.Router(&[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}).dispatch, .{
    .io             = process.io,
    .dispatch_model = .EPOLL,
    .workers        = 0, // 0 = cpu_count worker (default)
});
try server.run();
```

**Contoh (`zix.Grpc`):**
```zig
var server = zix.Grpc.Server.init(
    &[_]zix.Grpc.Route{
        .{ .path = "/helloworld.Greeter/SayHello", .handler = sayHello },
    },
    .{
        .io             = process.io,
        .dispatch_model = .EPOLL,
    },
);
try server.run();
```

**Biaya dan pertimbangan:**

| Item | Detail |
| :- | :- |
| Platform | Hanya Linux (`epoll_create1`, `epoll_wait`, `epoll_ctl`). Di luar Linux, `run()` mengembalikan `error.DispatchModelUnsupported` setelah mencatat model mana yang ditolak |
| Ketersediaan | `zix.Http` (HTTP/1), `zix.Http1`, `zix.Http2`, `zix.Grpc`, `zix.Fix`, dan `zix.Tcp` diimplementasikan secara native di Linux |
| Model accept (`zix.Http`) | Setiap worker memiliki `SO_REUSEPORT` listener tersendiri. Kernel mendistribusikan koneksi ke worker: tanpa antrian accept bersama |
| Perbedaan gRPC | `zix.Grpc` menggunakan model multiplexed shared-nothing: satu worker mendrive banyak koneksi h2 non-blocking via resumable state machine. Lihat ADR-031 |
| Field `workers` | Mengontrol jumlah worker di setiap engine (0 = cpu_count) |
| Biaya idle keep-alive | Hampir nol: socket idle duduk di epoll set tanpa menahan thread apapun |
| Debugging | `strace` atau `perf` akan menampilkan `epoll_wait` mendominasi waktu idle, ini adalah perilaku yang diharapkan dan benar |

**Kapan TIDAK menggunakan:**
- SSE atau WebSocket via `zix.Http`: koneksi tetap aktif dan data mengalir terus-menerus, blocking read akan menahan worker. Gunakan `.ASYNC`.
- Target non-Linux: `run()` menolak model-nya, jadi pilih `.ASYNC` secara eksplisit.
- Ketika jumlah koneksi rendah (< beberapa ratus): model `.ASYNC` yang lebih sederhana akan memiliki performa yang sama atau lebih baik dengan kompleksitas yang lebih rendah.

---

## .URING: Event Loop io_uring Shared-Nothing (Linux-only)

`.URING` adalah saudara completion-based dari `.EPOLL`: topologi thread-per-core, shared-nothing yang sama (satu `SO_REUSEPORT` listener dan satu ring per worker, tanpa queue bersama, tanpa perpindahan fd antar thread), tetapi accept, read, dan write disubmit sebagai SQE io_uring dan dipanen sebagai CQE alih-alih menunggu readiness `epoll_wait`. Sebagian besar transisi syscall di-batch ke dalam ring (ADR-037 Fase 4).

- Engine native: `zix.Http1`, `zix.Http`, `zix.Http2`, `zix.Grpc`, `zix.Fix`. Handler per-connection `zix.Tcp` tidak punya ring native dan melipat ke `.EPOLL` (callback framed `zix.Tcp` menjalankan ring). Di luar Linux, `run()` mengembalikan `error.DispatchModelUnsupported`.
- `workers` menentukan jumlah worker di setiap engine, persis seperti `.EPOLL`.
- Di loopback `.URING` setara `.EPOLL` pada throughput dan total CPU, menang terutama pada cache locality per-request. Di mesin many-core, ring close (`prep_close`, ADR-041) membuat worker terus memanen completion lintas connection churn alih-alih memblokir di `close` sinkron, jadi `.URING` mencapai paritas atau lebih baik dari `.EPOLL` di setiap beban yang diukur dengan memori jauh lebih sedikit.
- Ketika io_uring sendiri tidak tersedia di host (kernel lama, `RLIMIT_MEMLOCK` rendah, sandbox), engine melipat ke loop `.EPOLL` dengan notice yang dicatat. Itu capability gap saat runtime di platform yang didukung, bukan penolakan platform di atas.
- "Kapan tidak digunakan" sama dengan `.EPOLL`: SSE / WebSocket di `zix.Http`, jumlah koneksi rendah, target non-Linux.

---

## Mengapa Dispatch Loop Per-Engine

Tiap engine memegang dispatch loop-nya sendiri (`.ASYNC` / `.EPOLL` / `.URING`) di `server.zig`-nya masing-masing, bukan di belakang satu multiplexer generik. Pemisahan ini disengaja dan justru merupakan optimasinya: kepemilikan per-engine membuat tiap engine menyetel hot path-nya untuk bentuk koneksinya sendiri.

Contoh paling jelas adalah connection table `.EPOLL`, yang tampak sebagai bagian paling terduplikasi tetapi sebenarnya terspesialisasi per engine:

| Engine | Connection table | Alokasi | Alasan |
| :- | :- | :- | :- |
| `zix.Http1` | slab contiguous demand-paged | tanpa heap call per-accept | buffer diukir dari satu slab `MAX_FD * buf_size`, slot kosong adalah `buf.len == 0` |
| `zix.Grpc` | pointer heap per-koneksi | satu objek heap per accept | koneksi membawa state h2 + HPACK resumable, terlalu besar dan variabel untuk satu sel slab tetap |
| `zix.Fix` | pointer heap per-koneksi | satu objek heap per accept | koneksi membawa state sesi FIX (nomor urut, timing heartbeat) |

Satu loop generik akan memaksakan satu bentuk connection-table ke setiap engine (menghapus keuntungan slab) dan menambah indireksi callback-per-event di jalur accept / recv / send, yang merupakan jalur terpanas di library.

Hanya primitive byte-identical yang dibagikan, di `src/multiplexers/`. Saat ini itu adalah codec `user_data` `.URING` (`ring.zig`): setiap engine io_uring harus mem-pack bit yang sama (slot ber-key fd yang dijaga oleh generation dalam satu layout), jadi codec-nya diangkat keluar sementara ring loop dan slot table tetap per-engine. Aturannya: bagikan primitive yang harus cocok, pertahankan dispatch loop per-engine. Lihat ADR-042.

---

## Jumlah Thread

| Field | Default | Makna |
| :- | :- | :- |
| `dispatch_model = .ASYNC` | single accept, io.async() | 1 accept thread, io.async() per koneksi |
| `dispatch_model = .EPOLL` | worker epoll shared-nothing | satu worker per core, masing-masing dengan listener dan epoll instance sendiri |
| `dispatch_model = .URING` | worker io_uring shared-nothing | satu worker per core, masing-masing dengan listener dan ring sendiri |
| `workers = 0` | cpu_count thread | jumlah worker untuk `.EPOLL` dan `.URING` di setiap engine, diabaikan oleh `.ASYNC` |
| `workers = N` | N thread | jumlah worker eksplisit untuk `.EPOLL` dan `.URING`, diabaikan oleh `.ASYNC` |

---

## Perbandingan Model Dispatch

| | `.ASYNC` | `.EPOLL` | `.URING` |
| :- | :- | :- | :- |
| Accept thread | 1 | cpu_count (atau N) | cpu_count (atau N) |
| Dispatch koneksi | task `io.async()` | epoll per-worker, level-triggered | io_uring per-worker, completion-based |
| Overhead scheduler | ada (condvar wakeup) | tidak ada (epoll, Linux only) | tidak ada (ring, Linux only) |
| `SO_REUSEPORT` | tidak | ya (listener per-worker) | ya (listener per-worker) |
| Field `workers` digunakan | tidak (diabaikan) | ya | ya |
| Platform | semua | hanya Linux | hanya Linux |
| Terbaik untuk | SSE, WebSocket, latensi rendah, non-Linux | HTTP/1 atau gRPC throughput tinggi di Linux | sama seperti `.EPOLL`, memori lebih rendah saat churn |
| Tersedia di | Http, Http1, Http2, Grpc, Tcp, Fix | Http, Http1, Http2, Grpc, Fix, Tcp | Http, Http1, Http2, Grpc, Fix (Tcp melipat ke `.EPOLL`) |

---

## Penerapan per Protokol

| Protokol | `.ASYNC` | `.EPOLL` | `.URING` |
| :- | :- | :- | :- |
| HTTP | ya | ya, Linux-only | ya, Linux-only |
| SSE | ya, direkomendasikan | n/a | n/a |
| WebSocket | ya, direkomendasikan | n/a | n/a |
| HTTP/2 (h2c) | ya | ya, Linux-only | ya, Linux-only |
| HTTP/3 (QUIC) | ya (single worker) | ya, Linux-only | ya, Linux-only |
| gRPC (h2c) | ya | ya, Linux-only | ya, Linux-only |
| TCP (raw stream) | ya | ya, Linux-only | hanya callback framed, handler per-connection melipat ke `.EPOLL` |
| FIX 4.x | ya | ya, Linux-only | ya, Linux-only |
| UDP (raw) | ya (single worker) | ya, Linux-only | ya, Linux-only |
| UDS (stream) | ya (io.concurrent() per koneksi) | n/a | n/a |

Http3 di bawah `.EPOLL` / `.URING` menjalankan worker per-core sungguhan (CID steering lintas core untuk migrasi mid-connection adalah v2, ADR-049 fase 3).

---

## Backend Lintas-Platform (rencana)

Setiap model menamai dua hal sekaligus: bentuk konkurensi (single atau multi-core) dan, untuk model per-core, sebuah I/O backend. Backend bersifat OS-specific. Kontraknya: OS menukar backend, bukan sifat single-atau-multi dari model.

| Model | Perilaku core | OS | Status |
| :- | :- | :- | :- |
| `.ASYNC` | single | semua | sekarang |
| `.EPOLL` | multi (per-core) | Linux | sekarang |
| `.URING` | multi (per-core) | Linux | sekarang |
| `.KQUEUE` | multi (per-core) | macOS / BSD | rencana |
| `.IOCP` | multi (per-core) | Windows | rencana |

`.EPOLL`, `.KQUEUE`, dan `.IOCP` adalah ide multi-core per-core yang sama, satu per sistem operasi. Masing-masing berada di file `dispatch/<model>.zig` sendiri, sehingga folder-nya self-documenting: buka, lihat setiap model, tiap baris header menyatakan perilaku core dan OS-nya.

Seperti `.EPOLL` dan `.URING` saat ini, backend ini whole-family: setiap engine yang memilih `DispatchModel` (`zix.Http`, `zix.Http1`, `zix.Http2`, `zix.Http3`, `zix.Grpc`, `zix.Tcp`, `zix.Fix`, `zix.Udp`) mendapat backend platform-nya lewat enum yang sama.

Tidak ada keyword auto-select. Kode portable memilih `.ASYNC` langsung atau menamai backend yang tepat dengan satu baris comptime switch pada `builtin.os.tag`. Dua ketidakcocokan ditangani berbeda:

- Backend yang tidak bisa berjalan di OS target (misalnya `.EPOLL` di luar Linux) ditolak oleh `run()` dengan `error.DispatchModelUnsupported`. Ini config error, dilaporkan alih-alih diakali (ADR-065).
- Backend yang ada tapi tidak bisa dipakai mesin saat runtime (misalnya `.URING` di kernel lama) di-fold ke model yang bekerja dengan notice yang dicatat. Ini capability gap di platform yang memang mendukung model tersebut.

Sampai backend macOS dan Windows hadir, `.ASYNC` adalah model untuk setiap target non-Linux. `.KQUEUE` dan `.IOCP` hanya nama yang dipesan, belum diimplementasikan dan tidak hadir sebagai file source. Keduanya juga butuh maintainer sebelum bisa hadir: model yang zix pertahankan adalah model yang bisa ia rawat, dan itulah alasan `.POOL` dan `.MIXED` dilepas di ADR-065. Lihat ADR-050 dan ADR-065.

---

## Channel

`zix.Channel` **bukan** model konkurensi. Channel adalah primitif pengiriman pesan dalam proses yang bekerja berdampingan dengan ketiga model dispatch. Channel menghubungkan producer dan consumer task (OS thread atau fiber `io.async()`) di dalam proses yang sama. Channel tidak melintasi batas jaringan atau batas proses.

```
Producer task --> [ Channel(T) ring buffer ] --> Consumer task
```

Ketiga model dispatch dapat menghasilkan task `io.async()` atau OS thread yang berkomunikasi melalui Channel. Channel itu sendiri tidak bergantung pada model dispatch yang sedang digunakan.

| Properti | Channel |
| :- | :- |
| Melintasi batas proses/jaringan | tidak (hanya dalam proses) |
| Bekerja dengan task `io.async()` | ya, menggunakan `std.Io.Mutex` + `std.Io.Condition` (fiber-aware) |
| Bekerja dengan OS thread | ya: setiap thread membutuhkan `std.Io` sendiri dari `std.Io.Threaded` |
| Menggantikan model dispatch | tidak (ortogonal) |

Status: Sudah diimplementasikan. Lihat ADR-017 dan [`docs/hld-channel-id.md`](hld-channel-id.md).

---

###### end of concurrency
