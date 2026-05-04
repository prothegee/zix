# HLD -- zix.Uds

Unix Domain Socket server and client. Same-host IPC only -- no network routing.

---

## Status

Not yet designed. Design intent tracked in ADR-010.
For specification notes see [`rnd/uds_specification.md`](../rnd/uds_specification.md).

---

## Goals

- Explicit over implicit: same config pattern as `zix.Udp`.
- Same-host IPC: stream and datagram socket modes planned.
- No cross-protocol dependencies: `src/uds/` has no import from `src/tcp/` or `src/udp/`.
- Namespace follows the same pattern: `zix.Uds.Server`, `zix.Uds.Client`.

---

## Planned Source Layout

```
src/uds/
    config.zig   -- UdsServerConfig, UdsClientConfig, SocketMode
    server.zig   -- UdsServer
    client.zig   -- UdsClient
    Uds.zig      -- namespace aggregator
```

Export from `src/zix.zig` as `pub const Uds = @import("uds/Uds.zig")`.

---

## Not Yet Implemented

All. See `rnd/uds_specification.md` for open design questions.

---

###### end of hld-uds
