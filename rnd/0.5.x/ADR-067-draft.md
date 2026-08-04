# ADR-067 Draft: zix.Webrtc, a WebRTC peer as its own engine

Working draft. All work happens on the `webrtc` branch, on top of ADR-066. This file is the living
record: the ladder below was ticked in place as each phase landed. Promoted to `docs/adr-*.md`.

Gate for promotion, all met before this file was promoted:

- Every ladder phase 1 to 12 committed, one file per commit.
- `zig build test-all` green on `zig-0.16` and `zig-0.17` with a fresh cache directory, 2913 tests
  over 167 steps.
- `zig build test-runner-all` green, 55 of 55 protocols.
- All 7 CI legs green on branch `webrtc`.
- Every phase exit met by a real browser, not by a self-test.

## ADR-067: zix.Webrtc, a WebRTC peer as its own engine

**Status:** Accepted

**Context:** A browser cannot open a raw socket. The only transports it offers a server are HTTP,
WebSocket and WebRTC, and only WebRTC gives unreliable delivery, per-message ordering choices, and
audio and video. zix had the first two and not the third.

WebRTC is not one protocol. Reaching a browser at all means answering ICE connectivity checks over
STUN, completing a DTLS 1.2 handshake, running SCTP inside it for data channels, and negotiating
all of that through SDP. Carrying media means SRTP on top. Every one of those is a separate wire
format with its own RFC.

Three constraints shaped the design before any code was written:

1. **It is timer-driven.** DTLS retransmits on a 1 second doubling timer, SCTP has its own RTO,
   ICE has consent freshness, and an idle peer has to be dropped. Nothing else in zix's UDP family
   needs a clock: `zix.Udp` in raw mode hands a handler `fn (datagram, peer, sink) void` and its
   dispatch path has no tick, no deadline and no clock anywhere.

2. **A peer is its 4-tuple.** Every datagram of one session, whatever protocol it carries inside,
   arrives from the same address and port and has to reach the same state machine. That rules out
   the CPU steering (`reuseport_cbpf`) the raw UDP and HTTP/3 engines use, because steering picks a
   worker by receiving CPU and could split one session across two workers mid-handshake.

3. **Self-testing proves nothing here.** Eight layers tested against themselves agree with their
   own mistakes. This is an interop protocol, so the exit criterion for every phase had to be an
   independent implementation.

**Decision:** WebRTC is its own engine at `src/udp/webrtc/`, owning its socket and its own
`dispatch/`, not a mode of `zix.Udp`.

- **DTLS lives in `src/tls/` with a flat `dtls_` prefix**, beside the TLS 1.2 and 1.3 code it
  shares primitives with, not under the WebRTC tree. It keeps no separate public surface.
  `dtls_connection.zig` composes its own flights and reuses only leaf primitives (`tls12_prf`,
  certificate plus ECDSA signing, P-256 ECDHE). It cannot reuse `tls12_connection.zig`, because
  that one hashes TLS-framed bytes while RFC 6347 section 4.2.6 needs the transcript over DTLS
  12-byte headers as-if-unfragmented, excluding the first ClientHello and the HelloVerifyRequest.

- **ICE-lite, not a full ICE agent.** A server is not behind a NAT it has to discover its way out
  of. It has one candidate, it never gathers, it never nominates, and it answers 487 for every
  role tiebreaker because it has no role to switch to (RFC 8445 section 6.1.1). That removes
  candidate gathering, pair state, and trickle as a mechanism.

- **zix is always the DTLS server.** The answer is always `a=setup:passive`. That one value fixes
  the SRTP key direction (`client_write_*` opens what arrives, `server_write_*` seals what leaves)
  and fixes data channels to odd stream identifiers (RFC 8832 section 6).

- **Three dispatch models, matching every other engine.** `.ASYNC` runs one worker on every
  platform, `.EPOLL` and `.URING` run one SO_REUSEPORT worker per core and are rejected off Linux
  with `error.DispatchModelUnsupported`. The loop body is the same for all three, in
  `dispatch/worker.zig`, because the drain order is a correctness property and not a per-model
  detail. Outbound goes through `datagram.SendBatch`, which is `sendmmsg` on Linux and a portable
  `std.Io` sink elsewhere.

- **The wait is deadline-derived, not a fixed interval.** `Worker.waitMs` is the soonest peer
  deadline capped by `tick_interval_ms`, so the loop never parks past a retransmit and never spins
  when nothing is due. That is the whole reason this engine has its own loop instead of borrowing
  one.

- **Media is forwarded, never decoded.** With `carry_media` on, the engine opens a peer's SRTP
  packet, rewrites the RTP header, and seals it again under each receiver's key. It does not parse
  a codec, does not hold a frame, and has no opinion about what the payload is.

