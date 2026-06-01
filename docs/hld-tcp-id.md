# HLD: zix.Tcp (raw stream)

Server dan client raw TCP stream. Byte-stream generik melalui IP dengan framing yang didefinisikan oleh pengguna. Dispatch model POOL, ASYNC, dan MIXED didukung. EPOLL diterima oleh enum tetapi otomatis menggunakan fallback ke POOL.

---

## Status

Sudah diimplementasi. Lihat ADR-022 untuk dasar keputusan desain.

---

## Tujuan

- Eksplisit daripada implisit: pola config dan dispatch model yang sama seperti `zix.Http`.
- Pengguna memiliki handler: `HandlerFn = *const fn(stream, io) void`, identik dengan `zix.Uds.HandlerFn`.
- Framing dengan length-prefix sudah terintegrasi di echo handler default dan API client (big-endian, network byte order).
- Dispatch model POOL, ASYNC, MIXED dengan semantik yang sama seperti HTTP, terbukti melalui PoC di `rnd/`. EPOLL diterima tetapi menggunakan fallback ke POOL (tidak ada native epoll loop untuk raw TCP).
- `initArgs()` pada server maupun client agar `--ip` dan `--port` dapat diganti saat runtime tanpa perlu build ulang.
- Tidak ada dependensi lintas protokol: `src/tcp/server.zig`, `src/tcp/client.zig`, `src/tcp/config.zig` tidak mengimpor dari `src/tcp/http/`.

---

## Struktur Berkas

```
src/tcp/
    config.zig    // TcpServerConfig, TcpClientConfig, DispatchModel
    server.zig    // TcpServer, HandlerFn, echoHandler, ConnQueue
    client.zig    // TcpClient
    Tcp.zig       // namespace aggregator (juga me-re-export Http)
```

Export dari `src/zix.zig`:
```zig
pub const Tcp = @import("tcp/Tcp.zig");
// zix.Tcp.Server, zix.Tcp.Client, zix.Tcp.Http.*, ...
```

---

## API Publik

| Simbol | Tipe | Deskripsi |
| :- | :- | :- |
| `zix.Tcp.Server` | struct | `init(config)` / `initArgs(config, args)` / `run(io)` / `runWith(io, handler)` / `deinit()` |
| `zix.Tcp.Client` | struct | `connect(config, io)` / `connectArgs(config, io, args)` / `sendMsg(io, msg)` / `recvMsg(io, buf)` / `deinit(io)` |
| `zix.Tcp.ServerConfig` | struct | `ip`, `port`, `dispatch_model` (.ASYNC), `kernel_backlog` (4096), `max_msg_len` (4096), `workers` (0), `pool_size` (0) |
| `zix.Tcp.ClientConfig` | struct | `ip`, `port`, `max_msg_len` (4096) |
| `zix.Tcp.DispatchModel` | enum(u8) | `ASYNC=0`, `POOL=1`, `MIXED=2`, `EPOLL=3` (fallback ke POOL) |
| `zix.Tcp.HandlerFn` | tipe | `*const fn(stream: std.Io.net.Stream, io: std.Io) void` |
| `zix.Tcp.echoHandler` | fn | Echo handler default: membaca frame length-prefixed dan memantulkan setiap frame kembali |

---

## Format Frame

Baik `echoHandler` bawaan maupun `TcpClient.sendMsg`/`recvMsg` menggunakan frame length-prefix sederhana:

```
[ u32 payload_len, 4 bytes, big-endian (network byte order) ]
[ payload bytes, payload_len bytes ]
```

Big-endian digunakan karena TCP adalah protokol jaringan — network byte order adalah pilihan konvensional dan sesuai dengan cara sebagian besar library protokol mengkodekan integer multi-byte melalui jaringan. (Berbeda dengan `zix.Uds`, yang menggunakan little-endian karena UDS bersifat lokal saja.)

Frame dengan `payload_len == 0` atau `payload_len > max_msg_len` (default 4096) menutup koneksi.

---

## Model Dispatch

### POOL

N accept thread mendorong koneksi yang diterima ke `ConnQueue` bersama. M pool thread mengambil dan menangani setiap koneksi secara sinkron dengan blocking I/O.

```mermaid
flowchart TD
    A["TcpServer.runWith(io, handler)"] --> B["spawn pool_count pool threads"]
    B --> C["spawn worker_count accept threads"]
    C --> D["workerEntry loop"]
    D --> E["stream = accept(io)"]
    E --> F["queue.push(stream)"]
    F --> D
    B --> G["poolEntry loop"]
    G --> H["stream = queue.pop()"]
    H --> I["handler(stream, io)"]
    I --> G
```

- `workers = 0` menghasilkan `cpu_count` accept thread.
- `pool_size = 0` menghasilkan `max(10, cpu_count * 2)` pool thread.
- Semua accept thread mengikat port yang sama melalui `SO_REUSEPORT` (`.reuse_address = true`).

### ASYNC

Satu accept thread mendispatch setiap koneksi melalui `io.async()`. Tidak ada pool thread atau antrian bersama.

```mermaid
flowchart TD
    A["TcpServer.runWith(io, handler)"] --> B["listen on ip:port"]
    B --> C["accept loop"]
    C --> D["stream = accept(io)"]
    D --> E["io.async(dispatchConn, task)"]
    E --> C
    E --> F["handler(stream, io) in async task"]
    F --> G["stream.close(io)"]
```

