# UDS Specification -- zix.Uds

Unix Domain Socket server and client. Same-host IPC only -- no network routing.

---

## Goal

Same-host inter-process communication via filesystem paths. Use cases:

- Microservice communication on a single host
- Local daemon ↔ client control socket (e.g. `/run/app.sock`)
- Higher throughput than TCP loopback for same-machine traffic (no network stack overhead)

---

## Restriction

Same as UDP and TCP: std only. Explicit over implicit. Separation of concern -- no import from
`src/tcp/` or `src/udp/`.

---

## Socket Modes

| Mode | Type | Use case |
| :- | :- | :- |
| Stream | Connection-oriented (like TCP) | Daemon control sockets, persistent client sessions |
| Datagram | Connectionless (like UDP) | Low-latency one-shot messages, logging pipelines |

Stream mode planned first (most common for control sockets).

---

## Addressing

No IP or port -- uses a filesystem path.

| Type | Example | Notes |
| :- | :- | :- |
| Pathname | `/tmp/app.sock` | Visible in filesystem, must unlink on close |
| Abstract (Linux) | `\x00app.sock` | Kernel-only, auto-cleaned on process exit |

Config struct will use `path: []const u8` instead of `ip`/`port`.

Path cleanup on `deinit()`: server must `unlink()` the socket file. Stale socket file prevents rebind.

---

## Port Configuration

No port -- path replaces both IP and port. Equivalent to REQUIRED mode in UDP terms (path must be
non-empty in config). Configurable path via CLI arg is planned (`--socket-path`).

---

## Endianness

For datagram mode with binary structs: same pattern as UDP.
For stream mode: endianness is a framing concern (fixed in message format, not in config).

Use `NATIVE` by default -- UDS is always same-host, so native byte order is safe.

---

## Concurrency Model

Same as TCP and UDP: caller owns the `io` backend.
Model 1 (single accept loop + io.concurrent) is the default.
Model 2 (multiple workers + SO_REUSEPORT) is planned -- Linux only for UDS abstract sockets.

See [`docs/concurrency.md`](../docs/concurrency.md).

---

## src/ Structure (Planned)

```
src/uds/
    config.zig   -- UdsServerConfig, UdsClientConfig, SocketMode enum
    server.zig   -- UdsServer (stream and datagram)
    client.zig   -- UdsClient
    Uds.zig      -- namespace aggregator
```

Export from `src/zix.zig` as `pub const Uds = @import("uds/Uds.zig")`.

NOT YET IMPLEMENTED. See ADR-010.

---

## Zig 0.16.x UDS API (To Verify)

UDS socket API in Zig 0.16.x is unconfirmed. Expected:

```
Bind:    IpAddress equivalent for UDS path -- check for std.Io.net.UnixAddress or similar
Listen:  same .listen() pattern with .mode = .stream or .dgram
Accept:  same .accept(io) pattern for stream mode
Send:    same .send(io, &dest, data) for datagram mode
```

Linux abstract namespace (`\x00name`) avoids filesystem cleanup but is Linux-only.
Pathname sockets (`/tmp/name.sock`) are portable across Linux and macOS.

---

## Open Questions

| Question | Notes |
| :- | :- |
| Zig 0.16.x API for UDS addressing | Verify `std.Io.net` has UDS support |
| Abstract namespace vs pathname | Both planned; pathname first for portability |
| SO_REUSEPORT for Model 2 on UDS | Linux-only, may skip for initial implementation |
| Datagram mode client identity | No source address enforcement -- app must include identity in payload |

---

###### end of uds specification