- **Two `carry_media` switches on purpose.** `WebrtcServerConfig.carry_media` keys the transport,
  so the handshake negotiates `use_srtp` and exports keys. `sdp/answer.zig Config.carry_media`
  tells the peer to send in the first place. They sit at different layers, and an example sets
  both.

- **RTCP is answered, never forwarded.** A report names streams by their pre-rewrite identifiers,
  so relaying one describes a stream the far side never saw. A receiver's picture-loss indication
  is read, mapped back through its routes to the source, and rebuilt for the sender.

**Layer map**, one concern per file, 84 files under `src/udp/webrtc/` plus 9 `dtls_*` in
`src/tls/`:

| Directory | Owns |
| :- | :- |
| `stun/` | the RFC 8489 message container and the RFC 8489 section 6.3.1 binding rules |
| `ice/` | candidate, credentials, the four ICE attributes, the ice-lite responder |
| `sctp/` | 20 files, wire, control, data, reliability, reconfig, then the association driver |
| `datachannel/` | PPIDs, DCEP, stream identifier parity, channel registry, stream reset |
| `sdp/` | 18 files, the line and attribute codecs up to reading an offer and writing an answer |
| `media/` | RTP, RTCP, SRTP, SRTCP, and the forwarding path (routes, stream sets, per-peer state) |
| `dispatch/` | `worker.zig` holds the loop, one file per model, `common.zig` is substrate only |

**Consequences:**

- `zix.Webrtc.Server` answers a real browser under every dispatch model. Eight examples on ports
  9081 to 9088, four of which need a browser to drive.
- `max_peers` is per worker, so a server with N workers holds up to N times `max_peers`.
- One SRTP session per stream identifier, not per peer. The rollover counter and the replay list
  are per-SSRC, so audio and video sharing one session read each other's sequence numbers as gaps
  and reject real packets.
- A fan-out opens a packet once and seals it per receiver. Opening twice is a replay of an index
  the source stream already accepted, so `forward.relay` split into `open` plus `reseal`.
- The engine asks a source for a keyframe when a new route is admitted on any receiver. Nothing in
  a browser asks on a watcher's behalf, so without it a watcher joining mid-stream stays grey.
- `accept_any_peer_ice_ufrag` exists because a browser draws a fresh ICE ufrag per peer connection.
  With one server-wide credential set the ufrag comparison proved nothing the password did not, so
  the flag makes the password the only gate. It is off by default: a server that names one peer
  should keep refusing everybody else.
- Reach of `ctx.broadcast` is one worker. That is the whole room under `.ASYNC` and this core's
  share under `.EPOLL` or `.URING`, so the room examples pin `.ASYNC` and say why.
- `zix.Udp` is untouched. Nothing here was folded into it.
- Browser runs are not a CI check and must not become one. The CI exit gate is
  `tests/integration/webrtc/exchange_test.zig`, a whole session in memory in 435ms with no port and
  no sleep.

**What is not built:** TURN relaying, a full ICE agent, DTLS 1.3, periodic sender and receiver
reports on a timer, NACK answering (advertised in SDP, no packet history kept), payload type
remapping, simulcast and layer switching, `a=msid`, `a=extmap`, `a=ssrc`, RFC 8260 message
interleaving, and a room that spans cores.

**Evidence, and why self-tests were not enough:** five defects reached a browser and nothing
self-tested could have caught any of them, because in each case zix's own client agreed with zix's
own server.

| Defect | Why every self-test passed |
| :- | :- |
| HelloVerifyRequest and ServerHello both sent as record sequence 0 | zix's DTLS client only runs a replay window on epoch 1 |
| a fragmented ClientHello never reassembled | OpenSSL's hello is 206 bytes and fits one record, a browser's is about 1500 and never does |
| a full-range u64 SDP session id | RFC 8829 section 5.2.1 wants one that fits a signed 64-bit integer, zix's own reader did not care |
| a candidate published as 127.0.0.1 | Firefox gathers no loopback candidate and never pairs with one |
| no `a=candidate` line in a carried media section | the answer parses and reads back through zix's own offer reader |

The last one is the sharpest: a browser reads remote candidates off the BUNDLE-tagged section,
which is whichever section the offer put first, and with media offered that is audio or video, not
the data channel section that did carry a candidate. The peer had credentials to sign checks with
and no address to send them to.

**How a browser was driven without a display:** the page reassigns its own `log` to also
`fetch('http://' + location.hostname + ':9099/' + encodeURIComponent(line), {mode: 'no-cors'})`
against a small threaded `http.server`, then Firefox runs headless with
`media.navigator.streams.fake=true` and `media.navigator.permission.disabled=true`. That is what
makes a headless browser report back. For DTLS alone,
`openssl s_client -dtls1_2 -connect <ip>:<port> -state` reaches the DTLS server directly, because
the demux routes DTLS with no ICE gate.
