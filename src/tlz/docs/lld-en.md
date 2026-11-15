# tlz low-level design

Internals per module. For the architecture and the goals see [`hld-en.md`](hld-en.md).

tlz is sans-I/O. The server handshake is driven by `connection.serverHandshake`, the clients by `client.zig` and `tls12/client.zig`. The optional OpenSSL backend lives in `openssl/` and is reached through `binding.zig`. The caller owns the socket. Paths below are relative to `src/tlz/src/` unless they start with `src/zix/`.

## File kinds

A lower_snake_case file holds functions, a PascalCase file is one record. A functions file hands out the records in the directory of the same name: `connection.zig` re-exports `connection/Connection.zig`, `connection/HandshakeOptions.zig`, and so on. Tests live in the file they cover and run through `test.zig`.

## Errors

Every module that can fail declares its own `pub const Error`. Member names read `Tlz_<Module>_<Condition>`, for example `Tlz_Context_KeyFileNotFound` or `Tlz_Record_BadMac`. A module never aliases another module's set: an error from a callee is translated into the caller's own member, once, at the caller's public function. So `Context.init` reports `Tlz_Context_InvalidKey`, not the `Tlz_RsaPrivateKey_InvalidKey` it got from the key parser. In the same way, `Context.initWith` turns `Tlz_OpensslContext_KeyMismatch` into `Tlz_Context_KeyMismatch`, and `Client.connectWith` turns `Tlz_OpensslClient_*` into `Tlz_Client_*`.

## wire/

`Reader` and `Writer` over a caller byte slice, big-endian. `Reader.readU8`, `readU16`, `readU24`, `readBytes` are bounds checked and fail with `Tlz_WireReader_*`. `Writer.writeU8`, `writeU16`, `writeU24`, `writeBytes`, plus `placeU16` / `patchU16` and `placeU24` / `patchU24` to back-patch a length once the body is written (used for every variable-length TLS field). No allocation.

## Wire enums

One file each: `cipher_suite.zig`, `named_group.zig`, `signature_scheme.zig`, `extension_type.zig`, `handshake/handshake_type.zig`, `record/content_type.zig`, `alert/description.zig`, `alpn.zig`. Every enum is non-exhaustive (`_`), so an unknown value from a peer parses instead of failing.

```zig
pub const CipherSuite = enum(u16) {
    AES_128_GCM_SHA256 = 0x1301,
    AES_256_GCM_SHA384 = 0x1302, // declared, not implemented
    CHACHA20_POLY1305_SHA256 = 0x1303, // declared, not implemented
    ECDHE_ECDSA_AES128_GCM_SHA256 = 0xc02b, // TLS 1.2 floor suite
    _,
};
```

`NamedGroup` carries `SECP256R1` (0x0017) and `X25519` (0x001d). `SignatureScheme` carries `RSA_PKCS1_SHA256`, `ECDSA_SECP256R1_SHA256`, `RSA_PSS_RSAE_SHA256`, and `ED25519`.

## handshake.zig

- `SERVER_CIPHER_PREFS = {AES_128_GCM_SHA256}` and `SERVER_GROUP_PREFS = {X25519, SECP256R1}` are the built-in defaults.
- `parseClientHello(bytes)` returns a `ParseResult`: the parsed `ClientHello` record or an alert. The record holds `offers_tls13` (from supported_versions), whether signature_algorithms and supported_groups are present, their raw bodies, the per-group key shares, `sni`, and the raw ALPN list.
- `negotiate(hello, key_exchange, group_prefs)` returns an `Outcome`: `legacy_version` when 1.3 is not offered (the caller drops to the 1.2 track), an alert when a required extension is missing, `hello_retry_request` when the chosen curve has no key share, else `server_hello`. The group is the first of `group_prefs` the client also offered, so a restricted or reordered `Context.curves` is honored.
- `serializeServerHello` writes supported_versions (0x0304) and key_share. `serializeHelloRetryRequest` writes the HRR with the special random (`HELLO_RETRY_REQUEST_RANDOM`, SHA-256 of "HelloRetryRequest") and a key_share naming only the group to retry with.

## key_schedule.zig

`Secret = [32]u8`, SHA-256 throughout, so only the AES-128-GCM / SHA-256 suite is served on 1.3. `key_schedule/Transcript.zig` is the running SHA-256 of the handshake messages (`update`, `current`). `deriveSecret` and `expandLabel` build the early, handshake, and master secrets and the traffic keys (RFC 8446 7.1) on `HkdfSha256`.

