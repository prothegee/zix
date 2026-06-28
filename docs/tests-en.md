# Tests: zix

---

## Running Tests

```sh
# unit tests only (silent on success)
zig build unit-test

# integration tests: components wired together, no live server
zig build integration-test

# behaviour tests: observable API contracts
zig build behaviour-test

# edge tests: boundary conditions and error paths
zig build edge-test

# all of the above at once
zig build test-all
```

`zig build` alone does **not** run tests: test steps are separate named steps not wired into the default install step.

---

## Unit Tests

Source: `src/lib.zig`. Each module is exercised via `std.testing.refAllDecls`, which verifies every public declaration compiles and any inline `test` blocks pass.

### zix.Tcp (raw)

| Module | Coverage |
| :- | :- |
| `tcp/config.zig` | `refAllDecls` + behavioral: `TcpServerConfig` defaults (kernel_backlog=4096, max_msg_len=4096, workers=0, pool_size=0) with dispatch_model required (set explicitly), `TcpClientConfig` defaults (max_msg_len=4096) |
| `tcp/server.zig` | `refAllDecls` + behavioral: port zero -> `error.PortNotConfigured`, valid config succeeds and deinit is safe, valid EPOLL config succeeds and deinit is safe |
| `tcp/client.zig` | `refAllDecls` |

### zix.Http

| Module | Coverage |
| :- | :- |
| `tcp/http/method.zig` | `refAllDecls` |
| `tcp/http/status.zig` | `refAllDecls` |
| `tcp/http/content.zig` | `refAllDecls` + round-trip: `enumFromString` / `stringFromEnum` for every enum variant |
| `tcp/http/parser.zig` | `refAllDecls` + behavioral: incomplete returns null, minimal GET offsets, path+query split, header offsets, keep_alive flag, all methods, invalid method, chunked flag set/false, dechunk single/multiple/terminal/extension/invalid-hex/uppercase hex |
| `tcp/http/request.zig` | `refAllDecls` + behavioral: method, path, query string, queryParam (present / absent / flag), pathSegments, queryParams, header lookup (case-insensitive) |
| `tcp/http/response.zig` | `refAllDecls` + behavioral: setStatus, setContentType, setKeepAlive, addHeader, `HeaderSize.value()`, injection guard (CR/LF), TooManyHeaders, `SseWriter` wire formats, `Response.streaming` default |
| `tcp/http/router.zig` | `refAllDecls` + behavioral: matchParam, route registration (kind + path preserved) |
| `tcp/http/static.zig` | `refAllDecls` + behavioral: mimeType, parseRangeHeader |
| `tcp/http/websocket.zig` | `refAllDecls` + behavioral: acceptKey RFC vector, buildFrame + parseFrame round-trip, masked frame |
| `tcp/http/context.zig` | `refAllDecls` + behavioral: `timedOut` null deadline returns false, `isExpired` null deadline returns false |
| `tcp/http/server.zig` | `refAllDecls` + behavioral: `EpollConnTable` slab alloc / free lifecycle, filled-bytes accounting, out-of-range fd returns null, `getAvailableCpuCount` returns at least 1, `effectiveCacheEntries` honors the memory ceiling, EPOLL `processRequest` serves a cache miss then a hit |

### zix.Http1

| Module | Coverage |
| :- | :- |
| `tcp/http1/core.zig` | `refAllDecls` + behavioral: parseHead (GET fields, query split from path, POST Content-Length, HTTP/1.0 keep_alive default + Connection override, Expect 100-continue), getHeader case-insensitive, queryParam, parseRange, percentDecode, buildSimpleHeaderInto, writeSimple into the active RespSink with no buffer bounce, cache no-op / store-then-hit / key separation by path and query |
| `tcp/http1/server.zig` | `refAllDecls` + behavioral: config validation (POOL / EPOLL), serveEpollConn answers a pipelined burst in order, EPOLL cache miss-then-hit + effectiveCacheEntries memory ceiling, ConnTable slab lifecycle + ws_recv_buf sizing, serveEpollWs drains to EAGAIN, parseGetFastPath (GET / query / rejects POST and HTTP/1.0 / raw headers), initUringRing yields a usable ring, URING finishClose rings the close (`prep_close`) and recycles the slot |
| `tcp/http1/websocket.zig` | `refAllDecls` + behavioral: acceptKey RFC 6455 vector, buildFrame/parseFrame round-trip, SIMD unmask matches scalar (and tail bytes), buildHeader prefix, pump echoes over a socketpair, pumpRing stages then reports close, broadcast fan-out (+ dead-fd skip, empty list) |
| `tcp/http1/router.zig` | `refAllDecls` + behavioral: matchParam, comptime router |
| `tcp/http1/config.zig` | `refAllDecls` (default values exercised by `tests/behaviour/http1/config_test.zig`) |

### zix.Udp

| Module | Coverage |
| :- | :- |
| `udp/config.zig` | `refAllDecls` + defaults: `UdpServerConfig`, `UdpClientConfig`, `PortMode` and `Endianness` enum backing values |
| `udp/packet.zig` | `refAllDecls` + behavioral: NATIVE no-op, u8 array not swapped, LITTLE/BIG round-trip, non-native swaps integers and float array elements, `FeedbackResult` all variants |
| `udp/server.zig` | `refAllDecls` + behavioral: port zero -> `error.PortNotConfigured`, nonzero port succeeds, config fields preserved |
| `udp/client.zig` | `refAllDecls` |

