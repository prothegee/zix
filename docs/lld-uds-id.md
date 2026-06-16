# LLD: zix.Uds

Detail implementasi internal. Untuk alasan desain lihat [`docs/hld-uds-id.md`](hld-uds-id.md) dan ADR-010.

---

## server.zig

### Namespace Server dan factory type

```zig
// Namespace dengan constructor comptime (ADR-039), mengikuti zix.Tcp.
pub const UdsServer = struct {
    pub fn init(comptime handler: HandlerFn, config: UdsServerConfig) !UdsServerImpl(handler)
};

// Factory per-connection: handler dibakukan ke tipe, io dari config.io.
fn UdsServerImpl(comptime handler: HandlerFn) type {
    // config: UdsServerConfig
    // pub fn init(config) !Self          -> error.PathEmpty jika config.path kosong
    // pub fn deinit(self) void           -> no-op: resource dibebaskan di dalam run()
    // pub fn run(self) !void             -> membaca config.io, menjalankan accept loop
}
```

Default echo bawaan adalah `zix.Uds.echoHandler` publik, dilewatkan secara eksplisit ke `init`.

### run()

```
1. unlink config.path (abaikan error, bersihkan socket yang kedaluwarsa)
2. UnixAddress.init(config.path)
3. ua.listen(io, .{ .kernel_backlog = config.backlog }) -> net_server
4. defer: net_server.deinit(io) + unlink config.path
5. loop accept:
       stream = net_server.accept(io)   // blokir sampai ada koneksi
       task = ConnTask{ stream, io, handler }
       io.concurrent(dispatchConn, .{task}) catch dispatchConn(task)
```

Accept berjalan single-threaded (pola mirip `.ASYNC`). Setiap koneksi di-dispatch melalui `io.concurrent()` agar loop accept tidak diblokir oleh handler yang lambat.

### ConnTask

Struct privat yang diteruskan by value ke `io.concurrent()`:

```zig
const ConnTask = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    handler: HandlerFn,
};
```

### echoHandler()

```
defer stream.close(io)
loop:
    baca header 4-byte (loop sampai 4 byte diterima)
    len = readInt(u32, &hdr, .little)
    if len > payload_buf.len (4096): return  // terlalu besar, tutup koneksi
    baca len byte payload
    tulis hdr + payload kembali (echo)
    flush
```

Hanya menggunakan stack buffer (tidak ada alokasi heap di dalam `echoHandler`).

---

## client.zig

### UdsClient

```zig
pub const UdsClient = struct {
    stream: std.Io.net.Stream,
    config: UdsClientConfig,

    pub fn connect(config: UdsClientConfig, io: std.Io) !Self
    pub fn deinit(self: *Self, io: std.Io) void   // calls stream.close(io)
    pub fn sendMsg(self: *Self, io: std.Io, msg: []const u8) !void
    pub fn recvMsg(self: *Self, io: std.Io, buf: []u8) ![]u8
};
```

### sendMsg()

```
tulis [u32 len, LE][payload]
flush
```

Stack write buffer (4096 byte). Blokir sampai frame terkirim.

### recvMsg()

```
baca header 4-byte (loop sampai 4 byte)
len = readInt(u32, &hdr, .little)
if len > buf.len: return error.MessageTooLarge
baca len byte payload ke dalam buf[0..len]
return buf[0..len]
```

Stack read buffer (4096 byte). Mengembalikan slice ke dalam `buf` milik pemanggil.

---

## config.zig

```zig
pub const UdsServerConfig = struct {
    path:        []const u8,
    allocator:   std.mem.Allocator,  // unused in current impl: reserved for future extensions
    backlog:     u31  = 128,
    max_msg_len: usize = 4096,
};

pub const UdsClientConfig = struct {
    path: []const u8,
};
```

`allocator` ada di `UdsServerConfig` untuk konsistensi API dengan `UdpServerConfig` dan untuk mengakomodasi ekstensi di masa depan (misalnya connection pool, alokasi per-koneksi). Implementasi saat ini tidak melakukan alokasi heap: semua buffer bersifat stack-local di dalam handler.

---

###### end of lld-uds
