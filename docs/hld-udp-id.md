# HLD: zix.Udp

UDP server dan client yang dibangun di atas Zig 0.16.x `std.Io`. Tidak terkait dengan lapisan TCP/HTTP.

---

## Tujuan

- Eksplisit bukan implisit: setiap perilaku disebutkan secara langsung dalam konfigurasi.
- Interoperabilitas lintas bahasa: client dapat berupa Go, C++, Rust, atau bahasa lain yang menggunakan layout `extern struct` yang sama.
- Tidak ada tipe paket yang dikodekan secara tetap: pengguna mendefinisikan `extern struct` sendiri, zix diparameterisasi atas tipe tersebut saat comptime.
- Endianness yang dapat dikonfigurasi diterapkan secara transparan saat mengirim dan menerima.
- Pemisahan tanggung jawab: `src/udp/` tidak mengimpor apapun dari `src/tcp/`.

---

## Runtime Model

### Server

```mermaid
flowchart TD
    A["UdpServer(Packet).run(io)"] --> B["IpAddress.bind(io, .dgram .udp)"]
    B --> C["receive loop"]
    C --> D["socket.receiveTimeout(io, buf, poll_timeout)"]
    D -->|Timeout| E["checkDisconnections(clients, now)"]
    E --> C
    D -->|datagram| F{"size == @sizeOf(Packet)?"}
    F -->|no| G["drop + optional NACK\n(0x15)"]
    G --> C
    F -->|yes| H["update ClientRecord\nor register new client"]
    H --> I{"broadcast enabled?"}
    I -->|yes| J["heap-alloc peer snapshot\n[]IpAddress"]
    I -->|no| K["peers = empty slice"]
    J --> L["io.concurrent(processPacket, task)"]
    K --> L
    L --> C
    L --> M["processPacket(task)"]
    M --> N{"auto_ack?"}
    N -->|yes| O["send 0x06 ACK to sender"]
    N -->|no| P{" "}
    O --> P
    P --> Q{"auto_echo?"}
    Q -->|yes| R["send buf back to sender"]
    Q -->|no| S{" "}
    R --> S
    S --> T{"broadcast?"}
    T -->|yes| U["send buf to each peer\nfree peer snapshot"]
    T -->|no| V["free peer snapshot (empty)"]
```

### Client

```mermaid
flowchart TD
    A["UdpClient(Packet).init(config, io)"] --> B["bind 127.0.0.1:bind_port"]
    B --> C["resolve server IpAddress"]
    C --> D["client ready"]
    D --> E["send(packet)"]
    E --> F["toEndian(packet, config.endianness)"]
    F --> G["socket.send(io, dest, bytes)"]
    D --> H["receiveFeedback()"]
    H --> I["socket.receive(io, buf)"]
    I --> J{"len == 1?"}
    J -->|0x06| K[".ack"]
    J -->|other| L[".nack"]
    J -->|no| M{"len == @sizeOf(Packet)?"}
    M -->|yes| N["fromEndian(packet)\n.packet(Packet)"]
    M -->|no| O["error.UnexpectedPacketSize"]
```

---

## Struktur Berkas

```mermaid
graph TD
    zix["src/lib.zig"] --> Udp["udp/Udp.zig\nzix.Udp"]

    Udp --> config["config.zig\nPortMode, Endianness\nUdpServerConfig, UdpClientConfig"]
    Udp --> packet["packet.zig\nFeedbackResult\ntoEndian, fromEndian"]
    Udp --> server["server.zig\nUdpServer(Packet)"]
    Udp --> client["client.zig\nUdpClient(Packet)"]
```

---

## API Publik

Akses melalui `const zix = @import("zix");`

