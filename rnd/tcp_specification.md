# TCP Specification -- zix.Tcp

TCP as a transport base. Currently used by `zix.Http`.
Planned for FIX (Financial Information eXchange) protocol as a second protocol on TCP.

---

## Protocols on TCP

| Protocol | Namespace | Status |
| :- | :- | :- |
| HTTP | `zix.Http` (via `zix.Tcp.Http`) | Implemented |
| FIX (Financial Information eXchange) | `zix.Tcp.Fix` (planned) | Not yet designed |

---

## Zig 0.16.x TCP API Facts (from PoC)

```
Listen:  IpAddress.listen(io, .{ .mode = .stream, .protocol = .tcp,
                                  .reuse_address = true, .kernel_backlog = N })
         -> NetServer

Accept:  net_server.accept(io)              -> Stream   (blocks until TCP connect)
Read:    stream.reader(io, &buf)            -> Reader
Write:   stream.writer(io, &buf)            -> Writer
HTTP:    std.http.Server.init(&read.interface, &write.interface)
Close:   stream.close(io)
```

---

## Two Threading Models

Both models apply to any TCP-based protocol (HTTP, FiX, or other).
Full specification in [`docs/concurrency.md`](../docs/concurrency.md).

Reference PoC:
- Model 1: `rnd/server_model_1.zig` -- single accept loop, `std.Thread.spawn` per connection
- Model 2: `rnd/server_model_2.zig` -- N workers, each with own listen+accept, shared `io.concurrent` pool

Benchmarks (wrk, 100 connections, 2 threads, 10 s):
- Model 1: ~254,072 req/s
- Model 2: ~248,160 req/s

Model 2 advantage is latency distribution at extreme load, not raw throughput.

---

## FIX Protocol Notes (Planned)

FIX (Financial Information eXchange) is a session-layer messaging protocol used in financial
markets for order management, market data, and trade reporting. It runs over TCP.

Key FIX characteristics relevant to `zix.Tcp.Fix`:

| Decision | Notes |
| :- | :- |
| Message framing | Tag=Value pairs delimited by SOH (0x01); fixed header BeginString, BodyLength, MsgType |
| Session management | FIX session: Logon, Heartbeat, Logout, server tracks session state per TCP stream |
| Sequence numbers | Each message has MsgSeqNum, gap detection requires ResendRequest |
| Endianness | FIX is ASCII-based -- no binary endianness concern (unlike UDP binary structs) |
| Error handling | Reject (MsgType=3) for bad messages, session-level Logout on fatal errors |
| Planned namespace | `src/tcp/fix/` mirroring `src/tcp/http/` |

Comparison of TCP (FIX) vs UDP for protocol selection:

| | TCP (FIX) | UDP |
| :- | :- | :- |
| Delivery guarantee | yes (TCP retransmit) | no |
| Order guarantee | yes | no |
| Connection state | yes (FIX session) | no (datagram) |
| Message format | ASCII tag=value | user-defined extern struct |
| Max message size | unlimited (framed) | 65,507 bytes (RFC 768) |
| Latency | higher | lower |
| Use case | order management, trade reporting | real-time market data, telemetry |

FIX specification references: FIX 4.2 / 4.4 / 5.0 SP2 (FIX Protocol Ltd).

---

###### end of tcp specification
