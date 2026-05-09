# HLD -- zix.Channel

In-process typed message-passing channels.

---

## Status

Not yet implemented. Design intent tracked in ADR-017.
For specification notes and open questions see [`rnd/channel_specification.md`](../rnd/channel_specification.md).

---

## Goals

- Typed in-process communication between concurrent tasks (`io.concurrent`) or OS threads.
- Blocking and non-blocking variants: `send`/`recv` (blocking), `trySend`/`tryRecv` (non-blocking).
- Buffered (capacity > 0) and unbuffered (capacity = 0, rendezvous) modes.
- Comptime-generic over the message type — no runtime type erasure.
- No cross-process or cross-network boundary — in-process only.
- Explicit over implicit: allocator provided by caller if heap-backed.

---

## Model

```
Sender task  -->  [ Channel(T) ]  -->  Receiver task
               buffered: ring buffer
               unbuffered: rendezvous (both must be ready)
```

| Mode | `send` blocks when | `recv` blocks when |
| :- | :- | :- |
| Buffered (capacity = N) | queue full | queue empty |
| Unbuffered (capacity = 0) | no receiver waiting | no sender waiting |

---

## Proposed API

```zig
const MyChan = zix.Channel(MyMessage);

// buffered, capacity 16
var ch = try MyChan.init(allocator, 16);
defer ch.deinit();

// unbuffered (rendezvous)
var ch = try MyChan.init(allocator, 0);
defer ch.deinit();

try ch.send(msg);           // blocks if full or unbuffered with no waiting receiver
const msg = try ch.recv();  // blocks if empty or unbuffered with no waiting sender

ch.trySend(msg) catch {};   // error.Full or error.Closed
ch.tryRecv() catch {};      // error.Empty or error.Closed

ch.close(); // no more sends; receivers drain remaining items then get error.Closed
```

---

## Relation to Server Concurrency Models

Channel is orthogonal to Model 1 / Model 2. It does not replace or extend either model — it is an in-process coordination primitive that can be used alongside either.

```
Model 1 or Model 2 server
  handler task A  -->  Channel(Event)  -->  background task B
```

See [`docs/concurrency.md`](concurrency.md) for the Channel entry in the Protocol Applicability table.

---

## Not Yet Implemented

All. See `rnd/channel_specification.md` for the full API proposal and open design questions.
See `rnd/tracker.md` for the implementation checklist.

---

###### end of hld-channel
