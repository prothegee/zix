# LLD: zix.Tls (TLS 1.3 + 1.2 pure-Zig)

Detail implementasi internal. Untuk rasional desain lihat [`docs/hld-tls-id.md`](hld-tls-id.md) dan ADR-045 / 046 / 047.

`zix.Tls` bersifat sans-I/O. Handshake server didorong oleh `connection.serverHandshake`, client oleh `client.zig` / `tls12_client.zig`. Engine HTTP memiliki socket loop di `tcp/http1/tls_serve.zig` dan `tcp/http2/tls_serve.zig`.

---

## wire.zig

`Reader` dan `Writer` di atas byte slice, big-endian. `Reader.readU8 / readU16 / readU24 / readBytes` dengan cek batas. `Writer.writeU8 / writeU16 / writeU24 / writeBytes`, plus `placeU16 / patchU16` untuk back-patch panjang setelah body ditulis (dipakai tiap field TLS panjang-variabel). Tanpa alokasi: caller menyediakan `buf`.

## handshake.zig

### Enum wire

```zig
pub const CipherSuite = enum(u16) {
    AES_128_GCM_SHA256 = 0x1301,
    AES_256_GCM_SHA384 = 0x1302,           // dideklarasi, belum diimplementasi
    CHACHA20_POLY1305_SHA256 = 0x1303,     // dideklarasi, belum diimplementasi
    ECDHE_ECDSA_AES128_GCM_SHA256 = 0xc02b, // suite floor TLS 1.2
    _,
};
pub const NamedGroup = enum(u16) { SECP256R1 = 0x0017, X25519 = 0x001d, _ };
pub const SignatureScheme = enum(u16) { ECDSA_SECP256R1_SHA256 = 0x0403, ED25519 = 0x0807, _ };
```

`server_cipher_prefs = {AES_128_GCM_SHA256}` dan `server_group_prefs = {X25519, SECP256R1}` adalah default bawaan.

### Parse ClientHello

`parseClientHello` mengembalikan struct `ok` atau `alert`. Ia mencatat `offers_tls13` (dari supported_versions), `has_signature_algorithms`, `has_supported_groups`, body mentah `signature_schemes` dan `supported_groups`, key_share per-group (`x25519_share`, `secp256r1_share`), `sni`, dan ProtocolNameList `alpn` mentah. Helper: `offersCipher`, `offersGroup`, `hasKeyShare`, `offersSignatureScheme`.

### negotiate

```zig
pub fn negotiate(hello, key_exchange, group_prefs: []const NamedGroup) Outcome
```

Mengembalikan `legacy_version` saat 1.3 tidak ditawarkan (caller turun ke track 1.2), alert `MISSING_EXTENSION` tanpa sig-algs / groups, `hello_retry_request` saat curve pilihan tidak punya key_share, selain itu `server_hello`. `pickCipher` mengiterasi `server_cipher_prefs`. `pickGroup` mengiterasi `group_prefs` terkonfigurasi (jadi `Tls.Context.curves` yang dibatasi / diurut ulang dihormati), mengembalikan yang pertama juga ditawarkan client.

### Serializer

`serializeServerHello` menulis ServerHello dengan supported_versions (0x0304) dan key_share. `serializeHelloRetryRequest` menulis HRR dengan random sentinel HRR khusus (SHA-256 dari "HelloRetryRequest") dan extension key_share yang menamai hanya group untuk retry.

## key_schedule.zig

`Secret = [32]u8`, SHA-256 sepanjang jalur (jadi hanya suite 1.3 AES-128-GCM / SHA-256 yang dapat dihormati). `Transcript` membungkus SHA-256 berjalan dari pesan handshake, `update(bytes)` dan `current()`. `HkdfSha256.extract` / `deriveSecret` / `expandLabel` membangun early, handshake, dan master secret serta traffic key per RFC 8446 7.1.

## record.zig

`protect(out, plaintext, content_type, key, iv, seq)` membangun record AEAD: nonce per-record adalah `iv XOR seq` (seq 8-byte rata kanan), additional data adalah header record, inner plaintext adalah `content || content_type` (RFC 8446 5.2). `deprotect` membalikkannya dan mengembalikan inner content type. `ContentType` menyebut handshake / application_data / alert / change_cipher_spec.

## certificate.zig

```zig
pub const SigningKey = union(enum) {
    ecdsa_p256: EcdsaP256.KeyPair,
    ed25519: Ed25519.KeyPair,
    rsa: rsa.PrivateKey,
    pub fn scheme(self) SignatureScheme  // .ECDSA_SECP256R1_SHA256, .ED25519, atau .RSA_PSS_RSAE_SHA256
};
```

