# UDP SPECS

## Goal

Create UDP server & client.
For server see `rnd/udp_server.zig` and for client see `rnd/udp_client.zig`.

We expecting server can be configured explicitly for the data to process,
so later on when user deploy the server, they also can receive from any client type (the primitive type to process), which mean client is also can be sent from Go, C++, Rust, etc.

User also can explicitly configured where it can be part of the server, i.e.:
- Automatic ACK.
- Error reporting.
- Feedback to client.

If array data involved, use explicit size. If there's standardized rule for array data, use it.

For dummy server & client data test PoC, we gonna receive:
- id: char[16]
- type: int
- register: unsigned int
- position: [3]double (represent: x, y, z)

<br>

## Restriction

Implementation should not be "nice to have" but focus on UDP Core Responsibilities first.

<br>

## Important

Use std only.

Always seek the explicit over implicit.

Seperation concern, no relation for tcp.

Watch the overflow data buffer for security.

If functionality more an utils, move to utils dir.

Use multi-threads as always even if as passing request to actual process.

<br>

## Extend information

Notes from PoC (`rnd/`) conversation to address when moving into `src/udp/`.

<br>

### Port Configuration

Port binding must be governed by an explicit mode (`enum(u8)`, all uppercase values):

- `CONFIGURABLE` — config struct holds a default port. `init()` receives an args iterator and reads `--port` if present, falls back to the config default if not. Never fails for a missing arg — the default covers it. The point is the port is runtime-overridable.
- `REQUIRED` — port must be explicitly set non-zero in the config struct. `init()` takes no args iterator. Fails at `init()` with `error.PortNotConfigured` if port is zero.

Fail at `init()`, not at `run()`. Enforces "explicit over implicit."

CLI key format: `--port <value>` (server), `--bind-port <value>` / `--server-port <value>` (client).

<br>

### Endianness

Enum values use ALL_CAPS:

- `NATIVE` — same machine only, unsafe across platforms or languages
- `LITTLE` — recommended for most modern hardware (x86, ARM)
- `BIG` — network byte order, use when interoperating with legacy or internet protocols

Conversion is **transparent** — applied inside `send()` and `receive()` based on `config.endianness`. User declares once in config, no manual conversion call needed anywhere else. `packet.zig` exposes the helpers publicly so advanced users can call them directly if needed.

<br>

### Concurrency Model

Same model as TCP: caller owns the `io` backend — no `ConcurrencyMode` config field. Pass `process.io` for auto-managed threads or `threaded.io()` for an explicit cap. `io.concurrent()` is used internally. A multithreaded UDP example will go in `rnd/` as a separate PoC.

<br>

### Disconnect Detection

UDP has no connection state. Disconnect detection is purely timeout-based. Worst-case detection delay is `DISCONNECT_TIMEOUT_MS + POLL_TIMEOUT_MS`. Both must be configurable fields in `UdpServerConfig`. There is no OS-level signal equivalent to TCP FIN — document this limitation clearly.

<br>

### Feedback Shape

PoC `auto_echo` sends the received packet back as-is. In `src/`, feedback shape should be configurable — either echo the input or respond with a separate result struct. Define the result struct explicitly. Do not leave it as a raw byte echo in production code.

**Client reception (PoC):** client receives on its bound socket via a persistent `io.concurrent()` task (`receiveFeedback`). Interprets by received length: 1 byte -> ACK (`0x06`) / NACK (`0x15`); `@sizeOf(TestPacket)` bytes -> echo or broadcast packet decoded via `@bitCast`. Raw-byte length-dispatch is PoC-only.

**Client reception (src/):** decode into a comptime-generic tagged union:
```zig
pub fn FeedbackResult(comptime Packet: type) type {
    return union(enum) {
        ack,
        nack,
        packet: Packet,
    };
}
```
The receive loop produces `FeedbackResult(Packet)` values — no raw-byte length interpretation in production code.

**Broadcast (PoC):** `ServerConfig.broadcast = true` relays each received packet to all currently connected clients (not just the sender). The server snapshots connected client addresses into `PacketTask.peers[MAX_BROADCAST_CLIENTS]` at receive time and passes them by value to the concurrent task — this avoids sharing the mutable `ClientRecord` list across threads. The `MAX_BROADCAST_CLIENTS = 64` cap is a PoC constraint in `src/`, use an arena-allocated slice per packet to remove the hard limit. `auto_echo` and `broadcast` are independent: `auto_echo` sends only to the sender, `broadcast` sends to all.

**Position data (PoC):** client generates random `position` values in `[-1.0, 1.0)` per packet via `std.Random.DefaultPrng` seeded from `std.crypto.random`. PRNG is seeded once in `main`; access is sequential because a sleep separates each send, so no concurrent RNG use occurs. In `src/`, if sends become truly concurrent, each worker needs its own PRNG instance.

<br>

### send_every Precision (Client)

PoC uses milliseconds for `send_every`. If sub-millisecond send intervals are needed (real-time control loops), change the field to nanoseconds — trivial rename + unit change in the sleep call. Not needed for telemetry use cases.

<br>

### src/ Structure

```
src/udp/
    packet.zig    — endianness helpers (toEndian, fromEndian); user defines their own extern packet struct
    config.zig    — PortMode enum(u8), Endianness enum(u8), UdpServerConfig, UdpClientConfig
    server.zig    — UdpServer(comptime Packet: type)
    client.zig    — UdpClient(comptime Packet: type)
    Udp.zig       — namespace aggregator (mirrors Tcp.zig)
```

Export from `src/zix.zig` as `pub const Udp = @import("udp/Udp.zig");`.

**Packet / Identity:** `packet.zig` provides helpers only — no hardcoded struct. User defines their own `extern struct` and passes it at comptime. Server does not stamp or modify the packet's `id` field (PoC behavior dropped). Client owns its identity. Server tracks clients by address, connection index is internal metadata (logs only). Broadcast relays packet as-is. Identity structure and validation are the application's responsibility.

**Comments:** every config field gets one short inline comment. Every public function gets a brief doc block — what it does, what it fails on. Security and performance concerns marked `SECURITY:` / `PERF:`.

<br>

### Zig 0.16.x API Facts (from PoC)

- UDP socket: `std.Io.net.IpAddress.bind(io, .{ .mode = .dgram, .protocol = .udp })` -> `Socket`
- Receive: `socket.receive(io, buf)` -> `IncomingMessage` (`from`, `data`, `flags.trunc`)
- Receive with timeout: `socket.receiveTimeout(io, buf, timeout)` — returns `error.Timeout` on expiry
- Send: `socket.send(io, &dest, data)`
- Sleep: `std.Io.sleep(io, std.Io.Duration.fromMilliseconds(n), .awake)`
- Managed list: `std.array_list.Managed(T)` — `std.ArrayList(T)` is now unmanaged in 0.16.x
- Clock: `std.Io.Clock.Timestamp.now(io, .awake)` / `.durationTo(from, to).raw.toMilliseconds()`

<br>

---

###### end of udp specs
