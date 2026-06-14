# HLD: zix.Fix

FIX 4.x session protocol server. SOH-delimited (0x01) tag=value framing. Built entirely in Zig: no C FFI, no external libraries.

---

## Status

Implemented. See ADR-024 for design rationale.

---

## Goals

- Explicit over implicit: same config and dispatch-model pattern as `zix.Tcp`.
- SOH-delimited framing: no length prefix, delimiter-based message boundary detection.
- Session layer built in: Logon / Logout / Heartbeat / TestRequest handled automatically, all other messages are echoed.
- No heap allocation in `serveConn`: stack buffers throughout.
- POOL, ASYNC, MIXED, and EPOLL dispatch. Default: ASYNC (FIX sessions are long-lived). EPOLL runs natively on Linux (gRPC pattern: single epoll accept loop, pool workers hold each connection for its full lifetime). Falls back to POOL on non-Linux.
- `io: std.Io` in config (not passed to `run()`).

---

## Source Layout

```
src/tcp/fix/
    Fix.zig      // namespace aggregator
    core.zig     // parsing, building, checksum, serveConn, MsgType, FixContext, HandlerFn, FixRoute
    config.zig   // FixServerConfig, FixClientConfig
    server.zig   // FixServer: POOL, ASYNC, MIXED, and EPOLL (Linux-only) dispatch
    router.zig   // comptime FixRouter
    client.zig   // FixClient
```

Export from `src/lib.zig`:
```zig
pub const Fix = @import("tcp/fix/Fix.zig");
// zix.Fix.Server, zix.Fix.ServerConfig, zix.Fix.Client, zix.Fix.ClientConfig, zix.Fix.serveConn, ...
```

---

## Public API

| Symbol | Type | Description |
| :- | :- | :- |
| `zix.Fix.Server` | struct | `init(routes, config)` / `deinit()` / `run()` (routes is `[]const zix.Fix.Route`) |
| `zix.Fix.ServerConfig` | struct | See Server Config Fields below |
| `zix.Fix.ServeOpts` | struct | `{ logger, heartbeat_timeout_ms, connection_timeout_ms, handler_timeout_ms, routes }`: options for `serveConn` |
| `zix.Fix.Client` | struct | `connect(config, io)` / `deinit(io)` / `logon(io, heart_bt_int)` / `logout(io)` / `sendMessage(io, msg_type, extra)` / `recvMessage(io)` |
| `zix.Fix.ClientConfig` | struct | See Client Config Fields below |
| `zix.Fix.DispatchModel` | enum(u8) | Re-export of `zix.Tcp.DispatchModel` |
| `zix.Fix.Tag` | enum(u16) | Nonexhaustive enum of standard FIX 4.x tag numbers. Use `@enumFromInt` for custom tags not listed |
| `zix.Fix.MsgType` | struct | Namespace of compile-time string constants for FIX MsgType (tag 35) values. See MsgType Constants section |
| `zix.Fix.HandlerFn` | type | `*const fn (fields: []const Field, ctx: *Context) void`: application message handler |
| `zix.Fix.Route` | struct | `{ msg_type: []const u8, handler: HandlerFn, timeout_ms: u32 = 0 }`: one application message route |
| `zix.Fix.Context` | struct | Per-connection context passed to each handler. Fields: `sender_comp_id`, `target_comp_id`, `deadline_ns`. Methods: `sendMessage`, `isExpired` |
| `zix.Fix.Router(routes)` | comptime fn | Returns a comptime dispatch type with `dispatch(fields, ctx, server_timeout_ms)` |
| `zix.Fix.wallClockNs` | fn | `std.os.linux.clock_gettime(.REALTIME)` -> u64 nanoseconds (same as `zix.Grpc.wallClockNs`) |
| `zix.Fix.Field` | struct | `{ tag: Tag, value: []const u8 }`: zero-copy slice into receive buffer |
| `zix.Fix.BuildField` | struct | `{ tag: Tag, value: []const u8 }`: input to `buildMessage` |
| `zix.Fix.SOH` | u8 | `0x01`: field delimiter |
| `zix.Fix.VERSION` | []const u8 | `"FIX.4.2"` |
| `zix.Fix.MAX_FIELDS` | usize | 64: max fields parsed per message |
| `zix.Fix.MAX_MSG_SIZE` | usize | 8192: max message bytes |
| `zix.Fix.findMessageEnd` | fn | Scans buf for end of first complete FIX message, returns index past final SOH or null |
| `zix.Fix.parseFields` | fn | Parses raw bytes into `[]Field` (zero-copy slices into buf) |
| `zix.Fix.getField` | fn | Returns value of first field with given `Tag`, or null |
| `zix.Fix.computeChecksum` | fn | Sum of all bytes mod 256 |
| `zix.Fix.verifyChecksum` | fn | Returns true if tag-10 checksum matches computed value |
| `zix.Fix.buildMessage` | fn | Builds a complete FIX message into caller-supplied output buffer |
| `zix.Fix.serveConn` | fn | Session handler: `serveConn(stream, io, comp_id, opts)` (reads messages, dispatches Logon/Logout/Heartbeat, routes application messages) |