## record.zig

- `protect(out, plaintext, inner_type, key, iv, sequence)` builds one AEAD record. The nonce is `iv XOR sequence` (8 byte sequence, right aligned). The additional data is the 5 byte record header. The inner plaintext is `content || inner_type` (RFC 8446 5.2).
- `protect2(out, head, tail, ...)` is the gather form: two slices sealed as one record, so a small header and a large body need no join by the caller. `protect` is `protect2` with an empty tail.
- `deprotect(out, record, key, iv, sequence)` opens a record, strips the zero padding, and returns `Opened { inner_type, data }`. `data` points into `out`. Errors: `Tlz_Record_BadMac`, `Tlz_Record_Overflow`, `Tlz_Record_Decode`.
- `MAX_PLAINTEXT = 16384`, `MAX_RECORD_WIRE = 17 KiB`, `sealedLen(n)` is the wire size of `n` plaintext bytes.

## crypto/certificate.zig

```zig
pub const SigningKey = union(enum) {
    ecdsa_p256: EcdsaP256.KeyPair,
    ed25519: Ed25519.KeyPair,
    rsa: RsaPrivateKey,

    pub fn scheme(self: SigningKey) SignatureScheme // ECDSA, ED25519, or RSA_PSS_RSAE_SHA256
};
```

Builders for Certificate, CertificateRequest, CertificateVerify, and Finished. CertificateVerify signs `0x20 * 64 || context string || 0x00 || transcript hash` (RFC 8446 4.4.3) with the key's scheme: ECDSA gives a DER signature, Ed25519 the raw 64 bytes, RSA the `rsa_pss_rsae_sha256` signature. `buildCertificateVerify` takes the PSS salt, the ECDSA and Ed25519 paths ignore it. Finished `verify_data` is `HMAC(finished_key, transcript hash)`, checked byte for byte against the RFC 8448 trace in the file's tests. `verifyClientCertificateVerify` is the mTLS side.

## connection.zig

### HandshakeOptions

```zig
certificate_der: []const u8,
signing_key: SigningKey,
ephemeral_secret: [32]u8, // fresh per connection
server_random: [32]u8, // fresh per connection
pss_salt: [32]u8 = zeroes, // used only by an RSA CertificateVerify
alpn_prefs: []const Alpn = &.{},
group_prefs: []const NamedGroup = &SERVER_GROUP_PREFS,
request_client_cert: bool = false, // mTLS CertificateRequest
```

### serverHandshake

Parse the ClientHello, `negotiate`, seed the transcript with the ClientHello, then complete: check the cipher is `AES_128_GCM_SHA256`, check the client offered the signing key's scheme, negotiate ALPN, run the key exchange for the chosen curve, write ServerHello, EncryptedExtensions, (CertificateRequest), Certificate, CertificateVerify, and Finished, and derive the application keys into a `Connection`. The result is a `HandshakeResult { connection, to_send, alpn }`. A 1.2-only ClientHello returns `Tlz_Connection_UnsupportedTlsVersion`.

### HelloRetryRequest

`serverHelloRetry` negotiates only to find the group. When a retry is needed it serializes the HRR and seeds the transcript with the synthetic `message_hash` of ClientHello1 (`0xfe 00 00 <hash_len> || Hash(CH1)`, RFC 8446 4.4.1) followed by the HRR. It returns a `RetryFlight { to_send, state }`, or null when no retry is needed. `serverHandshakeAfterRetry` takes ClientHello2, negotiates again with the carried `RetryState`, checks the group matches, and completes on the carried transcript.

### Connection

Holds the application keys, the client handshake keys, the client Finished key, and three sequence numbers (`server_app_seq`, `client_app_seq`, `client_hs_seq`).

- `writeAppData` and `writeAppData2` seal and bump `server_app_seq`. They return an empty slice when `out` is too small.
- `readAppData` opens and classifies the inner type (RFC 8446 5.1): application_data gives the plaintext, an alert gives `PeerClosed`, a post-handshake handshake message gives `UnexpectedMessage`.
- `verifyClientFinished` checks the client Finished against the transcript. `verifyClientCertFlight` and `verifyClientAuthFlight` check the client Certificate and CertificateVerify when `request_client_cert` is on.
- `closeNotify` and `encryptedAlert` build outbound alerts.

`alertForError` and `alertRecordForError` map a handshake error to the alert to send (null for none).

