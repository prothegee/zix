# tlz

TLS 1.3, TLS 1.2, and DTLS 1.2, written in pure Zig on `std.crypto`. No OpenSSL, no C.

- Sans-I/O: a handshake call takes the bytes received and returns the bytes to send. The caller owns the socket, so tlz fits a blocking task, an epoll worker, or an io_uring ring the same way.
- Server: TLS 1.3 with a TLS 1.2 floor. Nothing below 1.2 is ever offered.
- Client: TLS 1.3 and TLS 1.2, with X.509 chain and hostname or IP checks.
- DTLS 1.2 for datagram transports, with the SRTP key export.
- Certificates: ECDSA P-256, Ed25519, or RSA (2048 and up).
- No allocator in the handshake or the record path. Everything works in caller buffers.
- Builds on Zig 0.17.

For the architecture see [`docs/hld-en.md`](docs/hld-en.md), for the internals see [`docs/lld-en.md`](docs/lld-en.md), for measured cost see [`docs/bench-en.md`](docs/bench-en.md).

## Import

tlz ships inside zix and is reachable from it:

```zig
const zix = @import("zix");

var tls = try zix.tlz.Context.init(allocator, io, .{
    .cert_path = "certs/ecdsa_p256_cert.pem",
    .key_path = "certs/ecdsa_p256_key.pem",
});
```

It is also a standalone package under `src/tlz` with its own build files, so it can be depended on by itself. Add it as a path dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .tlz = .{ .path = "path/to/tlz" },
},
```

Wire the module in `build.zig`:

```zig
const tlz = b.dependency("tlz", .{}).module("tlz");
exe.root_module.addImport("tlz", tlz);
```

## Server quickstart

A `Context` loads the certificate and key once. Each connection then runs the handshake on the bytes the caller read from its socket:

```zig
const tlz = @import("tlz");

var tls = try tlz.Context.init(allocator, io, .{
    .cert_path = "certs/ecdsa_p256_cert.pem",
    .key_path = "certs/ecdsa_p256_key.pem",
    .alpn = &.{.HTTP_1_1},
});
defer tls.deinit();

// Per connection: fresh randoms, then the handshake on the ClientHello record.
const opts = tls.handshakeOptions(ephemeral_secret, server_random, pss_salt);

var out: [8192]u8 = undefined;
var result = try tlz.serverHandshake(opts, client_hello, &out);
// send result.to_send, read the client Finished, then:
try result.connection.verifyClientFinished(client_finished);

// Application data, one record at a time.
const plaintext = try result.connection.readAppData(record, &plain_buf);
const reply = result.connection.writeAppData(response, &record_buf);
```

`ephemeral_secret`, `server_random`, and `pss_salt` must be fresh random bytes for every connection. A complete client and server run in one process is in [`examples/tls13_loopback.zig`](examples/tls13_loopback.zig).

## Context config

| Field | Default | Meaning |
| :- | :- | :- |
| `cert_path` | required | PEM certificate file |
| `key_path` | required | PEM key file (SEC1 for ECDSA, PKCS#8 for Ed25519, PKCS#1 or PKCS#8 for RSA) |
| `alpn` | `&.{}` | ALPN protocols in server preference order |
| `min_version` | `.TLS_1_2` | lowest version served |
| `max_version` | `.TLS_1_3` | highest version served |
| `curves` | `DEFAULT_CURVES` | X25519 and secp256r1 |
| `ciphers` | `DEFAULT_CIPHERS` | TLS_AES_128_GCM_SHA256 and ECDHE_ECDSA_AES128_GCM_SHA256 |
| `prefer_server_ciphers` | `true` | stored on the context, the handshake uses the server order today |
| `hsts_max_age_s` | `0` | HSTS max-age for a caller that sends the header |

An unsupported curve or cipher is a startup error from `Context.init`, never a silent no-op. An RSA certificate needs TLS 1.3 (the 1.2 track is ECDSA only).

## Client

```zig
var hello_buf: [512]u8 = undefined;
const started = try tlz.Client.start(.{
    .client_random = client_random,
    .ephemeral_secret = ephemeral_secret,
    .alpn = &.{.H2},
}, &hello_buf);
var state = started.state;
// send started.client_hello, read the server flight, then:

var finished_buf: [256]u8 = undefined;
var client = try tlz.Client.finish(&state, server_flight, &finished_buf);
try client.verifyServerCert(trust_anchor_der, "example.com", now_sec);
// send client.client_finished, then use client.connection
```

`tlz.Client12` is the TLS 1.2 client with the same `start` and `finish` shape.

## Public surface

| Name | What it is |
| :- | :- |
| `Context`, `Version`, `DEFAULT_CURVES`, `DEFAULT_CIPHERS` | server context and its policy |
| `serverHandshake`, `serverHelloRetry`, `serverHandshakeAfterRetry` | TLS 1.3 server handshake |
| `Connection`, `HandshakeOptions`, `HandshakeResult`, `RetryState`, `RetryFlight` | handshake input, output, and the established connection |
| `alertForError`, `alertRecordForError`, `parseInboundAlert` | alerts out and in |
| `Client`, `Client12`, `Server12` | TLS 1.3 client, TLS 1.2 client and server |
| `verifyChain`, `verifyCertChain`, `verifyCertHostname`, `verifyCertIdentity` | peer certificate checks |
| `pemToDer`, `SigningKey` | key and certificate loading |
| `MAX_PLAINTEXT`, `MAX_RECORD_WIRE`, `sealedLen` | record sizes |
| `Dtls` | DTLS 1.2: server, client, record, handshake, cookie, flight, exporter, use_srtp |
| `VERSION`, `VERSION_STRING` | package version |

## Errors

Every module declares its own error set. Members read `Tlz_<Module>_<Condition>`, for example `Tlz_Context_KeyFileNotFound` or `Tlz_Record_BadMac`, so an error names where it came from.

## Build target

AES-GCM picks hardware or software at compile time from the CPU target. Build with `-Dcpu=native`, or a target that has `aes` and `pclmul` (for example `-Dcpu=x86_64_v3+aes+pclmul`). Without them the record layer falls back to software and is much slower. `x86_64_v3` alone does not include them.

## Examples

| Example | What it shows |
| :- | :- |
| `tls13_loopback` | TLS 1.3 client and server in one process |
| `tls12_loopback` | TLS 1.2 client and server in one process |
| `dtls_loopback` | DTLS 1.2 client and server in one process |
| `cert_verify` | chain and hostname checks |
| `tls13_echo_server`, `tls13_echo_client` | TLS 1.3 over a real TCP socket |
| `bench_rsa`, `bench_ecdsa_p256`, `bench_ed25519`, `bench_record` | cost per primitive, see [`docs/bench-en.md`](docs/bench-en.md) |

From `src/tlz`:

```
zig build examples
zig build example-tls13_loopback
```

## Testing

From `src/tlz`:

```
zig build unit_edge-test
zig build behaviour-test
zig build all-test
```

From the zix root, the same package runs as `zig build tlz-unit_edge-test`, `tlz-behaviour-test`, `tlz-all-test`, and `tlz-examples`.
