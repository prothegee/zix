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

Platform behavior: with a foreign `-Dtarget` every suite compiles for that target and execution is skipped with a warning. On a non-Linux host, tests that exercise the Linux-only EPOLL / URING paths print a warn and skip, and tests scaffolded on Linux-only syscalls skip silently. The `test-runner-*` steps behave the same way: a foreign target compiles the runner plus its servers and passes, and on a non-Linux host every EPOLL / URING scenario reports a PASS line with a warn instead of running.

---

## Unit Tests

Source: `src/lib.zig`. Each module is exercised via `std.testing.refAllDecls`, which verifies every public declaration compiles and any inline `test` blocks pass.

### zix.Tcp (raw)

| Module | Coverage |
| :- | :- |
| `tcp/config.zig` | `refAllDecls` + behavioral: `TcpServerConfig` defaults (kernel_backlog=4096, max_recv_buf=4096, workers=0) with dispatch_model required (set explicitly), `DispatchModel` gapless backing values with only the three maintained models, the dropped POOL / MIXED names resolving to nothing, `TcpClientConfig` defaults (max_recv_buf=4096) |
| `tcp/server.zig` | `refAllDecls` + behavioral: port zero -> `error.ZixPortNotConfigured`, valid config succeeds and deinit is safe, valid EPOLL config succeeds and deinit is safe |
| `tcp/client.zig` | `refAllDecls` |

### zix.Http1

| Module | Coverage |
| :- | :- |
| `tcp/http1/method.zig` | `refAllDecls` + round-trip over every code including `QUERY` (RFC 10008), QUERY resolving from its wire token and never reported as GET, case-sensitive matching, `codeFromString` reporting an unknown token as null, a token past `MAX_TOKEN_LEN` refused by the length switch, `enumFromString` keeping its GET fallback |
| `tcp/http1/content.zig` | `refAllDecls` + round-trip: `typeFromString` / `stringFromEnum` for every enum variant, the RFC 10008 query types resolving from their strings, the 33-byte longest media type fitting the lowercase buffer, a value past `MAX_TYPE_LEN` reporting no match instead of panicking, `typeFromHeader` dropping parameters and staying case-insensitive |
| `tcp/http1/core.zig` | `refAllDecls` + behavioral: parseHead (GET fields, query split from path, POST Content-Length, HTTP/1.0 keep_alive default + Connection override, Expect 100-continue), getHeader case-insensitive, queryParam, parseRange, percentDecode, buildSimpleHeaderInto, sendSimpleFD into the active RespSink with no buffer bounce, cache no-op / store-then-hit / key separation by path and query, chunkedFrame walk (asks for more mid-body, terminator length, malformed vs too-large vs unfinished, data that spells the terminator, pipelined stop), decodeChunkedInBuf (in-place decode, source untouched while unfinished), ASYNC serveConn body path (fitting and over-large delivery with bodyReceived / bodyComplete reporting, the start of the body rather than drain leftovers, drain keeps the pipelined request, 413 declared and chunked past the buffer, 400 malformed chunked, 100 Continue, chunked arriving after the head, pipelined request behind a chunked body) |
| `tcp/http1/request.zig` | `refAllDecls` + behavioral: body returns the engine-delivered slice, bodyReceived defaults to the slice length and takes the engine override, bodyComplete defaults true and takes the engine override, fromRaw parses a raw buffer with body |
| `tcp/http1/server.zig` | `refAllDecls` + behavioral: config validation (ASYNC / EPOLL / URING), serveEpollConn answers a pipelined burst in order, EPOLL cache miss-then-hit + effectiveCacheEntries memory ceiling, ConnTable slab lifecycle + ws_recv_buf sizing, serveEpollWs drains to EAGAIN, parseGetFastPath (GET / query / rejects POST and HTTP/1.0 / raw headers), initUringRing yields a usable ring, URING finishClose rings the close (`prep_close`) and recycles the slot |
| `tcp/http1/dispatch/epoll.zig` (Linux) | behavioral body path: drain-then-serve reports the counted total, exact drain leaves the pipelined request intact, a peer that quits mid-drain is never served, a fitting body waits for the full count, 413 for a declared body past the limit and a chunked body past the body buffer, 400 on malformed chunked, one 100 Continue while the body is still arriving |
| `tcp/http1/dispatch/uring.zig` (Linux) | behavioral body path: a fully-present chunked body decodes, an oversized body is deferred and served with the counted total, a deferred request stays parked while its drain is unfinished, a fitting body waits for the full count, 413 declared and chunked, 400 malformed chunked, 100 Continue while the body is still arriving |
| `tcp/http1/websocket.zig` | `refAllDecls` + behavioral: acceptKey RFC 6455 vector, buildFrame/parseFrame round-trip, SIMD unmask matches scalar (and tail bytes), buildHeader prefix, pump echoes over a socketpair, pumpRing stages then reports close, broadcast fan-out (+ dead-fd skip, empty list) |
| `tcp/http1/router.zig` | `refAllDecls` + behavioral: matchParam, comptime router |
| `tcp/http1/config.zig` | `refAllDecls` (default values exercised by `tests/behaviour/http1/config_test.zig`) |

### zix.Udp

| Module | Coverage |
| :- | :- |
| `udp/config.zig` | `refAllDecls` + defaults: `UdpServerConfig`, `UdpClientConfig`, `allow_args` default, and `Endianness` enum backing values |
| `udp/packet.zig` | `refAllDecls` + behavioral: NATIVE no-op, u8 array not swapped, LITTLE/BIG round-trip, non-native swaps integers and float array elements, `FeedbackResult` all variants |
| `udp/server.zig` | `refAllDecls` + behavioral: port zero -> `error.ZixPortNotConfigured`, nonzero port succeeds, config fields preserved |
| `udp/client.zig` | `refAllDecls` |

### zix.Uds

| Module | Coverage |
| :- | :- |
| `uds/config.zig` | `refAllDecls` + defaults: `UdsServerConfig` (kernel_backlog=128, max_recv_buf=4096), `UdsClientConfig` |
| `uds/server.zig` | `refAllDecls` + behavioral: empty path -> `error.ZixPathEmpty`, valid path succeeds and deinit is safe |
| `uds/client.zig` | `refAllDecls` |

### zix.Channel