---

## Server Config Fields

| Field | Default | Description |
| :- | :- | :- |
| `io` | required | Io backend. Caller-provided, must outlive the server |
| `ip` | required | Bind address |
| `port` | required | Bind port. Must be non-zero |
| `comp_id` | required | Server SenderCompID (tag 49) |
| `dispatch_model` | `.ASYNC` | POOL, ASYNC, MIXED, or EPOLL (Linux-only: native epoll. Non-Linux falls back to POOL) |
| `kernel_backlog` | 1024 | TCP listen backlog |
| `workers` | 0 (cpu_count) | Accept thread count. Ignored by ASYNC |
| `pool_size` | 0 (auto) | Pool threads (`max(10, cpu_count * 2)`). Used by POOL only |
| `logger` | null | Optional logger for lifecycle and per-message session events |
| `heartbeat_timeout_ms` | 0 | Heartbeat timeout in ms. 0 = disabled. When non-zero: after this interval with no incoming message, TestRequest (35=1) is sent. If no response arrives within another interval, Logout (35=5) is sent and the connection closes. Only applies after Logon, before Logon, timeout closes silently. |
| `connection_timeout_ms` | 0 | Idle connection timeout in ms. 0 = disabled. When non-zero: if no message arrives within this interval (even with heartbeat disabled), the connection is closed. Distinct from `heartbeat_timeout_ms`: no TestRequest dance, just close. |
| `handler_timeout_ms` | 0 | Server-wide default max handler processing time in ms. 0 = no cap. Tightened per-route by `Route.timeout_ms`. Sets `Context.deadline_ns` before dispatch. |

---

## Client Config Fields

| Field | Description |
| :- | :- |
| `ip` | required, server address |
| `port` | required, server port. Must be non-zero |
| `comp_id` | required, this client's SenderCompID (tag 49) |
| `target_comp_id` | required, server's TargetCompID (tag 56) |

---

## Protocol Overview

FIX (Financial Information eXchange) 4.x uses SOH (0x01) as a field delimiter. Each field is `tag=value\x01`. A complete message starts at tag-8 (BeginString) and ends with tag-10 (Checksum) followed by a final SOH:

```
8=FIX.4.2\x019=26\x0135=A\x0149=CLIENT\x0156=SERVER\x0134=1\x0198=0\x01108=30\x0110=NNN\x01
```

Key standard tags:

| Tag | Name | Role |
| :- | :- | :- |
| 8 | BeginString | Always `FIX.4.2` in this implementation |
| 9 | BodyLength | Byte count from tag-35 to end of tag-10 value (before final SOH) |
| 35 | MsgType | `A`=Logon, `5`=Logout, `0`=Heartbeat, `1`=TestRequest, `D`=NewOrderSingle, etc. |
| 49 | SenderCompID | Sending party identity |
| 56 | TargetCompID | Receiving party identity |
| 34 | MsgSeqNum | Per-session sequence number (starts at 1) |
| 10 | Checksum | Sum of all message bytes mod 256, formatted as 3-digit decimal |

---

## Tag Enum