### zix.Uds

| Module | Coverage |
| :- | :- |
| `uds/config.zig` | `refAllDecls` + defaults: `UdsServerConfig` (backlog=128, max_msg_len=4096), `UdsClientConfig` |
| `uds/server.zig` | `refAllDecls` + behavioral: empty path -> `error.PathEmpty`, valid path succeeds and deinit is safe |
| `uds/client.zig` | `refAllDecls` |

### zix.Http.Client

| Module | Coverage |
| :- | :- |
| `tcp/http/client_config.zig` | `refAllDecls` + defaults: `HttpClientConfig` (connect_timeout_ms=0, response_timeout_ms=0, read_timeout_ms=0, max_response_body=4MB, follow_redirects=true, max_redirects=3, user_agent=`zon_options.user_agent`) |
| `tcp/http/client.zig` | `refAllDecls` |
| `tcp/http/sse_client.zig` | `refAllDecls` + behavioral: `splitField` (data / event / retry / bare field name / name mismatch / no leading space preserved), `parseHttpUrl` (basic, default port 80, https returns `TlsNotSupported`) |
| `tcp/http/ws_client.zig` | `refAllDecls` + behavioral: acceptKey RFC 6455 vector, `parseWsUrl` (basic, no path defaults to /, default port 80, wss returns `TlsNotSupported`, non-ws returns `InvalidUrl`) |

### zix.Channel

| Module | Coverage |
| :- | :- |
| `channel/channel.zig` | `refAllDecls` + behavioral: `Channel(u32)` init capacity and count, ring buffer tail arithmetic |

### zix.Fix

| Module | Coverage |
| :- | :- |
| `tcp/fix/config.zig` | `refAllDecls` + behavioral: `FixServerConfig` required fields (ip, port, comp_id), dispatch_model required (set explicitly), workers/pool_size default to 0, kernel_backlog default 1024, heartbeat_timeout_ms defaults to 0, `FixClientConfig` required fields (ip, port, comp_id, target_comp_id) |
| `tcp/fix/core.zig` | `refAllDecls` + behavioral: `parseFields` round-trip, `getField` lookup and null case, `computeChecksum` known vector, `verifyChecksum` valid/truncated/bad, `findMessageEnd` complete/partial/no-terminator, `buildMessage` produces valid checksum |
| `tcp/fix/server.zig` | `refAllDecls` + behavioral: port zero -> `error.PortNotConfigured`, valid config succeeds, deinit is safe |
| `tcp/fix/client.zig` | `refAllDecls` + behavioral: `FixClient.connect` port zero -> `error.PortNotConfigured` |
| `tcp/fix/router.zig` | `refAllDecls` + behavioral: dispatch calls the matching handler, no match leaves the handler uncalled, route timeout sets `deadline_ns` |

### zix.Http2

| Module | Coverage |
| :- | :- |
| `tcp/http2/frame.zig` | `refAllDecls` + behavioral: `FRAME_TYPE_HEADERS=0x01`, `FLAG_END_STREAM=0x01`, `ERR_NO_ERROR=0`, `writeFrameHeader`/`readFrameHeader` roundtrip via pipe, PREFACE starts with `PRI`, `sendSettings` writes a valid 9-byte SETTINGS frame via pipe |
| `tcp/http2/hpack.zig` | `refAllDecls` + behavioral: Huffman encode/decode roundtrip, `HpackEncoder.writeHeader` produces indexed entry from static table, `HpackDecoder.decode` decodes indexed `:method GET`, dynamic table eviction respects max_size, `HPACK_STATIC` index 8 is `:status 200` |
| `tcp/http2/core.zig` | `refAllDecls` + behavioral: `ServeOpts` struct defaults, `HandlerFn` is a function pointer type |
| `tcp/http2/config.zig` | `refAllDecls` + behavioral: `Http2ServerConfig` required fields compile, dispatch_model required (set explicitly), workers/pool_size default to 0, max_streams=16 and max_frame_size=16384 |
| `tcp/http2/server.zig` | `refAllDecls` + behavioral: port zero -> `error.PortNotConfigured`, valid config succeeds and deinit is safe |

### zix.Grpc

