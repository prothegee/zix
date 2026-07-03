# TCP Server/Client Specification -- zix.Tcp

Research notes and confirmed behaviors for the raw TCP transport layer.
This document covers the PoC phase only. Architectural decisions will move to `docs/adr.md` once finalized.

---

## Scope

Raw `zix.Tcp.Server` and `zix.Tcp.Client`.
No framing, no protocol awareness. The caller owns all bytes on the stream.

FIX protocol (`zix.Tcp.Fix`) builds on top of this layer and is tracked separately.

---

## Use case

Tcp Server:
- Custom binary protocol
- FiX

---

## Zig 0.16.x Std Primitives (TCP)

These are the foundational std calls for raw TCP. Order reflects server lifecycle.

### Server side

```
IpAddress.parse(text, port)             -> IpAddress    (IPv4/IPv6 literal, no io)
IpAddress.resolve(io, text, port)       -> IpAddress    (hostname, needs io for syscall)

IpAddress.listen(io, .{
    .mode           = .stream,
    .protocol       = .tcp,
    .reuse_address  = true,             -- SO_REUSEADDR + SO_REUSEPORT on POSIX
    .kernel_backlog = N,
}) -> net.Server

net_server.accept(io)                   -> net.Stream   (blocks until TCP connect)
net_server.deinit(io)                   -- releases listening socket

stream.reader(io, &buf_read)            -> net.Stream.Reader
stream.writer(io, &buf_write)           -> net.Stream.Writer

net.Stream.Reader wraps Io.Reader in an .interface field.
net.Stream.Writer wraps Io.Writer in an .interface field.
All rich read/write methods live on the .interface, not on the net wrapper directly.

reader.interface.takeVarInt(u32, .big, 4)    -> u32   (reads 4 bytes as big-endian u32)
reader.interface.readSliceAll(buf[0..n])     -> void  (reads exactly n bytes, errors on short)
writer.interface.writeAll(data)              -> void
writer.interface.flush()                     -> void  (flushes write buffer to socket)
stream.close(io)                             -- closes connection
```

### Client side

```
IpAddress.parse(text, port)             -> IpAddress

IpAddress.connect(io, .{
    .mode     = .stream,
    .protocol = .tcp,
}) -> net.Stream

stream.reader(io, &buf_read)            -> Reader
stream.writer(io, &buf_write)           -> Writer
stream.close(io)
```

### Key distinction from HTTP PoC

The HTTP PoC wraps `stream.reader()` / `stream.writer()` in `std.http.Server`.
Raw TCP does not: bytes flow directly through `Reader` and `Writer`.
All framing, parsing, and protocol state is the caller's responsibility.

---

## Dispatch Models

All three dispatch models apply to raw TCP, same as HTTP.
The `DispatchModel` enum is defined in `src/tcp/config.zig` and re-exported as `zix.Tcp.DispatchModel`.

| Model | Accept threads | Dispatch mechanism | Use case |
| :- | :- | :- | :- |
| POOL | N (cpu_count) | `ConnQueue` + M `std.Thread.spawn` pool threads | high throughput, short-lived sessions |
| ASYNC | 1 | `io.async()` per connection | low latency, long-lived sessions |
| MIXED | N (cpu_count) | `io.async()` per accept thread, no `ConnQueue` | balanced, no queue overhead |

`SO_REUSEPORT` (via `.reuse_address = true`) enables multiple accept threads binding the same port for POOL and MIXED.

`ConnQueue` is shared between accept threads (producers) and pool threads (consumers).
`io.async()` falls back to inline on the calling thread when the async limit is reached.

---

## Concurrency Primitives (std.Io)

```
io.concurrent(fn, args)     -- POOL: submits to shared thread pool, falls back inline
io.async(fn, args)          -- ASYNC/MIXED: io_uring/kqueue event-driven dispatch
std.Io.Threaded             -- when server creates its own io backend
std.Thread.spawn            -- for spawning N accept threads (POOL/MIXED)
```

---

## Buffer Strategy

Stack-allocated per connection. No arena needed for the transport layer itself.
Protocol layers above (e.g., FIX) may add per-session arena allocation.

```zig
var buf_read:  [config.max_client_request]u8 = undefined;
var buf_write: [config.max_client_response]u8 = undefined;
var rd = stream.reader(io, &buf_read);
var wr = stream.writer(io, &buf_write);
```

---

