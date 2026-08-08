# LLD: zix.Webrtc

Internal implementation details for the WebRTC engine. For design rationale see [`docs/hld-webrtc-en.md`](hld-webrtc-en.md).

The engine is layered. Each layer is a separate wire format with its own RFC, and one file owns one format. Every deterministic module carries its tests in-file, and the layers with published test vectors are pinned byte for byte against them.

---

## demux.zig

The first byte says which protocol a datagram carries (RFC 7983 section 7).

- `classify(datagram) Kind` over the first-byte ranges: `STUN` for `[0..3]`, `ZRTP` for `[16..19]`, `DTLS` for `[20..63]`, `TURN_CHANNEL` for `[64..79]`, `RTP` for `[128..191]`, `DROP` otherwise.
- The **RFC 7983 revision** is used, not the RFC 5764 text it replaced. STUN widened from `[0..1]`, and TURN and ZRTP are new ranges.
- Routing is not validation. The magic-cookie check stays in `stun/message.zig`, so a datagram that looks like STUN by its first byte still has to parse as one.

---

## Layer: STUN

### stun/message.zig

The RFC 8489 container.

- `parse` validates the **whole attribute region up front**, so iterating afterwards is infallible.
- Framing is strict: trailing bytes are an error, and final-attribute padding is required. Relax that only against a real capture, not on a hunch.
- The XOR-MAPPED-ADDRESS mask is applied to the port bytes and then the address bytes, with `mask[0..] = cookie ++ transaction_id`. A `% 4` on the address offset is the easy bug. Pinned by the byte-for-byte vector `192.0.2.1:32853 -> 00 01 A1 47 E1 12 A6 43`, which must not be replaced by a round-trip test alone.
- `addMessageIntegrity` / `messageIntegrity` live here rather than in `ice/` because the MAC covers a message **prefix** and needs the header length field rewritten mid-computation, exactly like the FINGERPRINT already in this file. A separate file would have to expose the writer internals.

### stun/binding.zig

The RFC 8489 section 6.3.1 request rules.

- `respond(datagram, peer, out) ?[]const u8` is a pure function over bytes, so it needs no socket and no engine.
- It returns null for **both** silent discard and a buffer too small, which is why `MAX_RESPONSE_BYTES` is published.

---

## Layer: ICE-lite

### ice/candidate.zig

`Type` / `Transport` / `Component`, `priorityOf`, `writeFoundation`.

- `256 - @intFromEnum(component)` in the priority formula does **not** compile: the enum tag is `u8` and 256 does not fit. Widen the type first.

### ice/credentials.zig

ufrag and password rules, USERNAME split and write, `fillIceChars`.

- USERNAME reads `<destination ufrag>:<source ufrag>`. On an **arriving** check the first half is this agent's own. Reading it the other way rejects every legitimate check.

### ice/check.zig

The four ICE attributes plus `read`, `writeRequest`, `requestLen`.

- The MAC is pinned to the RFC 5769 section 2.1 sample request (password `VOkJxbRl1RmTxUk/WvJxBt`, username `evtj:h6vY`), which also carries PRIORITY and ICE-CONTROLLED. One vector pins the MAC, the CRC, and two of the four attribute types. Its FINGERPRINT covers every byte before the MAC, so a clean CRC proves the transcription before the MAC is even judged. Keep that vector.

### ice/lite.zig

`Responder.respond` returning `Outcome{ reply, authenticated, nominated }`.

- The header length is rewritten to **end at MESSAGE-INTEGRITY** while the MAC runs, which is what lets FINGERPRINT be appended afterwards without breaking it.
- A lite agent answers 487 for **every** tiebreaker value, because it has no role to switch to (RFC 8445 section 6.1.1). There is no tiebreaker field in this file.
- Check order is RFC 8489 section 6.3: authentication, then unknown attributes, then the ICE rules. 400 and 401 go out **unsigned** (no verified key yet), 420 and 487 are signed.
- Nomination is taken only when a response was actually produced, so a buffer too small leaves the pair unselected and the peer retransmits.
- `Responder.remote_ufrag` set to null is what `accept_any_peer_ice_ufrag` produces. The empty-string state was not reused for it: `""` still means refuse everybody.

---

## Layer: DTLS 1.2 (in `src/tls/`)

Nine files, flat `dtls_` prefix, beside the TLS code they share primitives with.

### dtls_record.zig

The 13-byte header, epoch, 48-bit sequence, AEAD, anti-replay, plus `writePlaintext` for epoch 0.