| Module | Coverage |
| :- | :- |
| `channel/channel.zig` | `refAllDecls` + behavioral: `Channel(u32)` init capacity and count, ring buffer tail arithmetic |

### zix.Fix

| Module | Coverage |
| :- | :- |
| `tcp/fix/config.zig` | `refAllDecls` + behavioral: `FixServerConfig` required fields (ip, port, comp_id), dispatch_model required (set explicitly), workers defaults to 0, kernel_backlog default 1024, heartbeat_timeout_ms defaults to 0, `FixClientConfig` required fields (ip, port, comp_id, target_comp_id) |
| `tcp/fix/core.zig` | `refAllDecls` + behavioral: `parseFields` round-trip, `getField` lookup and null case, `computeChecksum` known vector, `verifyChecksum` valid/truncated/bad, `findMessageEnd` complete/partial/no-terminator, `buildMessage` produces valid checksum |
| `tcp/fix/server.zig` | `refAllDecls` + behavioral: port zero -> `error.ZixPortNotConfigured`, valid config succeeds, deinit is safe |
| `tcp/fix/client.zig` | `refAllDecls` + behavioral: `FixClient.connect` port zero -> `error.ZixPortNotConfigured` |
| `tcp/fix/router.zig` | `refAllDecls` + behavioral: dispatch calls the matching handler, no match leaves the handler uncalled, route timeout sets `deadline_ns` |

### zix.Http2

| Module | Coverage |
| :- | :- |
| `tcp/http2/frame.zig` | PREFACE is the 24-byte preface, type / flag / error code / settings id values follow RFC 7540, `MAX_FRAME_SIZE_LIMIT` is the largest u24, header round trip / big endian / largest length and stream id, reserved bit dropped, unknown frame type passes through |
| `tcp/http2/FrameHeader.zig` | keeps its fields, holds the largest length and stream id |
| `tcp/http2/writer.zig` | `writeAllFD` delivers data / marks the stream answered / empty data writes nothing, `writeAllDirectFD` leaves the mark alone / closed peer BrokenPipe, `writeFrameHeaderFD` sends 9 bytes, `sendResponseFD` bodyless END_STREAM on HEADERS / small body one DATA / at `SEND_STAGE_BODY_MAX` one DATA / past the stage vectored / past the max frame size split / marks answered / content-type past the scratch BufferFull, `sendResponseEncodedFD` closed peer BrokenPipe |
| `tcp/http2/reader.zig` | `readOnceFD` returns what arrived / 0 after close, `recvExact` fills / empty buffer / short is Closed, `readFrameHeader` parses / cut short is Closed |
| `tcp/http2/control.zig` | `sendSettingsFD` empty / each param / past 24-bit TooManySettings, `sendSettingsAckFD` ACK no payload, `sendPingAckFD` echoes, `sendGoawayFD` last stream and code, `sendRstStreamFD` targets the stream, `sendWindowUpdateFD` increment / top bit clear, closed peer BrokenPipe |
| `tcp/http2/hpack/Header.zig` | keeps its fields, holds an empty value |
| `tcp/http2/hpack/HuffSym.zig` | keeps its fields, holds the longest 30-bit code |
| `tcp/http2/hpack/huffman_table.zig` | known codes for space, `a`, byte 255, every code fits its bit length |
| `tcp/http2/hpack/static_table.zig` | index 0 empty, index 2 `:method GET`, index 8 `:status 200`, index 16, last index, every name lowercase |
| `tcp/http2/hpack/huffman.zig` | ascii and every byte round trip, RFC 7541 C.4.1 / C.4.2 vectors, empty input, OutputTooSmall on encode and decode, padding past 7 bits / long run of ones InvalidCode |
| `tcp/http2/hpack/integer.zig` | RFC 7541 C.1.1 / C.1.2 vectors, decode ignores representation bits, round trip across prefix sizes, UnexpectedEOF empty and mid-continuation, Overflow past 64 bits, BufferFull |
| `tcp/http2/hpack/DynamicTable.zig` | add is index 1, newest first, 32-byte overhead, bytes copied, out of range null, eviction past max_size, oversize entry empties, `evictTo` 0 empties, compaction keeps entries readable, full byte buffer skips |
| `tcp/http2/hpack/HpackDecoder.zig` | indexed `:method GET`, RFC 7541 C.3.1 and C.4.2, literal without indexing, output in scratch, size update evicts, `evictTo` forwards, InvalidIndex (unknown, 0), TooManyHeaders, ScratchFull, UnexpectedEOF, InvalidCode |
| `tcp/http2/hpack/HpackEncoder.zig` | exact static match one byte, static name index, literal name, name ignores case, round trip through decoder, past Huffman scratch plain literal, BufferFull (full, empty) |
| `tcp/http2/hpack/RespPrefix.zig` | same triple matches, other status / content-encoding does not, empty triple matches |
| `tcp/http2/hpack/response_block.zig` | matches `writeHeader` byte for byte, cached prefix same bytes / re-encodes length, content-encoding, null length omits content-length, round trip through decoder, five-digit status, long content-type bypasses cache, small dst BufferFull |
| `tcp/http2/ServeOpts.zig` | defaults, explicit limits |
| `tcp/http2/Stream.zig` | `open` resets and sets the id, `appendBody` accumulates / past the cap appends nothing / accepts an empty payload, `headerList` covers `header_count` |
| `tcp/http2/UpgradeHead.zig` | `settings` defaults to empty |
| `tcp/http2/stream_state.zig` | `IDLE` is the zero value, tag names match the enum |
| `tcp/http2/stream_slot.zig` | `claim` first free entry / past the cap returns null, `find` live entry / skips a freed entry, `requestInFlight` unended stream / all ended / empty table |
| `tcp/http2/declared.zig` | `LENGTH` carries the byte count, `ABSENT` and `BROKEN` are distinct |
| `tcp/http2/stream_body.zig` | no content-length is whole, exact count only, zero with a body, not a bare decimal, past u64, too many digits, repeated equal counts once, disagreeing values, case-insensitive name |
| `tcp/http2/stream_invoke.zig` | `buildRequest` pseudo-headers and fallback, whole body reaches the handler, short body is reset |
| `tcp/http2/handler.zig` | error with nothing answered becomes one 500, no second response after an fd or `Response` answer, swallowed error gets nothing, context carries opts and peer frame size, zero timeout leaves no deadline, access record written / skipped without a logger |
| `tcp/http2/cache.zig` | ttl defaults, key never zero, key separates bodies, miss without a cache, store then hit, another path misses, empty path stores nothing, miss without an io |
| `tcp/http2/upgrade.zig` | `headerValue` case and trim / skips request line / missing, `decodeSettings` valid / malformed / too large, `requestLine` split and fallback, `accept` answers 101 / 400 without h2c / head too large / peer closed mid-head |
| `tcp/http2/serve.zig` | `headerBlock` / `dataBlock` padding strip and malformed padding, `applySettings` valid / out of range / HPACK table size, `serveConn` prior knowledge / bad preface GOAWAY / h2c upgrade stream 1, short body reset, matching body served, body past the stream buffer 413, unfinished hang-up GOAWAY, idle hang-up no GOAWAY, PING ACK |
| `tcp/http2/Config.zig` | required fields, explicit dispatch model, worker / buffer / stream and frame defaults, response cache off, logger null, `handler_timeout_ms` zero, static serving off |
| `tcp/http2/Context.zig` | init keeps fd and stream id, no static dir and 16 KiB frame, no deadline at start, `withTimeout` zero expired / future not expired / original untouched, `withDeadline` past expired, `setTimeout` replaces the deadline |
| `tcp/http2/Request.zig` | `splitPath` path and query / no query / trailing `?`, `header` case-insensitive / pseudo-header / missing, `queryParam` value / valueless / missing / empty query, `queryParams` pairs / skips empty / empty / out of memory, `pathSegments` split / root / out of memory |
| `tcp/http2/Response.zig` | 200 and no content type by default, `setStatus`, `setContentType`, `send` matches `writer.sendResponseFD` / records sent and bytes_written / closed peer BrokenPipe, `sendJson`, `sendText`, `sendNoContent` 204 |
| `tcp/http2/server.zig` | `refAllDecls` + behavioral: port zero -> `error.ZixPortNotConfigured`, valid config succeeds and deinit is safe |
| `tcp/http2/router.zig` | builds at comptime, exact match, EXACT over PREFIX, longest PREFIX, PREFIX on the bare path, PREFIX past a segment boundary 404, unknown path Not Found, static off with empty `public_dir`, static fallback serves a file / marks the response sent |
| `tcp/http2/static.zig` | `zeroCopyAllowed` sentinel fd refused / real fd on Linux, `rangeAsk` FULL (none, malformed) / UNSATISFIABLE / PARTIAL, `renderContentRange` and `encodeHead` / `encodeUnsatisfiable` small buffer, `serve` traversal / missing / directory / past `PUBLIC_PATH_MAX` false, HEADERS plus DATA, MIME type, chunked at the frame size, empty file END_STREAM on HEADERS, 206 Content-Range / range length, open-ended range, 416 / END_STREAM on HEADERS, malformed Range 200, range chunked at the frame size, cache off, cached 206 repeat hit, cached brotli sibling, `acquireHit` resident when zero copy is refused / unread for sendfile, `fallback` without a root / root path / strips the slash |

