# HLD: zix.Logger

Structured event logger with thread-safe writes and automatic protocol integration.

---

## Status

Implemented. See ADR-023 for design rationale.

---

## Goals

- Thread-safe from any context including background OS threads (no `std.Io` dependency).
- Structured per-event method signatures rather than printf-style with a category string.
- Protocol-specific log types: `conn()`, `packet()`, `frame()`, `session()` give machine-parseable lines without post-processing.
- File rotation: daily subdirectory + per-file sequence number, no external tooling required.
- Zero allocation on the hot path: 64 KB write buffer flushed after every line written.
- Caller owns the allocator; logger is `init`/`deinit` lifetime.

---

## Source Layout

```
src/logger/
    logger.zig   // Logger struct with nested Config, Level, ConsoleMode, Dir
    Logger.zig   // namespace aggregator
```

Export from `src/zix.zig`:
```zig
pub const Logger = @import("logger/logger.zig").Logger;
// zix.Logger, zix.Logger.Level, zix.Logger.ConsoleMode, zix.Logger.Dir, zix.Logger.Config
```

---

## Public API

| Symbol | Type | Description |
| :- | :- | :- |
| `zix.Logger` | struct | `init(allocator, config)` / `deinit()` / `flush()` |
| `zix.Logger.Config` | struct | Configuration fields (nested type on the struct) |
| `zix.Logger.Level` | enum(u8) | `DEBUG=0` `INFO=1` `WARN=2` `ERROR=3` |
| `zix.Logger.ConsoleMode` | enum(u8) | `OFF=0` `DEBUG_ONLY=1` `ALWAYS=2` |
| `zix.Logger.Dir` | enum(u8) | `RECV=0` `SEND=1` — direction for `packet()` and `frame()` |

---

## Config Fields

| Field | Default | Description |
| :- | :- | :- |
| `console` | `.OFF` | Console output mode |
| `console_min_level` | `.INFO` | Minimum level printed to console |
| `save_path` | `""` | Root directory for log files. Must already exist. `""` disables file logging |
| `save_file` | `"log"` | Base filename. Files named `<save_file>-NNNNNN.log` |
| `save_min_level` | `.INFO` | Minimum level written to file |
| `max_lines` | 1,000,000 | Lines per file before rotating to next sequence number |

---

## Log Methods

| Method | Auto-called by | Level | Line format |
| :- | :- | :- | :- |
| `system(level, component, fmt, args)` | all servers (lifecycle) | caller-set | `DATE TIME LEVEL  [component] message` |
| `access(method, path, status, bytes, ua, origin)` | HTTP server (per-request) | derived from status | `DATE TIME LEVEL  METHOD PATH STATUS BYTES "UA" "ORIGIN"` |
| `conn(peer, dur_ms, err)` | TCP server (per-connection close) | INFO / WARN | `DATE TIME LEVEL  [tcp:conn] PEER dur=NNNms ERR` |
| `packet(dir, peer, size, err)` | UDP server (per-datagram) | INFO / WARN | `DATE TIME LEVEL  [udp:pkt] DIRECTION PEER size=N ERR` |
| `frame(dir, sock_path, size, err)` | UDS (manual) | INFO / WARN | `DATE TIME LEVEL  [uds:frame] DIRECTION SOCKPATH size=N ERR` |
| `session(msg_type, sender, target, seq, state)` | FIX server (per-message) | INFO | `DATE TIME LEVEL  [fix:sess] 35=TYPE sender=S target=T seq=N STATE` |
| `rpc(peer, path, grpc_status, recv_bytes, sent_bytes, dur_ms)` | gRPC server (per-stream close) | INFO / WARN | `DATE TIME LEVEL  [grpc:rpc] PEER PATH status=N recv=N sent=N dur=Nms` |

### Level Derivation

- `access()`: 2xx/3xx=INFO, 4xx=WARN, 5xx=ERROR, other=DEBUG.
- `conn()`: `err == null` -> INFO; `err != null` -> WARN.
- `packet()`, `frame()`: same as `conn()`.
- `session()`: always INFO.
- `rpc()`: `grpc_status == 0` -> INFO; `grpc_status != 0` -> WARN.
- `system()`: caller provides level explicitly.