## context.zig

`Version = enum { TLS_1_2, TLS_1_3 }`, ordered so `min <= max` is a plain compare.

`Context.init(allocator, io, config)`:

1. `config.validate()`, with no I/O.
2. Read both PEM files (`std.Io.Dir.cwd().readFileAlloc`, capped at 1 MiB). A missing file, a directory, a file too large, and an unreadable file each get their own error, for the cert and for the key.
3. `pemToDer`, duplicate the certificate DER into an owned slice.
4. Pass the certificate through `der_guard.isSafeCertificate`, parse it, and pick the key loader from `pub_key_algo`: ECDSA through `ecdsaScalarFromSec1`, Ed25519 through `ed25519SeedFromPkcs8`, RSA through `RsaPrivateKey.fromDer` (PKCS#1 or PKCS#8 by the PEM label), refused below RSA-2048 with `Tlz_Context_RsaKeyTooSmall`.

`handshakeOptions(ephemeral_secret, server_random, pss_salt)` fills a `HandshakeOptions` from the context and the per-connection randoms. `allowsTls13` and `allowsTls12` read the version range. `deinit` frees the certificate DER.

### validate

Refuses an empty curve or cipher list, a curve outside {X25519, SECP256R1}, a cipher outside {AES_128_GCM_SHA256, ECDHE_ECDSA_AES128_GCM_SHA256}, an inverted version range, an allowed version with no suite for it, and a 1.2 floor without secp256r1. Errors: `Tlz_ContextConfig_NoCurves`, `NoCiphers`, `UnsupportedCurve`, `UnsupportedCipher`, `InvalidVersionRange`, `MissingCipherForVersion`, `MissingCurveForTls12`. `Context.init` reports them under the `Tlz_Context_` prefix.

## crypto/pem.zig

`pemToDer(out, pem)` base64-decodes one PEM block (at most `MAX_PEM_BYTES` of base64). `ecdsaScalarFromSec1` pulls the 32 byte private scalar from a SEC1 EC key. `ed25519SeedFromPkcs8` pulls the 32 byte seed after the `04 22 04 20` PKCS#8 prefix.

## crypto/der_guard.zig and crypto/DerReader.zig

std's certificate DER reader does no bounds check, so a truncated certificate from a peer could make it read past the end. `isSafeCertificate` walks every element std later reads and refuses the certificate first if any is out of bounds. Every certificate from a peer or a file passes through it before std parses it. `DerReader.zig` is a small cursor for private key documents (tags, short and two byte lengths, INTEGER magnitudes).

## crypto/rsa.zig, crypto/rsa/

std verifies RSA but cannot sign, so tlz signs itself.

- `rsa/PrivateKey.zig`: `fromDer(der, is_pkcs8)` parses a two-prime RSAPrivateKey (RFC 8017 A.1.2), unwrapping the PKCS#8 OCTET STRING first. `n`, `d`, `p`, `q`, `dP`, `dQ`, and `qInv` are copied into owned fixed buffers, so the key is safe to store by value.
- `signPkcs1v15(message, out)` is the deterministic EMSA-PKCS1-v1_5 path (RFC 8017 9.2). `signPss(message, salt, out)` is EMSA-PSS with MGF1 (RFC 8017 9.1). The salt comes from the caller, so a signature is deterministic given its inputs and testable.
- Both end in RSASP1 through the Chinese Remainder Theorem (RFC 8017 5.1.2). `rsa/crt.zig` runs it on fixed-width Montgomery limbs for 2048, 3072, and 4096 bit keys. Any other width takes `std.crypto.ff`.

## crypto/montgomery.zig, crypto/montgomery/

Constant-time Montgomery arithmetic for the CRT sign: multiply, a dedicated square, reduction, and a fixed-window modular exponentiation (5 bit window for the 3072 and 4096 primes). Fixed iteration counts, every conditional subtract is a masked select, and the window table is read by a masked scan, so no secret steers a branch or an address. On x86_64 with ADX, `montgomery/asm_body.zig` builds the multiply and square asm at comptime (MULX with two carry chains, ADCX on CF and ADOX on OF). Elsewhere a portable CIOS multiply serves both. Both give identical bytes, and the signatures are fuzzed against `std.crypto.ff`.

## crypto/cert_verify.zig, crypto/cert_verify/

- `verifyCertChain(end_entity_der, trust_anchor_der, now_sec)`: one link, the leaf against its issuer (name, validity window, signature).
- `verifyChain(chain_der, trust_anchor_der, now_sec)`: a full [leaf, intermediate, ...] chain to an anchor. Each link through `verifyCertChain`, plus the path constraints of `cert_verify/PathConstraints.zig`: basicConstraints (cA, pathLen), keyUsage keyCertSign, and refusal of an unknown critical extension. std does not expose these, so the v3 extensions are walked by hand with the `der_guard` reader.
- `verifyCertHostname(end_entity_der, host)`: DNS identity through std.
- `verifyCertIdentity(end_entity_der, host)`: a DNS SAN, or an iPAddress SAN when `host` is an IPv4 literal (scanning for the `0x87 0x04 <4 bytes>` GeneralName, since std is DNS only).

## client.zig, client/

`start(opts, out)` builds the ClientHello from `client_random`, `ephemeral_secret`, and the ALPN offer, and returns the bytes plus a `State`. `finish(state, server_flight, out)` reads the server flight, verifies the CertificateVerify against the server certificate, checks the server Finished, and returns `FinishResult { connection, client_finished, alpn, ... }`. `verifyServerCert` on the result runs the chain and hostname checks. `ClientConnection` mirrors the server `Connection` (`writeAppData`, `readAppData`, `closeNotify`).

## tls12/

The 1.2 track mirrors the 1.3 layers:

| File | Role |
| :- | :- |
| `tls12/prf.zig` | HMAC-SHA256 PRF: master_secret, key_block, Finished verify_data |
| `tls12/record.zig` | 1.2 AES-GCM records with the explicit 8 byte nonce |
| `tls12/version.zig` | `selectVersion` and the downgrade sentinel in ServerHello.random (RFC 8446 4.1.3) |
| `tls12/connection.zig` | server: `serverFlight1` answers the ClientHello, `serverFinish` checks the client Finished (ECDHE-ECDSA-AES128-GCM, secp256r1) |
| `tls12/client.zig` | client: `start` and `finish` |

## dtls/

The DTLS 1.2 track (RFC 6347), public as `tlz.Dtls`. The caller owns the datagram socket and the timers.

| File | Role |
| :- | :- |
| `dtls/record.zig` | header codec, epoch, 48 bit sequence, AES-128-GCM protection, anti-replay window |
| `dtls/handshake.zig` | 12 byte handshake header, fragmenter, fragment walker, reassembler |
| `dtls/hello.zig` | ClientHello and HelloVerifyRequest codec |
| `dtls/cookie.zig` | stateless HMAC cookies for HelloVerifyRequest |
| `dtls/flight.zig` | retransmit timer and flight state (RFC 6347 4.2.4) |
| `dtls/connection.zig` | server: cookie exchange, server flight, finish |
| `dtls/client.zig` | client: hello with and without cookie, finish |
| `dtls/exporter.zig` | RFC 5705 key export and the RFC 5764 SRTP key split |
| `dtls/use_srtp.zig` | the `use_srtp` extension: read the offer, pick a profile, write the answer |

Three traps worth knowing:

- `dtls/connection.zig` builds its own flights and reuses only leaf primitives from the 1.2 track. The DTLS transcript is taken over 12 byte DTLS headers as if unfragmented, without the first ClientHello and the HelloVerifyRequest (RFC 6347 4.2.6). Getting this wrong is invisible until a real peer rejects the Finished.
- The anti-replay window in `dtls/record.zig` is checked before the AEAD and updated after it. Updating first would let a forged far-ahead sequence clear the window.
- DTLS-SRTP export uses the no-context seed form. Passing an empty context slice appends a two byte zero length and breaks interop.

## binding.zig

`Binding` is `enum(u8) { DEFAULT, OPENSSL }`. `isBuilt(binding)` is `true` for `.DEFAULT` and follows `c.ENABLED` for `.OPENSSL`. `requireBuilt(binding)` raises a `@compileError` (install the libssl dev package so `pkg-config openssl` finds it) when the backend is not built.

- `context/Context.zig`: `ContextFor(binding)` is `Self` for `.DEFAULT` and `openssl/Context.zig` for `.OPENSSL`. `initWith(allocator, io, config, binding)` calls `init` or the OpenSSL `init`, and translates the OpenSSL error into `Tlz_Context_*`.
- `client.zig`: `ConnectionFor(.OPENSSL)` is `openssl/Connection.zig`, `.DEFAULT` is a `@compileError` that points to `start` plus `finish`. `connectWith(ca_path, host, alpn_prefs, binding)` calls `openssl/client.connect` and translates its error into `Tlz_Client_*`.
- `lib.zig` re-exports `Binding`.

## openssl/

The OpenSSL backend. Only compiled when `build.zig` detected OpenSSL.

### Build

`build.zig` exposes `detectOpenssl(b, target)` and `linkOpenssl(b, target, optimize, module)`. `detectOpenssl` returns `false` for a cross target, otherwise it runs `pkg-config --exists openssl` and falls back to the standard `ssl.h` paths. The result goes into the `tlz_options` module as `openssl`. Zig 0.17 has no `@cImport`, so `linkOpenssl` writes a small header (`ssl.h`, `err.h`, `x509v3.h`) into the build cache, translates it with `addTranslateC`, adds it as the `openssl_c` module, and links libssl, libcrypto, and libc. No C header is tracked in the tree. The zix root `build.zig` calls the same two functions.

### c.zig

The single importer of `openssl_c`. `ENABLED` is `tlz_options.openssl`. `raw` is the translated module when enabled, an empty namespace otherwise. A `comptime` block rejects an `OPENSSL_VERSION_NUMBER` below `0x30000000` (OpenSSL 3.0). Every other openssl file uses `c.raw`, never an OpenSSL header directly.

### error.zig

Reads the OpenSSL error queue, which is per thread. `clearQueue` runs before each OpenSSL call so a later read sees only that call. `drainMatch(lib, reasons)` empties the queue and reports whether one entry matched a library reason (used for the ALPN failure). `describe` and `drainLastLine` copy the readable line into a caller buffer (`LINE_BUF_LEN = 256`), never a borrowed C pointer. The text is for logs, control flow uses the codes. It cannot fail, so it has no error set.

### Context.zig

Server `SSL_CTX` on `TLS_server_method`. `init(allocator, config)`:

1. Copies `cert_path` and `key_path` into zero-terminated buffers (`PathTooLong` past `PATH_MAX`).
2. `SSL_CTX_use_certificate_chain_file`, `SSL_CTX_use_PrivateKey_file`, and `SSL_CTX_check_private_key` (`CertLoadFailed`, `KeyLoadFailed`, `KeyMismatch`).
3. Maps `min_version` and `max_version` to the OpenSSL proto versions (`InvalidVersionRange`, `VersionSetFailed`).
4. Builds the ALPN wire list with `allocator` and installs a select callback. The callback picks the first server protocol the client also offers (RFC 7301 3.2). No overlap is a fatal `no_application_protocol` alert, like the native server.

Curves and ciphers keep the OpenSSL defaults. `newConnection` returns a server `Connection`. `deinit` frees the `SSL_CTX` and the ALPN list. A live `Connection` keeps the `SSL_CTX` alive, but not the ALPN list, so free every connection before the context.

### Connection.zig

Fields: `ssl`, `network_in`, `network_out`. `SSL_set_bio` attaches two memory BIOs: peer bytes are written into `network_in`, OpenSSL writes the bytes to send into `network_out`. `initServer` and `initClient` set the accept or connect state.

- `handshake(incoming, out)`: write `incoming` into `network_in`, run `SSL_do_handshake`, then `drain(out)`. `WANT_READ` and `WANT_WRITE` are not errors, they return whatever is queued (possibly empty). A client starts with an empty `incoming`, which produces the ClientHello.
- A failed handshake maps in this order: `ZERO_RETURN` to `PeerClosed`, a bad verify result to `PeerVerifyFailed`, an ALPN reason in the queue to `NoProtocolNegotiated`, else `HandshakeFailed`. An alert may still be queued after the error, so `drain` it to tell the peer.
- `pendingLen` and `drain`: OpenSSL can queue more than `out` holds (a large flight, an alert, a session ticket after a read). Drain until `pendingLen` is 0 before waiting on the peer.
- `writeAppData`, `readAppData`, `closeNotify`, `selectedAlpn` mirror the native `Connection`. `readAppData` returns an empty slice until a full record has arrived. Input longer than `c_int` is `InputTooLarge`.
- `deinit` calls `SSL_free`, which frees both BIOs.

### client.zig

`connect(ca_path, host, alpn_prefs)` builds a fresh `SSL_CTX` on `TLS_client_method` for each call:

1. `SSL_CTX_load_verify_file(ca_path)` and `SSL_VERIFY_PEER` (`CaLoadFailed`).
2. Minimum version TLS 1.2 (`VersionSetFailed`).
3. A client `Connection`. The context is freed at the end of `connect`, the `SSL` keeps its own reference.
4. `host` is required (`HostMissing`, since OpenSSL would skip the name check on an empty host) and at most 253 bytes (`HostTooLong`). It is set as SNI (`SSL_set_tlsext_host_name`) and as the name to verify (`SSL_set1_host`).
5. The ALPN offer, when not empty (`AlpnTooLong`, `AlpnSetFailed`).

The returned `Connection` is not handshaken yet. The first `handshake(&.{}, out)` writes the ClientHello.

### Tests

Unit and edge tests live in each file and skip with `error.SkipZigTest` when OpenSSL is not built. Loopback tests run an OpenSSL client against an OpenSSL server in one process: TLS 1.2 and 1.3, ALPN (server order, no overlap), a hostname mismatch, an untrusted chain, and close_notify. Cross-check tests use the `openssl s_client` and `openssl s_server` tools as the peer. An ALPN parity test runs `s_client` (offering h2 and http/1.1) against the native server and the OpenSSL server with the same server order, and expects the same protocol from both.

## Use in zix

zix owns the sockets. These files live in `src/zix/` and call tlz.

### src/zix/tls/tls_session.zig

A resumable TLS 1.3 server session that one worker drives for many connections. `Session.feed(input, to_send_buf, plain_buf)` takes ciphertext as it arrives, buffers a partial record, and returns a `FeedResult { to_send, plaintext, outcome }`. The phase runs `hello -> finished -> established -> closed`: `hello` calls `serverHandshake` and emits the flight, `finished` verifies the client Finished, `established` opens application data. TLS 1.3 only, a 1.2-only ClientHello is refused with a fatal alert.

### src/zix/multiplexers/tls_conn.zig

The transport shared by the multiplexed loops: the session plus an outbound ciphertext buffer. A write that hits `EAGAIN` is staged and `EPOLLOUT` is armed, so a write never blocks a worker. `conn_table.zig` maps an fd to its connection.

### Http1

- `.EPOLL` / `.URING`: `src/zix/tcp/http1/tls_mux.zig`. One `SO_REUSEPORT` listener and epoll instance per worker. Each connection terminates TLS in place: read ciphertext, `session.feed`, run the request through `tls_feed.zig`, seal the reply, send. SSE and WebSocket run in the same loop through the connection stream sink. TLS 1.3 only.
- `.ASYNC`: `src/zix/tcp/http1/tls_serve.zig`. One task per connection runs the handshake (1.3, or the 1.2 track for a 1.2-only client, within the context version range), then a keep-alive request loop. The handler writes into an in-memory sink. A response past that buffer, an SSE stream, and a WebSocket leave through `TlsStreamSink.zig`, sealed one write at a time.
- WebSocket broadcast over TLS: `TlsPeers.zig` maps an fd to its TLS connection, so a write to another connection is sealed with that connection's session, under a per-slot lock.
- Misdirected request (RFC 9110 7.4): the Host header (port stripped) is checked against the certificate with `verifyCertIdentity`. A mismatch returns `421 Misdirected Request` and closes.

### Http2 and Grpc

- `.EPOLL` / `.URING`: `src/zix/tcp/http2/tls_mux.zig` and `src/zix/tcp/http2/grpc/tls_mux.zig`. Same worker shape as Http1. Once the session is established, the plaintext feeds the h2 or gRPC mux, and the mux frames are sealed back into records through the writer's `write_hook`.
- `.ASYNC`: `src/zix/tcp/http2/tls_serve.zig` and `src/zix/tcp/http2/grpc/tls_serve.zig`. An accept loop hands each connection to its own task, which calls `src/zix/tls/h2_terminator.zig`. The terminator runs the handshake (1.3, or 1.2 as a fallback), requires ALPN h2, verifies the client Finished, then hands the connection to a driver (`MuxDriver.zig` for h2, `mux_driver.zig` for gRPC) that runs the mux inline over the decrypted records. No socketpair, no second thread.

### Dual listener

With `tls_port` set next to `tls`, one server serves cleartext on `port` and TLS on `tls_port` from the same workers. Under `.EPOLL` the TLS connections join the cleartext epoll loop. Under `.URING` they run on the ring (`dispatch/UringTlsConn.zig` for h2 and gRPC). Under `.ASYNC` a second accept loop runs the TLS serve path.
