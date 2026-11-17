# tlz low-level design

Detail internal per modul. Untuk arsitektur dan tujuan lihat [`hld-id.md`](hld-id.md).

tlz bersifat sans-I/O. Handshake server digerakkan oleh `connection.serverHandshake`, client oleh `client.zig` dan `tls12/client.zig`. Backend OpenSSL opsional ada di `openssl/` dan dijangkau lewat `binding.zig`. Pemanggil memiliki socket. Path di bawah relatif terhadap `src/tlz/src/` kecuali yang diawali `src/zix/`.

## Jenis file

File lower_snake_case berisi fungsi, file PascalCase adalah satu record. File fungsi memberikan record di direktori bernama sama: `connection.zig` me-re-export `connection/Connection.zig`, `connection/HandshakeOptions.zig`, dan seterusnya. Test ada di file yang diujinya dan dijalankan lewat `test.zig`.

## Error

Setiap modul yang bisa gagal mendeklarasikan `pub const Error` miliknya sendiri. Nama member berbentuk `Tlz_<Module>_<Condition>`, misalnya `Tlz_Context_KeyFileNotFound` atau `Tlz_Record_BadMac`. Modul tidak pernah meng-alias set error modul lain: error dari callee diterjemahkan ke member milik pemanggil, sekali, di fungsi publik pemanggil. Jadi `Context.init` melaporkan `Tlz_Context_InvalidKey`, bukan `Tlz_RsaPrivateKey_InvalidKey` yang diterimanya dari parser kunci. Dengan cara yang sama, `Context.initWith` mengubah `Tlz_OpensslContext_KeyMismatch` menjadi `Tlz_Context_KeyMismatch`, dan `Client.connectWith` mengubah `Tlz_OpensslClient_*` menjadi `Tlz_Client_*`.

## wire/

`Reader` dan `Writer` di atas slice byte milik pemanggil, big-endian. `Reader.readU8`, `readU16`, `readU24`, `readBytes` dicek batasnya dan gagal dengan `Tlz_WireReader_*`. `Writer.writeU8`, `writeU16`, `writeU24`, `writeBytes`, ditambah `placeU16` / `patchU16` dan `placeU24` / `patchU24` untuk mengisi panjang setelah body ditulis (dipakai untuk setiap field TLS yang panjangnya bervariasi). Tanpa alokasi.

## Enum wire

Satu file per enum: `cipher_suite.zig`, `named_group.zig`, `signature_scheme.zig`, `extension_type.zig`, `handshake/handshake_type.zig`, `record/content_type.zig`, `alert/description.zig`, `alpn.zig`. Setiap enum non-exhaustive (`_`), jadi nilai tak dikenal dari peer tetap ter-parse dan tidak gagal.

```zig
pub const CipherSuite = enum(u16) {
    AES_128_GCM_SHA256 = 0x1301,
    AES_256_GCM_SHA384 = 0x1302, // declared, not implemented
    CHACHA20_POLY1305_SHA256 = 0x1303, // declared, not implemented
    ECDHE_ECDSA_AES128_GCM_SHA256 = 0xc02b, // TLS 1.2 floor suite
    _,
};
```

`NamedGroup` berisi `SECP256R1` (0x0017) dan `X25519` (0x001d). `SignatureScheme` berisi `RSA_PKCS1_SHA256`, `ECDSA_SECP256R1_SHA256`, `RSA_PSS_RSAE_SHA256`, dan `ED25519`.

## handshake.zig

- `SERVER_CIPHER_PREFS = {AES_128_GCM_SHA256}` dan `SERVER_GROUP_PREFS = {X25519, SECP256R1}` adalah default bawaan.
- `parseClientHello(bytes)` mengembalikan `ParseResult`: record `ClientHello` yang sudah di-parse atau sebuah alert. Record itu menyimpan `offers_tls13` (dari supported_versions), ada tidaknya signature_algorithms dan supported_groups, body mentahnya, key share per group, `sni`, dan daftar ALPN mentah.
- `negotiate(hello, key_exchange, group_prefs)` mengembalikan `Outcome`: `legacy_version` jika 1.3 tidak ditawarkan (pemanggil turun ke jalur 1.2), alert jika extension wajib tidak ada, `hello_retry_request` jika curve terpilih tidak punya key share, selain itu `server_hello`. Group yang dipilih adalah yang pertama di `group_prefs` yang juga ditawarkan client, jadi `Context.curves` yang dibatasi atau diurutkan ulang tetap dihormati.
- `serializeServerHello` menulis supported_versions (0x0304) dan key_share. `serializeHelloRetryRequest` menulis HRR dengan random khusus (`HELLO_RETRY_REQUEST_RANDOM`, SHA-256 dari "HelloRetryRequest") dan key_share yang hanya menyebut group untuk dicoba ulang.