| Module | Coverage |
| :- | :- |
| `tcp/http2/grpc/status.zig` | `refAllDecls` + behavioral: OK=0, CANCELLED=1, UNIMPLEMENTED=12, UNAUTHENTICATED=16 |
| `tcp/http2/grpc/frame.zig` | `refAllDecls` + behavioral: `readGrpcPrefix` / `writeGrpcPrefix` roundtrip, compress flag preserved, message length preserved, `sendGrpcError` includes `content-type` header |
| `tcp/http2/grpc/proto.zig` | `refAllDecls` + behavioral: `encodeVarint` / `decodeVarint` roundtrip, `encodeString` produces LEN wire type, `encodeInt32` produces VARINT wire type, `encodeDouble` / `decodeDouble` roundtrip (positive and negative values), `MessageReader` iterates all fields |
| `tcp/http2/grpc/timeout.zig` | `refAllDecls` + behavioral: H/M/S/m/u/n units convert correctly, single-char returns null, empty returns null |
| `tcp/http2/grpc/core.zig` | `refAllDecls` + behavioral: `parsePath` valid and invalid inputs, `detectContentType` proto/json/unknown, `GrpcContext.recvMessage` empty body returns null, `Route.timeout_ms` defaults to zero, `GrpcContext.isExpired` null/past/future deadline, `GrpcServeOpts.handler_timeout_ms` defaults to zero, Router dispatches to matching handler |
| `tcp/http2/grpc/config.zig` | `refAllDecls` + behavioral: `GrpcServerConfig` required fields and defaults (handler_timeout_ms=0), `GrpcClientConfig` required fields |
| `tcp/http2/grpc/server.zig` | `refAllDecls` + behavioral: port zero -> `error.PortNotConfigured`, valid config succeeds, deinit is safe |
| `tcp/http2/grpc/client.zig` | `refAllDecls` + behavioral: `GrpcClient.connect` port zero -> `error.PortNotConfigured` |

### zix.Http3

The HTTP/3 (QUIC) layers are pure-Zig from the RFCs, so each carries the spec's own worked example as an in-file test. `zix.Http3` also exports these as primitives (mirroring `zix.Http2`), and the live round trip is driven by a native client hand-rolled from them in `test-runner-http3` / `test-runner-all`.

| Module | Coverage |
| :- | :- |
| `udp/http3/crypto.zig` | `refAllDecls` + behavioral: Initial secrets / AES-128-GCM keys from a connection id match the RFC 9001 Appendix A.1 worked example, AEAD nonce and header-mask helpers |
| `udp/http3/protection.zig` | `refAllDecls` + behavioral: seal-then-open round-trip for Initial / Handshake / 1-RTT packets, header protection applied and removed, a flipped byte fails AEAD |
| `udp/http3/keyschedule.zig` | `refAllDecls` + behavioral: handshake keys from ECDHE + transcript, 1-RTT application keys from the handshake secret + transcript through Finished |
| `udp/http3/qpack.zig` | `refAllDecls` + behavioral: prefixed-integer encode / decode, indexed field line, literal-with-name-reference, the static table entries |
| `udp/http3/huffman.zig` | `refAllDecls` + behavioral: decode of the RFC 7541 Appendix C.4 `www.example.com` vector and a request path with digits and symbols |
| `udp/http3/varint.zig` / `packet.zig` / `frame.zig` | `refAllDecls` + behavioral: varint read / write round-trip, long / short header parse, CRYPTO and STREAM frame parse |
| `udp/http3/request.zig` / `response.zig` | `refAllDecls` + behavioral: `parseRequest` recovers `:method` / `:path` past a leading ACK, `buildResponse` carries the control SETTINGS plus a HEADERS / DATA reply |
| `udp/http3/connection.zig` | `refAllDecls` + behavioral: `init` derives the Initial keys from the connection id (RFC 9001 A.1), the anti-amplification 3x cap |
| `udp/http3/router.zig` | `refAllDecls` + behavioral: dispatch calls the matching handler, the query is stripped before matching, no match returns 404 |
| `udp/http3/config.zig` / `server.zig` | `refAllDecls` + behavioral: required config fields and defaults, a null `Tls.Context` is rejected at init |

### zix.Logger

| Module | Coverage |
| :- | :- |
| `logger/logger.zig` | `refAllDecls` + behavioral: init and deinit with no save_path, system() below save_min_level is silent, access() below save_min_level is silent, statusLevel mapping (100=DEBUG 200=INFO 301=INFO 404=WARN 500=ERROR), conn/packet/frame/session/rpc below save_min_level are silent |

### zix.Utils

| Module | Coverage |
| :- | :- |
| `utils/file.zig` | `refAllDecls` + behavioral: extension, save |
| `utils/multipart.zig` | `refAllDecls` + behavioral: `Parser` parse + getField |
| `utils/response_cache.zig` | `refAllDecls` + behavioral: store-then-lookup returns identical bytes, miss on absent key, expired entry refetches, oversize value bypasses store, ttl 0 never fresh, distinct keys coexist via probing, `max_entries` rounded down to power of two, `hashKey` separates by query |

### zix.Multiplexers

| Module | Coverage |
| :- | :- |
| `multiplexers/ring.zig` | `refAllDecls` + behavioral: io_uring `user_data` round-trip preserves `{ op, gen, fd }`, each `OpKind` variant (`accept` / `recv` / `send` / `timeout` / `close`) decodes back, max generation does not bleed into the fd field |

---

## Integration Tests

Source: `tests/integration/`. Each file is a standalone test executable compiled with the `zix` module imported. These tests exercise components wired together against mock inputs, no live socket, no `std.Io` scheduler.

### tests/integration/tcp/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| `TcpServer.init` valid config | init with real ip and port succeeds, deinit is safe |
| `TcpServer.init` EPOLL dispatch model | init with `.EPOLL` dispatch model succeeds, deinit is safe |
| `TcpServer.init` port zero | returns `error.PortNotConfigured` |
| `HandlerFn` type check | `zix.Tcp.echoHandler` satisfies `zix.Tcp.HandlerFn` |
| `TcpClient.connect` port zero | returns `error.PortNotConfigured` before any socket call |