### zix.Grpc

| Module | Coverage |
| :- | :- |
| `tcp/http2/grpc/status.zig` | `refAllDecls` + behavioral: OK=0, CANCELLED=1, UNIMPLEMENTED=12, UNAUTHENTICATED=16 |
| `tcp/http2/grpc/frame.zig` | `refAllDecls` + behavioral: `readGrpcPrefix` / `writeGrpcPrefix` roundtrip, compress flag preserved, message length preserved, `sendGrpcError` includes `content-type` header |
| `tcp/http2/grpc/proto.zig` | `refAllDecls` + behavioral: `encodeVarint` / `decodeVarint` roundtrip, `encodeString` produces LEN wire type, `encodeInt32` produces VARINT wire type, `encodeDouble` / `decodeDouble` roundtrip (positive and negative values), `MessageReader` iterates all fields |
| `tcp/http2/grpc/timeout.zig` | `refAllDecls` + behavioral: H/M/S/m/u/n units convert correctly, single-char returns null, empty returns null |
| `tcp/http2/grpc/core.zig` | `refAllDecls` + behavioral: `parsePath` valid and invalid inputs, `detectContentType` proto/json/unknown, `GrpcContext.recvMessage` empty body returns null, `Route.timeout_ms` defaults to zero, `GrpcContext.isExpired` null/past/future deadline, `GrpcServeOpts.handler_timeout_ms` defaults to zero, Router dispatches to matching handler |
| `tcp/http2/grpc/config.zig` | `refAllDecls` + behavioral: `GrpcServerConfig` required fields and defaults (handler_timeout_ms=0), `GrpcClientConfig` required fields |
| `tcp/http2/grpc/server.zig` | `refAllDecls` + behavioral: port zero -> `error.ZixPortNotConfigured`, valid config succeeds, deinit is safe |
| `tcp/http2/grpc/client.zig` | `refAllDecls` + behavioral: `GrpcClient.connect` port zero -> `error.ZixPortNotConfigured` |

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
| `udp/http3/request.zig` / `response.zig` | `refAllDecls` + behavioral: `parseRequest` recovers `:method` / `:path` past a leading ACK, `streamBytes` sums stream payload bytes across streams and skips non-stream frames, `buildResponse` carries the control SETTINGS plus a HEADERS / DATA reply and rides a due MAX_STREAMS / MAX_DATA grant (`buildMaxStreams` / `buildMaxData` encode) |
| `udp/http3/connection.zig` | `refAllDecls` + behavioral: `init` derives the Initial keys from the connection id (RFC 9001 A.1), the anti-amplification 3x cap, `sendDatagramSize` clamps to config / client / ceiling, `replenishBidiStreams` and `replenishMaxData` raise their grants past the one-time allowances, `reserveSendStream` pool bounds, `AckTracker` hole tracking, `onAckFrame` RTT sampling |
| `udp/http3/router.zig` | `refAllDecls` + behavioral: dispatch calls the matching handler, the query is stripped before matching, no match returns 404 |
| `udp/http3/config.zig` / `server.zig` | `refAllDecls` + behavioral: required config fields and defaults, a null `Tls.Context` is rejected at run |
| `udp/http3/static.zig` | `refAllDecls` + behavioral: content-encoding maps only what the response path can emit, serve declines when caching is off (the body must outlive the handler, so it can only come from the cache), the response is filled from cached bytes and the pin is KEPT, the body stays readable after the handler frame is gone, a `.br` sibling is picked and named, traversal and a missing file are rejected, exactly one pin is held and `releasePin` returns it, a released pin lets the entry be reclaimed, an in-flight body is immune to the file being rewritten in place |

