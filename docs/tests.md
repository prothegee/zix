# Tests -- zix

---

## Running Tests

```sh
# unit tests only — silent on success
zig build unit-test

# integration tests only
zig build integration-test

# both at once
zig build test-all
```

`zig build` alone does **not** run tests — test steps are separate named steps not wired into the default install step.

---

## Unit Tests

Source: `src/zix.zig`. Each module is exercised via `std.testing.refAllDecls`, which verifies every public declaration compiles and any inline `test` blocks pass.

### zix.Http

| Module | Coverage |
| :- | :- |
| `tcp/http/method.zig` | `refAllDecls` |
| `tcp/http/status.zig` | `refAllDecls` |
| `tcp/http/content.zig` | `refAllDecls` + behavioral: `TEXT_EVENT_STREAM` round-trip (asString / enumFromString) |
| `tcp/http/request.zig` | `refAllDecls` + behavioral: method, path, query string, queryParam (present / absent / flag), pathSegments, queryParams |
| `tcp/http/response.zig` | `refAllDecls` + behavioral: setStatus, setContentType, setKeepAlive, addHeader, `HeaderSize.value()`, injection guard (CR/LF in name and value), TooManyHeaders, `SseWriter.writeEvent/writeNamedEvent/comment` wire format, `Response.streaming` defaults to false |
| `tcp/http/router.zig` | `refAllDecls` + behavioral: matchParam (single param, multi-param, segment count mismatch), route registration (kind + path preserved) |
| `tcp/http/static.zig` | `refAllDecls` + behavioral: mimeType, parseRangeHeader |
| `tcp/http/upload.zig` | `refAllDecls` + behavioral: MultipartParser parse + getField |
| `tcp/http/websocket.zig` | `refAllDecls` + behavioral: acceptKey RFC vector, buildFrame + parseFrame round-trip (text), parseFrame masked frame (RFC 6455 5.7) |

### zix.Udp

| Module | Coverage |
| :- | :- |
| `udp/config.zig` | `refAllDecls` + defaults: `UdpServerConfig`, `UdpClientConfig`, `PortMode` and `Endianness` enum backing values |
| `udp/packet.zig` | `refAllDecls` + behavioral: NATIVE no-op, u8 array not swapped, LITTLE/BIG round-trip identity, non-native swaps integers, non-native swaps float array elements, `FeedbackResult` all variants |
| `udp/server.zig` | `refAllDecls` + behavioral: port zero -> `error.PortNotConfigured`, nonzero port succeeds, config fields preserved |
| `udp/client.zig` | `refAllDecls` (socket bind required for behavioral tests — deferred to Tier 2 integration tests) |

### zix.Utils

| Module | Coverage |
| :- | :- |
| `utils/file.zig` | `refAllDecls` + behavioral: extension, saveFile |

---

## Integration Tests

Source: `tests/integration/`. Each file is a standalone test executable compiled with the `zix` module imported.

### Tier 1 — implemented (no server lifecycle required)

These tests exercise the library against mock inputs — no socket, no `std.Io` scheduler.

#### `http_request_test.zig`

| Test | What it verifies |
| :- | :- |
| `pathParam()` single param | captured segment returned by name, absent name -> null |
| `pathParam()` hyphenated names | `:tenant-id`, `:tenant-branch` (http_paths example pattern) |
| `body()` with body_cache | pre-set `body_cache` is returned without touching `reader`; second call returns same slice |
| `queryParam()` empty value | `?k=` -> `""` (not null) — behavioral distinction from `queryParams()` |
| `queryParams()` empty value | `?k=` -> `QueryParam{ .key="k", .value=null }` |

#### `http_router_test.zig`

| Test | What it verifies |
| :- | :- |
| Exact match | `dispatch` returns true correct handler called |
| No match | `dispatch` returns false |
| Exact beats param | exact registered after param still wins for the same path |
| Param beats prefix | param registered after prefix still wins |
| Param populates `path_params` | `req.path_params` is set after a param dispatch `req.pathParam()` returns the value |
| Longest prefix wins | `/api/users` beats `/api` for `/api/users/alice` |
| Prefix boundary | `/api` does **not** match `/apiv2` (next char after prefix must be `/`) |
| Prefix matches its own path | `/api` matches `/api` exactly |

#### `http_sse_test.zig`

| Test | What it verifies |
| :- | :- |
| `TEXT_EVENT_STREAM` content type string | public enum -> `"text/event-stream"` |
| `SseWriter` writeEvent wire format | `"data: ping\n\n"` via public `zix.Http.SseWriter` |
| `SseWriter` writeNamedEvent wire format | `"event: update\ndata: 99\n\n"` |
| `SseWriter` comment wire format | `": keepalive\n"` |
| `Response.streaming` defaults to false | public `init()` invariant |

#### `websocket_test.zig`

| Test | What it verifies |
| :- | :- |
| `parseFrame` incomplete -> null | < 2 bytes, and header present but payload truncated |
| `parseFrame` binary opcode | FIN, opcode, payload round-trip |
| `parseFrame` ping with payload | opcode, payload content |
| `parseFrame` pong opcode | opcode |
| `parseFrame` close, empty payload | opcode, zero-length payload |
| `parseFrame` 126-tier length | extended 16-bit encoding, 130-byte payload decoded correctly |
| `buildFrame` server frames unmasked | mask bit (byte[1] & 0x80) is zero for all opcodes |
| `buildFrame` FIN bit always set | byte[0] & 0x80 for text, binary, ping, pong, close |
| Round-trip all opcodes | buildFrame -> parseFrame for text, binary, ping, pong, close |
| `acceptKey` key too long | key ≥ 93 bytes -> `error.KeyTooLong` |
| `RoomMap` init / deinit | no connections, no crash or leak |

#### `udp_packet_test.zig`

Uses the same `Packet` type as `examples/udp_server.zig` and `examples/udp_client.zig` (`id [16]u8`, `packet_type i32`, `register u32`, `position [3]f64`).

| Test | What it verifies |
| :- | :- |
| NATIVE is a no-op | bytes unchanged |
| `id` field never swapped | `[16]u8` arrays skipped on LITTLE and BIG |
| Round-trip LITTLE | `toEndian` -> `fromEndian` restores original bytes |
| Round-trip BIG | same for BIG endian |
| Non-native swaps numeric fields | `packet_type` (i32), `register` (u32), each `position` (f64) element |
| `FeedbackResult.packet` value | `.packet` variant stores and returns the full packet correctly |
| Compile-time size guard | `@sizeOf(Packet) ≤ 65,507` (RFC 768 UDP payload limit) |

### Tier 2 — planned (requires server lifecycle control)

These require a running server with a clean `stop()` signal (see `rnd/server-lifecycle-proposal.md`).

| Area | Planned coverage |
| :- | :- |
| HTTP handler paths | 200 response bodies, method guards, JSON parse/format round-trip |
| HTTP middleware | Origin check (403), Basic auth (401), composed chains |
| HTTP static serving | GET known file -> 200 + content, GET unknown -> 404 |
| WebSocket | Full upgrade handshake (101), text frame broadcast, ping/pong, clean close |
| UDP server/client | ACK, NACK, echo, broadcast relay, disconnect detection |

---

###### end of tests
