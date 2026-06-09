# Model Konkurensi: zix

Empat model dispatch untuk HTTP dan raw TCP. Pilih melalui `config.dispatch_model` (enum `DispatchModel`) di `HttpServerConfig` atau `TcpServerConfig`. Default: `.ASYNC`.

---

## DispatchModel

```zig
pub const DispatchModel = enum(u8) {
    ASYNC = 0, // single accept, io.async() dispatch
    POOL  = 1, // work-queue thread pool
    MIXED = 2, // N accept threads, each dispatching via io.async()
    EPOLL = 3, // single epoll event loop, Linux-only
};
```

Didefinisikan sekali di `src/tcp/config.zig`. Diekspor ulang oleh `src/tcp/http/config.zig` (untuk `zix.Http`) dan diimpor oleh `src/tcp/http2/grpc/config.zig` (untuk `zix.Grpc`). Keempat nilai tersedia di setiap konfigurasi.

`.EPOLL = 3` hanya tersedia di Linux. `zix.Http` (HTTP/1), `zix.Grpc`, `zix.Fix`, dan `zix.Tcp` mengimplementasikannya secara native di Linux. `zix.Http2` dan build non-Linux akan fallback ke `.POOL` secara otomatis. Lihat tabel Perbandingan Model Dispatch di bawah.

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

N accept thread masing-masing mendispatch koneksi melalui `io.async()` secara langsung — tanpa `ConnQueue`. Throughput dan latensi yang seimbang, jitter lebih tinggi dibanding `.POOL` saat saturasi karena fallback `io.async()` ke eksekusi inline.

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

## .EPOLL: Single epoll Event Loop (Linux-only)

Satu thread event loop memanggil `epoll_wait` dalam sebuah loop. Ketika kernel menandai socket sebagai readable, fd socket didorong ke `FdQueue` dan pool worker menanganinya. Tidak ada overhead `io.async()`, tidak ada condvar wakeup per koneksi — kernel yang melacak kesiapan. Setiap `epoll_wait` menguras hingga `EPOLL_MAX_EVENTS` (512) event siap per pemanggilan.

**Mengapa ini ada:** `.POOL` dan `.ASYNC` keduanya membayar biaya condvar wakeup pada setiap koneksi yang diterima (baik melalui `ConnQueue.pop()` maupun melalui fiber scheduler `io.async()`). Pada jumlah koneksi yang sangat tinggi di mana sebagian besar koneksi idle pada saat tertentu (client lambat, banyak sesi terbuka), wakeup ini menumpuk. `epoll` memungkinkan kernel membatch sinyal kesiapan — thread event loop hanya berjalan ketika byte benar-benar tersedia, tanpa overhead thread per-koneksi.

```
Event loop thread (1):
  epoll_create1
  accept4 in a nonblocking loop when EPOLLIN fires on the listener
  for each new conn_fd:
    epoll_ctl(ADD, conn_fd, EPOLLIN | EPOLLONESHOT | EPOLLRDHUP)

Pool workers (pool_size, default max(10, cpu_count * 2)):
  loop:
    fd = FdQueue.pop()           <- blocks until epoll signals a readable fd
    serve one request on fd      <- blocking read/write, no fiber
    epoll_ctl(MOD, fd, re-arm)   <- re-arm EPOLLONESHOT for next request
    (or epoll_ctl(DEL) + close if connection ended)
```

`EPOLLONESHOT` berarti setiap readable event hanya muncul sekali. Setelah request dilayani, worker secara eksplisit melakukan re-arm pada socket. Koneksi keep-alive yang idle tidak menahan thread manapun — koneksi tersebut duduk di epoll set sampai client mengirimkan request berikutnya.

**Kapan menggunakan:**
- Deployment produksi Linux untuk `zix.Http` (HTTP/1) atau `zix.Grpc` dengan jumlah koneksi tinggi dan banyak koneksi idle.
- Client yang lambat atau bursty di mana koneksi tetap terbuka di antara request.
- Ingin menghindari overhead fiber scheduler `io.async()` sepenuhnya.
- `dispatch_model = .EPOLL` di `HttpServerConfig` atau `GrpcServerConfig`.
- `pool_size` mengontrol jumlah worker. `workers` diabaikan (satu thread event loop).