- Anti-replay must be **isNew before AEAD, then accept after**. Doing it in one step lets a forged far-ahead sequence clear the window.

### dtls_handshake.zig

The 12-byte header, `Fragmenter`, and an overlap-safe `Reassembler`.

- Reassembly tracks **which bytes arrived** with a bitmap, not how many, because overlapping fragments are legal.

### dtls_hello.zig

ClientHello with the cookie field, plus HelloVerifyRequest.

- A DTLS ClientHello carries a cookie vector between `session_id` and `cipher_suites`, so the TLS parser misparses it.

### dtls_cookie.zig

Stateless HMAC cookies with rotation.

### dtls_flight.zig

The retransmit timer and the RFC 6347 section 4.2.4 state machine.

### dtls_exporter.zig

RFC 5705 keying material export plus the RFC 5764 SRTP key split.

- RFC 5705 has **two** seed forms and DTLS-SRTP uses the **no-context** one. Passing an empty slice appends a 2-byte zero and silently breaks interop.

### dtls_use_srtp.zig

The RFC 5764 `use_srtp` extension. It lives in `src/tls/` because it is a TLS extension, not a WebRTC concept.

### dtls_connection.zig

The server driver: flights 2, 4 and 6.

- It composes its **own** flights and reuses only leaf primitives (`tls12_prf`, certificate plus ECDSA signing, P-256 ECDHE). `tls12_connection.zig` is untouched, because it hashes TLS-framed bytes while RFC 6347 section 4.2.6 needs the transcript over DTLS 12-byte headers as-if-unfragmented, excluding the first ClientHello and the HelloVerifyRequest.
- `HandshakeOptions.first_record_seq` exists because the cookie exchange stays stateless by answering on the sequence its ClientHello arrived with, and the server flight must then continue that numbering rather than restart at 0.
- SRTP keys are exported inside `serverFinish` through `dtls_exporter.srtpKeys` when `use_srtp` was negotiated.

### dtls_client.zig

The client half, so `examples/webrtc/webrtc_native_pair.zig` can dial. It is **not** certificate validating: RFC 8122 carries the fingerprint out of band and nothing checks against one yet.

---

## dtls_session.zig

The per-peer DTLS sequencer, the WebRTC side of the handshake.

- `Session.next_record_seq` is carried past the HelloVerifyRequest, which is what keeps the whole flight on one monotonic record sequence.
- `acceptFragment` resets the reassembler only on a **different** `message_seq` or `msg_type`. Resetting before every accept erases the first fragment of a two-fragment ClientHello, which is invisible against OpenSSL (206 bytes, one record) and fatal against a browser (about 1500 bytes, always two).

---

## Layer: SCTP

Twenty files under `sctp/`, grouped by concern rather than by RFC section. Do not consolidate them back.

| Group | Files |
| :- | :- |
| wire | `checksum`, `chunk`, `parameter`, `packet` |
| control | `init`, `cookie`, `error_cause`, `teardown`, `heartbeat` |
| data | `serial`, `data`, `sack`, `reassembly` |
| reliability | `rto`, `congestion`, `receive_queue`, `send_queue`, `forward_tsn` |
| driver | `reconfig`, `association` |

`association.zig` is the driver: a full 4-way handshake, data flow, heartbeat, 3-step shutdown, and abort. `Association.init` plus `connect` decides which side it plays.

Traps worth keeping:

- The CRC32c goes into the packet **little endian** while every other SCTP integer is network order (RFC 9260 Appendix A byte-swaps and then calls `htonl`, and the two cancel). The polynomial is **Castagnoli**, not the IEEE one that STUN FINGERPRINT uses.
- zig 0.17 renamed the catalog entry `Crc32Iscsi` to `@"CRC-32/ISCSI"`, picked with `@hasDecl` in `checksum.zig`. Watch for more catalog renames on any new `std.hash` use.
- Gap ack blocks are **offsets** from the cumulative TSN, not TSNs.
- Missing reports count only **below** the highest TSN newly acked. Counting above it retransmits data still in flight.
- Karn's algorithm is enforced in `send_queue.zig`, because `rto.zig` cannot see retransmits.
- A gap-block-only ack is marked **not freed**: the peer may renege.
- Refusing to buffer a chunk means **not acking its TSN**. That is the one unrecoverable mistake here.
- `cwnd` grows only while fully used.