## Planned API Sketch

### Server

```zig
pub const HandlerFn = *const fn (stream: std.Io.net.Stream, io: std.Io) void;

var server = try zix.Tcp.Server.init(.{
    .ip             = "127.0.0.1",
    .port           = 9200,
    .dispatch_model = .POOL,
    .workers        = 0,       // 0 = cpu_count accept threads
    .pool_size      = 0,       // 0 = max(10, cpu_count * 2) pool threads (POOL only)
    .backlog        = 1024 * 4,
});
defer server.deinit();
try server.runWith(process.io, myHandler);
```

Handler contract (same as UDS):

```zig
fn myHandler(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);
    var buf_read:  [4096]u8 = undefined;
    var buf_write: [4096]u8 = undefined;
    var rd = stream.reader(io, &buf_read);
    var wr = stream.writer(io, &buf_write);
    // read raw bytes, apply own framing, write response
}
```

### Client

```zig
var client = try zix.Tcp.Client.connect(.{
    .ip   = "127.0.0.1",
    .port = 9200,
}, io);
defer client.deinit(io);

try client.send(io, data);
const n = try client.recv(io, &buf);
```

---

## Planned Config Fields

### TcpServerConfig

| Field | Type | Default | Notes |
| :- | :- | :- | :- |
| `ip` | `[]const u8` | required | bind address |
| `port` | `u16` | required | bind port, non-zero |
| `dispatch_model` | `DispatchModel` | `.POOL` | selects concurrency model |
| `workers` | `usize` | `0` | 0 = cpu_count (ignored by ASYNC) |
| `pool_size` | `usize` | `0` | 0 = max(10, cpu_count * 2) (POOL only) |
| `backlog` | `usize` | `4096` | kernel listen backlog |
| `max_client_request` | `usize` | `4096` | read buffer per connection |
| `max_client_response` | `usize` | `4096` | write buffer per connection |

### TcpClientConfig

| Field | Type | Default | Notes |
| :- | :- | :- | :- |
| `ip` | `[]const u8` | required | remote address |
| `port` | `u16` | required | remote port, non-zero |

---

## PoC Files

All 4 PoC files implemented (2026-05-18). Verified std API surface before `src/tcp/`.

| File | Model | Port | Purpose |
| :- | :- | :- | :- |
| `rnd/tcp_poc_model_1_async.zig` | ASYNC | 9200 | single accept + `io.async()` per connection |
| `rnd/tcp_poc_model_2_pool.zig` | POOL | 9201 | `ConnQueue` + N accept threads + M pool threads |
| `rnd/tcp_poc_model_3_mixed.zig` | MIXED | 9202 | N accept threads each `io.async()` directly |
| `rnd/tcp_poc_client.zig` | client | 9200 (default) | shared client, `--ip`/`--port` args |

src/ implementation: `src/tcp/server.zig`, `src/tcp/client.zig`, `src/tcp/config.zig`, `src/tcp/Tcp.zig`.

---

## Relationship to Existing Code

| | TCP raw (this) | zix.Http | zix.Uds |
| :- | :- | :- | :- |
| Transport | `std.Io.net` (IP) | `std.Io.net` (IP) | `std.Io.net` (Unix) |
| Framing | caller | HTTP/1.1 | length-prefix |
| Dispatch | POOL/ASYNC/MIXED | POOL/ASYNC/MIXED | `io.concurrent` only |
| Config | `TcpServerConfig` | `HttpServerConfig` | `UdsServerConfig` |
| HandlerFn signature | `(stream, io)` | `(req, res, ctx)` | `(stream, io)` |

`HandlerFn` for TCP raw is identical to UDS. The server skeleton can share the same dispatch infrastructure.

---

## Real-World Attempt

Design decisions confirmed from PoC design session (2026-05-18).

### Echo Protocol (PoC framing)

All 3 PoC files use the same length-prefix framing to verify the std API surface.
This is not the production API. Production callers define their own framing.

```
client -> server:   [4 bytes u32 big-endian: payload length][N bytes: payload]
server -> client:   [4 bytes u32 big-endian: payload length][N bytes: payload]  (echo)
```

### Handler (identical across all 3 models)