### tests/integration/http/

#### `request_test.zig`

| Test | What it verifies |
| :- | :- |
| `pathParam()` single param | captured segment returned by name (absent name returns null) |
| `pathParam()` hyphenated names | `:tenant-id`, `:tenant-branch` (http_paths example pattern) |
| `body()` chunked single chunk decoded correctly | `"5\r\nhello\r\n0\r\n\r\n"` -> `"hello"` |
| `body()` chunked multiple chunks assembled | `"3\r\nfoo\r\n4\r\nbarr\r\n0\r\n\r\n"` -> `"foobarr"` |
| `body()` chunked empty body returns empty string | terminal chunk only -> `""` |
| `body()` returns body_cache without touching reader | pre-set `body_cache` short-circuits read, second call returns same pointer |

#### `router_test.zig`

| Test | What it verifies |
| :- | :- |
| Exact match | `dispatch` returns true, correct handler called |
| Param populates `path_params` | `req.path_params` set after param dispatch. `req.pathParam()` returns the value. |
| Two path params both populated | multi-param route captures both segments |
| Prefix routes to handler | prefix match returns true and calls handler |

#### `context_test.zig`

| Test | What it verifies |
| :- | :- |
| `withTimeout` / `withDeadline` timing | 60s budget not expired. 10ms budget exceeded after 50ms sleep. |

#### `header_index_test.zig`

| Test | What it verifies |
| :- | :- |
| Empty index returns null | no headers indexed (all lookups return null) |
| Case-insensitive lookup | pre-populated map: `Content-Type` found via `content-type` |

#### `sse_test.zig`

| Test | What it verifies |
| :- | :- |
| `SseWriter.writeEvent` wire format | `"data: ping\n\n"` via `std.Io.Writer.fixed` buffer |
| `SseWriter.writeNamedEvent` wire format | `"event: update\ndata: 99\n\n"` |
| `SseWriter.comment` wire format | `": keepalive\n"` |

### tests/integration/websocket/

#### `websocket_test.zig`

| Test | What it verifies |
| :- | :- |
| `parseFrame` binary opcode | FIN, opcode, payload round-trip |
| `parseFrame` ping with payload | opcode, payload content |
| `parseFrame` pong opcode | opcode |
| `parseFrame` close with empty payload | opcode, zero-length payload |
| Round-trip all opcodes | buildFrame -> parseFrame for text, binary, ping, pong, close |
| `RoomMap` init / deinit | no connections (no crash or leak) |

### tests/integration/udp/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| `UdpServer.init` valid config | init with real ip and port succeeds |
| `UdpServer.init` port zero | returns `error.PortNotConfigured` |
| `UdpClient.init` zero bind_port | returns `error.PortNotConfigured` before any socket call |

#### `packet_test.zig`

| Test | What it verifies |
| :- | :- |
| Round-trip LITTLE | `toEndian` -> `fromEndian` restores original bytes |
| Round-trip BIG | same for BIG endian |
| `FeedbackResult.packet` value | `.packet` variant stores and returns the full packet |

### tests/integration/http/ (client)

#### `client_test.zig`

| Test | What it verifies |
| :- | :- |
| `HttpClient.init` and `deinit` | no requests: init + deinit is safe with Threaded io |
| `ClientResponse.header()` on mock head bytes | lookup by name and case-insensitive lookup |
| `ClientResponse.iterateHeaders()` | counts all headers from raw head bytes |
| `ClientRequestOpts` defaults | `headers` empty, `body` null, `connect_timeout_ms` null |

### tests/integration/uds/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| `UdsServer.init` valid path | succeeds and `deinit` is safe |
| `HandlerFn` type check | `zix.Uds.echoHandler` satisfies `zix.Uds.HandlerFn` |

### tests/integration/logger/

#### `logger_test.zig`

| Test | What it verifies |
| :- | :- |
| `Logger.system()` writes line to file | `[component]` tag and message text appear in log file |
| `Logger.access()` writes line to file | method, path, status, bytes all appear in log file |
| Absent UA and origin logged as dash | empty `""` args produce `"-"` in the quoted fields |
| Present UA appears in file | non-empty UA string written as-is |
| 5xx status maps to ERROR level | `access()` with status 500 writes `ERROR` label |
| `anyerror` arg formats correctly | `{}` format of an error value renders the error name |

### tests/integration/fix/

#### `server_test.zig`

| Test | What it verifies |
| :- | :- |
| `FixServer` init and deinit do not error | valid config succeeds, deinit is safe |
| `FixServer` init port zero | returns `error.PortNotConfigured` |
| Logon handshake and echo round-trip succeed | send Logon, receive Logon reply with MsgType=A send NewOrderSingle, receive echo, send Logout, receive Logout reply |
| Multiple sequential messages are all echoed | three NewOrderSingle messages echoed with ClOrdID preserved across all |

### tests/integration/http2/

#### `server_test.zig`

Ports: 18082-18085.

