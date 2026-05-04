# Tests -- zix

---

## Running Tests

```sh
# via build system (silent on success -- no output means all passed)
zig build test

# direct -- always prints each test name and result
zig test src/zix.zig
```

`zig build` alone does **not** run tests -- the `test` step is a separate named step not wired into the default install step.

---

## Unit Tests

Defined in `src/zix.zig`. Each module is exercised via `std.testing.refAllDecls`, which verifies every public declaration compiles and any inline `test` blocks pass.

### zix.Http

| Module | Coverage |
| :- | :- |
| `tcp/http/method.zig` | `refAllDecls` |
| `tcp/http/status.zig` | `refAllDecls` |
| `tcp/http/content.zig` | `refAllDecls` |
| `tcp/http/request.zig` | `refAllDecls` |
| `tcp/http/response.zig` | `refAllDecls` + behavioral tests (`HeaderSize.value()`) |
| `tcp/http/router.zig` | `refAllDecls` + behavioral tests (matchParam, registration) |
| `tcp/http/static.zig` | `refAllDecls` + behavioral tests (mimeType, parseRangeHeader) |
| `tcp/http/upload.zig` | `refAllDecls` + behavioral test (MultipartParser parse + getField) |
| `tcp/http/websocket.zig` | `refAllDecls` + behavioral tests (acceptKey, frame, masked frame) |

### zix.Udp

| Module | Coverage |
| :- | :- |
| `udp/config.zig` | `refAllDecls` + defaults: `UdpServerConfig`, `UdpClientConfig`, enum backing values |
| `udp/packet.zig` | `refAllDecls` + behavioral: NATIVE no-op, u8 array not swapped, LITTLE/BIG round-trip identity, non-native swaps integers, non-native swaps float array elements, `FeedbackResult` all variants |
| `udp/server.zig` | `refAllDecls` + behavioral: port zero returns `error.PortNotConfigured`, nonzero port succeeds, config preserved |
| `udp/client.zig` | `refAllDecls` (socket bind required for behavioral tests -- deferred to integration tests) |

### zix.Utils

| Module | Coverage |
| :- | :- |
| `utils/file.zig` | `refAllDecls` + behavioral tests (extension, saveFile) |

---

## Integration Tests

Not yet implemented. Planned coverage:

- HTTP round-trip: connect, send request, assert response (exact, param, prefix routes)
- UDP server/client: send packet, assert ACK / echo / broadcast received
- Static file serving: GET known file, assert 200 + content; GET unknown, assert 404
- WebSocket: upgrade handshake, text frame broadcast, clean close

---

###### end of tests