- `workers` dan `pool_size` diabaikan.
- Lebih cocok ketika koneksi bersifat long-lived (tidak menggunakan pool thread secara terus-menerus).

### MIXED

N accept thread, masing-masing mendispatch koneksi melalui `io.async()` secara langsung — tanpa `ConnQueue`.

```mermaid
flowchart TD
    A["TcpServer.runWith(io, handler)"] --> B["spawn worker_count accept threads"]
    B --> C["asyncWorkerEntry loop"]
    C --> D["stream = accept(io)"]
    D --> E["io.async(dispatchConn, task)"]
    E --> C
    E --> F["handler(stream, io) in async task"]
```

- `pool_size` diabaikan. `workers = 0` menghasilkan `cpu_count` accept thread.
- Throughput dan latensi yang seimbang.

---

## Siklus Hidup Server

```
TcpServer.init(config): memvalidasi port != 0
    -> .runWith(io, handler): mendispatch berdasarkan dispatch_model
        -> memblokir hingga error (ASYNC) atau accept thread selesai (POOL/MIXED)

TcpServer.deinit(): no-op (resource dibebaskan di dalam runWith melalui defer)
```

- `init()` hanya memvalidasi konfigurasi — tidak membuka socket.
- `runWith()` membuka socket, menspawn thread (POOL/MIXED), kemudian memblokir.
- `deinit()` adalah no-op. Semua resource jaringan dibebaskan saat `runWith()` kembali.

---

## Siklus Hidup Client

```
TcpClient.connect(config, io): resolusi alamat, membuka TCP stream
    -> .sendMsg(io, msg): menulis [u32 BE len][payload], flush
    -> .recvMsg(io, buf): membaca [u32 BE len][payload] ke dalam buf
    -> .deinit(io): menutup stream
```

`TcpClient` menyimpan satu `std.Io.net.Stream` yang persisten. Reconnect saat terjadi error adalah tanggung jawab pemanggil.

---

## Siklus Hidup Koneksi

```mermaid
sequenceDiagram
    participant C as TcpClient
    participant S as TcpServer
    participant H as HandlerFn task

    C->>S: TCP connect (ip:port)
    S->>H: io.async or pool dispatch
    Note over S: immediately back to accept()

    loop frame loop
        C->>H: [u32 BE len][payload bytes]
        H->>C: [u32 BE len][response bytes]
    end

    C->>H: connection close
    H->>H: stream.close(io), handler exits
```

---

## Penanganan Error

| Error | Sumber | Makna |
| :- | :- | :- |
| `error.PortNotConfigured` | `Server.init()` / `Client.connect()` | `config.port` bernilai 0 |
| `error.MessageTooLarge` | `Client.recvMsg()` | payload frame server melebihi `buf.len` milik pemanggil |
| `error.ConnectionClosed` | `Client.recvMsg()` | server menutup koneksi di tengah frame |

---

## Override Argumen CLI

Baik server maupun client mendukung `initArgs` / `connectArgs` untuk override `--ip` / `--port` saat runtime tanpa perlu build ulang:

```zig
// server
var server = try zix.Tcp.Server.initArgs(.{
    .ip   = "127.0.0.1",
    .port = 9300,
    .dispatch_model = .ASYNC,
}, process.minimal.args);

// client
var client = try zix.Tcp.Client.connectArgs(.{
    .ip   = "127.0.0.1",
    .port = 9300,
}, process.io, process.minimal.args);
```

Argumen diproses dari kiri ke kanan. Argumen yang tidak dikenal dilewati tanpa pesan error. Jika `--ip` atau `--port` tidak ada, nilai default dari config tetap digunakan.

---

## Contoh

| Berkas | Dispatch model | Port | Sasaran |
| :- | :- | :- | :- |
| `examples/tcp_server_1_async.zig` | `.ASYNC` | 9300 | Pemula: server paling sederhana, satu accept, custom handler |
| `examples/tcp_server_2_pool.zig` | `.POOL` | 9301 | Berpengalaman: tuning workers/pool_size secara eksplisit |
| `examples/tcp_server_3_mixed.zig` | `.MIXED` | 9302 | Berpengalaman: N accept + io.async, tanpa antrian |
| `examples/tcp_client.zig` | n/a | 9300 | Koneksi, kirim satu pesan, cetak respons, keluar |

---

## Integrasi Logger

`TcpServerConfig.logger: ?*Logger = null`. Jika tidak null:
- `system(.INFO, "tcp", ...)` dipanggil saat bind dan shutdown.
- `conn(peer, dur_ms, err)` dipanggil setelah handler kembali untuk setiap koneksi. `peer` adalah alamat remote (`"1.2.3.4:54321"` atau `"-"` jika tidak tersedia); `dur_ms` adalah durasi koneksi berdasarkan wall-clock; `err` bernilai null jika koneksi ditutup dengan bersih.

```zig
var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    .console = .ALWAYS,
});
defer logger.deinit();

var server = try zix.Tcp.Server.init(.{
    .ip     = "127.0.0.1",
    .port   = 9300,
    .logger = &logger,
});
```

Lihat `docs/hld-logger-id.md` untuk format baris log dan detail konfigurasi.

---

## Dukungan Platform

Socket stream TCP tersedia di semua platform yang didukung oleh `std.Io.net.IpAddress` milik Zig. Tidak diperlukan guard platform-specific selain yang sudah disediakan oleh `std.Io.net`.

---

###### end of hld-tcp