| Test | What it verifies |
| :- | :- |
| `Http2Server.init` and deinit do not error | valid config succeeds, deinit is safe |
| `Http2Server.init` port zero | returns `error.PortNotConfigured` |
| `Http2 HandlerFn` type is a function pointer | `zix.Http2.HandlerFn` assignment compiles |
| Http2 GET / returns Hello World over h2c direct | h2c PRI preface + HEADERS + DATA round-trip returns response body |
| Http2 POST /echo returns request body | POST with body DATA frame, server echoes body back |
| Http2 two sequential streams on same connection | stream IDs 1 and 3 each receive correct responses |
| Http2 h2c upgrade GET / returns Hello World | HTTP/1.1 `Upgrade: h2c` -> 101 Switching Protocols -> h2c response |

### tests/integration/grpc/

#### `server_test.zig`

Ports: 18200-18206.

| Test | What it verifies |
| :- | :- |
| `GrpcServer.init` and deinit do not error | valid config succeeds, deinit is safe |
| `GrpcServer.init` port zero | returns `error.PortNotConfigured` |
| gRPC unary returns greeting | `greetHandler` reads one message, replies `"Hello, world!"` |
| gRPC server streaming sends multiple responses | `echoHandler` sends two messages, client receives both in order |
| gRPC client streaming collects all messages | `collectHandler` buffers three messages, replies with count `"got 3"` |
| gRPC bidirectional echoes each message | `echoHandler` echoes `"ping"` then `"pong"` from two client messages |
| gRPC unknown method returns UNIMPLEMENTED | `dispatchHandler` replies with `GrpcStatus.UNIMPLEMENTED` for unknown path |
| gRPC trailers-only error is received as INVALID_ARGUMENT | `errorOnlyHandler` calls `ctx.finish(INVALID_ARGUMENT, ...)` without sending data, client receives the error status |
| gRPC two streams on same connection both return OK | two sequential unary RPCs on one connection, both streams receive correct responses |

### tests/integration/channel/

#### `channel_test.zig`

| Test | What it verifies |
| :- | :- |
| `Channel(u32)` init capacity | `buf.len == 8`, `count == 0`, `head == 0` |
| `Channel([]const u8)` compiles | slice element type accepted |
| `Channel(struct)` compiles | struct element type accepted |
| `Channel(u32)` send and recv round-trip | send then recv returns the sent value |
| `Channel(u32)` drain after close | send two items, close, recv both, third recv returns `error.Closed` |

---

## Behaviour Tests

Source: `tests/behaviour/`. Each file verifies observable API contracts that callers rely on: the "what does this always do" properties.

### tests/behaviour/tcp/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| `TcpServerConfig` dispatch_model is required (set explicitly) | `.ASYNC` stored as set |
| `TcpServerConfig` kernel_backlog default | 4096 |
| `TcpServerConfig` max_msg_len default | 4096 |
| `TcpServerConfig` workers default | 0 (auto) |
| `TcpServerConfig` pool_size default | 0 (auto) |
| `TcpClientConfig` max_msg_len default | 4096 |
| TCP frame length header | 4-byte big-endian u32 encodes and decodes correctly |
| TCP frame zero-length payload | encodes as four zero bytes |
| TCP frame header size | always exactly 4 bytes |
| `DispatchModel.ASYNC` is zero value | `@intFromEnum(.ASYNC) == 0` |

### tests/behaviour/http/

#### `request_test.zig`

| Test | What it verifies |
| :- | :- |
| `path()` strips query string | `"/api/users?limit=10"` -> `"/api/users"` |
| `path()` returns full target when no `?` | `"/api/users/alice"` unchanged |
| `path()` root path | `"/"` returns `"/"` |
| `query()` returns portion after `?` | `"q=hello&lang=zig"` |
| `query()` returns empty when no `?` | `""` |
| `body()` chunked produces same payload as Content-Length | chunked `"world"` matches `body_cache = "world"` |
| `body()` second call returns cached result | `b1.ptr == b2.ptr` after two body() calls |
| `method()` resolves each method | DELETE/PATCH/PUT/OPTIONS/HEAD/GET/POST all resolved |

#### `router_test.zig`

| Test | What it verifies |
| :- | :- |
| Exact beats param regardless of registration order | exact registered after param still wins |
| Param beats prefix regardless of registration order | param registered after prefix still wins |
| Prefix: longest match wins | `/api/users` beats `/api` for `/api/users/alice` |
| Prefix matches its own path exactly | `/api` matches `/api` |
| Query string transparent for param dispatch | `"/users/bob?role=admin"` captures `bob` via `:id` |
| Query string transparent for exact dispatch | `"/about?ref=menu"` matches `/about` |

#### `content_test.zig`

