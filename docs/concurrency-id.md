# Model Konkurensi: zix

Lima model dispatch untuk HTTP dan raw TCP. Pilih melalui `config.dispatch_model` (enum `DispatchModel`) di `HttpServerConfig` atau `TcpServerConfig`. Default: `.ASYNC`.

---

## DispatchModel

```zig
pub const DispatchModel = enum(u8) {
    ASYNC = 0, // single accept, io.async() dispatch
    POOL  = 1, // work-queue thread pool
    MIXED = 2, // N accept threads, each dispatching via io.async()
    EPOLL = 3, // shared-nothing epoll workers, Linux-only
    URING = 4, // shared-nothing io_uring workers, Linux-only
};
```

Didefinisikan sekali di `src/tcp/config.zig`. Diekspor ulang oleh `src/tcp/http/config.zig` (untuk `zix.Http`) dan diimpor oleh `src/tcp/http2/grpc/config.zig` (untuk `zix.Grpc`). Kelima nilai tersedia di setiap konfigurasi.

`.EPOLL = 3` hanya tersedia di Linux. `zix.Http` (HTTP/1), `zix.Grpc`, `zix.Fix`, dan `zix.Tcp` mengimplementasikannya secara native di Linux. `zix.Http2` dan build non-Linux akan fallback ke `.POOL` secara otomatis. `.URING = 4` juga hanya tersedia di Linux dan native di `zix.Http1`, `zix.Http`, `zix.Grpc`, dan `zix.Fix`. `zix.Http2` melipat ke `.POOL` dan handler per-connection `zix.Tcp` melipat ke `.EPOLL` (callback framed `zix.Tcp` menjalankan ring secara native). Lihat tabel Perbandingan Model Dispatch di bawah.

---

## .POOL: Work-Queue Thread Pool

N accept thread mendorong koneksi yang diterima ke `ConnQueue` bersama. M pool thread mengambil koneksi dan menanganinya secara sinkron dengan blocking I/O. `SO_REUSEPORT` memungkinkan semua accept thread mendengarkan port yang sama secara paralel.

```
Main thread:
  create ConnQueue + std.Io.Threaded backend
  spawn pool_size pool threads
  spawn worker_count accept threads
  join accept threads -> queue.close() -> join pool threads

Accept threads (worker_count, default cpu_count):
  bind/listen on same port with SO_REUSEPORT
  loop:
    stream = accept(io)
    queue.push(stream)   <- fast, never blocks on I/O

Pool threads (pool_size, default max(10, cpu_count * 2)):
  loop:
    stream = queue.pop()          <- blocks until a connection arrives
    handleConnection(stream, io)  <- synchronous blocking I/O, keep-alive loop
    (loop, next pop)
```

**Kapan menggunakan:**
- Throughput terbaik pada jumlah koneksi yang tinggi.
- `dispatch_model = .POOL` (eksplisit).
- `workers = 0` (default) menggunakan cpu_count accept thread.
- `workers = N` menggunakan tepat N accept thread.
- `pool_size = 0` (default) mengatur ukuran pool menjadi `max(10, cpu_count * 2)`.
- `pool_size = N` menggunakan tepat N pool thread.

**Persyaratan OS:** `SO_REUSEPORT` (Linux >= 3.9, macOS, BSD).

**Contoh** (`examples/http_basic.zig` dengan POOL eksplisit):
```zig
pub fn main(process: std.process.Init) !void {
    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/", .handler = homeHandler },
    }, .{
        .io             = process.io,
        .dispatch_model = .POOL,
        // workers   = 0  -> cpu_count accept threads
        // pool_size = 0  -> max(10, cpu_count * 2) pool threads
    });
    try server.run();
}
```

**Jumlah thread eksplisit:**
```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io        = process.io,
    .workers   = 4,   // 4 accept threads
    .pool_size = 32,  // 32 pool threads
});
```

---

## .ASYNC: Single Accept, Dispatch io.async()

Satu accept thread mendispatch setiap koneksi yang diterima sebagai concurrent task melalui `io.async()` (non-blocking). Pemanggil memiliki backend `std.Io`. Paling baik untuk beban kerja latensi rendah dan koneksi yang berumur panjang (SSE, WebSocket) di mana pool thread tidak boleh diblokir.

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
- SSE dan WebSocket: koneksi berumur panjang menghabiskan pool thread di `.POOL`. `.ASYNC` lebih direkomendasikan.
- Perlu `concurrent_limit` eksplisit (deployment dengan sumber daya terbatas).
- `dispatch_model = .ASYNC` di `HttpServerConfig`.
- `workers` dan `pool_size` diabaikan.

