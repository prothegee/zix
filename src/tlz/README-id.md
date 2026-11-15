# tlz

TLS 1.3, TLS 1.2, dan DTLS 1.2, ditulis dalam Zig murni di atas `std.crypto`. Jalur default tanpa OpenSSL dan tanpa C.

- Sans-I/O: pemanggilan handshake menerima byte yang diterima dan mengembalikan byte yang harus dikirim. Pemanggil memiliki socket, jadi tlz cocok untuk blocking task, epoll worker, atau io_uring ring dengan cara yang sama.
- Server: TLS 1.3 dengan TLS 1.2 sebagai batas bawah. Tidak ada yang di bawah 1.2 yang pernah ditawarkan.
- Client: TLS 1.3 dan TLS 1.2, dengan cek rantai X.509 dan hostname atau IP.
- DTLS 1.2 untuk transport datagram, dengan ekspor kunci SRTP.
- Sertifikat: ECDSA P-256, Ed25519, atau RSA (2048 ke atas).
- Tidak ada allocator di jalur handshake maupun record. Semua bekerja di buffer milik pemanggil.
- Backend OpenSSL opsional, dipilih per context dengan `initWith(..., .OPENSSL)`, hanya dipakai jika sistem menyediakan libssl (lihat [Backend OpenSSL](#backend-openssl-opsional)).
- Build di Zig 0.17.

Untuk arsitektur lihat [`docs/hld-id.md`](docs/hld-id.md), untuk detail internal lihat [`docs/lld-id.md`](docs/lld-id.md), untuk biaya yang diukur lihat [`docs/bench-id.md`](docs/bench-id.md).

## Import

tlz ikut di dalam zix dan bisa dijangkau dari sana:

```zig
const zix = @import("zix");

var tls = try zix.tlz.Context.init(allocator, io, .{
    .cert_path = "certs/ecdsa_p256_cert.pem",
    .key_path = "certs/ecdsa_p256_key.pem",
});
```

tlz juga package mandiri di `src/tlz` dengan file build sendiri, jadi bisa dipakai sebagai dependency tersendiri. Tambahkan sebagai path dependency di `build.zig.zon`:

```zig
.dependencies = .{
    .tlz = .{ .path = "path/to/tlz" },
},
```

Sambungkan modulnya di `build.zig`:

```zig
const tlz = b.dependency("tlz", .{}).module("tlz");
exe.root_module.addImport("tlz", tlz);
```

## Mulai cepat: server

`Context` memuat sertifikat dan kunci sekali. Setiap koneksi lalu menjalankan handshake atas byte yang dibaca pemanggil dari socket-nya:

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

`ephemeral_secret`, `server_random`, dan `pss_salt` harus byte random yang segar untuk setiap koneksi. Contoh lengkap client dan server dalam satu proses ada di [`examples/tls13_loopback.zig`](examples/tls13_loopback.zig).

## Config Context

| Field | Default | Arti |
| :- | :- | :- |
| `cert_path` | wajib | file sertifikat PEM |
| `key_path` | wajib | file kunci PEM (SEC1 untuk ECDSA, PKCS#8 untuk Ed25519, PKCS#1 atau PKCS#8 untuk RSA) |
| `alpn` | `&.{}` | protokol ALPN dalam urutan preferensi server |
| `min_version` | `.TLS_1_2` | versi terendah yang dilayani |
| `max_version` | `.TLS_1_3` | versi tertinggi yang dilayani |
| `curves` | `DEFAULT_CURVES` | X25519 dan secp256r1 |
| `ciphers` | `DEFAULT_CIPHERS` | TLS_AES_128_GCM_SHA256 dan ECDHE_ECDSA_AES128_GCM_SHA256 |
| `prefer_server_ciphers` | `true` | disimpan di context, handshake saat ini memakai urutan server |
| `hsts_max_age_s` | `0` | max-age HSTS untuk pemanggil yang mengirim header-nya |

Curve atau cipher yang tidak didukung menjadi error saat startup dari `Context.init`, tidak pernah diam-diam diabaikan. Sertifikat RSA butuh TLS 1.3 (jalur 1.2 hanya ECDSA).

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

`tlz.Client12` adalah client TLS 1.2 dengan bentuk `start` dan `finish` yang sama.

## Backend OpenSSL (opsional)

Backend native adalah default. Jika host build memiliki OpenSSL 3.0 atau lebih baru (ditemukan oleh `pkg-config openssl`), build juga mengompilasi backend OpenSSL dan me-link libssl, libcrypto, dan libc. Tidak ada build flag. Context atau client memilihnya lewat parameter terakhir:

```zig
// Config sama dengan Context.init, binding adalah parameter terakhir.
var ssl_ctx = try tlz.Context.initWith(allocator, io, .{
    .cert_path = "certs/ecdsa_p256_cert.pem",
    .key_path = "certs/ecdsa_p256_key.pem",
    .alpn = &.{.H2},
}, .OPENSSL);
defer ssl_ctx.deinit();

var conn = try ssl_ctx.newConnection();
defer conn.deinit();

// Client: file CA, nama server (SNI dan cek nama), penawaran ALPN.
var client = try tlz.Client.connectWith("ca.pem", "example.com", &.{.H2}, .OPENSSL);
defer client.deinit();
```

- `Context.init` dan `initWith(..., .DEFAULT)` tetap native, bahkan ketika OpenSSL ikut di-build.
- Memilih `.OPENSSL` tanpa OpenSSL di host build adalah build error, bukan error saat runtime.
- Handshake berupa loop: `conn.handshake(incoming, &out)` sampai `conn.handshakeDone()`. Client mulai dengan `handshake(&.{}, &out)`, yang menulis ClientHello. Selama `conn.pendingLen()` di atas 0, panggil `conn.drain(&out)` dan kirim byte-nya.
- Setelah handshake: `readAppData`, `writeAppData`, `closeNotify`, `selectedAlpn`, nama yang sama dengan native.
- Hanya `cert_path`, `key_path`, `alpn`, `min_version`, dan `max_version` yang berlaku. Curve dan cipher memakai default OpenSSL.

Detailnya ada di [`docs/hld-id.md`](docs/hld-id.md#model-backend) dan [`docs/lld-id.md`](docs/lld-id.md#openssl).

## Permukaan publik

| Nama | Apa itu |
| :- | :- |
| `Context`, `Version`, `DEFAULT_CURVES`, `DEFAULT_CIPHERS` | context server dan policy-nya |
| `Binding`, `Context.initWith`, `Context.ContextFor`, `Client.connectWith`, `Client.ConnectionFor` | pilihan backend (native atau OpenSSL) |
| `serverHandshake`, `serverHelloRetry`, `serverHandshakeAfterRetry` | handshake server TLS 1.3 |
| `Connection`, `HandshakeOptions`, `HandshakeResult`, `RetryState`, `RetryFlight` | input dan output handshake, serta koneksi yang sudah established |
| `alertForError`, `alertRecordForError`, `parseInboundAlert` | alert keluar dan masuk |
| `Client`, `Client12`, `Server12` | client TLS 1.3, client dan server TLS 1.2 |
| `verifyChain`, `verifyCertChain`, `verifyCertHostname`, `verifyCertIdentity` | cek sertifikat peer |
| `pemToDer`, `SigningKey` | pemuatan kunci dan sertifikat |
| `MAX_PLAINTEXT`, `MAX_RECORD_WIRE`, `sealedLen` | ukuran record |
| `Dtls` | DTLS 1.2: server, client, record, handshake, cookie, flight, exporter, use_srtp |
| `VERSION`, `VERSION_STRING` | versi package |

## Error

Setiap modul mendeklarasikan set error-nya sendiri. Member berbentuk `Tlz_<Module>_<Condition>`, misalnya `Tlz_Context_KeyFileNotFound` atau `Tlz_Record_BadMac`, jadi sebuah error menyebutkan dari mana asalnya.

## Build target

AES-GCM memilih hardware atau software saat compile dari CPU target. Build dengan `-Dcpu=native`, atau target yang punya `aes` dan `pclmul` (misalnya `-Dcpu=x86_64_v3+aes+pclmul`). Tanpa keduanya, record layer jatuh ke software dan jauh lebih lambat. `x86_64_v3` saja tidak menyertakan keduanya.

## Example

| Example | Yang ditunjukkan |
| :- | :- |
| `tls13_loopback` | client dan server TLS 1.3 dalam satu proses |
| `tls12_loopback` | client dan server TLS 1.2 dalam satu proses |
| `dtls_loopback` | client dan server DTLS 1.2 dalam satu proses |
| `cert_verify` | cek rantai dan hostname |
| `tls13_echo_server`, `tls13_echo_client` | TLS 1.3 lewat socket TCP sungguhan |
| `bench_rsa`, `bench_ecdsa_p256`, `bench_ed25519`, `bench_record` | biaya per primitive, lihat [`docs/bench-id.md`](docs/bench-id.md) |

Dari `src/tlz`:

```
zig build examples
zig build example-tls13_loopback
```

## Testing

Dari `src/tlz`:

```
zig build unit_edge-test
zig build behaviour-test
zig build all-test
```

Dari root zix, package yang sama dijalankan sebagai `zig build tlz-unit_edge-test`, `tlz-behaviour-test`, `tlz-all-test`, dan `tlz-examples`.