FIX tag numbers are transmitted as ASCII integers on the wire (e.g. `35`, `49`, `108`). Reading numeric literals in code requires knowing the FIX spec by memory. `zix.Fix.Tag` is a nonexhaustive `enum(u16)` that maps standard tag numbers to named constants, the wire format is unchanged.

```zig
pub const Tag = enum(u16) {
    MsgType      = 35,
    SenderCompID = 49,
    TargetCompID = 56,
    MsgSeqNum    = 34,
    HeartBtInt   = 108,
    // ... 54 tags total
    _,  // catch-all: any u16 is a valid Tag value
};
```

### Covered tags

Session layer: `BeginString` (8), `BodyLength` (9), `CheckSum` (10), `MsgSeqNum` (34), `MsgType` (35), `SenderCompID` (49), `SenderSubID` (50), `SendingTime` (52), `TargetCompID` (56), `TargetSubID` (57), `PossDupFlag` (43), `PossResend` (97), `EncryptMethod` (98), `HeartBtInt` (108), `TestReqID` (112), `OrigSendingTime` (122), `GapFillFlag` (123), `LastMsgSeqNumProcessed` (369).

Order and execution: `Account` (1), `AvgPx` (6), `ClOrdID` (11), `CumQty` (14), `Currency` (15), `ExecID` (17), `ExecTransType` (20), `HandlInst` (21), `LastPx` (31), `LastShares` (32), `OrderID` (37), `OrderQty` (38), `OrdStatus` (39), `OrdType` (40), `OrigClOrdID` (41), `Price` (44), `Side` (54), `StopPx` (99), `TimeInForce` (59), `TransactTime` (60), `ExecType` (150), `LeavesQty` (151).

Instrument: `SecurityID` (48), `SecurityIDSource` (22), `Symbol` (55), `Text` (58), `ExDestination` (100), `SecurityType` (167), `MaturityMonthYear` (200), `SecurityExchange` (207), `TradeDate` (75).

Repeating group counts: `NoRelatedSym` (146), `NoMDEntries` (268), `NoPartyIDs` (453), `NoUnderlyings` (539), `NoLegs` (555).

### How to use

Reading a field by name:

```zig
const msgtype  = zix.Fix.getField(fslice, .MsgType)      orelse return;
const sender   = zix.Fix.getField(fslice, .SenderCompID) orelse "";
const seq_str  = zix.Fix.getField(fslice, .MsgSeqNum)    orelse "0";
```

Building a message with named fields:

```zig
try client.sendMessage(io, "D", &[_]zix.Fix.BuildField{
    .{ .tag = .ClOrdID,  .value = "ORD-001" },
    .{ .tag = .Symbol,   .value = "AAPL" },
    .{ .tag = .Side,     .value = "1" },
    .{ .tag = .OrderQty, .value = "100" },
    .{ .tag = .OrdType,  .value = "2" },
    .{ .tag = .Price,    .value = "185.50" },
});
```

### Custom and extension tags

The enum is nonexhaustive (`_`). Any `u16` is a valid `Tag` value: use `@enumFromInt` for tags not listed:

```zig
const my_tag: zix.Fix.Tag = @enumFromInt(9999);
const extra = [_]zix.Fix.BuildField{
    .{ .tag = @enumFromInt(9001), .value = "custom-data" },
};
```

`parseFields` converts wire integers to `Tag` via `@enumFromInt` automatically, no conversion needed when reading received fields.

### Considerations

- The backing type is `u16`, matching the `Field.tag` and `BuildField.tag` fields. No runtime cost vs storing a raw `u16`.
- Unknown tags received from the wire (`parseFields`) become nonexhaustive enum values: they compare correctly with `==` and print as their integer value.
- The enum does not validate tag values or enforce FIX version restrictions. All semantic validation remains the application's responsibility.
- `getField` accepts `Tag`: passing a raw integer literal directly no longer compiles. Use the named constant or `@enumFromInt(n)`.

---

## Session Layer

`serveConn` implements the FIX session layer automatically. No handler callback: all session logic is inside `serveConn`:

