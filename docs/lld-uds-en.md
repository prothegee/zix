# LLD: zix.Uds

Internal implementation details. For design rationale see [`docs/hld-uds.md`](hld-uds.md) and ADR-010.

---

## server.zig

### UdsServer

```zig
pub const UdsServer = struct {
    config: UdsServerConfig,

    pub fn init(config: UdsServerConfig) !Self
    pub fn deinit(self: *Self) void   // no-op: resources released inside run()
    pub fn run(self: *Self, io: std.Io) !void          // uses echoHandler
    pub fn runWith(self: *Self, io: std.Io, handler: HandlerFn) !void
};
```

### runWith()

```
1. unlink config.path (ignore error, stale socket cleanup)
2. UnixAddress.init(config.path)
3. ua.listen(io, .{ .kernel_backlog = config.backlog }) -> net_server
4. defer: net_server.deinit(io) + unlink config.path
5. accept loop:
       stream = net_server.accept(io)   // blocks until connection
       task = ConnTask{ stream, io, handler }
       io.concurrent(dispatchConn, .{task}) catch dispatchConn(task)
```

Accept is single-threaded (`.ASYNC`-style pattern). Each connection is dispatched via `io.concurrent()` so the accept loop is not blocked by slow handlers.

### ConnTask

Private struct passed by value to `io.concurrent()`:

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
    read 4-byte header (loop until 4 bytes received)
    len = readInt(u32, &hdr, .little)
    if len > payload_buf.len (4096): return  // oversized, close
    read len payload bytes
    write hdr + payload back (echo)
    flush
```

Stack buffers only (no heap allocation inside `echoHandler`).

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
write [u32 len, LE][payload]
flush
```

Stack write buffer (4096 bytes). Blocks until the frame is sent.

### recvMsg()

```
read 4-byte header (loop until 4 bytes)
len = readInt(u32, &hdr, .little)
if len > buf.len: return error.MessageTooLarge
read len payload bytes into buf[0..len]
return buf[0..len]
```

Stack read buffer (4096 bytes). Returns a slice into the caller's `buf`.

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

`allocator` is present in `UdsServerConfig` for API consistency with `UdpServerConfig` and to allow future extensions (e.g. connection pool, per-connection allocations). The current implementation does not heap-allocate: all buffers are stack-local inside the handler.

---

###### end of lld-uds
