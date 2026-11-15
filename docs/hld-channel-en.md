# HLD: zix.Channel

In-process typed message-passing channels.

---

## Status

Implemented. See ADR-017 for design rationale.

---

## Goals

- Typed in-process communication between concurrent tasks (`io.concurrent`) or OS threads.
- Blocking `send`/`recv` only. Non-blocking variants are deferred (see below).
- Buffered (capacity > 0) mode. Unbuffered (rendezvous) is not yet supported.
- One plain struct for every message type. The type is given to `init`, `send`, and `recv`,
  and checked at runtime (type-erased byte ring, like std `Io.TypeErasedQueue`).
- No cross-process or cross-network boundary (in-process only).
- Explicit over implicit: caller provides the allocator.

---

## Model

```
Sender task  -->  [ Channel ring buffer ]  -->  Receiver task
               capacity N: blocks when full/empty
```

| Operation | Blocks when |
| :- | :- |
| `send(io, T, value)` | buffer is full |
| `recv(io, T)` | buffer is empty |

After `close(io)` no new sends are accepted. `recv()` drains any remaining items then returns `error.ZixChannel_Channel_Closed`.

---

## API

```zig
// buffered, capacity 8, element type u32
var channel: zix.Channel = try .init(allocator, u32, 8);
defer channel.deinit();

// send blocks when full, returns error.ZixChannel_Channel_Closed after close()
try channel.send(io, u32, 42);

// recv blocks when empty, drains remaining items after close(),
// then returns error.ZixChannel_Channel_Closed
const value = try channel.recv(io, u32); // value == 42

// close: no more sends, blocked receivers are unblocked and drain remaining items
channel.close(io);
```

Capacity must be > 0. `init()` asserts this at runtime. Unbuffered (rendezvous) is not yet supported.

The element type is fixed by `init`. `send` and `recv` take the same type again, and a different
type returns `error.ZixChannel_Channel_TypeMismatch`.

| Error | When |
| :- | :- |
| `ZixChannel_Channel_Closed` | `send` after `close`, or `recv` on a closed and empty channel |
| `ZixChannel_Channel_OutOfMemory` | `init` cannot allocate the ring buffer |
| `ZixChannel_Channel_TypeMismatch` | `send` or `recv` with a type other than the `init` type |

---

## Source Layout

```
src/zix/channel
|
|___Channel.zig            (Channel struct, fields at file scope, in-file tests)
```

Export from `src/zix/lib.zig`:
```zig
pub const Channel = @import("channel/Channel.zig");
```

---

## Concurrency Requirement

`Channel.send()` and `Channel.recv()` call `std.Io.Mutex.lockUncancelable(io)`. This requires an `io` that is valid on the calling thread. The io of one `std.Io.Threaded` can be shared by OS threads (the examples do this), or each thread can create its own.

```zig
var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
defer threaded.deinit();
const io = threaded.io();

var channel: zix.Channel = try .init(std.heap.smp_allocator, u32, 8);
defer channel.deinit();

const worker_thread = try std.Thread.spawn(.{}, workerFn, .{ &channel, io });
```

---

## Relation to Server Concurrency Models

Channel is orthogonal to the HTTP dispatch model (`.ASYNC`, `.EPOLL`, `.URING`). It does not replace or extend any model. It is an in-process coordination primitive that can be used alongside any of them.

```
.ASYNC / .EPOLL / .URING server
  handler task A  -->  Channel(Event)  -->  background task B
```

Integration example: `uds_http.zig` wires a UDS fetcher task into SSE handlers via a `Channel(u64)`:

```
[uds_server] /tmp/zix.sock [fetcher task] Channel(u64) [SSE handler]
                                                      \ [/data handler]
```

See [`docs/concurrency.md`](concurrency.md) for the Channel entry in the Protocol Applicability table.

---

## Examples

| File | Pattern |
| :- | :- |
| `examples/channel_basic.zig` | Producer/consumer: a u32 channel with two OS threads |
| `examples/channel_worker_pool.zig` | Fan-out worker pool: one producer many consumers |
| `examples/channel_pipeline.zig` | Multi-stage pipeline: each stage runs at its own pace |
| `examples/channel_ipc_a.zig` | IPC process side A (UDS server, sends and receives), pair with ipc_b |
| `examples/channel_ipc_b.zig` | IPC process side B (UDS client, sends and receives), pair with ipc_a |
| `examples/uds_http.zig` | HTTP + UDS + Channel integration: full real-world pattern |

---

## Logger Integration

`Channel` has no server config struct, so there is no `logger` field. `Channel` prints nothing (library code does not use `std.debug.print`, see ADR-023). For lifecycle logging use `logger.system()` manually:

```zig
// Uncomment to add logger (console only):
// var logger = try zix.Logger.init(std.heap.smp_allocator, .{
//     .console           = .ALWAYS,
//     .console_min_level = .INFO,
// });
// defer logger.deinit();

// Use logger.system(.INFO, "channel", "started", .{}) for manual lifecycle logging.
```

The Channel examples do not carry this block. Add it where logging is wanted.

---

## Not Yet Implemented

| Feature | Note |
| :- | :- |
| Non-blocking `trySend`/`tryRecv` | Deferred. Blocking variants cover all current examples. |
| Unbuffered (rendezvous, capacity = 0) | `init()` asserts capacity > 0. Two-sided sync adds complexity. |
| `select` / multiplex over N channels | Deferred. Internal ring design does not preclude it. |
| `send` / `recv` with timeout | Deferred. Zig 0.17 `std.Io.Condition` has `waitTimeout`, so it can be built later. |

---

###### end of hld-channel