**Contoh (`zix.Http`):**
```zig
var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
}, .{
    .io             = process.io,
    .dispatch_model = .EPOLL,
    .pool_size      = 32, // worker threads; 0 = max(10, cpu_count * 2)
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
| Model accept | Accept single-threaded di dalam event loop (tanpa `SO_REUSEPORT`). Accept rate yang tinggi dapat menjadi bottleneck — gunakan `.MIXED` jika connection churn (bukan jumlah koneksi) yang menjadi bottleneck |
| Perbedaan gRPC, FIX, dan TCP | gRPC, FIX, dan TCP EPOLL memberikan setiap koneksi ke pool worker untuk keseluruhan masa hidupnya (ketiganya adalah protokol stream berumur panjang). `EPOLLONESHOT` tidak digunakan. Keuntungannya adalah accept single-threaded vs N accept thread di `.POOL` |
| Field `pool_size` | Mengontrol jumlah worker thread yang menangani request. `workers` diabaikan |
| Biaya idle keep-alive | Hampir nol: socket idle duduk di epoll set tanpa menahan thread apapun |
| Debugging | `strace` atau `perf` akan menampilkan `epoll_wait` mendominasi waktu idle — ini adalah perilaku yang diharapkan dan benar |

**Kapan TIDAK menggunakan:**
- SSE atau WebSocket: koneksi tetap aktif dan data mengalir terus-menerus — overhead re-arm `EPOLLONESHOT` menumpuk tanpa manfaat. Gunakan `.ASYNC`.
- Target non-Linux: gunakan `.POOL` atau `.ASYNC` secara eksplisit untuk menghindari fallback dengan debug print.
- Ketika jumlah koneksi rendah (< beberapa ratus): model `.POOL` atau `.ASYNC` yang lebih sederhana akan memiliki performa yang sama atau lebih baik dengan kompleksitas yang lebih rendah.

---

## Jumlah Thread

| Field | Default | Makna |
| :- | :- | :- |
| `dispatch_model = .POOL` | work-queue thread pool | N accept thread + M pool thread |
| `dispatch_model = .ASYNC` | single accept, io.async() | 1 accept thread, io.async() per koneksi |
| `dispatch_model = .MIXED` | N accept, io.async() | N accept thread, masing-masing mendispatch via io.async() |
| `workers = 0` | cpu_count accept thread | digunakan oleh `.POOL` dan `.MIXED` |
| `workers = N` | N accept thread | override eksplisit untuk `.POOL` dan `.MIXED` |
| `pool_size = 0` | `max(10, cpu_count * 2)` | jumlah pool thread untuk `.POOL` saja |
| `pool_size = N` | N pool thread | ukuran pool eksplisit untuk `.POOL` saja |

---

## Perbandingan Model Dispatch

| | `.POOL` | `.ASYNC` | `.MIXED` | `.EPOLL` |
| :- | :- | :- | :- | :- |
| Accept thread | cpu_count (atau N) | 1 | cpu_count (atau N) | 1 |
| Dispatch koneksi | `queue.pop()` + sync I/O | task `io.async()` | task `io.async()` | epoll event loop |
| Overhead scheduler | tidak ada (blocking pop, tanpa fiber) | ada (condvar wakeup) | ada (condvar wakeup) | tidak ada (epoll, Linux only) |
| Pool thread | ada (`pool_size`) | tidak ada | tidak ada | tidak ada |
| `SO_REUSEPORT` | ya | tidak | ya | tidak |
| Field `pool_size` digunakan | ya | tidak (diabaikan) | tidak (diabaikan) | tidak (diabaikan) |
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

## Channel

`zix.Channel` **bukan** model konkurensi. Channel adalah primitif pengiriman pesan dalam proses yang bekerja berdampingan dengan keempat model dispatch. Channel menghubungkan producer dan consumer task (OS thread atau fiber `io.async()`) di dalam proses yang sama. Channel tidak melintasi batas jaringan atau batas proses.

```
Producer task --> [ Channel(T) ring buffer ] --> Consumer task
```

Keempat model dispatch dapat menghasilkan task `io.async()` atau OS thread yang berkomunikasi melalui Channel. Channel itu sendiri tidak bergantung pada model dispatch yang sedang digunakan.

| Properti | Channel |
| :- | :- |
| Melintasi batas proses/jaringan | tidak (hanya dalam proses) |
| Bekerja dengan task `io.async()` | ya, menggunakan `std.Io.Mutex` + `std.Io.Condition` (fiber-aware) |
| Bekerja dengan OS thread | ya: setiap thread membutuhkan `std.Io` sendiri dari `std.Io.Threaded` |
| Menggantikan model dispatch | tidak (ortogonal) |

Status: Sudah diimplementasikan. Lihat ADR-017 dan [`docs/hld-channel-id.md`](hld-channel-id.md).

---

###### end of concurrency
