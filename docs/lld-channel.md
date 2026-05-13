# LLD -- zix.Channel

Not yet implemented. For design intent see [`docs/hld-channel.md`](hld-channel.md) and ADR-017.

---

## Proposed Internal Structure

### Buffered mode (capacity > 0)

Ring buffer of `[capacity]T` with head and tail indices. One mutex + one condvar (or two condvars — not-full, not-empty). Writers advance tail readers advance head.

```
[ _ | msg | msg | msg | _ ]
      ^head            ^tail
```

### Unbuffered mode (capacity = 0)

No buffer. Sender blocks until a receiver calls `recv()`; receiver blocks until a sender calls `send()`. Requires a rendezvous slot (`?T`) and two condvars (sender-ready, receiver-ready).

### Locking primitive (open question)

| Option | Fiber-safe | OS thread-safe | Notes |
| :- | :- | :- | :- |
| `std.Io.Mutex` + `std.Io.Condition` | yes | yes | Required if Channel is used from `io.concurrent()` handler tasks |
| `std.Thread.Mutex` + `std.Thread.Condition` | no | yes | Simpler, only safe if used exclusively from OS threads |

**Decision needed before implementation.** See ADR-017 and `rnd/channel_specification.md`.

---

## Planned Source Layout

```
src/channel/
    channel.zig   -- Channel(comptime T: type) generic implementation
    Channel.zig   -- namespace aggregator
```

---

###### end of lld-channel