Builder untuk Certificate, CertificateVerify, dan Finished. CertificateVerify menandatangani `0x20 * 64 || context-string || 0x00 || transcript-hash` (RFC 8446 4.4.3) dengan scheme key: ECDSA mengeluarkan signature DER, Ed25519 64 byte mentah, dan key RSA signature PSS `rsa_pss_rsae_sha256` via `signPss` (`buildCertificateVerify` menerima salt-nya, jalur ECDSA / Ed25519 mengabaikannya). `verify_data` Finished adalah `HMAC(finished_key, transcript-hash)`, diverifikasi byte-exact terhadap trace RFC 8448 in-file.

## connection.zig

### HandshakeOptions

```zig
certificate_der, signing_key,
ephemeral_secret: [32]u8, server_random: [32]u8,   // fresh per koneksi
alpn_prefs: []const Alpn = &.{},
group_prefs: []const NamedGroup = &server_group_prefs,
request_client_cert: bool = false,                  // CertificateRequest mTLS
```

### serverHandshake

Parse ClientHello, `negotiate(&hello, &.{}, opts.group_prefs)`, seed transcript dengan ClientHello, lalu `completeHandshake`. `completeHandshake` menjaga `cipher == AES_128_GCM_SHA256`, mengecek client menawarkan scheme signing key (`NoCommonSignatureScheme` jika tidak), menegosiasi ALPN, menjalankan `computeKeyExchange` untuk curve, menulis ServerHello + EncryptedExtensions + Certificate + CertificateVerify + Finished, dan menurunkan application key ke sebuah `Connection`.

### HelloRetryRequest

`serverHelloRetry` menegosiasi hanya untuk menemukan group, men-serialize HRR, dan seed transcript dengan `message_hash` sintetik dari ClientHello1 (`0xfe 00 00 <hash_len> || Hash(CH1)`, RFC 8446 4.4.1) diikuti HRR. Ia mengembalikan `RetryFlight { to_send, state }`. `serverHandshakeAfterRetry` mengonsumsi ClientHello2, re-negotiate dengan `state.opts.group_prefs`, memastikan group cocok, dan menjalankan `completeHandshake` di transcript yang dibawa.

### Connection

Memegang application key + client-handshake key dan tiga sequence number (`server_app_seq`, `client_app_seq`, `client_hs_seq`). `writeAppData` meng-encrypt dan menaikkan `server_app_seq`. `readAppData` men-decrypt dan mengklasifikasi inner type (RFC 8446 5.1): application_data mengembalikan plaintext, alert -> `PeerClosed`, handshake pasca-handshake -> `UnexpectedMessage`. `verifyClientFinished` mengecek client Finished terhadap transcript. `encryptedAlert` / `closeNotify` membangun alert keluar.

## context.zig

`Version = enum(u8) { TLS_1_2 = 0x12, TLS_1_3 = 0x13 }` (terurut untuk min <= max). `Context.init` memanggil `validate(config)` yang I/O-free, membaca PEM cert / key, `pemToDer`, menduplikasi DER ke slice milik sendiri, lalu mendeteksi tipe key dari `cert.pub_key_algo` (`.X9_62_id_ecPublicKey` -> ECDSA via `ecdsaScalarFromSec1`, `.curveEd25519` -> Ed25519 via `ed25519SeedFromPkcs8`, `.rsaEncryption` -> RSA via `rsa.PrivateKey.fromDer`, menolak di bawah RSA-2048 dengan `RsaKeyTooSmall`). Buffer DER key berukuran untuk key PKCS#8 RSA, lebih besar dari key EC. `handshakeOptions(ephemeral, random, pss_salt)` mengisi `HandshakeOptions` dari context plus random per-koneksi (salt hanya dikonsumsi oleh CertificateVerify RSA). `allowsTls13` / `allowsTls12` membaca version range.

### validate (honesty boundary)

Menolak list curve / cipher kosong, curve di luar {X25519, SECP256R1}, cipher di luar {AES_128_GCM_SHA256, ECDHE_ECDSA_AES128_GCM_SHA256}, version range terbalik, ceiling 1.3 tanpa AES_128_GCM_SHA256, dan floor 1.2 tanpa suite 1.2 atau secp256r1. Error: `TlsUnsupportedCurve`, `TlsUnsupportedCipher`, `TlsInvalidVersionRange`, `TlsMissingCipherForVersion`, `TlsMissingCurveForTls12`, `TlsNoCurves`, `TlsNoCiphers`.

## pem.zig