| Simbol | Tipe | Deskripsi |
| :- | :- | :- |
| `zix.Udp.Server(Packet)` | generic fn | Mengembalikan tipe `UdpServer(Packet)` |
| `zix.Udp.Client(Packet)` | generic fn | Mengembalikan tipe `UdpClient(Packet)` |
| `zix.Udp.ServerConfig` | struct | Konfigurasi server |
| `zix.Udp.ClientConfig` | struct | Konfigurasi client |
| `zix.Udp.PortMode` | enum(u8) | `CONFIGURABLE` atau `REQUIRED` |
| `zix.Udp.Endianness` | enum(u8) | `NATIVE`, `LITTLE`, `BIG` |
| `zix.Udp.FeedbackResult(Packet)` | union(enum) | `.ack`, `.nack`, `.packet(Packet)` |
| `zix.Udp.toEndian(Packet, pkt, end)` | fn | Terapkan endianness sebelum pengiriman ke jaringan |
| `zix.Udp.fromEndian(Packet, pkt, end)` | fn | Terapkan endianness setelah penerimaan dari jaringan |

### Metode UdpServer(Packet)

| Metode | Deskripsi |
| :- | :- |
| `init(config)` | Mode REQUIRED: port harus bukan nol |
| `initArgs(config, args)` | Mode CONFIGURABLE: membaca `--port` dari argumen CLI |
| `run(io)` | Bind socket, masuk ke receive loop. Memblokir sampai terjadi error. |
| `deinit()` | Lepaskan resource. |

### Metode UdpClient(Packet)

| Metode | Deskripsi |
| :- | :- |
| `init(config, io)` | Mode REQUIRED: bind socket segera |
| `initArgs(config, io, args)` | Mode CONFIGURABLE: membaca `--bind-port` dan `--server-port` |
| `send(packet)` | Terapkan endianness dan kirim ke server |
| `receiveFeedback()` | Penerimaan blocking: mengembalikan `FeedbackResult` |
| `deinit()` | Tutup socket. |

---

## UdpServerConfig

```zig
pub const UdpServerConfig = struct {
    allocator:             std.mem.Allocator,          // caller-owned, used for client list and broadcast snapshots
    ip:                    []const u8,                 // bind address
    port:                  u16,                        // bind port & must be non-zero
    port_mode:             PortMode   = .REQUIRED,
    endianness:            Endianness = .LITTLE,
    disconnect_timeout_ms: i64        = 5000, // silence before client considered disconnected
    poll_timeout_ms:       i64        = 2000, // receiveTimeout interval for disconnect checks
    auto_ack:              bool       = false, // send 0x06 ACK to sender on receipt
    error_report:          bool       = false, // send 0x15 NACK on malformed/oversized datagram
    auto_echo:             bool       = false, // send received packet back to sender only
    broadcast:             bool       = false, // relay received packet to all connected clients
};
```

`allocator`, `ip`, dan `port` wajib diisi (tidak ada nilai default). `auto_ack` dan `auto_echo` bersifat independen: keduanya dapat bernilai true secara bersamaan (ACK lalu echo). `broadcast` mengirim ke semua client, `auto_echo` hanya mengirim ke pengirim.

---

## UdpClientConfig

```zig
pub const UdpClientConfig = struct {
    server_ip:   []const u8, // server address to send packets to
    server_port: u16,        // server port & must be non-zero
    bind_port:   u16,        // local port: server uses this to send responses back
    port_mode:   PortMode   = .REQUIRED,
    endianness:  Endianness = .LITTLE, // must match server
    send_once:   bool       = false,
    send_every:  u64        = 99, // milliseconds between sends in run loop
};
```

`server_ip`, `server_port`, dan `bind_port` wajib diisi (tidak ada nilai default). `UdpClient` tidak melakukan heap allocation (semua buffer dialokasikan di stack), sehingga tidak dibutuhkan field `allocator`.

---

## Model Paket

Pengguna mendefinisikan `extern struct` sendiri. zix diparameterisasi atas tipe tersebut saat comptime.

```zig
// User-defined: must be an extern struct for fixed C ABI layout.
// All clients and the server must use the exact same definition.
const Packet = extern struct {
    id:          [16]u8,   // u8 arrays are NOT byte-swapped (identity bytes)
    packet_type: i32,      // swapped on non-native endian
    register:    u32,      // swapped on non-native endian
    position:    [3]f64,   // each element swapped on non-native endian
};

const MyServer = zix.Udp.Server(Packet);
const MyClient = zix.Udp.Client(Packet);
```