### zix.Webrtc

Every WebRTC layer is written from its own RFC, so each file carries its tests in-file and the
layers with published vectors are pinned byte for byte against them. `zix.Webrtc` exports the
layers as primitives too, so a peer or a test harness can build the other side of the wire.

| Module | Coverage |
| :- | :- |
| `udp/webrtc/demux.zig` | `refAllDecls` + behavioral: every first byte routes to its RFC 7983 section 7 kind, including the ranges the RFC 5764 text did not have |
| `udp/webrtc/stun/message.zig` | `refAllDecls` + behavioral: the XOR-MAPPED-ADDRESS vector `192.0.2.1:32853` byte for byte, strict framing (trailing bytes and unpadded final attributes refused), MESSAGE-INTEGRITY over a rewritten header length |
| `udp/webrtc/stun/binding.zig` | `refAllDecls` + behavioral: the RFC 8489 section 6.3.1 request rules, silent discard and a too-small buffer both reporting null |
| `udp/webrtc/ice/*.zig` | `refAllDecls` + behavioral: the RFC 5769 section 2.1 sample request pins the MAC, the CRC and two attribute types at once, USERNAME split with this agent's ufrag first, 487 for every tiebreaker, 400 and 401 unsigned against 420 and 487 signed |
| `udp/webrtc/sctp/*.zig` | `refAllDecls` + behavioral across 20 files: CRC32c written little endian with the Castagnoli polynomial, gap ack blocks as offsets, missing reports counted below the highest newly acked TSN only, a full 4-way handshake plus data, heartbeat, shutdown and abort between two in-memory associations |
| `udp/webrtc/datachannel/*.zig` | `refAllDecls` + behavioral: the seven payload types, DCEP OPEN and ACK round-trip, stream identifier parity by DTLS role, messages reported ahead of closes, deferred reset processing, two peers talking in memory |
| `udp/webrtc/sdp/*.zig` | `refAllDecls` + behavioral across 18 files: CRLF and bare LF both read, media-section lookup ahead of session level, a missing `a=sctp-port` refused, the session id capped at 62 bits, and a candidate written into every carried media section |
| `udp/webrtc/media/*.zig` | `refAllDecls` + behavioral: RFC 3711 B.2 and B.3 and RFC 2202 case 1 pinned byte for byte, the KDF label XORed at byte 7, one profile carrying two tag lengths, ROC estimate kept separate from accept, the SRTCP index stopping rather than wrapping |
| `udp/webrtc/dispatch/*.zig` | `refAllDecls` + behavioral: each model's `pass()` drives a whole session against a real bound socket with the real `Dialer`, so a difference between the models is a difference in the loop |
| `udp/webrtc/config.zig` / `server.zig` | `refAllDecls` + behavioral: every `run()` rejection in order (port, ICE credentials present, ICE credentials legal, TLS present, key is ECDSA P-256, dispatch model against the platform) |
| `tls/dtls_*.zig` | `refAllDecls` + behavioral: anti-replay checked before the AEAD and updated after, reassembly tracked by bitmap so overlapping fragments are legal, the record sequence carried past the HelloVerifyRequest, RFC 5705 export in its no-context seed form |

### zix.Logger

| Module | Coverage |
| :- | :- |
| `logger/logger.zig` | `refAllDecls` + behavioral: init and deinit with no save_path, system() below save_min_level is silent, access() below save_min_level is silent, statusLevel mapping (100=DEBUG 200=INFO 301=INFO 404=WARN 500=ERROR), conn/packet/frame/session/rpc below save_min_level are silent |

### zix.Utils

| Module | Coverage |
| :- | :- |
| `utils/file.zig` | `refAllDecls` + behavioral: extension, save |
| `utils/multipart.zig` | `refAllDecls` + behavioral: `Parser` parse + getField |
| `utils/media_type.zig` | `refAllDecls` + behavioral: `stripParameters` drops a charset parameter, leaves a bare value unchanged, trims the space before a parameter, keeps a multipart boundary out of the result, handles more than one parameter, yields empty for an empty value or a lone semicolon. `equalIgnoreParameters` ignores case, rejects a different subtype, and rejects a prefix that is not the whole type |
| `utils/response_cache.zig` | `refAllDecls` + behavioral: store-then-lookup returns identical bytes, miss on absent key, expired entry refetches, oversize value bypasses store, ttl 0 never fresh, distinct keys coexist via probing, `max_entries` rounded down to power of two, `hashKey` separates by query |
| `utils/static_cache.zig` | `refAllDecls` + behavioral: path join rejects traversal / absolute / oversize, header carries `Vary` and only encodes when compressed, entry count clamped and rounded to a power of two, second request reuses the same open file, a miss caches nothing, ttl 0 never touches the table, `.br` / `.gz` siblings picked up and negotiated, a file with no sibling serves identity, an expired entry is reclaimed and re-opened, a pinned slot survives reclaim, a full table degrades to null, a sweep frees room, `install` is process-wide and `shutdown` clears it |
| `utils/dispatch_support.zig` | `refAllDecls` + behavioral: `.ASYNC` is supported on every platform, `.EPOLL` / `.URING` support follows the target os tag, `rejectedName` reports the model tag, `Error` carries the single canonical reject error |
| `utils/static_send.zig` | `refAllDecls` + behavioral: the copy path writes the whole body through the engine write, honours an offset and a partial length, a zero-length range never touches the socket, a body larger than the copy buffer loops, a failing engine write surfaces as BrokenPipe. Linux only: the zero-copy path delivers exact bytes over a real socket, honours an offset, and reports BrokenPipe on a closed peer |
| `utils/socket_poll.zig` | `refAllDecls` + behavioral: `readableWithin` skips the wait when the budget is zero, `waitReady` reports a datagram already queued on the socket, `waitReady` reports not ready when nothing arrives in the budget |
| `utils/counter_scale.zig` | `refAllDecls` + behavioral: `scaleCounter` converts a reading below one whole second, holds past the point where the direct form overflows u64 in nanoseconds and again in microseconds, keeps the sub-second remainder instead of truncating to whole seconds, converts under a frequency that divides neither the counter nor the scale evenly, and keeps rising across the overflow boundary |

