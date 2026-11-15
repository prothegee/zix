# LLD: zix.Channel

Internal implementation details. For design rationale see [`docs/hld-channel-en.md`](hld-channel-en.md) and ADR-017.

---

## Source Layout

```
src/zix/channel
|
|___Channel.zig            (Channel struct, fields at file scope, in-file tests)
```

---

## Data Structure

Ring buffer backed by a heap-allocated `[]u8` slice (type-erased). `Channel.zig` is the struct
itself, its fields sit at file scope.

```
buf: []u8         // heap-allocated ring, length = capacity * elem_size
capacity: usize   // number of slots
elem_size: usize  // @sizeOf(T) of the init type
type_name: []const u8 // @typeName(T) of the init type
head: usize       // index of the next item to read
count: usize      // number of items currently in the buffer
closed: bool      // set by close(), no new sends after this point
mutex: std.Io.Mutex
not_empty: std.Io.Condition
not_full:  std.Io.Condition
allocator: std.mem.Allocator
```

Ring arithmetic:
- Write (tail) index: `(head + count) % capacity`
- Advance head on recv: `head = (head + 1) % capacity`
- Slot bytes: `buf[index * elem_size ..][0..elem_size]`, values are copied with `@memcpy`

---

## Locking Primitive

`std.Io.Mutex` + `std.Io.Condition` (fiber-aware). Required so Channel can be used from `io.concurrent()` handler tasks as well as plain OS threads.

`std.Thread.Mutex` was evaluated and rejected because it blocks the OS thread rather than yielding to the scheduler, incompatible with fiber-based concurrency.

---

## send()

```
if T is not the init type: return error.ZixChannel_Channel_TypeMismatch
lock mutex
while count == capacity and not closed:
    not_full.waitUncancelable(io, &mutex)
if closed: unlock + return error.ZixChannel_Channel_Closed
copy value bytes into slot (head + count) % capacity
count += 1
unlock
not_empty.signal(io)
```

---

## recv()

```
if T is not the init type: return error.ZixChannel_Channel_TypeMismatch
lock mutex
while count == 0:
    if closed: unlock + return error.ZixChannel_Channel_Closed
    not_empty.waitUncancelable(io, &mutex)
copy slot head bytes into value
head = (head + 1) % capacity
count -= 1
unlock
not_full.signal(io)
return value
```

---

## close()

```
lock mutex
closed = true
unlock
not_empty.broadcast(io)   // unblock all waiting recvs
not_full.broadcast(io)    // unblock all waiting sends
```

---

## Memory

`init()` calls `allocator.alloc(u8, capacity * @sizeOf(T))`. `deinit()` calls `allocator.free(buf)`. No other heap allocations.

---

###### end of lld-channel