| MsgType (tag 35) | Server action |
| :- | :- |
| `A` (Logon) | Respond with Logon (`A`), CompIDs swapped, seq=1 |
| `5` (Logout) | Respond with Logout (`5`), then close connection |
| `0` (Heartbeat) | Respond with Heartbeat (`0`) |
| `1` (TestRequest) | Respond with Heartbeat (`0`) |
| any other (routes non-empty) | Dispatch to matching `Route.handler` via `FixRouter`. If no route matches, message is silently ignored |
| any other (routes empty) | Echo the message back unchanged (backward-compatible echo mode) |

Bad checksum closes the connection without a response.

---

## MsgType Constants

FIX MsgType values (tag 35) are ASCII strings, not integers. `zix.Fix.MsgType` is a namespace struct of 47 compile-time string constants covering FIX 4.0-4.4. Use these instead of raw string literals to avoid typos and aid readability.

```zig
// Session
zix.Fix.MsgType.Heartbeat                   // "0"
zix.Fix.MsgType.TestRequest                 // "1"
zix.Fix.MsgType.ResendRequest               // "2"
zix.Fix.MsgType.Reject                      // "3"
zix.Fix.MsgType.SequenceReset               // "4"
zix.Fix.MsgType.Logout                      // "5"
zix.Fix.MsgType.Logon                       // "A"

// Application (single-char)
zix.Fix.MsgType.ExecutionReport             // "8"
zix.Fix.MsgType.OrderCancelReject           // "9"
zix.Fix.MsgType.IOIAcknowledgement          // "6"
zix.Fix.MsgType.IOI                         // "C"
zix.Fix.MsgType.NewOrderSingle              // "D"
zix.Fix.MsgType.NewOrderList                // "E"
zix.Fix.MsgType.OrderCancelRequest          // "F"
zix.Fix.MsgType.OrderCancelReplaceRequest   // "G"
zix.Fix.MsgType.OrderStatusRequest          // "H"
zix.Fix.MsgType.Allocation                  // "J"
// ... and more (Quote, MarketData*, Security*, TradingSession*, etc.)

// Application (two-char, FIX 4.3-4.4)
zix.Fix.MsgType.TradeCaptureReport          // "AE"
zix.Fix.MsgType.OrderMassStatusRequest      // "AF"
```

Usage in route table and `sendMessage`:

```zig
&[_]zix.Fix.Route{
    .{ .msg_type = zix.Fix.MsgType.NewOrderSingle,    .handler = handleNewOrder },
    .{ .msg_type = zix.Fix.MsgType.OrderCancelRequest, .handler = handleCancel },
},

// in handler:
ctx.sendMessage(zix.Fix.MsgType.ExecutionReport, &[_]zix.Fix.BuildField{ ... });

// in client:
try client.sendMessage(io, zix.Fix.MsgType.NewOrderSingle, &order_fields);
```

---

## Router and Application Message Dispatch

Routes are passed at `Fix.Server.init()`. Session messages (Logon/Logout/Heartbeat/TestRequest) are always handled internally by `serveConn`. Only application messages (everything else) reach the router.

```zig
var server = try zix.Fix.Server.init(
    &[_]zix.Fix.Route{
        .{ .msg_type = zix.Fix.MsgType.NewOrderSingle,    .handler = handleNewOrder,   .timeout_ms = 500 },
        .{ .msg_type = zix.Fix.MsgType.OrderCancelRequest, .handler = handleCancel,     .timeout_ms = 500 },
    },
    .{
        .io                    = process.io,
        .ip                    = "0.0.0.0",
        .port                  = 9500,
        .comp_id               = "BROKER",
        .dispatch_model        = .ASYNC,
        .connection_timeout_ms = 60_000,
        .handler_timeout_ms    = 200,
    },
);
```

Empty routes (`&.{}`) enable echo mode (backward-compatible: all non-session messages are echoed).

### HandlerFn

```zig
fn handleNewOrder(fields: []const zix.Fix.Field, ctx: *zix.Fix.Context) void {
    if (ctx.isExpired()) return;
    const symbol = zix.Fix.getField(fields, .Symbol) orelse return;
    ctx.sendMessage(zix.Fix.MsgType.ExecutionReport, &[_]zix.Fix.BuildField{
        .{ .tag = .Symbol,    .value = symbol },
        .{ .tag = .OrdStatus, .value = "0" },
    });
}
```