```zig
const MAX_MSG: usize = 4096;

fn handleConnection(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);

    var rd_buf: [MAX_MSG + 4]u8 = undefined;
    var wr_buf: [MAX_MSG + 4]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    while (true) {
        const len = rd.takeVarInt(u32, .big, 4) catch break;
        if (len == 0 or len > MAX_MSG) break;

        var body: [MAX_MSG]u8 = undefined;
        rd.readSliceAll(body[0..len]) catch break;

        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, len, .big);
        wr.writeAll(&hdr) catch break;
        wr.writeAll(body[0..len]) catch break;
        wr.flush() catch break;
    }
}
```

### What is removed vs the HTTP PoC

| HTTP PoC had | TCP raw PoC | Reason |
| :- | :- | :- |
| HTTP request parser (~80 lines) | removed | no protocol layer |
| Date cache + timer thread | removed | no HTTP headers |
| `fdWriteAll` posix workaround | removed | `stream.reader/writer` used directly |
| `std.http.Server` wrapper | removed | raw byte stream |

### Dispatch per model

**ASYNC (`main` only, no extra threads):**

```zig
pub fn main(process: std.process.Init) !void {
    const io = process.io;
    const addr = try std.Io.net.IpAddress.resolve(io, IP, PORT);
    var net_server = try addr.listen(io, .{ .mode = .stream, .protocol = .tcp,
        .reuse_address = true, .kernel_backlog = 4096 });
    defer net_server.deinit(io);
    while (true) {
        const stream = net_server.accept(io) catch continue;
        _ = io.async(handleConnection, .{ stream, io });
    }
}
```

**POOL (ConnQueue + explicit threads, owned io):**

```zig
fn acceptEntry(ctx: AcceptCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, IP, PORT) catch return;
    var net_server = addr.listen(ctx.io, .{ .reuse_address = true, ... }) catch return;
    defer net_server.deinit(ctx.io);
    while (true) {
        const stream = net_server.accept(ctx.io) catch continue;
        ctx.queue.push(stream, ctx.io);
    }
}

fn poolEntry(ctx: PoolCtx) void {
    while (ctx.queue.pop(ctx.io)) |stream| handleConnection(stream, ctx.io);
}
```

**MIXED (N accept threads, each `io.async()`, no ConnQueue, owned io):**

```zig
fn acceptEntry(io: std.Io) void {
    const addr = std.Io.net.IpAddress.resolve(io, IP, PORT) catch return;
    var net_server = addr.listen(io, .{ .reuse_address = true, ... }) catch return;
    defer net_server.deinit(io);
    while (true) {
        const stream = net_server.accept(io) catch continue;
        _ = io.async(handleConnection, .{ stream, io });
    }
}
```

### ConnQueue (POOL only)

Copy of `ConnQueue` from `rnd/archieve-0.1.x/http_poc_model_2_pool.zig`, model-independent,
no changes needed. Uses `std.Io.Mutex` + `std.Io.Condition` + `std.ArrayListUnmanaged`.

### Client (shared across all 3 models)

One client file covers all 3 server models. The dispatch model (ASYNC/POOL/MIXED) is a
server-side concern only. Once the TCP connection is established the stream is identical
to the client regardless of which model answered it.

Target model is selected by changing the `PORT` constant:

| PORT | Server model |
| :- | :- |
| 9200 | `tcp_poc_model_1_async.zig` |
| 9201 | `tcp_poc_model_2_pool.zig` |
| 9202 | `tcp_poc_model_3_mixed.zig` |

Client mirrors the handler in reverse:

| Server handler step | Client step |
| :- | :- |
| reads length prefix | writes length prefix |
| reads payload | writes payload + flush |
| writes length prefix | reads length prefix |
| writes payload + flush | reads payload |

```zig
const addr   = try std.Io.net.IpAddress.resolve(io, IP, PORT);
const stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
defer stream.close(io);

var rd_buf: [MAX_MSG + 4]u8 = undefined;
var wr_buf: [MAX_MSG + 4]u8 = undefined;
var rd = stream.reader(io, &rd_buf);
var wr = stream.writer(io, &wr_buf);

var hdr: [4]u8 = undefined;
std.mem.writeInt(u32, &hdr, @intCast(MESSAGE.len), .big);
try wr.writeAll(&hdr);
try wr.writeAll(MESSAGE);
try wr.flush();

const len = try rd.takeVarInt(u32, .big, 4);
var body: [MAX_MSG]u8 = undefined;
try rd.readSliceAll(body[0..len]);
```

### Message Types and Protocol Semantics