## key_schedule.zig

`Secret = [32]u8`, SHA-256 di semua tempat, jadi hanya suite AES-128-GCM / SHA-256 yang dilayani di 1.3. `key_schedule/Transcript.zig` adalah SHA-256 berjalan dari pesan handshake (`update`, `current`). `deriveSecret` dan `expandLabel` membangun early, handshake, dan master secret serta traffic key (RFC 8446 7.1) di atas `HkdfSha256`.

## record.zig

- `protect(out, plaintext, inner_type, key, iv, sequence)` membangun satu record AEAD. Nonce-nya `iv XOR sequence` (sequence 8 byte, rata kanan). Additional data-nya header record 5 byte. Inner plaintext-nya `content || inner_type` (RFC 8446 5.2).
- `protect2(out, head, tail, ...)` adalah bentuk gather: dua slice di-seal sebagai satu record, jadi header kecil dan body besar tidak perlu digabung oleh pemanggil. `protect` adalah `protect2` dengan tail kosong.
- `deprotect(out, record, key, iv, sequence)` membuka record, membuang zero padding, dan mengembalikan `Opened { inner_type, data }`. `data` menunjuk ke dalam `out`. Error: `Tlz_Record_BadMac`, `Tlz_Record_Overflow`, `Tlz_Record_Decode`.
- `MAX_PLAINTEXT = 16384`, `MAX_RECORD_WIRE = 17 KiB`, `sealedLen(n)` adalah ukuran wire dari `n` byte plaintext.

## crypto/certificate.zig

```zig
pub const SigningKey = union(enum) {
    ecdsa_p256: EcdsaP256.KeyPair,
    ed25519: Ed25519.KeyPair,
    rsa: RsaPrivateKey,

    pub fn scheme(self: SigningKey) SignatureScheme // ECDSA, ED25519, or RSA_PSS_RSAE_SHA256
};
```

Builder untuk Certificate, CertificateRequest, CertificateVerify, dan Finished. CertificateVerify menandatangani `0x20 * 64 || context string || 0x00 || transcript hash` (RFC 8446 4.4.3) dengan scheme milik kunci: ECDSA menghasilkan signature DER, Ed25519 64 byte mentah, RSA signature `rsa_pss_rsae_sha256`. `buildCertificateVerify` menerima salt PSS, jalur ECDSA dan Ed25519 mengabaikannya. `verify_data` Finished adalah `HMAC(finished_key, transcript hash)`, dicek byte per byte terhadap trace RFC 8448 di test file tersebut. `verifyClientCertificateVerify` adalah sisi mTLS.

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

Parse ClientHello, `negotiate`, isi transcript dengan ClientHello, lalu selesaikan: cek cipher adalah `AES_128_GCM_SHA256`, cek client menawarkan scheme milik signing key, negosiasi ALPN, jalankan key exchange untuk curve terpilih, tulis ServerHello, EncryptedExtensions, (CertificateRequest), Certificate, CertificateVerify, dan Finished, lalu turunkan application key ke dalam `Connection`. Hasilnya `HandshakeResult { connection, to_send, alpn }`. ClientHello yang hanya 1.2 mengembalikan `Tlz_Connection_UnsupportedTlsVersion`.

### HelloRetryRequest