| Test | What it verifies |
| :- | :- |
| Text group extensions | html/htm/css/txt/csv |
| Application group extensions | json/map/js/min.js/xml/pdf/wasm/zip/gz/tar/7z/rar/rtf |
| Image group extensions | png/jpg/jpeg/gif/svg/webp/ico |
| Audio group extensions | mp3/wav/flac/mid/midi |
| Video group extensions | mp4/webm/ogg/mpeg/avi/mov/wmv/flv/mkv |
| Font group extensions | ttf/otf/woff/woff2 |
| Matching is case-insensitive | HTML, PNG, JS, JSON, JPG, JPEG, CSS, WOFF2 |
| `fromExtension()` returns correct MIME string | representative set |
| Alias pairs produce identical MIME strings | jpg==jpeg, mid==midi, html==htm, js==min.js, json==map |

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| Buffer size defaults | `kernel_backlog`, `max_recv_buf`, `max_allocator_size`, `max_client_response` all 4096 |
| Timeout defaults are disabled | `conn_timeout_ms == 0`, `handler_timeout_ms == 0` |
| Static serving disabled by default | `public_dir == ""`, `public_dir_upload == "u"` |
| `dispatch_model` is required (no default) | caller must set it in `HttpServerConfig` |
| Worker pool defaults to auto-size | `workers == 0`, `pool_size == 0` |
| `max_request_headers` defaults to `.LARGE` | enum variant and `.value()` == 64 |
| `RequestHeaderSize` tier values | MINIMAL=16, COMMON=32, LARGE=64 |
| `RequestHeaderSize.CUSTOM(N)` capped at 64 | values above 64 silently return 64 |
| `max_response_headers` defaults to MINIMAL (16) | enum value and `.value()` |
| `HeaderSize` tier values | MINIMAL=16, COMMON=32, LARGE=64, EXTRA_LARGE=128 |
| `HeaderSize.CUSTOM(N)` returns N | 7 and 100 |
| `Response` status defaults to OK | `init()` invariant |

#### `sse_test.zig`

| Test | What it verifies |
| :- | :- |
| `ContentType.TEXT_EVENT_STREAM.asString()` | returns `"text/event-stream"` |
| `Response.streaming` defaults to false | `init()` invariant |

### tests/behaviour/websocket/

#### `websocket_test.zig`

| Test | What it verifies |
| :- | :- |
| FIN bit always set | byte[0] & 0x80 for text, binary, ping, pong, close |
| Server frames unmasked | byte[1] & 0x80 == 0 for all opcodes (RFC 6455 5.1) |

### tests/behaviour/udp/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| `UdpServerConfig` conn_timeout_ms | default 5000 |
| `UdpServerConfig` poll_timeout_ms | default 2000 |
| `UdpServerConfig` auto_ack | default false |
| `UdpServerConfig` broadcast | default false |
| `UdpServerConfig` endianness | default LITTLE |
| `UdpServerConfig` port_mode | default REQUIRED |
| `UdpClientConfig` send_once | default false |
| `UdpClientConfig` send_every | default 99 |
| `UdpClientConfig` endianness | default LITTLE |

#### `packet_test.zig`

| Test | What it verifies |
| :- | :- |
| `toEndian` NATIVE is a no-op | bytes unchanged on any host |
| u8 array fields never swapped | `id [4]u8` untouched by LITTLE and BIG |
| Non-native swaps integer fields | `i32` field byte-swapped |
| Non-native swaps float array elements | `[2]f64` elements each swapped |

### tests/behaviour/http/ (client)

#### `client_test.zig`

| Test | What it verifies |
| :- | :- |
| `ClientConfig` connect/response/read timeout defaults | all 0 (disabled) |
| `ClientConfig` max_response_body default | 4 MB (1024 * 1024 * 4) |
| `ClientConfig` follow_redirects default | true |
| `ClientConfig` max_redirects default | 3 |
| `ClientConfig` user_agent default | matches `zix.Http.default_user_agent` (library version string from `build.zig.zon`) |
| `ClientResponse.status()` | returns status_code field |
| `ClientResponse.body()` | returns body_data slice |
| `ClientResponse.header()` case-insensitive | matches regardless of header name casing |
| `ClientResponse.deinit()` zero-length body | safe, no crash or leak |

### tests/behaviour/uds/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| `UdsServerConfig` backlog default | 128 |
| `UdsServerConfig` max_msg_len default | 4096 |
| `UdsClientConfig` stores path | path field preserved |
| UDS frame length header | 4-byte little-endian u32 encodes and decodes correctly |
| UDS frame zero-length payload | encodes as four zero bytes |
| UDS frame header size | always exactly 4 bytes |

### tests/behaviour/fix/

#### `session_test.zig`

| Test | What it verifies |
| :- | :- |
| Logon response has MsgType=A and CompIDs swapped | reply tag-35="A", tag-49=SERVER, tag-56=CLIENT, tag-34=1 |
| NewOrderSingle body fields are preserved in echo | tag-11 (ClOrdID), tag-55 (Symbol), tag-54 (Side), tag-38 (Qty) all present in echo |
| Clean Logout causes no server-side error | server error field is null after Logout exchange |

### tests/behaviour/logger/

#### `logger_test.zig`

| Test | What it verifies |
| :- | :- |
| `Level` backing values | DEBUG=0 INFO=1 WARN=2 ERROR=3 |
| `ConsoleMode` backing values | OFF=0 DEBUG_ONLY=1 ALWAYS=2 |
| `Config` defaults | console=OFF, console_min_level=INFO, save_path="", save_file="log", save_min_level=INFO, max_lines=1_000_000 |
| `Logger` init and deinit with no save_path | no crash or leak |
| `Logger` flush with no save_path is a no-op | no crash |
| `Http.ServerConfig.logger` defaults to null | `cfg.logger == null` invariant |
| `Http.Context.logger` defaults to null | `ctx.logger == null` invariant |
| `Http.Response.bytes_written` defaults to 0 | `res.bytes_written == 0` after `init()` |