The length-prefix framing defines the boundary of each message. It says nothing about
what the payload means. Content semantics are the application's responsibility.

#### Framing vs content contract

| Layer | Defined by | What it covers |
| :- | :- | :- |
| Framing | `[u32 len][payload]` | where each message starts and ends |
| Content | application | what the payload bytes mean |

Without a content contract the client receives bytes it cannot interpret, it can
only print them as a string. This is sufficient for the echo PoC but not for a real protocol.

#### Adding a message type byte

Standard approach: prepend a type byte inside the payload, before the body.

```
[4 bytes: total payload length][1 byte: msg type][N bytes: body]
```

Both sides share the same enum:

```zig
const MsgType = enum(u8) {
    REQUEST  = 0,
    RESPONSE = 1,
    ERROR    = 2,
};
```

Client read side:

```zig
const len  = try rd.interface.takeVarInt(u32, .big, 4);
const kind = try rd.interface.takeVarInt(u8,  .big, 1);

switch (@as(MsgType, @enumFromInt(kind))) {
    .RESPONSE => // handle normal response
    .ERROR    => // handle server error
    else      => break,
}
```

#### Client can send different types in the same connection

Unlike UDP (fixed packet struct, every message the same shape), TCP allows the client
to send different message types on the same connection depending on what is happening:

```
Client -> Server:   [len][TYPE=LOGIN ][credentials]
Server -> Client:   [len][TYPE=OK    ][session token]

Client -> Server:   [len][TYPE=DATA  ][payload]
Server -> Client:   [len][TYPE=DATA  ][result]

Client -> Server:   [len][TYPE=DATA  ][bad payload]
Server -> Client:   [len][TYPE=ERROR ][reason]
```

Same connection, multiple message types, both directions.

#### TCP vs UDP feedback: not the same

| | UDP (zix) | TCP raw |
| :- | :- | :- |
| Packet shape | one fixed `extern struct` | variable, defined per message type |
| Client sends different types | no, always the same struct | yes, type byte determines shape |
| Server response types | fixed: ack / nack / packet | anything the application defines |
| Connection state | none (each datagram independent) | yes, session persists across messages |
| Protocol definition | zix (partially) | entirely the application |

UDP is suitable when all messages have the same shape (telemetry, position, sensor).
TCP is suitable when the conversation has multiple stages or message kinds (login, query, logout).

#### Why `nc`/`socat` cannot talk to the PoC server

`nc` and `socat` send raw text with no length prefix. The server reads the first 4 bytes
as a u32 length (`Hell` = 1,214,606,444), exceeds `MAX_MSG`, and closes the connection.
Only a client that prepends the correct 4-byte header is a valid peer.

A Python client that would work:

```python
import socket, struct
s = socket.create_connection(("127.0.0.1", 9200))
msg = b"Hello from Python"
s.sendall(struct.pack(">I", len(msg)) + msg)
hdr  = s.recv(4)
body = s.recv(struct.unpack(">I", hdr)[0])
print(body.decode())   # Hi from TCP Server
s.close()
```

The framing is the protocol. Any language that implements the same byte layout is a valid client.

#### Path-style endpoints (`ip:port/foo`) do not apply to raw TCP

Paths are an HTTP (Layer 7) concept. Raw TCP's endpoint is `ip:port` only.
The connection has no concept of routes, methods, or paths. The handler owns the
entire stream. For path-based routing use `zix.Http.Server`.

#### `rd_buf` size: why `MAX_MSG + 4`

`rd_buf` is the internal staging area the reader fills from the socket in one syscall.
When `takeVarInt` triggers a socket read, the OS may deliver the header AND payload
together. If `rd_buf` is only `[MAX_MSG]u8`, a max-sized message (4 + MAX_MSG bytes)
overflows by 4, the last 4 bytes remain in the socket buffer and require a second
syscall during `readSliceAll`. Sizing to `MAX_MSG + 4` fits one complete framed message
in one fill, avoiding that extra syscall for the worst case.

For messages smaller than MAX_MSG the `+ 4` has no effect. It is a correctness-neutral
optimization and an intent signal: this buffer is sized to one full framed message.

Step-by-step with `MAX_MSG + 4`:

```
Socket delivers: [00 00 00 15][Hello from TCP client]   (4 + 21 = 25 bytes)

Step 1 -- takeVarInt triggers fill:
  rd_buf: [00 00 00 15 H e l l o  f r o m  T C P  c l i e n t _ _ ...]
           consumed ^   remaining in rd_buf ^

Step 2 -- takeVarInt consumes 4 bytes -> len = 21

Step 3 -- readSliceAll(body[0..21]) drains rd_buf -> no extra syscall
```

