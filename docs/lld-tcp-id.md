# LLD: zix.Tcp (raw stream)

Detail implementasi internal. Untuk dasar keputusan desain lihat [`docs/hld-tcp-id.md`](hld-tcp-id.md) dan ADR-022.

---

## server.zig

### Namespace Server dan factory type

```zig
// Namespace tanpa field dengan constructor comptime (ADR-038).
pub const Server = struct {
    pub fn init(comptime handler: HandlerFn, config: TcpServerConfig) !TcpServerImpl(handler)
    pub fn initArgs(comptime handler: HandlerFn, config: TcpServerConfig, args: anytype) !TcpServerImpl(handler)
    pub fn initFramed(comptime frame_fn: FrameFn, config: TcpServerConfig) !TcpFramedServerImpl(frame_fn)
    pub fn initFramedArgs(comptime frame_fn: FrameFn, config: TcpServerConfig, args: anytype) !TcpFramedServerImpl(frame_fn)
};

// Factory per-connection: handler dibakukan ke tipe, run() hanya menerima io.
fn TcpServerImpl(comptime handler: HandlerFn) type        // .init(config) -> error.PortNotConfigured jika port == 0; .deinit() no-op; .run() membaca config.io
fn TcpFramedServerImpl(comptime frame_fn: FrameFn) type   // .init(config); .deinit(); .run() -> ring di .URING, selain itu fallback frameAdapter

// Worker dispatch bebas (handler disimpan sebagai nilai runtime, bentuk sama seperti zix.Http1):
fn serveDispatch(cfg: TcpServerConfig, io: std.Io, handler: HandlerFn) !void  // switch ASYNC/POOL/MIXED/EPOLL
fn runEpoll(cfg: TcpServerConfig, io: std.Io, handler: HandlerFn, cpu: usize) !void
```

Handler (atau callback per-frame) diketahui comptime di batas tipe, tetapi fungsi worker internal menerimanya sebagai nilai runtime, sehingga `serveDispatch` / `runEpoll` dibagi lintas setiap spesialisasi tanpa code bloat per-handler (ADR-038). Default echo bawaan adalah `zix.Tcp.echoHandler` publik, dilewatkan secara eksplisit ke `init`.

### serveDispatch jalur ASYNC

```
1. resolve ip:port -> addr
2. addr.listen(io, .{ .mode = .stream, .protocol = .tcp, .reuse_address = true, .kernel_backlog = cfg.kernel_backlog })
3. defer net_server.deinit(io)
4. loop:
       stream = net_server.accept(io)
       task = ConnTask{ stream, io, handler }
       io.async(dispatchConn, .{task})
```

Satu accept thread. Setiap koneksi didispatch sebagai task `io.async()`. Accept loop tidak pernah memblokir pada penanganan koneksi.

### serveDispatch jalur POOL

```
1. worker_count = cfg.workers  (0 -> cpu_count)
   pool_count   = cfg.pool_size (0 -> max(10, cpu_count * 2))
2. var queue = ConnQueue{}
3. spawn pool_count pool threads: poolEntry(&queue, io, handler)
4. spawn worker_count accept threads: workerEntry(cfg, &queue, io)
5. join accept threads
6. queue.close(io)   <- memberi sinyal ke pool thread untuk menguras antrian dan keluar
7. join pool threads
```

Accept thread dan pool thread berbagi handle `io` yang sama (diteruskan sebagai nilai; `std.Io.Threaded` bersifat thread-safe).

### serveDispatch jalur MIXED

```
1. worker_count = cfg.workers (0 -> cpu_count)
2. spawn worker_count accept threads: asyncWorkerEntry(cfg, io, handler)
3. join accept threads
```

Setiap accept thread mendengarkan pada port yang sama (SO_REUSEPORT melalui `.reuse_address = true`) dan mendispatch melalui `io.async()`. Tidak ada antrian bersama.

### ConnQueue

```zig
const ConnQueue = struct {
    mutex:  std.Io.Mutex                              = .init,
    ready:  std.Io.Condition                          = .init,
    items:  std.ArrayListUnmanaged(std.Io.net.Stream) = .empty,
    closed: bool                                      = false,

    fn push(self, stream, io) void   // lock -> append -> unlock -> signal
    fn pop(self, io) ?Stream         // lock -> wait while empty -> orderedRemove(0) -> unlock
    fn close(self, io) void          // lock -> closed=true -> unlock -> broadcast
    fn deinit(self) void             // items.deinit(smp_allocator)
};
```

- `push` menggunakan `smp_allocator` secara langsung, tidak ada arena per koneksi.
- Jika OOM terjadi di `push`, stream ditutup dan koneksi dibuang.
- `pop` mengembalikan `null` hanya setelah `close()` dipanggil dan antrian sudah sepenuhnya terkuras.
- `orderedRemove(0)` menjaga urutan kedatangan (FIFO).

### ConnTask

```zig
const ConnTask = struct {
    stream:  std.Io.net.Stream,
    io:      std.Io,
    handler: HandlerFn,
};

fn dispatchConn(task: ConnTask) void {
    task.handler(task.stream, task.io);
}
```

`dispatchConn` adalah fungsi yang diketahui pada comptime yang diteruskan ke `io.async()`. Function pointer runtime (`handler`) disimpan di dalam `ConnTask` dan dipanggil saat runtime.

### workerEntry (accept thread POOL)