zix memberlakukan batasan ini saat comptime (RFC 768):
```
@sizeOf(Packet) must be <= 65,507 bytes
(65,535 - 8 UDP header - 20 min IPv4 header)
```

---

## Port Mode

| Mode | Perilaku | Kunci CLI |
| :- | :- | :- |
| `REQUIRED` | Port dari struct konfigurasi. `init()` gagal dengan `error.PortNotConfigured` jika port bernilai nol. | tidak ada |
| `CONFIGURABLE` | Port dibaca dari argumen CLI. Menggunakan default konfigurasi jika argumen tidak ada. Tidak pernah gagal karena argumen hilang. | `--port` (server), `--bind-port` / `--server-port` (client) |

Validasi dilakukan saat `init()`, bukan saat `run()`.

---

## Endianness

| Nilai | Deskripsi |
| :- | :- |
| `NATIVE` | Tanpa swap. Hanya untuk mesin yang sama (tidak aman lintas platform atau bahasa). |
| `LITTLE` | Swap jika native adalah big-endian. Direkomendasikan untuk penggunaan lintas bahasa (x86, ARM). |
| `BIG` | Swap jika native adalah little-endian. Network byte order (konvensi RFC 791). |

Konversi endianness bersifat transparan: diterapkan di dalam `send()` dan `receive()`. Pengguna mendeklarasikan sekali dalam konfigurasi. `toEndian` dan `fromEndian` adalah operasi yang sama (swap adalah kebalikan dari dirinya sendiri).

Aturan swap berdasarkan tipe field:
- `int`: `@byteSwap`
- `float`: interpretasi ulang sebagai unsigned int, `@byteSwap`, interpretasi ulang kembali
- `[N]T` di mana T bukan u8: swap setiap elemen secara rekursif
- `[N]u8`: tanpa swap (identity bytes, misalnya field id)

---

## Disconnect

UDP tidak memiliki status koneksi. Deteksi disconnect murni berbasis timeout.

```mermaid
flowchart TD
    A["packet arrives"] --> B["update ClientRecord.last_seen"]
    B --> C{"poll_timeout_ms\nelapsed since last check?"}
    C -->|yes| D["checkDisconnections()"]
    C -->|no| E["skip check"]
    F["receiveTimeout (Timeout error)"] --> D
    D --> G["for each client:\nelapsed = now - last_seen"]
    G --> H{"elapsed >= disconnect_timeout_ms?"}
    H -->|yes| I["swapRemove from clients list\nlog disconnect"]
    H -->|no| J["keep client"]
```

Penundaan deteksi maksimum: `disconnect_timeout_ms + poll_timeout_ms`. Tidak ada sinyal tingkat OS yang setara dengan TCP FIN.

---

## Bentuk Feedback

| Skenario | Perilaku server | Client mendekode sebagai |
| :- | :- | :- |
| `auto_ack = true` | Kirim 1 byte `0x06` ke pengirim | `.ack` |
| `error_report = true` | Kirim 1 byte `0x15` ke pengirim pada datagram yang rusak | `.nack` |
| `auto_echo = true` | Kirim packet lengkap kembali ke pengirim | `.packet(Packet)` |
| `broadcast = true` | Kirim packet lengkap ke semua client yang terhubung | `.packet(Packet)` |

Nilai byte ACK/NACK (`0x06`, `0x15`) adalah kode kontrol ASCII (ACK, NAK). Keduanya merupakan konvensi tingkat aplikasi, bukan mandat dari RFC manapun.

---

## Model Konkurensi

Mengikuti pola TCP/HTTP: pemanggil memiliki backend `io`. Teruskan `process.io` untuk konkurensi yang dikelola runtime atau `threaded.io()` untuk batas eksplisit. `io.concurrent()` digunakan secara internal untuk mendispatch `processPacket`.

---

## Model Memori