### multiplexers (src/multiplexers/, internal)

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
| `TcpServer.init` port zero | returns `error.ZixPortNotConfigured` |
| `HandlerFn` type check | `zix.Tcp.echoHandler` satisfies `zix.Tcp.HandlerFn` |
| `TcpClient.connect` port zero | returns `error.ZixPortNotConfigured` before any socket call |

### tests/integration/http1/

#### `server_test.zig`

| Test | What it verifies |
| :- | :- |
| `Http1Server.init` valid config, deinit is safe | init succeeds and deinit does not error |
| `Http1Server.init` URING dispatch model | the model is accepted and stored |
| `Http1Server.init` EPOLL dispatch model | the model is accepted and stored |
| `Http1Server.init` URING dispatch model | the model is accepted and stored |

#### `router_test.zig`

| Test | What it verifies |
| :- | :- |
| Router dispatch routes to matching handler | an exact path reaches its handler |
| Router dispatch selects correct route among multiple | the right handler wins with several registered |
| Router dispatch unknown path writes 404 | no match falls through to the 404 |

#### `tls_dual_test.zig`

| Test | What it verifies |
| :- | :- |
| Dual listener EPOLL serves cleartext on port | cleartext leg answers on `port` |
| Dual listener EPOLL serves TLS on tls_port with the same routes | the TLS leg serves the same route table |
| Dual listener URING serves cleartext on port | cleartext leg answers under the ring |
| Dual listener URING serves TLS on-ring on tls_port | the TLS leg runs on the ring |
| Dual listener ASYNC serves cleartext on port | cleartext leg answers on the thread model |
| Dual listener ASYNC serves TLS via the extra accept thread | the TLS leg gets its own accept thread |
| `tls_port` equal to `port` is rejected at run | returns `error.ZixTlsPortConflict` |

#### `static_cache_test.zig`

Drives the real router path over a socketpair, so what is asserted is the bytes a client receives.

| Test | What it verifies |
| :- | :- |
| Router serves an unmatched path from the static cache | 200 with the right content type and body |
| Router still 404s an unmatched path with no file behind it | a missing file is still a 404 |
| Router keeps routed paths ahead of the static cache | a routed handler wins over a file that would shadow it |
| Router repeats a cached file byte for byte across requests | the replayed header and body are identical to the cold response |
| Router serves the same file uncached when no cache is installed | the shipped default still serves through the original path |

### tests/integration/websocket/

#### `websocket_test.zig`

| Test | What it verifies |
| :- | :- |
| `parseFrame` binary opcode | FIN, opcode, payload round-trip |
| `parseFrame` ping with payload | opcode, payload content |
| `parseFrame` pong opcode | opcode |
| `parseFrame` close with empty payload | opcode, zero-length payload |
| Round-trip all opcodes | buildFrame -> parseFrame for text, binary, ping, pong, close |

### tests/integration/udp/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| `UdpServer.init` valid config | init with real ip and port succeeds |
| `UdpServer.init` port zero | returns `error.ZixPortNotConfigured` |
| `UdpClient.init` zero bind_port | returns `error.ZixPortNotConfigured` before any socket call |

#### `packet_test.zig`

| Test | What it verifies |
| :- | :- |
| Round-trip LITTLE | `toEndian` -> `fromEndian` restores original bytes |
| Round-trip BIG | same for BIG endian |
| `FeedbackResult.packet` value | `.packet` variant stores and returns the full packet |

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
| `FixServer` init port zero | returns `error.ZixPortNotConfigured` |
| Logon handshake and echo round-trip succeed | send Logon, receive Logon reply with MsgType=A send NewOrderSingle, receive echo, send Logout, receive Logout reply |
| Multiple sequential messages are all echoed | three NewOrderSingle messages echoed with ClOrdID preserved across all |

### tests/integration/http2/

#### `server_test.zig`

Ports: 18082-18085.

| Test | What it verifies |
| :- | :- |
| `Http2Server.init` and deinit do not error | valid config succeeds, deinit is safe |
| `Http2Server.init` port zero | returns `error.ZixPortNotConfigured` |
| `Http2 HandlerFn` type is a function pointer | `zix.Http2.HandlerFn` assignment compiles |
| Http2 GET / returns Hello World over h2c direct | h2c PRI preface + HEADERS + DATA round-trip returns response body |
| Http2 POST /echo returns request body | POST with body DATA frame, server echoes body back |
| Http2 two sequential streams on same connection | stream IDs 1 and 3 each receive correct responses |
| Http2 h2c upgrade GET / returns Hello World | HTTP/1.1 `Upgrade: h2c` -> 101 Switching Protocols -> h2c response |

### tests/integration/http3/

#### `static_test.zig`

Builds the trio the engine builds and calls `Router.dispatch`, so what is asserted is the response
the engine would go on to frame, including the cache pin it hands back.

| Test | What it verifies |
| :- | :- |
| Router serves an unmatched path from the static cache | 200, correct body and content type, and `static_slot` is handed back still pinned |
| Router 404s an unmatched path with no file behind it | a missing file is a 404 and no pin is taken |
| Router keeps routed paths ahead of the static fallback | a routed handler wins over a file that would shadow it |
| Router 404s static paths when caching is off | the file exists, but this engine has no safe body source without the cache |
| Router serves a multi-packet body that outlives the dispatch call | a 64 KiB body reads back intact after the Context is gone |

### tests/integration/webrtc/

#### `exchange_test.zig`

The CI exit gate for the engine: a whole session between two in-memory peers, no port and no sleep.
This is what proves the eight sans-I/O layers agree when two independent instances meet.

| Test | What it verifies |
| :- | :- |
| A dialer and an answerer carry a message end to end | ICE, DTLS, SCTP and DCEP all complete, and a payload survives the round trip |
| The answerer nominates the pair the checks came from | an ice-lite agent selects on a verified check, not on a candidate it invented |
| The channel lands on an even identifier because the dialer opened it | the DTLS role decides parity, and getting it wrong is invisible against a peer that shares the mistake |
| Neither peer is left with a deadline it will never meet | every timer the session armed is either met or retired |

### tests/integration/grpc/