`serverHelloRetry` bernegosiasi hanya untuk menemukan group. Jika retry dibutuhkan, ia men-serialize HRR dan mengisi transcript dengan `message_hash` sintetis dari ClientHello1 (`0xfe 00 00 <hash_len> || Hash(CH1)`, RFC 8446 4.4.1) diikuti HRR. Hasilnya `RetryFlight { to_send, state }`, atau null jika retry tidak dibutuhkan. `serverHandshakeAfterRetry` menerima ClientHello2, bernegosiasi lagi dengan `RetryState` yang dibawa, mengecek group-nya sama, dan menyelesaikan di atas transcript yang dibawa.

### Connection

Menyimpan application key, client handshake key, client Finished key, dan tiga nomor sequence (`server_app_seq`, `client_app_seq`, `client_hs_seq`).

- `writeAppData` dan `writeAppData2` melakukan seal dan menaikkan `server_app_seq`. Keduanya mengembalikan slice kosong jika `out` terlalu kecil.
- `readAppData` membuka dan mengklasifikasikan inner type (RFC 8446 5.1): application_data memberi plaintext, alert memberi `PeerClosed`, pesan handshake setelah handshake memberi `UnexpectedMessage`.
- `verifyClientFinished` mengecek client Finished terhadap transcript. `verifyClientCertFlight` dan `verifyClientAuthFlight` mengecek Certificate dan CertificateVerify client saat `request_client_cert` aktif.
- `closeNotify` dan `encryptedAlert` membangun alert keluar.

`alertForError` dan `alertRecordForError` memetakan error handshake ke alert yang harus dikirim (null jika tidak ada).

## context.zig

`Version = enum { TLS_1_2, TLS_1_3 }`, diurutkan supaya `min <= max` cukup dengan perbandingan biasa.

`Context.init(allocator, io, config)`:

1. `config.validate()`, tanpa I/O.
2. Baca kedua file PEM (`std.Io.Dir.cwd().readFileAlloc`, maksimal 1 MiB). File tidak ada, direktori, file terlalu besar, dan file tidak terbaca masing-masing punya error sendiri, untuk cert dan untuk key.
3. `pemToDer`, salin DER sertifikat ke slice milik sendiri.
4. Lewatkan sertifikat ke `der_guard.isSafeCertificate`, parse, lalu pilih pemuat kunci dari `pub_key_algo`: ECDSA lewat `ecdsaScalarFromSec1`, Ed25519 lewat `ed25519SeedFromPkcs8`, RSA lewat `RsaPrivateKey.fromDer` (PKCS#1 atau PKCS#8 menurut label PEM), ditolak jika di bawah RSA-2048 dengan `Tlz_Context_RsaKeyTooSmall`.

`handshakeOptions(ephemeral_secret, server_random, pss_salt)` mengisi `HandshakeOptions` dari context dan random per koneksi. `allowsTls13` dan `allowsTls12` membaca rentang versi. `deinit` membebaskan DER sertifikat.

### validate

Menolak daftar curve atau cipher kosong, curve di luar {X25519, SECP256R1}, cipher di luar {AES_128_GCM_SHA256, ECDHE_ECDSA_AES128_GCM_SHA256}, rentang versi terbalik, versi yang diizinkan tanpa suite untuknya, dan batas bawah 1.2 tanpa secp256r1. Error: `Tlz_ContextConfig_NoCurves`, `NoCiphers`, `UnsupportedCurve`, `UnsupportedCipher`, `InvalidVersionRange`, `MissingCipherForVersion`, `MissingCurveForTls12`. `Context.init` melaporkannya dengan prefix `Tlz_Context_`.

## crypto/pem.zig

`pemToDer(out, pem)` men-decode base64 satu blok PEM (maksimal `MAX_PEM_BYTES` base64). `ecdsaScalarFromSec1` mengambil scalar privat 32 byte dari kunci EC SEC1. `ed25519SeedFromPkcs8` mengambil seed 32 byte setelah prefix PKCS#8 `04 22 04 20`.

## crypto/der_guard.zig dan crypto/DerReader.zig

Pembaca DER sertifikat milik std tidak mengecek batas, jadi sertifikat terpotong dari peer bisa membuatnya membaca melewati ujung. `isSafeCertificate` menelusuri setiap elemen yang nanti dibaca std dan menolak sertifikat lebih dulu jika ada yang di luar batas. Setiap sertifikat dari peer atau dari file melewatinya sebelum std mem-parse. `DerReader.zig` adalah cursor kecil untuk dokumen kunci privat (tag, panjang pendek dan dua byte, magnitude INTEGER).

## crypto/rsa.zig, crypto/rsa/

std bisa memverifikasi RSA tapi tidak bisa menandatangani, jadi tlz menandatangani sendiri.

- `rsa/PrivateKey.zig`: `fromDer(der, is_pkcs8)` mem-parse RSAPrivateKey dua prima (RFC 8017 A.1.2), membuka OCTET STRING PKCS#8 lebih dulu. `n`, `d`, `p`, `q`, `dP`, `dQ`, dan `qInv` disalin ke buffer tetap milik sendiri, jadi kunci aman disimpan sebagai nilai.
- `signPkcs1v15(message, out)` adalah jalur EMSA-PKCS1-v1_5 yang deterministik (RFC 8017 9.2). `signPss(message, salt, out)` adalah EMSA-PSS dengan MGF1 (RFC 8017 9.1). Salt datang dari pemanggil, jadi signature deterministik terhadap inputnya dan bisa diuji.
- Keduanya berakhir di RSASP1 lewat Chinese Remainder Theorem (RFC 8017 5.1.2). `rsa/crt.zig` menjalankannya di limb Montgomery lebar tetap untuk kunci 2048, 3072, dan 4096 bit. Lebar lain memakai `std.crypto.ff`.

## crypto/montgomery.zig, crypto/montgomery/

Aritmetika Montgomery constant-time untuk sign CRT: perkalian, square khusus, reduksi, dan eksponensiasi modular fixed-window (window 5 bit untuk prima 3072 dan 4096). Jumlah iterasi tetap, setiap pengurangan bersyarat adalah masked select, dan tabel window dibaca dengan masked scan, jadi tidak ada rahasia yang mengarahkan branch atau alamat. Di x86_64 dengan ADX, `montgomery/asm_body.zig` membangun asm perkalian dan square saat comptime (MULX dengan dua rantai carry, ADCX di CF dan ADOX di OF). Di tempat lain perkalian CIOS portable melayani keduanya. Keduanya menghasilkan byte yang sama, dan signature-nya di-fuzz terhadap `std.crypto.ff`.

## crypto/cert_verify.zig, crypto/cert_verify/

- `verifyCertChain(end_entity_der, trust_anchor_der, now_sec)`: satu tautan, leaf terhadap issuer-nya (nama, masa berlaku, signature).
- `verifyChain(chain_der, trust_anchor_der, now_sec)`: rantai penuh [leaf, intermediate, ...] ke anchor. Setiap tautan lewat `verifyCertChain`, ditambah path constraint dari `cert_verify/PathConstraints.zig`: basicConstraints (cA, pathLen), keyUsage keyCertSign, dan penolakan extension critical yang tidak dikenal. std tidak menyediakan ini, jadi extension v3 ditelusuri manual dengan reader `der_guard`.
- `verifyCertHostname(end_entity_der, host)`: identitas DNS lewat std.
- `verifyCertIdentity(end_entity_der, host)`: SAN DNS, atau SAN iPAddress jika `host` adalah literal IPv4 (memindai GeneralName `0x87 0x04 <4 byte>`, karena std hanya mendukung DNS).

## client.zig, client/

`start(opts, out)` membangun ClientHello dari `client_random`, `ephemeral_secret`, dan penawaran ALPN, lalu mengembalikan byte-nya ditambah `State`. `finish(state, server_flight, out)` membaca flight server, memverifikasi CertificateVerify terhadap sertifikat server, mengecek Finished server, dan mengembalikan `FinishResult { connection, client_finished, alpn, ... }`. `verifyServerCert` pada hasil itu menjalankan cek rantai dan hostname. `ClientConnection` adalah cermin `Connection` server (`writeAppData`, `readAppData`, `closeNotify`).

## tls12/

Jalur 1.2 mencerminkan layer 1.3:

| File | Peran |
| :- | :- |
| `tls12/prf.zig` | PRF HMAC-SHA256: master_secret, key_block, verify_data Finished |
| `tls12/record.zig` | Record AES-GCM 1.2 dengan explicit nonce 8 byte |
| `tls12/version.zig` | `selectVersion` dan downgrade sentinel di ServerHello.random (RFC 8446 4.1.3) |
| `tls12/connection.zig` | server: `serverFlight1` menjawab ClientHello, `serverFinish` mengecek client Finished (ECDHE-ECDSA-AES128-GCM, secp256r1) |
| `tls12/client.zig` | client: `start` dan `finish` |

## dtls/

Jalur DTLS 1.2 (RFC 6347), publik sebagai `tlz.Dtls`. Pemanggil memiliki socket datagram dan timer-nya.

| File | Peran |
| :- | :- |
| `dtls/record.zig` | codec header, epoch, sequence 48 bit, proteksi AES-128-GCM, window anti-replay |
| `dtls/handshake.zig` | header handshake 12 byte, fragmenter, penelusur fragmen, reassembler |
| `dtls/hello.zig` | codec ClientHello dan HelloVerifyRequest |
| `dtls/cookie.zig` | cookie HMAC stateless untuk HelloVerifyRequest |
| `dtls/flight.zig` | timer retransmit dan state flight (RFC 6347 4.2.4) |
| `dtls/connection.zig` | server: pertukaran cookie, flight server, finish |
| `dtls/client.zig` | client: hello dengan dan tanpa cookie, finish |
| `dtls/exporter.zig` | ekspor kunci RFC 5705 dan pemecahan kunci SRTP RFC 5764 |
| `dtls/use_srtp.zig` | extension `use_srtp`: baca penawaran, pilih profil, tulis jawaban |

Tiga jebakan yang perlu diketahui:

- `dtls/connection.zig` membangun flight-nya sendiri dan hanya memakai ulang primitive dasar dari jalur 1.2. Transcript DTLS diambil atas header DTLS 12 byte seolah tidak terfragmentasi, tanpa ClientHello pertama dan HelloVerifyRequest (RFC 6347 4.2.6). Kesalahan di sini tidak terlihat sampai peer sungguhan menolak Finished.
- Window anti-replay di `dtls/record.zig` dicek sebelum AEAD dan diperbarui sesudahnya. Memperbarui lebih dulu akan membiarkan sequence palsu yang jauh di depan menghapus window.
- Ekspor DTLS-SRTP memakai bentuk seed tanpa context. Memberi slice context kosong menambahkan panjang nol dua byte dan merusak interop.

## binding.zig

`Binding` adalah `enum(u8) { DEFAULT, OPENSSL }`. `isBuilt(binding)` bernilai `true` untuk `.DEFAULT` dan mengikuti `c.ENABLED` untuk `.OPENSSL`. `requireBuilt(binding)` memunculkan `@compileError` (pasang paket dev libssl supaya `pkg-config openssl` menemukannya) jika backend tidak ikut di-build.

- `context/Context.zig`: `ContextFor(binding)` adalah `Self` untuk `.DEFAULT` dan `openssl/Context.zig` untuk `.OPENSSL`. `initWith(allocator, io, config, binding)` memanggil `init` atau `init` OpenSSL, dan menerjemahkan error OpenSSL ke `Tlz_Context_*`.
- `client.zig`: `ConnectionFor(.OPENSSL)` adalah `openssl/Connection.zig`, `.DEFAULT` adalah `@compileError` yang menunjuk ke `start` ditambah `finish`. `connectWith(ca_path, host, alpn_prefs, binding)` memanggil `openssl/client.connect` dan menerjemahkan error-nya ke `Tlz_Client_*`.
- `lib.zig` me-re-export `Binding`.

## openssl/

Backend OpenSSL. Hanya dikompilasi jika `build.zig` mendeteksi OpenSSL.

### Build

Probe ada di `scripts/OpensslProbe.zig` (tanpa `std.Build`, jadi program cek memakainya juga). `probe` mencoba `OPENSSL_DIR` (`<dir>/include/openssl/ssl.h` wajib ada, jika tidak `Tlz_OpensslProbe_EnvDirInvalid`), lalu `pkg-config --modversion openssl` dan `--variable=includedir`, lalu `/usr/include` dan `/usr/local/include` di host yang bukan Windows. Versi diambil dari `pkg-config`, jika tidak dari `OPENSSL_VERSION_STR` di `opensslv.h`. Path dirangkai dengan `std.fs.path.join`. `build.zig` menyediakan `detectOpenssl(b, target)` (mengembalikan `?OpensslProbe`), `linkOpenssl(b, target, optimize, module, openssl)`, `addOpensslCheck`, dan `addBuildHelperTests`. `detectOpenssl` mengembalikan null untuk target cross dan menulis satu baris log info: target cross, tidak terdeteksi, versi tidak diketahui, atau versi beserta sumbernya dan pemanggilan cek nama untuk jalurnya. Versi di bawah 3.5 atau `OPENSSL_DIR` yang tidak valid menghentikan build (`std.process.fatal`). Versi yang tidak diketahui tetap memakai binding, `c.zig` memeriksa batasnya lagi. Zig men-cache hasil configure, jadi `detectOpenssl` memantau `opensslv.h` yang ditemukan (`b.dependOnFileContents`) atau, jika tidak ditemukan, direktori include standar yang ada (`b.dependOnDirectoryMetadata`). Path yang tidak ada tidak pernah dipantau, karena Zig akan configure di setiap build. `zig build openssl-check` menjalankan `scripts/openssl_check.zig`: probe lagi, bandingkan dengan state saat configure (`none`, `unknown`, atau versinya), dan keluar dengan 1 jika berbeda. Hasilnya masuk ke modul `tlz_options` sebagai `openssl`. Zig 0.17 tidak punya `@cImport`, jadi `linkOpenssl` menulis header kecil (`ssl.h`, `err.h`, `x509v3.h`) ke build cache, menerjemahkannya dengan `addTranslateC` (dengan direktori include yang ditemukan), menambahkannya sebagai modul `openssl_c`, dan me-link libssl, libcrypto, dan libc (`libssl` dan `libcrypto` di target MSVC, belum diverifikasi di Windows). Dengan `OPENSSL_DIR`, direktori library ditambahkan dan `pkg-config` tidak dipakai untuk linking. Tidak ada header C yang disimpan di tree. `build.zig` root zix memanggil fungsi yang sama.

### c.zig

Satu-satunya yang meng-import `openssl_c`. `ENABLED` adalah `tlz_options.openssl`. `raw` adalah modul hasil terjemahan jika aktif, dan namespace kosong jika tidak. Blok `comptime` menolak `OPENSSL_VERSION_NUMBER` di bawah `0x30500000` (OpenSSL 3.5). `VERSION_MAJOR` adalah `OPENSSL_VERSION_MAJOR` (3 atau 4, 0 tanpa OpenSSL). Semua file openssl lain memakai `c.raw`, tidak pernah header OpenSSL secara langsung.

### error.zig

Membaca error queue OpenSSL, yang berlaku per thread. `clearQueue` dijalankan sebelum setiap pemanggilan OpenSSL supaya pembacaan berikutnya hanya melihat pemanggilan itu. `drainMatch(lib, reasons)` mengosongkan queue dan melaporkan apakah ada entri yang cocok dengan reason sebuah library (dipakai untuk kegagalan ALPN). `describe` dan `drainLastLine` menyalin baris yang bisa dibaca ke buffer milik pemanggil (`LINE_BUF_LEN = 256`), tidak pernah pointer C pinjaman. Teksnya untuk log, alur kontrol memakai kodenya. File ini tidak bisa gagal, jadi tidak punya set error.

### Context.zig

`SSL_CTX` server di atas `TLS_server_method`. `init(allocator, config)`:

1. Menyalin `cert_path` dan `key_path` ke buffer berakhiran nol (`PathTooLong` jika melebihi `PATH_MAX`).
2. `SSL_CTX_use_certificate_chain_file`, `SSL_CTX_use_PrivateKey_file`, dan `SSL_CTX_check_private_key` (`CertLoadFailed`, `KeyLoadFailed`, `KeyMismatch`).
3. Memetakan `min_version` dan `max_version` ke versi proto OpenSSL (`InvalidVersionRange`, `VersionSetFailed`).
4. Membangun daftar wire ALPN dengan `allocator` dan memasang select callback. Callback memilih protokol server pertama yang juga ditawarkan client (RFC 7301 3.2). Tidak ada irisan berarti alert fatal `no_application_protocol`, sama seperti server native.

Curve dan cipher memakai default OpenSSL. `newConnection` mengembalikan `Connection` server. `deinit` membebaskan `SSL_CTX` dan daftar ALPN. `Connection` yang masih hidup menjaga `SSL_CTX` tetap hidup, tapi tidak daftar ALPN, jadi bebaskan semua koneksi sebelum context.

### Connection.zig

Field: `ssl`, `network_in`, `network_out`. `SSL_set_bio` memasang dua memory BIO: byte dari peer ditulis ke `network_in`, OpenSSL menulis byte yang harus dikirim ke `network_out`. `initServer` dan `initClient` mengatur state accept atau connect.

- `handshake(incoming, out)`: tulis `incoming` ke `network_in`, jalankan `SSL_do_handshake`, lalu `drain(out)`. `WANT_READ` dan `WANT_WRITE` bukan error, keduanya mengembalikan apa pun yang mengantre (bisa kosong). Client mulai dengan `incoming` kosong, yang menghasilkan ClientHello.
- Handshake yang gagal dipetakan dengan urutan ini: `ZERO_RETURN` ke `PeerClosed`, hasil verify yang buruk ke `PeerVerifyFailed`, reason ALPN di queue ke `NoProtocolNegotiated`, selain itu `HandshakeFailed`. Alert mungkin masih mengantre setelah error, jadi `drain` untuk memberi tahu peer.
- `pendingLen` dan `drain`: OpenSSL bisa mengantrekan lebih dari kapasitas `out` (flight besar, alert, session ticket setelah read). Lakukan `drain` sampai `pendingLen` bernilai 0 sebelum menunggu peer.
- `writeAppData`, `readAppData`, `closeNotify`, `selectedAlpn` adalah cermin dari `Connection` native. `readAppData` mengembalikan slice kosong sampai satu record penuh tiba. Input yang lebih panjang dari `c_int` adalah `InputTooLarge`.
- `deinit` memanggil `SSL_free`, yang membebaskan kedua BIO.

### client.zig

`connect(ca_path, host, alpn_prefs)` membangun `SSL_CTX` baru di atas `TLS_client_method` untuk setiap pemanggilan:

1. `SSL_CTX_load_verify_file(ca_path)` dan `SSL_VERIFY_PEER` (`CaLoadFailed`).
2. Versi minimum TLS 1.2 (`VersionSetFailed`).
3. Satu `Connection` client. Context dibebaskan di akhir `connect`, `SSL` menyimpan referensinya sendiri.
4. `host` wajib (`HostMissing`, karena OpenSSL akan melewati cek nama jika host kosong) dan paling panjang 253 byte (`HostTooLong`). Nilainya dipasang sebagai SNI (`SSL_set_tlsext_host_name`) dan sebagai nama yang diverifikasi: `SSL_set1_dnsname` di 4.x, `SSL_set1_host` di 3.x, dipilih saat compile dari `c.VERSION_MAJOR`. Aturan host kedua pemanggilan itu berbeda (lihat tabel di [`hld-id.md`](hld-id.md#model-backend)).
5. Penawaran ALPN, jika tidak kosong (`AlpnTooLong`, `AlpnSetFailed`).

`Connection` yang dikembalikan belum melakukan handshake. `handshake(&.{}, out)` pertama menulis ClientHello.

### Test

Test unit dan edge ada di setiap file dan dilewati dengan `error.SkipZigTest` jika OpenSSL tidak ikut di-build. Test untuk satu jalur OpenSSL dilewati di jalur lain dengan satu baris info, contohnya `OpenSSL 3.x only (found 4.x), test skipped`. Test loopback menjalankan client OpenSSL melawan server OpenSSL dalam satu proses: TLS 1.2 dan 1.3, ALPN (urutan server, tanpa irisan), hostname yang tidak cocok, chain yang tidak dipercaya, dan close_notify. Test cek silang memakai tool `openssl s_client` dan `openssl s_server` sebagai peer. Test ALPN parity menjalankan `s_client` (menawarkan h2 dan http/1.1) melawan server native dan server OpenSSL dengan urutan server yang sama, dan mengharapkan protokol yang sama dari keduanya.

## Pemakaian di zix

zix memiliki socket. File-file ini ada di `src/zix/` dan memanggil tlz.

### src/zix/tls/tls_session.zig

Session server TLS 1.3 yang bisa dilanjutkan, digerakkan satu worker untuk banyak koneksi. `Session.feed(input, to_send_buf, plain_buf)` menerima ciphertext saat tiba, menahan record yang belum lengkap, dan mengembalikan `FeedResult { to_send, plaintext, outcome }`. Fase berjalan `hello -> finished -> established -> closed`: `hello` memanggil `serverHandshake` dan mengirim flight, `finished` memverifikasi client Finished, `established` membuka application data. Hanya TLS 1.3, ClientHello yang hanya 1.2 ditolak dengan alert fatal.

### src/zix/multiplexers/tls_conn.zig

Transport bersama untuk loop multiplexed: session ditambah buffer ciphertext keluar. Penulisan yang terkena `EAGAIN` ditahan dan `EPOLLOUT` dipasang, jadi penulisan tidak pernah mem-block worker. `conn_table.zig` memetakan fd ke koneksinya.

### Http1

- `.EPOLL` / `.URING`: `src/zix/tcp/http1/tls_mux.zig`. Satu listener `SO_REUSEPORT` dan satu instance epoll per worker. Setiap koneksi mengakhiri TLS di tempat: baca ciphertext, `session.feed`, jalankan request lewat `tls_feed.zig`, seal balasan, kirim. SSE dan WebSocket berjalan di loop yang sama lewat stream sink koneksi. Hanya TLS 1.3.
- `.ASYNC`: `src/zix/tcp/http1/tls_serve.zig`. Satu task per koneksi menjalankan handshake (1.3, atau jalur 1.2 untuk client yang hanya 1.2, dalam rentang versi context), lalu loop request keep-alive. Handler menulis ke sink di memori. Response yang melebihi buffer itu, stream SSE, dan WebSocket keluar lewat `TlsStreamSink.zig`, di-seal satu tulisan per kali.
- Broadcast WebSocket lewat TLS: `TlsPeers.zig` memetakan fd ke koneksi TLS-nya, jadi tulisan ke koneksi lain di-seal dengan session koneksi itu, di bawah lock per slot.
- Misdirected request (RFC 9110 7.4): header Host (tanpa port) dicek terhadap sertifikat dengan `verifyCertIdentity`. Jika tidak cocok, dikembalikan `421 Misdirected Request` lalu koneksi ditutup.

### Http2 dan Grpc

- `.EPOLL` / `.URING`: `src/zix/tcp/http2/tls_mux.zig` dan `src/zix/tcp/http2/grpc/tls_mux.zig`. Bentuk worker sama dengan Http1. Setelah session established, plaintext diberikan ke mux h2 atau gRPC, dan frame mux di-seal kembali menjadi record lewat `write_hook` milik writer.
- `.ASYNC`: `src/zix/tcp/http2/tls_serve.zig` dan `src/zix/tcp/http2/grpc/tls_serve.zig`. Accept loop memberikan setiap koneksi ke task-nya sendiri, yang memanggil `src/zix/tls/h2_terminator.zig`. Terminator menjalankan handshake (1.3, atau 1.2 sebagai fallback), mewajibkan ALPN h2, memverifikasi client Finished, lalu menyerahkan koneksi ke driver (`MuxDriver.zig` untuk h2, `mux_driver.zig` untuk gRPC) yang menjalankan mux langsung di atas record yang sudah didekripsi. Tanpa socketpair, tanpa thread kedua.

### Dual listener

Jika `tls_port` diisi di samping `tls`, satu server melayani cleartext di `port` dan TLS di `tls_port` dari worker yang sama. Di `.EPOLL` koneksi TLS bergabung ke loop epoll cleartext. Di `.URING` koneksi TLS berjalan di ring (`dispatch/UringTlsConn.zig` untuk h2 dan gRPC). Di `.ASYNC` accept loop kedua menjalankan serve path TLS.