`pemToDer(out, pem)` men-decode base64 satu blok PEM. `ecdsaScalarFromSec1` mengekstrak scalar privat 32-byte dari key EC SEC1. `ed25519SeedFromPkcs8` mengekstrak seed 32-byte setelah prefix PKCS#8 `04 22 04 20`.

## rsa.zig

Signer RSA (ADR-048), sisi server saja. `PrivateKey.fromDer(der, is_pkcs8)` mem-parse RSAPrivateKey two-prime (RFC 8017 A.1.2): wrapper PKCS#8 dibuka dulu ke OCTET STRING di dalamnya, lalu modulus `n` dan private exponent `d` disalin ke buffer tetap milik sendiri (leading-zero dibuang). `signPkcs1v15(message, out)` adalah jalur EMSA-PKCS1-v1_5 deterministik (RFC 8017 9.2): `0x00 01 PS 00 || DigestInfo || SHA256(message)`. `signPss(message, salt, out)` adalah EMSA-PSS (RFC 8017 9.1) dengan MGF1, salt diinjeksi oleh pemanggil sehingga encoding-nya deterministik dan bisa diuji unit. Keduanya berakhir di RSASP1, `s = m^d mod n` via `std.crypto.ff.Modulus.powWithEncodedExponent` (constant-time, jadi `d` tidak bocor), lalu I2OSP ke `k` byte. Prime CRT di-parse tetapi tidak dipakai (jalur `m^d mod n` polos hanya butuh `n` dan `d`).

## cert_verify.zig

`verifyChain(chain_der, anchor_der, now_sec)` memverifikasi chain [leaf, intermediate, ...] ke anchor: signature tiap link via std `Parsed.verify`, plus walk extension manual untuk basicConstraints (cA / pathLen), keyUsage (keyCertSign), dan penanganan critical-ext (wrapper extensions `[3]` terbaca sebagai tag `.bitstring` dari `std.crypto.Certificate.der.Element`, dicerminkan di sini). `verifyCertIdentity(end_entity_der, host)` mengecek DNS SAN (std `verifyHostName`) atau IPv4 SAN (`sanHasIp4`, men-scan GeneralName `0x87 0x04 <4 byte>`, karena std hanya DNS).

## tcp/http1/tls_serve.zig

`runTls` membaca `config.tls.?` (context) dan menjalankan accept loop. `serveConnTls(fd, handler, ctx)`:

1. baca record ClientHello, generate `ephemeral_secret` + `server_random` + `pss_salt` (getrandom), bangun `opts = ctx.handshakeOptions(...)`.
2. version policy: jika `!ctx.allowsTls13()`, langsung ke jalur 1.2 (ECDSA saja, jika tidak `Tls12RequiresEcdsa`).
3. ronde HelloRetryRequest jika `serverHelloRetry` mengembalikan satu, jika tidak `serverHandshake`. Saat `UnsupportedTlsVersion`: jika `!ctx.allowsTls12()` kirim alert `protocol_version`, jika tidak ambil jalur 1.2.
4. baca (ChangeCipherSpec) + client Finished, lalu satu record aplikasi -> `readAppData` -> `core.parseHead`.
5. Host vs identitas cert (`verifyCertIdentity`) -> 421 saat mismatch, jika tidak jalankan fd-handler lewat pipe dan `writeAppData` response, lalu `closeNotify`.

`readRecord` / `readAll` / `writeAll` memakai `std.os.linux.read` / `write` dengan switch errno (tanpa wrapper std.posix demi portabilitas lintas 0.16 / 0.17).

## tcp/http2/tls_serve.zig

`serveConnTls(routes, fd, config, opts, ctx)` menjalankan handshake dengan cara sama (version policy + fallback 1.2 ke `serveConnTls12H2`), memastikan ALPN memilih h2 (`AlpnNotH2` jika tidak), lalu menyiapkan socketpair: engine h2c yang tidak diubah (`core.serveConn`) berjalan di satu ujung dalam thread yang di-spawn, dan `pump` men-decrypt record masuk jadi plaintext untuk engine dan meng-encrypt frame engine kembali. Teardown memakai `shutdown(SHUT_WR)` supaya engine melihat EOF tanpa write yang berlomba dengan peer yang sudah ditutup.

## tls12_*.zig

Track 1.2 mencerminkan lapisan 1.3: `tls12_prf` (key schedule PRF SHA-256), `tls12_record` (AES-GCM 1.2 dengan nonce eksplisit 8-byte), `tls12_version` (`selectVersion` + downgrade sentinel di ServerHello.random, RFC 8446 4.1.3), `tls12_connection` (`serverFlight1` + `serverFinish`, ECDHE-ECDSA-AES128-GCM, secp256r1), dan `tls12_client`.