`association.zig` also carries the reconfiguration wiring the data channel layer drives: `Outcome.reconfig`, `sendReconfig`, `resetOutboundStream`, `lastAssignedTsn`, `cumulativeTsn`, `peerInitialTsn` (a reset request sequence starts at the peer's first TSN) and `supportsReconfig`.

---

## Layer: data channels

Seven files under `datachannel/`.

- `payload.zig`: the seven PPIDs and the empty-message convention.
- `dcep.zig`: the OPEN and ACK codec.
- `stream_id.zig`: even or odd by DTLS role.
- `channel.zig`: one channel plus the DCEP-to-SCTP option mapping.
- `registry.zig`: the table and admission control.
- `reset.zig`: the RFC 6525 driver.
- `peer.zig`: the driver, tested with two peers talking in memory.

Traps worth keeping:

- A `nextEvent` message payload dies on the **next** call, because the reassembler frees it.
- Messages must be reported **before** closes. A reset waits for everything ahead of it (RFC 6525 section 5.2.2), so reporting the close first loses the last message.
- A RE-CONFIG carries **no TSN**, so it overtakes DATA still retransmitting. That is why reset processing is deferred.
- The DTLS role decides even against odd identifiers, and getting it wrong is invisible locally: every open succeeds and a real peer refuses all of them.
- An empty message is one zero byte under its own PPID, and the receiver drops that byte.

Decisions: one reset request names **one** stream (the reader accepts a list, since a peer may batch). An incoming SSN Reset is answered DENIED, because RFC 8831 section 6.7 closes by resetting the **sender's** outgoing stream. A refused close retires the identifier, and calling `closeChannel` again is what re-asks. No timer was invented for it.

---

## Layer: SDP

Eighteen files under `sdp/`, split into the container codecs and the media-section codecs.

| File | Owns |
| :- | :- |
| `line.zig` | the `x=value` line and both terminators |
| `attribute.zig` | the `a=` flag and value forms plus region lookup |
| `address.zig` | `IN IP4 x` and RFC 5952 IPv6 text |
| `media.zig` | the `m=` line and the data channel shape |
| `session.zig` | session level against media sections |
| `fingerprint.zig` | RFC 8122, five hash functions, compute from DER |
| `setup.zig` | RFC 4145 roles |
| `candidate.zig` | `a=candidate` over the ICE candidate model |
| `builder.zig` | the shared line appender |
| `direction.zig` | RFC 3264 section 6.1 |
| `rtpmap.zig`, `fmtp.zig`, `rtcp_feedback.zig`, `format.zig` | one payload type gathered |
| `media_offer.zig`, `media_answer.zig` | reading and writing one media section |
| `offer.zig`, `answer.zig` | the whole offer and the whole answer |

Traps worth keeping:

- Accept CRLF **and** bare LF on read (RFC 8866 section 5 asks for tolerance, and signalling paths strip the CR). Write CRLF.
- Look attributes up **media-section first**, then session level. Browsers put ICE credentials and the fingerprint in the section, the RFCs put them at session level.
- The `m=` port and `a=sctp-port` are different numbers.
- The origin line names `IN IP4 0.0.0.0` always (RFC 8829 section 5.2.1 and RFC 8828), never the real address.
- `a=tls-id` is written only if the offer had one (RFC 8842 section 5.3). Browsers send none.
- Hash function names **and** the candidate transport are compared without case, because the RFCs and the browsers disagree on capitalisation.
- A missing `a=sctp-port` is an error (RFC 8841 section 5.1). A missing `a=max-message-size` defaults to 64 KB, and a value of 0 means any size.
- `MAX_SESSION_ID` caps the origin session id at 62 bits, because RFC 8829 section 5.2.1 wants one that fits a **signed** 64-bit integer. A full-range `u64` makes Firefox refuse the whole answer about half the time.
- **`media_answer.zig` writes `a=candidate` plus `end-of-candidates` in every carried section.** A browser reads remote candidates off the BUNDLE-tagged section, which is a media section when media is offered. Without it the peer has credentials and no address, and ICE fails with zero datagrams sent.
- `offer.zig` requires a data channel section and answers `error.NoDataChannel` without one, so a browser page must `createDataChannel` alongside its media.

Policy: media is refused by default. Offered formats are **echoed, not chosen between**, because this engine has no codecs and therefore no opinion. `rtx` (RFC 4588) is dropped, because it needs a packet history that does not exist. Feedback is answered only where it is both offered and implemented, which is `nack` and `nack pli` only. `a=rtcp-mux` is required, since there is one socket.

---

## Layer: media

Sixteen files under `media/`. The `use_srtp` extension itself is `dtls_use_srtp.zig` in `src/tls/`, counted with the DTLS files above, because it is a TLS extension and not a WebRTC concept.

| File | Owns |
| :- | :- |
| `profile.zig` | the RFC 5764 section 4.1.2 parameter table |
| `rtp.zig` | the RFC 3550 section 5.1 header plus in-place setters |
| `mux.zig` | RFC 5761 RTP against RTCP |
| `rtcp.zig`, `report.zig`, `feedback.zig` | compound framing, SR and RR, RFC 4585 NACK and PLI |
| `srtp_cipher.zig`, `srtp_key.zig`, `srtp_auth.zig`, `srtp_index.zig` | AES-CM, the KDF, truncated HMAC-SHA1, ROC plus replay |
| `srtp.zig`, `srtcp.zig` | media and control protect and open |
| `forward.zig` | `open`, `reseal`, and `relay` as their composition |
| `stream_set.zig` | one `srtp.Session` per stream identifier, per direction |
| `route.zig` | which source feeds which of one receiver's streams |
| `peer_media.zig` | one peer's whole media state |

This is the layer with **real external evidence**. Three published vectors are pinned byte for byte: RFC 3711 B.2 (the AES-CM keystream over 3 blocks, which also proves the block counter advances), RFC 3711 B.3 (the cipher key, salt, and the full 94-byte auth key over 6 blocks), and RFC 2202 case 1 (HMAC-SHA1, whose key is 20 bytes, exactly the session auth key length).

Traps worth keeping:

- The KDF label byte is XORed into `master_salt` at **byte 7**, because the 7-byte key id and the 14-byte salt are aligned at their low ends. A wrong offset gives random-looking keys that match nothing.
- `SRTP_AES128_CM_HMAC_SHA1_32` has an **80-bit RTCP tag and a 32-bit RTP tag**. One profile, two tag lengths, and using one number breaks RTCP only.
- The ROC is guessed and never sent, so `estimate` is pure and `accept` is a second call made **after** authentication. Otherwise a forged sequence number drags the counter forward and locks out the real stream.
- SRTCP tags **after** appending the flag-and-index word.
- The SRTCP index **stops** at 2^31 rather than wrapping, because a reused index reuses a counter block.

### stream_set.zig

`MAX_STREAMS = 8` per direction per peer, `sessionFor(ssrc)` creating on first use, `find`, `overhead`.

One session **per stream identifier**, not per peer, because the rollover counter and the replay list are per-SSRC. Audio and video sharing one session read each other's sequence numbers as gaps or wraps and reject real packets.

### route.zig

`MAX_ROUTES = 8` per receiving peer. A `Route` holds `source_ssrc`, its `forward.Mapping`, the last sequence and timestamp it sent, and `started`.

`Table.admit(source_ssrc)` defaults to the identity mapping. `switchSource(carried_ssrc, source_ssrc, first)` swap-removes any existing entry feeding that carried SSRC, so one output stream has exactly one source and a keyframe request is never sent to a peer that stopped.

### forward.zig

`relay` is the composition of two halves that had to be separable:

- `open(source, buffer, packet_len)` unprotects in place.
- `reseal(destination, mapping, buffer, body_len)` rewrites SSRC, sequence and timestamp through the mapping, then protects for that destination.

A fan-out opens **once** and reseals per receiver. Calling `open` twice on the same packet is a replay of an index the source stream already accepted.

### peer_media.zig

Both stream sets (`inbound` keyed by `client_write_*`, `outbound` by `server_write_*`, because zix is always the DTLS server), both SRTCP sessions, and the route table.

`sealFor(header, buffer, body_len)` admits the route, picks the outbound session by the **carried** SSRC, reseals, then records what it sent.

---

## connection.zig

One answering peer, and the file that ties the layers together.

- `Options.srtp_profiles` is empty unless the server carries media. When it is empty, `media_buf` is allocated zero-length, so a data-channel-only server pays nothing for the media path.
- `Outcome` gained `media` and `keyframe_requested` so the worker can act without re-parsing.
- `isNewSource` is true for exactly one packet after a route is admitted, which is what triggers the keyframe ask.
- `FORWARDER_SSRC` is the identifier zix uses when it speaks RTCP in its own name.
- The outbound batch is **not** reset at the top of `handle`. Doing that loses replies when a driver hands the connection several datagrams without draining between them, which is a defect this engine shipped once already.

---

## dispatch/

- `worker.zig` owns the loop for all three models: `serve`, `sweep`, `flush`, `waitMs`, `sweepDue`, plus `forwardMedia`, `forwardKeyframeRequest`, `requestKeyframe` and `queueDatagram`. The drain order is a correctness property, so it lives here once.
- `common.zig` is substrate only: `optionsFrom`, socket setup, buffer sizing. `sendBufBytes` is `@max(max_recv_buf + srtp.MAX_OVERHEAD, path_max_bytes + DTLS_OVERHEAD + 64)`.
- `async.zig`, `epoll.zig`, `uring.zig` each own their real loop and nothing else. URING submits 64 one-shot `recvmsg` plus one timeout, and sends flush with `sendmmsg`. Multishot, a provided buffer ring, and the double-buffered send ring HTTP/3 carries are deliberately absent: no measurement asks for them and this engine has no baseline to defend yet.
- `test_session.zig` is test-only scaffolding holding the dialing half, shared by both Linux models so a difference between them is a difference in the loop. The precedent for a test-only file under `src/` is `src/driver/*/tests/`.

Each model's loop body is a `pass()` method (one wait plus whatever it brought), so a test can bind a real socket and drive a whole session against it with the real `Dialer`, under `zig build test-all` rather than only on a runner leg.

---

## table.zig, timer.zig, fanout.zig

- `table.zig`: address to connection, and it owns the connections. Lookup is a walk over `max_peers` (tens, not thousands), so there is no hash keyed peer table yet.
- `timer.zig`: the four deadlines, `DTLS_RETRANSMIT`, `SCTP_RETRANSMIT`, `ICE_CONSENT`, `IDLE`.
- `fanout.zig`: just the `Sink` (`*anyopaque` plus one deliver function, the same idiom as `TlsSink` in `src/tcp/http1/core.zig`). The walk itself lives in `worker.zig`, because the peer table is the worker's own and `core.zig` cannot import it (the table imports the connection, which imports core).

---

## server.zig and config.zig

`server.zig` validates before it binds anything, in this order: port, ICE credentials present, ICE credentials legal, TLS context present, key is ECDSA P-256, then dispatch model against the platform. `WebrtcServerImpl(handler)` bakes the handler in at comptime, the same shape every other engine uses.

`config.zig` publishes `SRTP_PROFILES` with the 80-bit tag first. The 32-bit profile saves six bytes a packet and gives up authentication strength for them, so it is answered only to a peer that offers nothing else. The NULL profiles are not in the list at all: they authenticate without encrypting, which is not something to agree to on a path that was just given a certificate.

---

## Testing

| Tier | File | What it covers |
| :- | :- | :- |
| integration | `tests/integration/webrtc/exchange_test.zig` | the CI exit gate, a whole session in memory in 435ms, no port and no sleep |
| behaviour | `tests/behaviour/webrtc/session_test.zig` | the session surface |
| edge | `tests/edge/webrtc/session_test.zig` | the boundaries |
| runner | `tests/runner/webrtc_client.zig` | the one socket dial loop, shared by the aggregate runner and the standalone one |

The runner table is one row per **server** binary, so `webrtc_datachannel_echo` has a row and `webrtc_native_pair` does not: the pair is a client that dials and exits, and the check drives the same session in-process through `webrtc_client.zig`. Keeping the dial loop in one file is what stops the hand-run example and the automated check from drifting.

A skip names its reason with `std.log.info` and then returns plainly, never a silent `catch return` and never `return error.SkipZigTest`, so the run says why a session test stopped instead of leaving a hole in the summary.

`webrtc_native_pair` cannot be run twice inside 30 seconds against the same echo server, and that is expected. The dialer binds a fixed local port and the server keys a peer by its 4-tuple, so a second run lands on the peer the first one left behind, which is past its handshake and ignores a fresh ClientHello. The server lets go at `peer_idle_ms`. Do **not** "fix" this in the engine by restarting a session on a ClientHello: with fixed ICE credentials the server cannot tell a restart from a replay, and a real WebRTC restart arrives with new credentials.

---

## Testing DTLS without a browser

`openssl s_client -dtls1_2 -connect <ip>:<port> -state` prints each handshake state, and `connection.zig` routes DTLS with **no ICE gate**, so it reaches the DTLS server directly. Success reads `Cipher is ECDHE-ECDSA-AES128-GCM-SHA256`, plus a line in the engine log. The self-signed verify error is correct: RFC 8122 carries the fingerprint in SDP, and nothing checks a certificate against one yet.

---

###### end of lld-webrtc