#### `server_test.zig`

Ports: 18200-18206.

| Test | What it verifies |
| :- | :- |
| `GrpcServer.init` and deinit do not error | valid config succeeds, deinit is safe |
| `GrpcServer.init` port zero | returns `error.ZixPortNotConfigured` |
| gRPC unary returns greeting | `greetHandler` reads one message, replies `"Hello, world!"` |
| gRPC server streaming sends multiple responses | `echoHandler` sends two messages, client receives both in order |
| gRPC client streaming collects all messages | `collectHandler` buffers three messages, replies with count `"got 3"` |
| gRPC bidirectional echoes each message | `echoHandler` echoes `"ping"` then `"pong"` from two client messages |
| gRPC unknown method returns UNIMPLEMENTED | `dispatchHandler` replies with `GrpcStatus.UNIMPLEMENTED` for unknown path |
| gRPC trailers-only error is received as INVALID_ARGUMENT | `errorOnlyHandler` calls `res.finish(INVALID_ARGUMENT, ...)` without sending data, client receives the error status |
| gRPC two streams on same connection both return OK | two sequential unary RPCs on one connection, both streams receive correct responses |

### tests/integration/channel/

#### `channel_test.zig`

| Test | What it verifies |
| :- | :- |
| `Channel(u32)` init capacity | `buf.len == 8`, `count == 0`, `head == 0` |
| `Channel([]const u8)` compiles | slice element type accepted |
| `Channel(struct)` compiles | struct element type accepted |
| `Channel(u32)` send and recv round-trip | send then recv returns the sent value |
| `Channel(u32)` drain after close | send two items, close, recv both, third recv returns `error.ZixClosed` |

---

## Behaviour Tests

Source: `tests/behaviour/`. Each file verifies observable API contracts that callers rely on: the "what does this always do" properties.

### tests/behaviour/dispatch/

#### `platform_gate_test.zig`

The cross-engine `DispatchModel` platform contract (ADR-065), asserted once for the whole tree.

| Test | What it verifies |
| :- | :- |
| `DispatchModel` is one shared type | every engine namespace (Tcp, Http, Http1, Http2, Grpc, Fix, Udp, Http3) re-exports the same type |
| `DispatchModel` carries exactly ASYNC, EPOLL, URING | an exhaustive switch with no else prong, so a fourth variant breaks the build |
| the dropped POOL and MIXED names resolve to nothing | `std.meta.stringToEnum` returns null for both |
| backing values are gapless with ASYNC as zero | 0 / 1 / 2, and a zero-init config lands on the portable model |
| `isSupported` accepts ASYNC everywhere | the portable model is never rejected |
| `isSupported` gates EPOLL and URING on the target os | true only on a Linux target |
| the rejected model is named in the log line | `rejectedName` returns the model tag, so an operator sees which one was refused |
| ASYNC config is accepted by every engine | init stores the portable model without starting an accept loop |
| the grpc engine takes the shared model on its Router-typed server | `Grpc.Server.init(Router(&routes), ...)` stores `.ASYNC` |

### tests/behaviour/tcp/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| `TcpServerConfig` dispatch_model is required (set explicitly) | `.ASYNC` stored as set |
| `TcpServerConfig` kernel_backlog default | 4096 |
| `TcpServerConfig` max_recv_buf default | 4096 |
| `TcpServerConfig` workers default | 0 (auto) |
| `TcpClientConfig` max_recv_buf default | 4096 |
| TCP frame length header | 4-byte big-endian u32 encodes and decodes correctly |
| TCP frame zero-length payload | encodes as four zero bytes |
| TCP frame header size | always exactly 4 bytes |
| `DispatchModel.ASYNC` is zero value | `@intFromEnum(.ASYNC) == 0` |

### tests/behaviour/http1/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| `dispatch_model` is required and stored as set | the field round-trips |
| `workers` defaults to zero (auto) | zero means auto-size |
| `kernel_backlog` default is 1024 | the shipped default |
| Buffer size defaults | `max_recv_buf` 6 KiB, `compression_max_out` 256 KiB |
| Compression defaults | off, `min_size` 256, `max_out` 256 KiB |
| `DispatchModel` integer backing values | `ASYNC` is the zero value |
| Static cache is off by default | `public_dir_cache_ttl_ms` 0, `public_dir_cache_max_entries` 256 |
| Static cache fields are stored as set | both round-trip |
| Static cache knobs are independent of the response cache knobs | the two caches share no state |

#### `core_test.zig`

| Test | What it verifies |
| :- | :- |
| `parseHead` extracts method, path, and version | the request line is split correctly |
| `parseHead` HTTP/1.1 defaults keep_alive to true | RFC default persistence |
| `parseHead` `Connection: close` disables keep_alive | the header overrides the default |
| `getHeader` returns value case-insensitively | header lookup ignores case |
| `queryParam` returns value for named param | query parsing by name |

#### `query_test.zig`

RFC 10008 QUERY support through the public `zix.Http1` surface.

| Test | What it verifies |
| :- | :- |
| `parseHead` reads QUERY off the request line | the method token survives the parse |
| `Request.method` resolves a QUERY request to QUERY | the typed code, not a fallback |
| A QUERY request is distinguishable from a GET | the defect this closes: unknown tokens used to resolve to GET |
| A QUERY request carries its content like a POST | Content-Length framing and `body()` delivery |
| A QUERY request exposes its declared Content-Type | section 2 needs the handler to read it |
| A QUERY without Content-Type reports no type | the 400 case |
| An unsupported query content type reports no match, never sniffed | section 2.1 forbids guessing from the body |
| Every query content type RFC 10008 names is recognised | sql, jsonpath, graphql, x-www-form-urlencoded, multipart/form-data |
| A QUERY response is never filed under the request cache key | section 2.7, the key carries no content |
| Refusing QUERY leaves GET on the same path cacheable | the refusal is scoped to the method |
| The query content types compose a valid Accept-Query value | section 3, an RFC 9651 sf-list of bare items |
| A method it does not implement draws 501, not a wrong answer | RFC 9110 section 15.6.2 |
| QUERY is implemented, so it parses instead of drawing 501 | the same gate that refuses an unknown method passes QUERY |

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
| `UdpServerConfig` allow_args | default false |
| `Udp.DispatchModel` re-export | resolves to the shared dispatch enum |
| `UdpClientConfig` endianness | default LITTLE |
| `UdpClientConfig` recv_timeout_ms | default 0 (disabled) |