#### Header validation in the PoC

The PoC performs minimal validation: only the length field is checked:

```zig
const len = rd.interface.takeVarInt(u32, .big, 4) catch break;
if (len == 0 or len > MAX_MSG) break;
```

No magic number, no version check, no checksum. This is sufficient for a local echo
but not for a production protocol exposed to untrusted clients.

#### Length prefix size: not always 4 bytes

The prefix size is a protocol design decision based on the maximum expected payload:

| Prefix | Type | Max payload | When to use |
| :- | :- | :- | :- |
| 1 byte | `u8` | 255 bytes | IoT sensors, tiny fixed commands |
| 2 bytes | `u16` | 65,535 bytes | game state, moderate payloads |
| 4 bytes | `u32` | ~4 GB | most general-purpose protocols (PoC default) |
| 8 bytes | `u64` | ~18 EB | large binary streams, file transfer |
| varint (LEB128) | variable | unlimited | protobuf, gRPC, compact for small messages |

4 bytes is the most common default: covers virtually all practical sizes, naturally aligned.

#### What a real protocol header carries

A production header validates more than just length:

```
[2 bytes: magic number]   -- identifies this protocol, rejects garbage connections
[1 byte:  version]        -- allows protocol upgrades without breaking old clients
[1 byte:  msg type]       -- what kind of message this is
[4 bytes: payload length] -- how many bytes follow
[4 bytes: CRC32]          -- integrity check
= 12 bytes total header
```

Server validates each field in order: reject early on any mismatch:

```zig
const magic   = rd.interface.takeVarInt(u16, .big, 2) catch break;
if (magic != MAGIC) break;

const version = rd.interface.takeVarInt(u8, .big, 1) catch break;
if (version != PROTOCOL_VERSION) break;

const kind    = rd.interface.takeVarInt(u8,  .big, 1) catch break;
const len     = rd.interface.takeVarInt(u32, .big, 4) catch break;
if (len == 0 or len > MAX_MSG) break;

const crc_expected = rd.interface.takeVarInt(u32, .big, 4) catch break;

var body: [MAX_MSG]u8 = undefined;
rd.interface.readSliceAll(body[0..len]) catch break;

const crc_actual = std.hash.Crc32.hash(body[0..len]);
if (crc_actual != crc_expected) break;
```

#### Delimiter-based framing: no length prefix

Some protocols skip the length prefix and scan for a sentinel byte instead:

| Protocol | Sentinel | Notes |
| :- | :- | :- |
| FIX | SOH (0x01) between fields, `10=checksum\x01` ends message | ASCII tag=value |
| HTTP | `\r\n\r\n` ends headers, `Content-Length` or chunked for body | text-based |
| Redis (RESP) | `\r\n` terminates each line | text-based |
| SMTP | `.` on its own line ends body | text-based |

Delimiter scanning requires reading byte-by-byte or buffering until the sentinel appears,
slower than length-prefix for large payloads. Suitable for text protocols where
readability matters more than throughput.

### PoC files

| File | Role | Port |
| :- | :- | :- |
| `rnd/tcp_poc_model_1_async.zig` | server, ASYNC | 9200 |
| `rnd/tcp_poc_model_2_pool.zig` | server, POOL | 9201 |
| `rnd/tcp_poc_model_3_mixed.zig` | server, MIXED | 9202 |
| `rnd/tcp_poc_client.zig` | client, shared | 9200 default, `--ip`/`--port` args |

### How to run

Start one server model, then run the client in a separate terminal.

ASYNC server (port 9200):
```sh
zig run rnd/tcp_poc_model_1_async.zig
```

POOL server (port 9201):
```sh
zig run rnd/tcp_poc_model_2_pool.zig
```

MIXED server (port 9202):
```sh
zig run rnd/tcp_poc_model_3_mixed.zig
```

Client (default connects to port 9200):
```sh
zig run rnd/tcp_poc_client.zig
```

Client (target a specific model):
```sh
zig run rnd/tcp_poc_client.zig -- --port 9201
zig run rnd/tcp_poc_client.zig -- --ip 127.0.0.1 --port 9202
```

---

###### end of tcp server specification