**Contoh** (`examples/http_sse.zig`, `examples/http_websocket.zig`):
```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/events", .handler = eventsHandler },
}, .{
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

var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = threaded.io(),
    .dispatch_model = .ASYNC,
});
```

---

## .MIXED: N Accept Thread, Dispatch io.async()

N accept thread masing-masing mendispatch koneksi melalui `io.async()` secara langsung, tanpa `ConnQueue`. Throughput dan latensi yang seimbang, jitter lebih tinggi dibanding `.POOL` saat saturasi karena fallback `io.async()` ke eksekusi inline.

```
Main thread:
  spawn worker_count accept threads

Accept threads (worker_count, default cpu_count):
  bind -> listen with SO_REUSEPORT
  loop:
    stream = accept(io)
    io.async(handleConnection, stream)
```

**Kapan menggunakan:**
- Paralelisme multi-accept tanpa blocking pool.
- `dispatch_model = .MIXED` di `HttpServerConfig`.
- `pool_size` diabaikan. `workers` mengontrol jumlah accept thread.

**Contoh:**
```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .MIXED,
});
```

---

## .EPOLL: Shared-Nothing epoll Event Loop (Linux-only)

Setiap worker memiliki `SO_REUSEPORT` listener dan `epoll` instance tersendiri. Kernel
mendistribusikan koneksi baru ke listener per-worker. Tidak ada queue bersama, tidak ada
handoff fd antar thread. Setiap worker menerima, mendaftarkan, membaca, dan merespons
koneksinya sendiri tanpa menyentuh state worker lain.

**Mengapa ini ada:** `.POOL` dan `.ASYNC` keduanya membayar biaya wakeup lintas thread pada
setiap koneksi yang diterima (baik melalui `ConnQueue.pop()` maupun melalui fiber scheduler
`io.async()`). Pada jumlah koneksi sangat tinggi di mana koneksi cepat namun banyak yang
tumpang tindih, contention antrian menumpuk. Dengan shared-nothing, worker menerima langsung
di listenernya sendiri dan menangani semua I/O secara inline: tanpa mutex, tanpa condvar,
tanpa handoff fd.

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
- `workers` mengontrol jumlah worker (0 = cpu_count). `pool_size` diabaikan untuk `zix.Http`.

**Contoh (`zix.Http`):**
```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .EPOLL,
    .workers        = 0, // 0 = cpu_count worker (default)
});
try server.run();
```