#### `packet_test.zig`

| Test | What it verifies |
| :- | :- |
| `toEndian` NATIVE is a no-op | bytes unchanged on any host |
| u8 array fields never swapped | `id [4]u8` untouched by LITTLE and BIG |
| Non-native swaps integer fields | `i32` field byte-swapped |
| Non-native swaps float array elements | `[2]f64` elements each swapped |

### tests/behaviour/uds/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| `UdsServerConfig` backlog default | 128 |
| `UdsServerConfig` max_recv_buf default | 4096 |
| `UdsClientConfig` stores path | path field preserved |
| UDS frame length header | 4-byte big-endian u32 encodes and decodes correctly |
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
| `Http2ServerConfig` max_streams defaults to 128 | `max_streams == 128` invariant |
| `Http2ServerConfig` max_frame_size defaults to 16384 | `max_frame_size == 16384` invariant |
| `Http2` HandlerFn can be assigned to a local variable | `zix.Http2.HandlerFn` type assignment compiles |
| `Http2` PREFACE length is 24 | `zix.Http2.PREFACE.len == 24` |
| `Http2` ERR_NO_ERROR is zero | `zix.Http2.ERR_NO_ERROR == 0` |
| `Http2` FLAG_END_STREAM and FLAG_END_HEADERS are distinct | `FLAG_END_STREAM != FLAG_END_HEADERS` |

### tests/behaviour/http3/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| Static serving is off by default | empty `public_dir`, ttl 0, 256 entries |
| Static fields are stored as set | all three round-trip |
| Static serving needs caching, unlike the other engines | pins the deliberate asymmetry: on Http3 a ttl of 0 disables static serving entirely, because the response body outlives its handler |

### tests/behaviour/webrtc/

#### `session_test.zig`

| Test | What it verifies |
| :- | :- |
| A peer answers a connectivity check before anything is negotiated | ICE runs ahead of DTLS, so a check is answered on a peer with no session yet |
| The association only exists once the handshake finishes | SCTP is inside DTLS, so nothing is readable before the handshake completes |
| A peer that says nothing is dropped on its idle deadline | `peer_idle_ms` is enforced, which is what covers a browser closing its tab |
| Every datagram pushes the idle deadline back | a live but quiet peer is not dropped |
| A dialer keeps asking until a check is answered | the retransmit timer drives the client half, not a fixed count |

### tests/behaviour/grpc/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| `GrpcServerConfig` defaults | dispatch_model=ASYNC, kernel_backlog=1024, workers=0, max_streams=128, max_frame_size=16384, max_body=16384 |
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
| `TcpServer.init` port zero | returns `error.ZixPortNotConfigured` |
| `DispatchModel` backing values stable | ASYNC=0, EPOLL=1, URING=2 |
| `DispatchModel` dropped names gone | `stringToEnum` returns null for POOL and MIXED |
| TCP frame max u32 length | `maxInt(u32)` encodes and decodes correctly via big-endian |

### tests/edge/websocket/

#### `websocket_test.zig`