### tests/behaviour/http2/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| `Http2ServerConfig` dispatch_model is required (no default) | caller must set it explicitly |
| `Http2ServerConfig` max_streams defaults to 16 | `max_streams == 16` invariant |
| `Http2ServerConfig` max_frame_size defaults to 16384 | `max_frame_size == 16384` invariant |
| `Http2` HandlerFn can be assigned to a local variable | `zix.Http2.HandlerFn` type assignment compiles |
| `Http2` PREFACE length is 24 | `zix.Http2.PREFACE.len == 24` |
| `Http2` ERR_NO_ERROR is zero | `zix.Http2.ERR_NO_ERROR == 0` |
| `Http2` FLAG_END_STREAM and FLAG_END_HEADERS are distinct | `FLAG_END_STREAM != FLAG_END_HEADERS` |

### tests/behaviour/grpc/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| `GrpcServerConfig` defaults | dispatch_model=ASYNC, kernel_backlog=1024, workers=0, pool_size=0, max_streams=16, max_frame_size=16384, max_body=65536 |
| `GrpcClientConfig` basic fields | ip and port fields preserved |
| `GrpcStatus` enum values | OK=0, CANCELLED=1, UNIMPLEMENTED=12, UNAUTHENTICATED=16 |
| `GrpcContext.recvMessage` empty body | returns null immediately |
| `GrpcPrefix` roundtrip | writePrefix -> readPrefix preserves compress flag and message length |
| `parsePath` valid path | `/helloworld.Greeter/SayHello` -> `package_service="helloworld.Greeter"`, `method="SayHello"` |
| `parseTimeout` seconds | `"2S"` -> 2,000,000,000 nanoseconds |

### tests/behaviour/channel/

#### `channel_test.zig`

| Test | What it verifies |
| :- | :- |
| `closed` field defaults to false | `init()` invariant |
| `head` starts at zero | `init()` invariant |
| Ring tail formula is `(head + count) % buf.len` | manually set state verifies arithmetic |
| `send` increments count | count goes from 0 to 1 after one send |
| `recv` decrements count | count returns to 0 after recv |
| `close` sets closed field | `ch.closed == true` after close |

---

## Edge Tests

Source: `tests/edge/`. Each file verifies boundary conditions and error paths.

### tests/edge/tcp/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| `TcpServer.init` port zero | returns `error.PortNotConfigured` |
| `DispatchModel` backing values stable | ASYNC=0, POOL=1, MIXED=2, EPOLL=3 |
| TCP frame max u32 length | `maxInt(u32)` encodes and decodes correctly via big-endian |

### tests/edge/http/

#### `request_test.zig`

| Test | What it verifies |
| :- | :- |
| `queryParam` key present with empty value | `"?k="` -> `""` (not null) |
| `queryParam` key absent returns null | key not in query string |
| `queryParam` no query string at all returns null | target has no `?` |
| `body()` chunked invalid hex returns empty string | `"zz"` chunk size -> `""` (dechunk error -> 0 bytes) |
| `body()` chunked missing terminal chunk returns partial data | no `0\r\n\r\n` -> partial data returned |
| `body()` chunked single-byte chunks | `1\r\na\r\n1\r\nb\r\n1\r\nc\r\n0\r\n\r\n` -> `"abc"` |

#### `router_test.zig`

| Test | What it verifies |
| :- | :- |
| No registered route returns false | empty router, `dispatch` returns false |
| Prefix `/api` does NOT match `/apiv2` | next char after prefix must be `/` or end-of-path |

#### `response_test.zig`

| Test | What it verifies |
| :- | :- |
| CR in header name -> `InvalidHeaderName` | injection guard |
| LF in header name -> `InvalidHeaderName` | injection guard |
| CR in header value -> `InvalidHeaderValue` | injection guard |
| LF in header value -> `InvalidHeaderValue` | injection guard |
| Buffer grows from 4 to 5 on 5th header | initial cap=4, growth to min(8, max_headers) |
| `max_headers=1` rejects second header | no growth: `TooManyHeaders` immediately |
| `HeaderSize.CUSTOM(0).value()` | returns 0 |

#### `content_test.zig`

| Test | What it verifies |
| :- | :- |
| Unknown extension -> `APPLICATION_OCTET_STREAM` | xyz, bin, dat, unknown |
| Empty string -> `APPLICATION_OCTET_STREAM` | `typeFromExtension("")` |
| `fromExtension` unknown -> `"application/octet-stream"` | string form of fallback |

### tests/edge/websocket/

#### `websocket_test.zig`