```
resolve ip:port
listen with .reuse_address = true
loop:
    stream = accept(io)
    if err != ConnectionAborted: break
    queue.push(stream, io)
```

### poolEntry (pool thread POOL)

```
loop:
    stream = queue.pop(io)   <- memblokir hingga ada koneksi atau antrian ditutup
    if null: break
    handler(stream, io)      <- blocking I/O sinkron
```

### asyncWorkerEntry (accept thread MIXED)

```
resolve ip:port
listen with .reuse_address = true
loop:
    stream = accept(io)
    if err != ConnectionAborted: break
    io.async(dispatchConn, ConnTask{ stream, io, handler })
```

### echoHandler()

```
defer stream.close(io)
var rbuf, wbuf [4096+4]u8 = undefined
var payload_buf [4096]u8 = undefined
rdr = stream.reader(io, &rbuf)
wtr = stream.writer(io, &wbuf)
loop:
    len = rdr.interface.takeVarInt(u32, .big, 4)   <- membaca tepat 4 byte sebagai big-endian u32
    if len == 0 or len > 4096: return              <- frame kosong atau terlalu besar -> tutup
    rdr.interface.readSliceAll(payload_buf[0..len]) <- membaca tepat len byte
    writeInt(u32, &hdr, len, .big)
    wtr.interface.writeAll(&hdr)
    wtr.interface.writeAll(payload_buf[0..len])
    wtr.interface.flush()
```

Hanya menggunakan stack buffer: tidak ada alokasi heap di dalam `echoHandler`. Menggunakan `takeVarInt` (membaca tepat N byte sebagai integer) dan `readSliceAll` (membaca tepat N byte, error jika kurang) alih-alih loop `readSliceShort` yang digunakan di `zix.Uds.echoHandler`.

---

## client.zig

### TcpClient

```zig
pub const TcpClient = struct {
    stream: std.Io.net.Stream,
    config: TcpClientConfig,

    pub fn connect(config: TcpClientConfig, io: std.Io) !Self
    pub fn connectArgs(config: TcpClientConfig, io: std.Io, args: anytype) !Self
    pub fn deinit(self: *Self, io: std.Io) void        // stream.close(io)
    pub fn sendMsg(self: *Self, io: std.Io, msg: []const u8) !void
    pub fn recvMsg(self: *Self, io: std.Io, buf: []u8) ![]u8
};
```

### connect()

```
if config.port == 0: return error.PortNotConfigured
addr = IpAddress.resolve(io, config.ip, config.port)
stream = addr.connect(io, .{ .mode = .stream, .protocol = .tcp })
```

### sendMsg()

```
if msg.len > config.max_msg_len: return error.MessageTooLarge
var wbuf [4096+4]u8 = undefined
wtr = stream.writer(io, &wbuf)
writeInt(u32, &hdr, msg.len, .big)
wtr.interface.writeAll(&hdr)
wtr.interface.writeAll(msg)
wtr.interface.flush()
```

Stack write buffer (4100 byte). Semua penulisan di-buffer dan dikirim dalam satu flush syscall untuk pesan berukuran kecil.

### recvMsg()

```
var rbuf [4096+4]u8 = undefined
rdr = stream.reader(io, &rbuf)
len = rdr.interface.takeVarInt(u32, .big, 4) catch return error.ConnectionClosed
if len > buf.len: return error.MessageTooLarge
rdr.interface.readSliceAll(buf[0..len]) catch return error.ConnectionClosed
return buf[0..len]
```

Stack read buffer (4100 byte). Mengembalikan slice ke dalam `buf` milik pemanggil. Pemanggil mengendalikan masa hidup buffer.

### connectArgs() / initArgs()

```zig
var it = std.process.Args.Iterator.init(args);
_ = it.skip();   // skip argv[0]
while (it.next()) |arg| {
    if eql(arg, "--ip")   -> cfg.ip   = next val
    if eql(arg, "--port") -> cfg.port = parseInt(next val) catch cfg.port
}
```

Pola yang sama digunakan oleh `TcpServer.initArgs` dan `TcpClient.connectArgs`. Argumen yang tidak dikenal dilewati tanpa pesan error. Kegagalan parsing `--port` mempertahankan nilai default dari config.

---

## config.zig

```zig
pub const DispatchModel = enum(u8) {
    ASYNC = 0,
    POOL  = 1,
    MIXED = 2,
};

pub const TcpServerConfig = struct {
    ip:             []const u8,
    port:           u16,
    dispatch_model: DispatchModel = .ASYNC,
    kernel_backlog: u31           = 4096,
    max_msg_len:    usize         = 4096,
    workers:        usize         = 0,
    pool_size:      usize         = 0,
};

pub const TcpClientConfig = struct {
    ip:          []const u8,
    port:        u16,
    max_msg_len: usize = 4096,
};
```

`DispatchModel` didefinisikan sekali di `src/tcp/config.zig` dan di-re-export sebagai `zix.Tcp.DispatchModel`. Config HTTP dan FIX mengimpornya dari sana. Tipe backing adalah `u8` sesuai konvensi enum dalam proyek ini.

`max_msg_len` pada kedua config merupakan ambang validasi runtime, bukan ukuran buffer comptime. Buffer I/O di `echoHandler`, `sendMsg`, dan `recvMsg` dialokasikan di stack dengan ukuran `4096 + 4` byte terlepas dari nilai config.

---

###### end of lld-tcp
