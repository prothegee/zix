# HLD: zix.Uds

Server dan client Unix Domain Socket. Hanya untuk IPC pada host yang sama (tidak ada routing jaringan).

---

## Status

Sudah diimplementasi. Lihat ADR-010 untuk dasar keputusan desain.

---

## Tujuan

- Eksplisit bukan implisit: pola konfigurasi sama dengan `zix.Udp`.
- IPC pada host yang sama menggunakan stream socket (berbasis koneksi).
- Framing berbasis length-prefix sudah tersedia di default echo handler dan API client.
- Tidak ada dependensi lintas protokol: `src/uds/` tidak mengimpor dari `src/tcp/` maupun `src/udp/`.
- Namespace mengikuti pola yang sama: `zix.Uds.Server`, `zix.Uds.Client`.

---

## Struktur Berkas

```
src/uds/
    config.zig   // UdsServerConfig, UdsClientConfig
    server.zig   // UdsServer, HandlerFn, echoHandler
    client.zig   // UdsClient
    Uds.zig      // namespace aggregator
```

Ekspor dari `src/zix.zig`:
```zig
pub const Uds = @import("uds/Uds.zig");
```

---

## API Publik

| Simbol | Tipe | Deskripsi |
| :- | :- | :- |
| `zix.Uds.Server` | struct | `init(config)` / `run(io)` / `runWith(io, handlerFn)` / `deinit()` |
| `zix.Uds.Client` | struct | `connect(config, io)` / `sendMsg(io, msg)` / `recvMsg(io, buf)` / `deinit(io)` |
| `zix.Uds.ServerConfig` | struct | `path`, `allocator`, `backlog` (128), `max_msg_len` (4096) |
| `zix.Uds.ClientConfig` | struct | `path` |
| `zix.Uds.HandlerFn` | type | `*const fn(stream: std.Io.net.Stream, io: std.Io) void` |
| `zix.Uds.echoHandler` | fn | Default echo handler: membaca frame berbasis length-prefix dan mengembalikan setiap frame |

---

## Format Frame

Baik `echoHandler` bawaan maupun `UdsClient.sendMsg`/`recvMsg` menggunakan format frame sederhana berbasis length-prefix:

```
[ u32 payload_len, 4 bytes, native little-endian ]
[ payload bytes, payload_len bytes ]
```

Frame dengan `payload_len > max_msg_len` (default 4096) akan menutup koneksi.

---

## Siklus Hidup Server

```mermaid
flowchart TD
    A["UdsServer.init(config)"] --> B["runWith(io, handler)"]
    B --> C["unlink stale socket if exists"]
    C --> D["UnixAddress.listen(io)"]
    D --> E["accept loop"]
    E --> F["stream = accept(io)"]
    F --> G["io.concurrent(dispatchConn)"]
    G --> E
    G --> H["handler(stream, io)"]
    H --> I["stream.close(io), handler owns stream"]
    B --> Z["defer: net_server.deinit + unlink socket"]
```

- Berkas socket lama di-unlink sebelum binding (restart aman setelah crash).
- Setiap koneksi yang diterima di-dispatch sebagai task konkuren melalui `io.concurrent()`.
- Fallback ke dispatch sinkron jika concurrent pool habis.
- Berkas socket di-unlink kembali saat `runWith()` selesai.

---

## Siklus Hidup Client

```
connect(config, io)  -->  sendMsg(io, msg)  -->  recvMsg(io, buf)  -->  deinit(io)
                          (ulangi sesuai kebutuhan)
```

`UdsClient` memegang satu `std.Io.net.Stream` yang persisten. Reconeksi saat error menjadi tanggung jawab pemanggil (lihat `examples/uds_http.zig` untuk pola reconnect-on-failure).

---

## Siklus Hidup Koneksi

```mermaid
sequenceDiagram
    participant C as UdsClient
    participant S as UdsServer
    participant H as HandlerFn task

    C->>S: Unix stream connect
    S->>H: io.concurrent(handler, stream)
    Note over S: immediately back to accept()

    loop frame loop
        C->>H: [u32 len][payload bytes]
        H->>C: [u32 len][response bytes]
    end

    C->>H: connection close
    H->>H: stream.close(io), handler exits
```

---

## Penanganan Error

| Error | Sumber | Arti |
| :- | :- | :- |
| `error.PathEmpty` | `Server.init()` | `config.path` kosong |
| `error.MessageTooLarge` | `Client.recvMsg()` | payload frame dari server melebihi `buf.len` pemanggil |
| `error.ConnectionClosed` | `Client.recvMsg()` | server menutup koneksi di tengah frame |

---

## Keterbatasan Timeout

`std.Io.net.UnixAddress.connect` tidak menerima parameter timeout. Berbeda dengan `IpAddress.connect` pada TCP yang menerima `ConnectOptions.timeout`, path connect UDS tidak memiliki hook di stdlib untuk deadline. Timeout connect tidak dapat diimplementasi tanpa perubahan di stdlib.

`echoHandler` dan handler kustom membaca frame dengan blocking I/O. Timeout per-read maupun per-frame tidak tersedia karena alasan yang sama: tidak ada API stdlib yang menyediakan timed read untuk stream socket selain path TCP.

Kedua keterbatasan ini disebabkan oleh stdlib, bukan keputusan desain zix. Akan ditinjau kembali saat stdlib menyediakan primitif yang diperlukan.

---

## Contoh

| Berkas | Pola |
| :- | :- |
| `examples/uds_server.zig` | Penyedia data: menaikkan counter per frame |
| `examples/uds_http.zig` | HTTP frontend berbasis UDS: SSE, one-shot endpoint, Channel bridge |

---

## Integrasi Logger

`UdsServerConfig.logger: ?*Logger = null`. Saat tidak null:
- `system(.INFO, "uds", ...)` dipanggil saat bind, koneksi diterima, dan shutdown.

Server tidak memanggil `frame()` secara otomatis: `frame()` tersedia untuk penggunaan manual di dalam implementasi `HandlerFn` yang ingin mencatat log per frame:

```zig
fn myHandler(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);
    // ...
    // logger.frame(.RECV, SOCK_PATH, payload_len, null);
}
```

```zig
var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    .console = .ALWAYS,
});
defer logger.deinit();

var server = try zix.Uds.Server.init(.{
    .path      = "/tmp/app.sock",
    .allocator = std.heap.smp_allocator,
    .logger    = &logger,
});
```

Lihat `docs/hld-logger-id.md` untuk format baris log dan detail konfigurasi.

---

## Dukungan Platform

Stream socket UDS memerlukan `std.Io.net.has_unix_sockets == true`. Kondisi ini terpenuhi di Linux, macOS, dan Windows 10 RS4+. WASI tidak didukung. Baik `Server.init()` maupun `Client.connect()` menghasilkan `@compileError` pada platform yang tidak didukung.

---

###### end of hld-uds