| Test | What it verifies |
| :- | :- |
| 0 bytes -> null | fewer than 2 bytes (can't read header) |
| 1 byte -> null | fewer than 2 bytes |
| Truncated payload -> null | header says 5 bytes but only 3 present |
| Extended 16-bit length (126-tier) | 130-byte payload: byte[1] carries 126 marker |
| `acceptKey` key too long -> `error.KeyTooLong` | key >= 93 bytes exceeds 128-byte hash_input |

### tests/edge/udp/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| `PortMode.CONFIGURABLE` backing value | equals 0 |
| `PortMode.REQUIRED` backing value | equals 1 |
| Port zero with `REQUIRED` mode | `UdpServer.init` returns `error.PortNotConfigured` |
| Non-zero port with `REQUIRED` mode | `UdpServer.init` succeeds |

#### `packet_test.zig`

| Test | What it verifies |
| :- | :- |
| `Endianness` enum backing values stable | NATIVE=0, LITTLE=1, BIG=2 |
| `FeedbackResult` ack/nack are tag-only | active tag matches .ack and .nack |

### tests/edge/http/ (client)

#### `client_test.zig`

| Test | What it verifies |
| :- | :- |
| Unsupported scheme -> `error.InvalidUrl` | `ftp://` scheme not accepted |
| Missing host -> `error.InvalidUrl` | `http://` with no host |
| Malformed URL -> `error.InvalidUrl` | `:::bad` fails at parse |
| `ClientResponse.header()` absent name | returns null |
| `RequestOpts.connect_timeout_ms` override | null, 0, and non-zero are distinct values |

### tests/edge/uds/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| Empty path -> `error.PathEmpty` | `UdsServer.init(.{ .path = "" })` returns PathEmpty |

### tests/edge/logger/

#### `logger_test.zig`

| Test | What it verifies |
| :- | :- |
| `statusLevel` 2xx boundary | `access()` does not crash for every status class (100-599) |
| `Level` enum ordering | DEBUG < INFO < WARN < ERROR via `@intFromEnum` |
| `system()` below `save_min_level` is silent | calls below threshold do not open a file (`file_fd == -1`) |
| `access()` below `save_min_level` is silent | same: `file_fd == -1` after filtered call |
| `system()` with empty component does not panic | `component = ""` is safe |
| `system()` with empty format does not panic | `fmt = ""` is safe |
| `access()` with empty method and path does not panic | empty strings are safe |
| `init` with empty `save_path`, `file_fd` stays invalid | `file_fd == -1` with `save_path = ""` |
| Console OFF (no output or panic for any level) | all four levels produce no crash with `console = .OFF` |

### tests/edge/fix/

#### `session_test.zig`

| Test | What it verifies |
| :- | :- |
| `parseFields` handles maximum number of fields without panic | `MAX_FIELDS - 1` tag=value pairs parsed without overflow or crash |
| `verifyChecksum` returns false for truncated message | message missing final SOH checksum delimiter |
| `findMessageEnd` returns null for message with tag-10 value but no final SOH | partial checksum field returns null |
| `buildMessage` with zero extra fields produces valid message | output passes `verifyChecksum` and `parseFields` round-trip |
| Message arriving in two TCP segments is reassembled correctly | split Logon across two flushes, server still replies with MsgType=A |
| Bad checksum causes server to close without server-side error propagation | corrupted message byte closes connection `ctx.err == null` |

### tests/edge/http2/

#### `server_test.zig`

Port: 18100.

| Test | What it verifies |
| :- | :- |
| bad PRI preface causes server to close connection | malformed preface bytes -> server closes the connection cleanly |
| client sends GOAWAY and server connection loop exits | GOAWAY frame -> server exits the frame loop without error |
| `Http2Server.init` rejects port zero | returns `error.PortNotConfigured` |
| `HpackDecoder` decode of empty block returns zero headers | `decode(&.{}, ...)` returns 0 headers without error |
| `writeFrameHeader` stream_id high bit is cleared on read | `stream_id = 0x7FFF_FFFF` roundtrips correctly via pipe |

### tests/edge/grpc/

#### `server_test.zig`

Ports: 18220-18221.

| Test | What it verifies |
| :- | :- |
| `readGrpcPrefix` with 4 bytes | returns `error.TooShort` |
| `readGrpcPrefix` with empty slice | returns `error.TooShort` |
| `GrpcContext.recvMessage` body shorter than prefix | body has 3 bytes (need 5 for prefix): returns null |
| `GrpcContext.recvMessage` msg_len exceeds body | prefix claims 100 bytes but body has only 5: returns null |
| `parsePath` empty string | returns null |
| `parsePath` no leading slash | returns null |
| `parsePath` only slash | returns null |
| `detectContentType` no header | returns UNKNOWN |
| `detectContentType` text/plain | returns UNKNOWN |
| `parseTimeout` single character | returns null |
| `GrpcClient.connect` port zero | returns `error.PortNotConfigured` |
| `serveConn` closes cleanly on immediate client disconnect | server accepts, client disconnects immediately, no crash or error |
| gRPC finish-only handler delivers error status to client | handler calls `ctx.finish(INVALID_ARGUMENT, ...)` only, client receives the error status without any data frames |

### tests/edge/channel/

#### `channel_test.zig`

| Test | What it verifies |
| :- | :- |
| Capacity 1 allocates exactly one slot | `buf.len == 1`, `count == 0` |
| Ring head wraps at `buf.len` | `(3+1) % 4 == 0` |
| Full boundary: `count == buf.len` | tail index wraps back to head |
| `send` after close | returns `error.Closed` |
| `recv` on empty closed channel | returns `error.Closed` |

---

###### end of tests
