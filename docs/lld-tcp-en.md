# LLD: zix.Tcp (raw stream)

Internal implementation details. For design rationale see [`docs/hld-tcp.md`](hld-tcp.md) and ADR-022.

---

## server.zig

### TcpServer

```zig
pub const TcpServer = struct {
    config: TcpServerConfig,

    pub fn init(config: TcpServerConfig) !Self       // error.PortNotConfigured if port == 0
    pub fn initArgs(config: TcpServerConfig, args: anytype) !Self
    pub fn deinit(self: *Self) void                  // no-op
    pub fn run(self: *Self, io: std.Io) !void        // uses echoHandler
    pub fn runWith(self: *Self, io: std.Io, handler: HandlerFn) !void
};
```

### runWith() — ASYNC path

```
1. resolve ip:port -> addr
2. addr.listen(io, .{ .mode = .stream, .protocol = .tcp, .reuse_address = true, .kernel_backlog = cfg.kernel_backlog })
3. defer net_server.deinit(io)
4. loop:
       stream = net_server.accept(io)
       task = ConnTask{ stream, io, handler }
       io.async(dispatchConn, .{task})
```

Single accept thread. Each connection is dispatched as an `io.async()` task. The accept loop never blocks on connection handling.

### runWith() — POOL path

```
1. worker_count = cfg.workers  (0 -> cpu_count)
   pool_count   = cfg.pool_size (0 -> max(10, cpu_count * 2))
2. var queue = ConnQueue{}
3. spawn pool_count pool threads: poolEntry(&queue, io, handler)
4. spawn worker_count accept threads: workerEntry(cfg, &queue, io)
5. join accept threads
6. queue.close(io)   <- signals pool threads to drain and exit
7. join pool threads
```

Accept threads and pool threads share the same `io` handle (passed by value; `std.Io.Threaded` is thread-safe).

### runWith() — MIXED path

```
1. worker_count = cfg.workers (0 -> cpu_count)
2. spawn worker_count accept threads: asyncWorkerEntry(cfg, io, handler)
3. join accept threads
```

Each accept thread listens on the same port (SO_REUSEPORT via `.reuse_address = true`) and dispatches via `io.async()`. No shared queue.

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

- `push` uses `smp_allocator` directly — no per-connection arena.
- On OOM in `push`, the stream is closed and the connection dropped.
- `pop` returns `null` only after `close()` has been called and the queue is fully drained.
- `orderedRemove(0)` preserves arrival order (FIFO).

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

`dispatchConn` is the comptime-known function passed to `io.async()`. The runtime function pointer (`handler`) is stored inside `ConnTask` and called through at runtime.

### workerEntry (POOL accept thread)

```
resolve ip:port
listen with .reuse_address = true
loop:
    stream = accept(io)
    if err != ConnectionAborted: break
    queue.push(stream, io)
```

### poolEntry (POOL pool thread)

```
loop:
    stream = queue.pop(io)   <- blocks until connection or close
    if null: break
    handler(stream, io)      <- synchronous blocking I/O
```

### asyncWorkerEntry (MIXED accept thread)

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
    len = rdr.interface.takeVarInt(u32, .big, 4)   <- reads exactly 4 bytes as big-endian u32
    if len == 0 or len > 4096: return              <- oversized or empty frame -> close
    rdr.interface.readSliceAll(payload_buf[0..len]) <- reads exactly len bytes
    writeInt(u32, &hdr, len, .big)
    wtr.interface.writeAll(&hdr)
    wtr.interface.writeAll(payload_buf[0..len])
    wtr.interface.flush()
```

Stack buffers only — no heap allocation inside `echoHandler`. Uses `takeVarInt` (reads exactly N bytes as int) and `readSliceAll` (reads exactly N bytes, errors on short read) rather than the `readSliceShort` loop used in `zix.Uds.echoHandler`.

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

Stack write buffer (4100 bytes). All writes are buffered and sent in a single flush syscall for small messages.

### recvMsg()

```
var rbuf [4096+4]u8 = undefined
rdr = stream.reader(io, &rbuf)
len = rdr.interface.takeVarInt(u32, .big, 4) catch return error.ConnectionClosed
if len > buf.len: return error.MessageTooLarge
rdr.interface.readSliceAll(buf[0..len]) catch return error.ConnectionClosed
return buf[0..len]
```

Stack read buffer (4100 bytes). Returns a slice into the caller's `buf`. The caller controls buffer lifetime.

### connectArgs() / initArgs()

```zig
var it = std.process.Args.Iterator.init(args);
_ = it.skip();   // skip argv[0]
while (it.next()) |arg| {
    if eql(arg, "--ip")   -> cfg.ip   = next val
    if eql(arg, "--port") -> cfg.port = parseInt(next val) catch cfg.port
}
```

Pattern shared by `TcpServer.initArgs` and `TcpClient.connectArgs`. Unknown args are silently skipped. Parsing failure for `--port` keeps the config default.

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

`DispatchModel` is defined once in `src/tcp/config.zig` and re-exported as `zix.Tcp.DispatchModel`. HTTP and FIX configs import it from there. The backing type is `u8` per the project enum convention.

`max_msg_len` in both configs is a runtime validation threshold, not a comptime buffer size. The I/O buffers in `echoHandler`, `sendMsg`, and `recvMsg` are stack-allocated to `4096 + 4` bytes regardless of the config value.

---

###### end of lld-tcp