---

## Line Format Examples

```
2026-05-23 14:22:01.456 INFO   [startup] server listening on 9300
2026-05-23 14:22:01.789 INFO   GET /api/items 200 512 "curl/8.1" "-"
2026-05-23 14:22:01.790 WARN   GET /missing 404 0 "-" "-"
2026-05-23 14:22:02.100 INFO   [tcp:conn] 127.0.0.1:54321 dur=12ms -
2026-05-23 14:22:02.200 INFO   [udp:pkt] recv 127.0.0.1:5001 size=56 -
2026-05-23 14:22:02.300 INFO   [uds:frame] recv /tmp/app.sock size=8 -
2026-05-23 14:22:02.400 INFO   [fix:sess] 35=A sender=CLIENT target=ZIX seq=1 Logon
2026-05-25 10:15:33.201 INFO   [grpc:rpc] 127.0.0.1:56789 /helloworld.Greeter/SayHello status=0 recv=16 sent=22 dur=1ms
```

---

## File Rotation

Files are written to `<save_path>/YYYY-MM-DD/<save_file>-NNNNNN.log`:
- A new date directory is created automatically on the first write of a new calendar day.
- When `line_count` reaches `max_lines`, the sequence number increments and a new file opens.
- Maximum sequence number is 999,999. On exhaustion, file logging suspends and a message is written to stderr.
- `save_path` itself must already exist — the logger does not create it. Use a `createLogDir` helper before `Logger.init`.

---

## Thread Safety

All log methods are safe to call simultaneously from any OS thread:
- A spinlock (atomic CAS) serializes all writes to the shared file buffer and file descriptor.
- `rawWrite` uses the raw POSIX `write` syscall — no `std.Io` dependency, safe on background OS threads.
- No `std.debug.print` or any path through `std.Options.debug_io`. Safe during `zig build test-all`.

---

## Protocol Wiring

Each server accepts an optional `logger: ?*Logger = null` in its config. When non-null, automatic logging is active:

| Protocol | Methods called automatically | Config field |
| :- | :- | :- |
| HTTP | `access()` per request, `system()` lifecycle | `HttpServerConfig.logger` |
| TCP | `conn()` on connection close, `system()` lifecycle | `TcpServerConfig.logger` |
| UDP | `packet()` per datagram, `system()` lifecycle | `UdpServerConfig.logger` |
| UDS | `system()` lifecycle | `UdsServerConfig.logger` |
| FIX | `session()` per message, `system()` lifecycle | `FixServerConfig.logger` |
| gRPC | `rpc()` per stream close, `system()` lifecycle | `GrpcServerConfig.logger` |
| Channel | no server config; call `logger.system()` manually | n/a |

`frame()` is available for manual use inside UDS handlers (the handler owns the stream, so frame-level events are caller-driven).

---

## Usage

```zig
fn createLogDir(io: std.Io) void {
    std.Io.Dir.cwd().createDirPath(io, "./logs") catch {};
}

pub fn main(process: std.process.Init) !void {
    createLogDir(process.io);

    var logger = try zix.Logger.init(std.heap.smp_allocator, .{
        .save_path      = "./logs",
        .save_file      = "app",
        .save_min_level = .INFO,
        .console        = .ALWAYS,
    });
    defer logger.deinit();

    // Manual lifecycle event
    logger.system(.INFO, "startup", "server starting on port {d}", .{9300});

    // Wire into server (automatic access/conn/packet/session logging)
    var server = try zix.Tcp.Server.init(.{
        .ip     = "127.0.0.1",
        .port   = 9300,
        .logger = &logger,
    });
    defer server.deinit();
    try server.runWith(process.io, myHandler);
}
```

---

## Examples

All network server examples include a commented logger init block at the top that can be enabled without code changes:
- `examples/tcp_server_1_async.zig`
- `examples/fix_server_1_async.zig`
- `examples/udp_server.zig`
- `examples/uds_server.zig`
- `examples/http_basic_1_async.zig`
- `examples/grpc_location_server_1_async.zig` (logger wired and active by default)
- `examples/grpc_multi_server.zig` (logger wired and active by default)

---

###### end of hld-logger
