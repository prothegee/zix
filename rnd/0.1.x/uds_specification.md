# UDS Specification: zix.Uds

Unix Domain Socket server and client. Same-host IPC only. No network routing.

---

## Goal

Same-host inter-process communication via filesystem paths. Use cases:

- Microservice communication on a single host
- Local daemon ↔ client control socket (e.g. `/run/app.sock`)
- Higher throughput than TCP loopback for same-machine traffic (no network stack overhead)

---

## Restriction

Same as UDP and TCP: std only. Explicit over implicit. Separation of concern. No import from
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

No IP or port. Uses a filesystem path.

| Type | Example | Notes |
| :- | :- | :- |
| Pathname | `/tmp/app.sock` | Visible in filesystem, must unlink on close |
| Abstract (Linux) | `\x00app.sock` | Kernel-only, auto-cleaned on process exit |

Config struct will use `path: []const u8` instead of `ip`/`port`.

Path cleanup on `deinit()`: server must `unlink()` the socket file. Stale socket file prevents rebind.

---

## Port Configuration

No port. Path replaces both IP and port. Equivalent to REQUIRED mode in UDP terms (path must be
non-empty in config). Configurable path via CLI arg is planned (`--socket-path`).

---

## Endianness

For datagram mode with binary structs: same pattern as UDP.
For stream mode: endianness is a framing concern (fixed in message format, not in config).

Use `NATIVE` by default. UDS is always same-host, so native byte order is safe.

---

## Concurrency Model

Same as TCP and UDP: caller owns the `io` backend.
Model 1 (single accept loop + io.concurrent) is the default.
Model 2 (multiple workers + SO_REUSEPORT) is planned. Linux only for UDS abstract sockets.

See [`docs/concurrency.md`](../docs/concurrency.md).

---

## src/ Structure (Planned)

```
src/uds/
    config.zig   : UdsServerConfig, UdsClientConfig, SocketMode enum
    server.zig   : UdsServer (stream and datagram)
    client.zig   : UdsClient
    Uds.zig      : namespace aggregator
```

Export from `src/zix.zig` as `pub const Uds = @import("uds/Uds.zig")`.

NOT YET IMPLEMENTED. See ADR-010.

---

## Zig 0.16.x UDS API (Verified 2026-05-09)

`std.Io.net.UnixAddress` exists and is the correct entry point:

```zig
// Create address from path (max 108 bytes on Linux/macOS)
const ua = try std.Io.net.UnixAddress.init("/tmp/app.sock");

// Server side (stream mode)
var server = try ua.listen(io, .{ .kernel_backlog = 128 });
defer server.deinit(io);
const stream = try server.accept(io); // same Stream type as TCP

// Client side (stream mode)
const stream = try ua.connect(io); // same Stream type as TCP

// Abstract namespace (Linux only): null-byte prefix
const abstract = try std.Io.net.UnixAddress.init("\x00app.sock");
_ = abstract.isAbstract(); // true

// Platform guard
if (!std.Io.net.has_unix_sockets) @compileError("UDS not supported on this platform");
```

**What is NOT available via `std.Io.net.UnixAddress`:**
- Datagram mode: `UnixAddress` only exposes `listen()` and `connect()` (stream). Datagram would require raw `std.posix` syscalls.

**Path cleanup:** `std.Io` does not unlink the socket file. Server `deinit()` must call `std.posix.unlink(path)` explicitly. Abstract namespace sockets (`\x00name`) are cleaned up by the kernel automatically.

---

## Open Questions

| Question | Status | Notes |
| :- | :- | :- |
| Zig 0.16.x API for UDS addressing | **Resolved** | `std.Io.net.UnixAddress` confirmed, see section above |
| Abstract namespace vs pathname | Open | Both supported pathname first for portability |
| SO_REUSEPORT for Model 2 on UDS | Open | Linux-only skip for initial stream implementation |
| Datagram mode client identity | Open | Not via std.Io.net would need raw std.posix defer |
| Datagram mode: include or defer? | **Decision needed** | Stream-only v1 is simpler and covers the main use cases |

---

###### end of uds specification