```mermaid
graph TD
    CA["config.allocator\ncaller-owned\nMUST be general-purpose"] -->|client list| CL["Managed(ClientRecord)\nprocess lifetime"]
    CA -->|broadcast peers| PS["[]IpAddress per packet\nallocated before concurrent dispatch\nfreed inside processPacket"]
    Stack["Stack"] -->|receive buffer| RB["[@sizeOf(Packet)]u8\nper receive loop iteration"]
```

| Ruang Lingkup | Allocator | Masa Hidup |
| :- | :- | :- |
| Daftar ClientRecord | `config.allocator` | Masa hidup proses server |
| Peer snapshot (broadcast) | `config.allocator` | Satu dispatch packet |
| Receive buffer | Stack | Satu iterasi receive loop |
| Socket | OS | `init()` hingga `deinit()` |

### Mengapa ArenaAllocator tidak cocok

`ArenaAllocator.free()` adalah no-op: memori hanya diklaim kembali ketika seluruh arena di-deinit. Broadcast peer snapshot dialokasikan dan dibebaskan pada setiap packet. Menggunakan arena secara diam-diam mengubah setiap `free(peers)` menjadi no-op, menyebabkan pertumbuhan memori tanpa batas selama masa hidup server:

```zig
// Each packet received when broadcast = true:
allocator.alloc(IpAddress, N)  // real allocation, arena grows
allocator.free(peers)          // no-op on ArenaAllocator, memory never reclaimed
// After M packets: M * N * @sizeOf(IpAddress) bytes held permanently
```

Gunakan `std.heap.smp_allocator` (atau general-purpose allocator apapun) agar `free()` benar-benar berfungsi. `std.testing.allocator` (didukung oleh `GeneralPurposeAllocator`) adalah pilihan yang tepat dalam pengujian: allocator ini akan mendeteksi kebocoran apapun jika jalur `free` rusak.

---

## Catatan RFC

- **RFC 768 (UDP)**: Port 0 adalah reserved. `init()` menolaknya dengan `error.PortNotConfigured`. Payload maksimum adalah 65.507 byte, diberlakukan saat comptime melalui `@compileError`.
- **RFC 791 / konvensi jaringan**: `Endianness.BIG` bersesuaian dengan network byte order (big-endian).
- Deteksi disconnect berbasis timeout tidak memiliki RFC (perilaku tingkat aplikasi karena UDP tidak memiliki koneksi).
- Nilai byte ACK (0x06) dan NACK (0x15) adalah kode kontrol ASCII, tidak didefinisikan oleh RFC UDP manapun.

---

## Integrasi Logger

`UdpServerConfig.logger: ?*Logger = null`. Ketika bernilai non-null:
- `system(.INFO, "udp", ...)` saat bind dan shutdown.
- `packet(.RECV, peer, size, err)` di dalam `processPacket` setelah setiap datagram diterima. `peer` adalah alamat pengirim; `size` adalah `@sizeOf(Packet)`.

```zig
var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    .console = .ALWAYS,
});
defer logger.deinit();

var server = try MyServer.init(.{
    .allocator = std.heap.smp_allocator,
    .ip        = "127.0.0.1",
    .port      = 9100,
    .logger    = &logger,
});
```

`frame()` tidak dipanggil secara otomatis oleh UDP server (UDP tidak memiliki lapisan framing). Gunakan `logger.frame()` secara manual di dalam logika pemrosesan kustom jika diperlukan.

Lihat `docs/hld-logger-id.md` untuk format baris log dan detail konfigurasi.

---

## Belum Diimplementasikan

| Fitur | Catatan |
| :- | :- |
| Batching `sendmmsg` | N `send()` berurutan per broadcast, `sendmmsg` akan mereduksi menjadi 1 syscall |
| Interval pengiriman sub-milidetik | `send_every` dalam milidetik, ganti nama ke nanodetik jika diperlukan |
| Penghapusan batas peer yang dialokasikan arena | PoC menggunakan `MAX_BROADCAST_CLIENTS=64`. Implementasi src saat ini menggunakan heap slice tanpa batas |
| Struct feedback yang dapat dikonfigurasi | Saat ini echo mengirimkan kembali packet mentah. Produksi dapat menggunakan tagged result |

<!-- tickrate 64 vs 128 -->

---

###### end of hld-udp