### FixContext Fields

| Field | Type | Description |
| :- | :- | :- |
| `sender_comp_id` | `[]const u8` | Peer's SenderCompID from session Logon |
| `target_comp_id` | `[]const u8` | Server's comp_id (our identity) |
| `deadline_ns` | `?u64` | Absolute deadline (CLOCK_REALTIME nanoseconds). Set from tightest of `handler_timeout_ms`, `Route.timeout_ms`. Null = no deadline |

### FixContext Methods

| Method | Description |
| :- | :- |
| `sendMessage(msg_type, fields)` | Build and send a FIX response on this connection (swapped CompIDs) |
| `isExpired()` bool | Returns true when `deadline_ns` is set and has passed |

### Deadline Override

```zig
ctx.deadline_ns = zix.Fix.wallClockNs() + 2 * std.time.ns_per_s; // extend to 2 s
ctx.deadline_ns = null;                                            // disable
```

### FixRouter (comptime)

`FixRouter(routes)` generates a comptime `dispatch` function: `inline for` unrolled at comptime, zero runtime cost.

```zig
const r = zix.Fix.Router(&[_]zix.Fix.Route{
    .{ .msg_type = zix.Fix.MsgType.NewOrderSingle, .handler = handleNewOrder },
});
r.dispatch(fields, ctx, server_handler_timeout_ms);
```

The router is wired automatically when routes are passed to `Server.init`. Use it directly only when calling `serveConn` manually.

---

## Framing

FIX uses delimiter-based framing (SOH = 0x01), not length-prefix framing. The receive loop accumulates bytes via `takeByte` until `findMessageEnd` detects a complete message. This avoids the `readSliceShort` deadlock that occurs when a large buffer is passed but the message is shorter than the buffer capacity (see CLAUDE.md pitfall section).

```
recv_buf:  [complete message][leftover bytes][free]
                                      ^
                                      shifted after each message
```

---

## Dispatch Models

Same four models as `zix.Http.Server`. Default is ASYNC (FIX sessions are long-lived. POOL can exhaust threads under sustained load):

| Model | Accept threads | Notes |
| :- | :- | :- |
| `.ASYNC` (default) | 1 | Long-lived sessions, standard FIX deployments |
| `.POOL` | cpu_count | High connection volume with short sessions |
| `.MIXED` | cpu_count | Balanced throughput and latency |
| `.EPOLL` | 1 (Linux-only) | Single epoll accept loop. Pool workers hold each connection for its full lifetime. Non-Linux falls back to POOL. |

---

## Server Lifecycle

```
Fix.Server.init(config): validates port != 0, io taken from config
    -> .run(): dispatches via dispatch_model, blocks until error
Fix.Server.deinit(): no-op (resources released in run() via defer)
```

---

## Logger Integration

When `config.logger` is non-null:
- `system(.INFO, "fix", ...)` on bind and shutdown.
- `session(msg_type, sender, target, seq, state)` after each message processed in `serveConn`.

See `docs/hld-logger.md` for log line format details.

---

## Examples

| File | Role | Port |
| :- | :- | :- |
| `examples/fix_server_1_async.zig` | `.ASYNC` server (echo mode) | 9500 |
| `examples/fix_server_2_pool.zig` | `.POOL` server (echo mode) | 9500 |
| `examples/fix_server_3_mixed.zig` | `.MIXED` server (echo mode) | 9500 |
| `examples/fix_server_4_epoll.zig` | `.EPOLL` server (Linux-only: native epoll. Non-Linux falls back to POOL) | 9500 |
| `examples/fix_server_trading.zig` | `.ASYNC` server with router: NewOrderSingle + OrderCancelRequest, JSON append, logger, timeouts | 9500 |
| `examples/fix_client.zig` | `FixClient` high-level client | 9500 |
| `examples/fix_client_raw.zig` | raw core primitives client | 9500 |
| `examples/fix_client_trading.zig` | trading client: buy/cancel/sell/cancel flow | 9500 |

---

###### end of hld-fix