**Contoh (`zix.Grpc`):**
```zig
var server = try zix.Grpc.Server.init(
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
| Platform | Hanya Linux (`epoll_create1`, `epoll_wait`, `epoll_ctl`). Non-Linux fallback ke `.POOL` secara otomatis (dengan debug print) |
| Ketersediaan | `zix.Http` (HTTP/1), `zix.Grpc`, `zix.Fix`, dan `zix.Tcp` diimplementasikan secara native di Linux. `zix.Http2` fallback ke `.POOL` |
| Model accept (`zix.Http`) | Setiap worker memiliki `SO_REUSEPORT` listener tersendiri. Kernel mendistribusikan koneksi ke worker: tanpa antrian accept bersama |
| Perbedaan gRPC | `zix.Grpc` menggunakan model multiplexed shared-nothing: satu worker mendrive banyak koneksi h2 non-blocking via resumable state machine. `pool_size` sebagai jumlah worker. Lihat ADR-031 |
| Perbedaan FIX dan TCP | `zix.Fix` dan `zix.Tcp` EPOLL menggunakan desain terpusat: satu accept loop mendorong fd ke antrian bersama, pool worker pop dan menahan setiap koneksi sepanjang hidupnya. `pool_size` sebagai jumlah worker |
| Field `workers` (`zix.Http`, `zix.Http1`) | Mengontrol jumlah thread worker shared-nothing (0 = cpu_count). `pool_size` diabaikan |
| Field `pool_size` (gRPC, FIX, TCP) | Mengontrol jumlah worker multiplexed atau pool. Lihat dokumentasi per-protokol |
| Biaya idle keep-alive | Hampir nol: socket idle duduk di epoll set tanpa menahan thread apapun |
| Debugging | `strace` atau `perf` akan menampilkan `epoll_wait` mendominasi waktu idle, ini adalah perilaku yang diharapkan dan benar |

**Kapan TIDAK menggunakan:**
- SSE atau WebSocket via `zix.Http`: koneksi tetap aktif dan data mengalir terus-menerus, blocking read akan menahan worker. Gunakan `.ASYNC`.
- Target non-Linux: gunakan `.POOL` atau `.ASYNC` secara eksplisit untuk menghindari fallback dengan debug print.
- Ketika jumlah koneksi rendah (< beberapa ratus): model `.POOL` atau `.ASYNC` yang lebih sederhana akan memiliki performa yang sama atau lebih baik dengan kompleksitas yang lebih rendah.

---

## .URING: Event Loop io_uring Shared-Nothing (Linux-only)

`.URING` adalah saudara completion-based dari `.EPOLL`: topologi thread-per-core, shared-nothing yang sama (satu `SO_REUSEPORT` listener dan satu ring per worker, tanpa queue bersama, tanpa perpindahan fd antar thread), tetapi accept, read, dan write disubmit sebagai SQE io_uring dan dipanen sebagai CQE alih-alih menunggu readiness `epoll_wait`. Sebagian besar transisi syscall di-batch ke dalam ring (ADR-037 Fase 4).

- Engine native: `zix.Http1`, `zix.Http`, `zix.Grpc`, `zix.Fix`. `zix.Http2` dan handler per-connection `zix.Tcp` tidak punya ring native dan melipat ke `.POOL` / `.EPOLL` (callback framed `zix.Tcp` menjalankan ring). Build non-Linux fallback ke `.POOL`.
- `workers` (Http/Http1) atau `pool_size` (gRPC/FIX/TCP) menentukan jumlah worker, persis seperti `.EPOLL`.
- Di loopback `.URING` setara `.EPOLL` pada throughput dan total CPU, menang terutama pada cache locality per-request. Di mesin many-core, ring close (`prep_close`, ADR-041) membuat worker terus memanen completion lintas connection churn alih-alih memblokir di `close` sinkron, jadi `.URING` mencapai paritas atau lebih baik dari `.EPOLL` di setiap beban yang diukur dengan memori jauh lebih sedikit.
- "Kapan tidak digunakan" sama dengan `.EPOLL`: SSE / WebSocket di `zix.Http`, jumlah koneksi rendah, target non-Linux.

---

## Mengapa Dispatch Loop Per-Engine

Tiap engine memegang dispatch loop-nya sendiri di `server.zig`-nya masing-masing, bukan di belakang satu multiplexer generik. Pemisahan ini disengaja dan justru merupakan optimasinya: kepemilikan per-engine membuat tiap engine menyetel hot path-nya untuk bentuk koneksinya sendiri.

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
| `dispatch_model = .POOL` | work-queue thread pool | N accept thread + M pool thread |
| `dispatch_model = .ASYNC` | single accept, io.async() | 1 accept thread, io.async() per koneksi |
| `dispatch_model = .MIXED` | N accept, io.async() | N accept thread, masing-masing mendispatch via io.async() |
| `workers = 0` | cpu_count thread | digunakan oleh `.POOL`, `.MIXED`, dan `.EPOLL` (untuk `zix.Http` dan `zix.Http1`) |
| `workers = N` | N thread | override eksplisit untuk `.POOL`, `.MIXED`, dan `.EPOLL` (untuk `zix.Http` dan `zix.Http1`) |
| `pool_size = 0` | `max(10, cpu_count * 2)` | jumlah pool thread untuk `.POOL`. Jumlah worker EPOLL untuk `zix.Grpc`, `zix.Fix`, `zix.Tcp` |
| `pool_size = N` | N pool atau mux worker | ukuran eksplisit untuk `.POOL`. Jumlah worker EPOLL eksplisit untuk `zix.Grpc`, `zix.Fix`, `zix.Tcp` |

---

## Perbandingan Model Dispatch

| | `.POOL` | `.ASYNC` | `.MIXED` | `.EPOLL` |
| :- | :- | :- | :- | :- |
| Accept thread | cpu_count (atau N) | 1 | cpu_count (atau N) | cpu_count (atau N) |
| Dispatch koneksi | `queue.pop()` + sync I/O | task `io.async()` | task `io.async()` | epoll per-worker, level-triggered |
| Overhead scheduler | tidak ada (blocking pop, tanpa fiber) | ada (condvar wakeup) | ada (condvar wakeup) | tidak ada (epoll, Linux only) |
| Pool thread | ada (`pool_size`) | tidak ada | tidak ada | tidak ada |
| `SO_REUSEPORT` | ya | tidak | ya | ya (listener per-worker, Http only) |
| Field `workers` digunakan | ya | tidak (diabaikan) | ya | ya (Http/Http1 only) |
| Field `pool_size` digunakan | ya | tidak (diabaikan) | tidak (diabaikan) | tidak (Http: diabaikan). Ya (gRPC/FIX/TCP) |
| Terbaik untuk | throughput, jumlah koneksi tinggi | SSE, WebSocket, latensi rendah | balanced, multi-accept async | HTTP/1 atau gRPC throughput tinggi di Linux |
| Tersedia di | Http, Http2, Grpc, Tcp, Fix | Http, Http2, Grpc, Tcp, Fix | Http, Http2, Grpc, Tcp, Fix | Http, Grpc, Fix, Tcp (Linux-only: Http2 fallback ke .POOL) |

---

## Penerapan per Protokol

| Protokol | `.POOL` | `.ASYNC` | `.MIXED` | `.EPOLL` |
| :- | :- | :- | :- | :- |
| HTTP | ya | ya (default) | ya | ya, Linux-only |
| SSE | tidak direkomendasikan (menghabiskan pool thread) | ya, direkomendasikan | ya | n/a |
| WebSocket | tidak direkomendasikan (koneksi berumur panjang) | ya, direkomendasikan | ya | n/a |
| HTTP/2 (h2c) | ya | ya (default) | ya | n/a |
| gRPC (h2c) | ya | ya (default) | ya | ya, Linux-only |
| TCP (raw stream) | ya | ya (default) | ya | ya, Linux-only |
| FIX 4.x | ya | ya (default) | ya | ya, Linux-only |
| UDP | n/a | n/a | n/a | n/a |
| UDS (stream) | n/a | ya (io.concurrent() per koneksi) | n/a | n/a |

---

## Backend Lintas-Platform (rencana)

Setiap model menamai dua hal sekaligus: bentuk konkurensi (single atau multi-core) dan, untuk model per-core, sebuah I/O backend. Backend bersifat OS-specific. Kontraknya: OS menukar backend, bukan sifat single-atau-multi dari model.

| Model | Perilaku core | OS | Status |
| :- | :- | :- | :- |
| `.ASYNC` | single | semua | sekarang |
| `.POOL` | multi (thread pool) | semua | sekarang |
| `.MIXED` | multi (hybrid) | semua | sekarang |
| `.EPOLL` | multi (per-core) | Linux | sekarang |
| `.URING` | multi (per-core) | Linux | sekarang |
| `.KQUEUE` | multi (per-core) | macOS / BSD | rencana |
| `.IOCP` | multi (per-core) | Windows | rencana |

`.EPOLL`, `.KQUEUE`, dan `.IOCP` adalah ide multi-core per-core yang sama, satu per sistem operasi. Masing-masing berada di file `dispatch/<model>.zig` sendiri, sehingga folder-nya self-documenting: buka, lihat setiap model, tiap baris header menyatakan perilaku core dan OS-nya.

Seperti `.EPOLL` dan `.URING` saat ini, backend ini whole-family: setiap engine yang memilih `DispatchModel` (`zix.Http`, `zix.Http1`, `zix.Http2`, `zix.Grpc`, `zix.Tcp`, `zix.Fix`, `zix.Udp`) mendapat backend platform-nya lewat enum yang sama.

Tidak ada keyword auto-select. Kode portable memilih bentuk portable (`.POOL` / `.MIXED`) atau menamai backend yang tepat dengan satu baris comptime switch pada `builtin.os.tag`. Dua ketidakcocokan ditangani berbeda:

- Backend yang tidak mungkin ada di OS target (misalnya `.IOCP` di Linux) adalah compile-time error (category error), tertangkap saat build.
- Backend yang ada tapi tidak bisa dipakai mesin saat runtime (misalnya `.URING` di kernel lama) di-fold ke model yang bekerja dengan notice yang dicatat (capability gap).

Saat ini, sebelum backend macOS dan Windows hadir, `.EPOLL` di build non-Linux di-fold ke `.POOL` sebagai interim. `.KQUEUE` dan `.IOCP` hanya nama yang dipesan, belum diimplementasikan dan tidak hadir sebagai file source. Lihat ADR-050.

---

## Channel

`zix.Channel` **bukan** model konkurensi. Channel adalah primitif pengiriman pesan dalam proses yang bekerja berdampingan dengan kelima model dispatch. Channel menghubungkan producer dan consumer task (OS thread atau fiber `io.async()`) di dalam proses yang sama. Channel tidak melintasi batas jaringan atau batas proses.

```
Producer task --> [ Channel(T) ring buffer ] --> Consumer task
```

Kelima model dispatch dapat menghasilkan task `io.async()` atau OS thread yang berkomunikasi melalui Channel. Channel itu sendiri tidak bergantung pada model dispatch yang sedang digunakan.

| Properti | Channel |
| :- | :- |
| Melintasi batas proses/jaringan | tidak (hanya dalam proses) |
| Bekerja dengan task `io.async()` | ya, menggunakan `std.Io.Mutex` + `std.Io.Condition` (fiber-aware) |
| Bekerja dengan OS thread | ya: setiap thread membutuhkan `std.Io` sendiri dari `std.Io.Threaded` |
| Menggantikan model dispatch | tidak (ortogonal) |

Status: Sudah diimplementasikan. Lihat ADR-017 dan [`docs/hld-channel-id.md`](hld-channel-id.md).

---

###### end of concurrency
