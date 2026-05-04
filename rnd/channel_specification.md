# Channel Specification -- zix.Channel

Typed in-process communication channels. Approaching Go's channel model.

---

## Goal

A synchronized message-passing primitive for concurrent Zig tasks within one process.
Unlike UDP/TCP/UDS, channels do not cross a network or process boundary -- they are in-memory
queues between concurrent tasks sharing the same address space.

Modeled after Go channels and OS pipes (at the conceptual level).
Implemented in Zig with comptime-generic types.

---

## Model

```
sender task  ──►  [ buffered queue ]  ──►  receiver task
               (or direct handoff for unbuffered)
```

| Property | Unbuffered (capacity = 0) | Buffered (capacity = N) |
| :- | :- | :- |
| Send blocks until | receiver is ready | queue has space |
| Recv blocks until | sender sends | queue is non-empty |
| Synchronization | rendezvous (both must be ready) | decoupled up to N |

---

## API Shape (Proposed)

```zig
const MyChan = zix.Channel(MyMessage);

// unbuffered
var ch = try MyChan.init(allocator, 0);
defer ch.deinit();

// buffered, capacity 16
var ch = try MyChan.init(allocator, 16);
defer ch.deinit();

// blocking send (blocks if full or unbuffered with no receiver ready)
try ch.send(msg);

// blocking receive (blocks if empty or unbuffered with no sender ready)
const msg = try ch.recv();

// non-blocking variants
ch.trySend(msg) catch |err| { _ = err; }; // error.Full
ch.tryRecv() catch |err| { _ = err; };    // error.Empty

// close (signals no more sends; receivers drain remaining items then get error.Closed)
ch.close();
```

---

## Direction

Bidirectional by default (same as Go channels). Both the sender and receiver hold a pointer to
the same `Channel` value. Directional restriction (send-only, receive-only) is enforced at the
type level if needed via wrapper types at implementation time.

---

## Comparison With Related Concepts

| Feature | Go channel | POSIX pipe | zix.Channel |
| :- | :- | :- | :- |
| Typed | yes (generic) | no (bytes only) | yes (comptime generic) |
| Bidirectional | yes | no (one-way) | yes |
| Cross-process | no | yes | no -- in-process only |
| Buffered | yes | limited (pipe buffer) | yes |
| Select / multiplex | yes (`select`) | `poll`/`epoll` | planned -- defer |

---

## Integration With io.concurrent

Channels are designed to work alongside `io.concurrent()` tasks. A producer task sends to a
channel; a consumer task receives. No shared mutable state between tasks except through the
channel itself.

```zig
// producer
_ = try io.concurrent(producerFn, .{ &ch });

// consumer
_ = try io.concurrent(consumerFn, .{ &ch });

fn producerFn(cap: struct { ch: *MyChan }) void {
    cap.ch.send(.{ .value = 42 }) catch {};
}

fn consumerFn(cap: struct { ch: *MyChan }) void {
    const msg = cap.ch.recv() catch return;
    _ = msg;
}
```

---

## src/ Structure

NOT YET DESIGNED. Marked as planned.

```
src/channel/   -- planned; not yet implemented
    channel.zig  -- Channel(comptime T: type) generic
    Channel.zig  -- namespace aggregator
```

Export from `src/zix.zig` as `pub const Channel = @import("channel/Channel.zig")` when implemented.

---

## Open Questions

| Question | Notes |
| :- | :- |
| Select / multiplex over N channels | Defer until single-channel is stable |
| Cancellation / deadline | Integrate with `std.Io` cancellation or keep separate |
| Naming: `Channel` vs `Chan` | Decide at implementation time |
| Internal locking primitive | Mutex + Condvar vs futex vs `std.Io` event |
| Cross-thread safety | Channel must be safe to use from io.concurrent tasks on any thread |

---

###### end of channel specification