| Test | What it verifies |
| :- | :- |
| 0 bytes -> null | fewer than 2 bytes (can't read header) |
| 1 byte -> null | fewer than 2 bytes |
| Truncated payload -> null | header says 5 bytes but only 3 present |
| Extended 16-bit length (126-tier) | 130-byte payload: byte[1] carries 126 marker |
| `acceptKey` key too long -> `error.ZixKeyTooLong` | key >= 93 bytes exceeds 128-byte hash_input |

### tests/edge/udp/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| Port zero | `UdpServer.init` returns `error.ZixPortNotConfigured` |
| Non-zero port | `UdpServer.init` succeeds |

#### `packet_test.zig`

| Test | What it verifies |
| :- | :- |
| `Endianness` enum backing values stable | NATIVE=0, LITTLE=1, BIG=2 |
| `FeedbackResult` ack/nack are tag-only | active tag matches .ack and .nack |

### tests/edge/uds/

#### `config_test.zig`

| Test | What it verifies |
| :- | :- |
| Empty path -> `error.ZixPathEmpty` | `UdsServer.init(.{ .path = "" })` returns PathEmpty |

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

### tests/edge/http1/

#### `body_test.zig`

Content-Length is what every dispatch model uses to decide whether a body is delivered whole, waited for, or drained, so a value the parser rejects changes which path a request takes.

| Test | What it verifies |
| :- | :- |
| absent Content-Length frames the request as bodyless | no header -> `content_length` 0, chunked flag false |
| zero Content-Length frames the request as bodyless | `Content-Length: 0` -> 0 |
| non-numeric Content-Length falls back to zero | `abc` -> 0 |
| Content-Length with a trailing space falls back to zero | `5 ` -> 0 |
| Content-Length past u64 falls back to zero | 23-digit value -> 0 |
| Content-Length is read case-insensitively | `cOnTeNt-LeNgTh` honored |
| chunked request sets the chunked flag beside Content-Length | both header values are kept |
| Expect 100-continue is flagged for a body-carrying request | `expect_continue` true |
| Request bodyReceived is zero for a bodyless request | and `body()` returns empty |
| Request bodyReceived tracks the delivered slice by default | 4-byte slice -> 4 |
| Request bodyComplete is true for a bodyless request | nothing declared, nothing could fall short |
| Request bodyComplete is independent of the delivered length | a short delivered slice stays complete, the engine override makes it false |

#### `core_test.zig`

| Test | What it verifies |
| :- | :- |
| `parseHead` missing CRLF terminator | returns `IncompleteHeader` |
| `parseHead` empty request line | returns `InvalidRequest` |
| `parseHead` missing HTTP version | returns `InvalidRequest` |
| `queryParam` key with empty value | returns an empty string, not null |
| `queryParam` absent key | returns null |
| `parseRange` start beyond total | returns null |
| `parseRange` missing `bytes=` prefix | returns null |
| `percentDecode` encoded space | decoded in place |

#### `static_cache_test.zig`

Every case here ends in a null hit, which the engines treat as "serve it uncached".

| Test | What it verifies |
| :- | :- |
| Declines a path that escapes public_dir | traversal, absolute, and empty are refused before any open |
| Declines a resolved path longer than its buffer | an oversize path is declined, not truncated |
| With ttl 0 never stores anything | the disabled default consumes no slot |
| Declines a directory | a directory opens but is not servable, so it is not published |
| Serves a zero-byte file as a real hit | `Content-Length: 0`, still a hit |
| Expiry is exact at the window boundary | fresh at `insert + ttl - 1`, expired at `insert + ttl` |
| Keeps serving after the table fills with pinned entries | a full table declines the new path and leaves held entries intact |
| Negotiation falls back to identity when a client rejects everything | serving the plain file beats refusing it |
| Init survives an absurd entry request | clamped against the descriptor budget, still a power of two |

#### `query_test.zig`

QUERY boundary conditions: the two peer-controlled values a QUERY puts on paths that bodyless methods never reached.

| Test | What it verifies |
| :- | :- |
| A lowercase method token is refused, not folded | RFC 9110 section 9.1, method names are case-sensitive |
| Http1 and Http answer a lowercase method the same way | one shared method table, so the two engines cannot drift apart again |
| A method token past the known maximum is refused, not truncated | bounded by the length switch |
| An unimplemented method answers 501, a broken line answers 400 | the two failures stay apart |
| A malformed request line is not reported as an unknown method | a line that never tokenized says nothing about the method |
| A QUERY with an empty method-adjacent target still parses | root target |
| Zero and absent Content-Length frame as bodyless | nothing declared means nothing to read |
| A chunked QUERY sets the chunked flag | chunked framing is method-agnostic |
| A QUERY may carry Expect 100-continue | the large-body handshake |
| A QUERY body past the receive buffer reports what arrived | `bodyReceived` vs `content_length`, the case a GET cannot express |
| A QUERY keeps both its query string and its content | the target parameters are not replaced by the body |
| The longest query content type is matched, not truncated | 33 bytes, the value that overran the old buffer |
| An absurd Content-Type reports no match instead of overrunning | a peer controls this header |
| An empty Content-Type value reports no match | empty, lone semicolon, whitespace |
| A multipart QUERY boundary parameter does not defeat the match | parameters are stripped first |
| A QUERY store is refused even when the response fits the cache | not a size effect |
| A QUERY encoded store is refused on the compressed path too | the per-encoding slots carry the same refusal |

### tests/edge/http2/

#### `server_test.zig`

Port: 18100.

| Test | What it verifies |
| :- | :- |
| bad PRI preface causes server to close connection | malformed preface bytes -> server closes the connection cleanly |
| client sends GOAWAY and server connection loop exits | GOAWAY frame -> server exits the frame loop without error |
| `Http2Server.init` rejects port zero | returns `error.ZixPortNotConfigured` |
| `HpackDecoder` decode of empty block returns zero headers | `decode(&.{}, ...)` returns 0 headers without error |
| `writeFrameHeader` stream_id high bit is cleared on read | `stream_id = 0x7FFF_FFFF` roundtrips correctly via pipe |

### tests/edge/http3/

#### `static_test.zig`

The boundaries where the engine has to decline rather than hand its send path a body it cannot hold.

| Test | What it verifies |
| :- | :- |
| Declines a file past the snapshot ceiling | over 8 MiB is declined for bytes, while the descriptor path still resolves it for the other engines |
| Serves a file exactly at the snapshot ceiling | the ceiling is inclusive |
| Serves a zero-byte file as an empty body | an empty slice is already stable, nothing is snapshotted |
| Bytes are a snapshot, not a window onto the file | an in-place rewrite does not change bytes already handed out |
| Bytes survive a truncation to a shorter file | the dangerous shape: the file shrinks while a response is still sending |
| Declines every unsafe path before touching the disk | traversal, absolute, and empty |
| Bytes are snapshotted once and reused across requests | one copy backs concurrent responses, and each holds its own pin |

### tests/edge/webrtc/

#### `session_test.zig`

Everything arrives on one port and is sorted by its first byte, so the boundaries here are about
what a peer does with a datagram it cannot use.

| Test | What it verifies |
| :- | :- |
| A peer survives every first byte there is | all 256 values are classified and none of them panics |
| An empty datagram is dropped and changes nothing | no state moves on a zero-length receive |
| A DTLS record whose length runs off the end is not read past | the declared length is never trusted over the buffer |
| A STUN message with the right first byte and nothing else is refused | routing is not validation, the magic cookie still has to check out |
| Application data before the handshake finishes goes nowhere | epoch 1 records are refused until there are epoch 1 keys |
| The same garbage a thousand times still leaves the peer alive | a repeated bad datagram exhausts nothing |
| A dialer refuses a response carrying somebody else's transaction | the transaction id is checked, not just the message type |

### tests/edge/grpc/

#### `server_test.zig`

Ports: 18220-18221.

| Test | What it verifies |
| :- | :- |
| `readGrpcPrefix` with 4 bytes | returns `error.ZixTooShort` |
| `readGrpcPrefix` with empty slice | returns `error.ZixTooShort` |
| `GrpcContext.recvMessage` body shorter than prefix | body has 3 bytes (need 5 for prefix): returns null |
| `GrpcContext.recvMessage` msg_len exceeds body | prefix claims 100 bytes but body has only 5: returns null |
| `parsePath` empty string | returns null |
| `parsePath` no leading slash | returns null |
| `parsePath` only slash | returns null |
| `detectContentType` no header | returns UNKNOWN |
| `detectContentType` text/plain | returns UNKNOWN |
| `parseTimeout` single character | returns null |
| `GrpcClient.connect` port zero | returns `error.ZixPortNotConfigured` |
| `serveConn` closes cleanly on immediate client disconnect | server accepts, client disconnects immediately, no crash or error |
| gRPC finish-only handler delivers error status to client | handler calls `res.finish(INVALID_ARGUMENT, ...)` only, client receives the error status without any data frames |

### tests/edge/channel/

#### `channel_test.zig`

| Test | What it verifies |
| :- | :- |
| Capacity 1 allocates exactly one slot | `buf.len == 1`, `count == 0` |
| Ring head wraps at `buf.len` | `(3+1) % 4 == 0` |
| Full boundary: `count == buf.len` | tail index wraps back to head |
| `send` after close | returns `error.ZixClosed` |
| `recv` on empty closed channel | returns `error.ZixClosed` |

---

###### end of tests
