# LLD: zix.Webrtc

Detail implementasi internal untuk engine WebRTC. Untuk alasan desainnya lihat [`docs/hld-webrtc-id.md`](hld-webrtc-id.md).

Engine ini berlapis. Setiap lapis adalah format wire terpisah dengan RFC-nya sendiri, dan satu berkas memiliki satu format. Setiap modul deterministik membawa test-nya di dalam berkas, dan lapis yang punya test vector terbit dipatok byte demi byte terhadapnya.

---

## demux.zig

Byte pertama menentukan protokol yang dibawa sebuah datagram (RFC 7983 bagian 7).

- `classify(datagram) Kind` di atas rentang byte pertama: `STUN` untuk `[0..3]`, `ZRTP` untuk `[16..19]`, `DTLS` untuk `[20..63]`, `TURN_CHANNEL` untuk `[64..79]`, `RTP` untuk `[128..191]`, selain itu `DROP`.
- Yang dipakai adalah **revisi RFC 7983**, bukan teks RFC 5764 yang digantikannya. STUN melebar dari `[0..1]`, dan TURN serta ZRTP adalah rentang baru.
- Routing bukan validasi. Pemeriksaan magic cookie tetap di `stun/message.zig`, jadi datagram yang tampak seperti STUN dari byte pertamanya masih harus lolos parse sebagai STUN.

---

## Lapis: STUN

### stun/message.zig

Container RFC 8489.

- `parse` memvalidasi **seluruh region attribute di muka**, sehingga iterasi sesudahnya tidak bisa gagal.
- Framing bersifat ketat: byte sisa adalah error, dan padding attribute terakhir wajib. Longgarkan hanya berdasarkan capture sungguhan, bukan dugaan.
- Mask XOR-MAPPED-ADDRESS diterapkan ke byte port lalu byte address, dengan `mask[0..] = cookie ++ transaction_id`. `% 4` pada offset address adalah bug yang mudah terjadi. Dipatok oleh vector byte demi byte `192.0.2.1:32853 -> 00 01 A1 47 E1 12 A6 43`, yang tidak boleh diganti hanya dengan test round-trip.
- `addMessageIntegrity` / `messageIntegrity` ada di sini, bukan di `ice/`, karena MAC-nya menutupi **prefix** pesan dan butuh field length di header ditulis ulang di tengah perhitungan, persis seperti FINGERPRINT yang sudah ada di berkas ini. Berkas terpisah akan terpaksa membuka internal writer-nya.

### stun/binding.zig

Aturan request RFC 8489 bagian 6.3.1.

- `respond(datagram, peer, out) ?[]const u8` adalah fungsi murni di atas byte, jadi tidak butuh socket maupun engine.
- Ia mengembalikan null untuk **keduanya**, yaitu silent discard dan buffer yang terlalu kecil, itulah alasan `MAX_RESPONSE_BYTES` dipublikasikan.

---

## Lapis: ICE-lite

### ice/candidate.zig

`Type` / `Transport` / `Component`, `priorityOf`, `writeFoundation`.

- `256 - @intFromEnum(component)` pada formula prioritas **tidak** terkompilasi: tag enum-nya `u8` dan 256 tidak muat. Lebarkan tipenya dulu.

### ice/credentials.zig

Aturan ufrag dan password, pemisahan dan penulisan USERNAME, `fillIceChars`.

- USERNAME berbunyi `<ufrag tujuan>:<ufrag pengirim>`. Pada check yang **datang**, paruh pertama adalah milik agent ini. Membacanya terbalik menolak setiap check yang sah.

### ice/check.zig

Empat atribut ICE plus `read`, `writeRequest`, `requestLen`.

- MAC-nya dipatok ke sample request RFC 5769 bagian 2.1 (password `VOkJxbRl1RmTxUk/WvJxBt`, username `evtj:h6vY`), yang juga membawa PRIORITY dan ICE-CONTROLLED. Satu vector memaku MAC, CRC, dan dua dari empat tipe atribut. FINGERPRINT-nya menutupi setiap byte sebelum MAC, jadi CRC yang bersih membuktikan transkripsi sebelum MAC dinilai sama sekali. Pertahankan vector itu.

### ice/lite.zig

`Responder.respond` mengembalikan `Outcome{ reply, authenticated, nominated }`.

- Field length di header ditulis ulang supaya **berakhir di MESSAGE-INTEGRITY** selagi MAC dihitung, itulah yang membuat FINGERPRINT bisa ditambahkan sesudahnya tanpa merusaknya.
- Lite agent menjawab 487 untuk **setiap** nilai tiebreaker, karena ia tidak punya role untuk ditukar (RFC 8445 bagian 6.1.1). Tidak ada field tiebreaker di berkas ini.
- Urutan pemeriksaan mengikuti RFC 8489 bagian 6.3: autentikasi, lalu atribut tak dikenal, lalu aturan ICE. 400 dan 401 keluar **tanpa tanda tangan** (belum ada kunci terverifikasi), 420 dan 487 ditandatangani.
- Nominasi diambil hanya ketika respons benar-benar dihasilkan, jadi buffer yang terlalu kecil membiarkan pair tidak terpilih dan peer mengulang kirim.
- `Responder.remote_ufrag` bernilai null adalah hasil dari `accept_any_peer_ice_ufrag`. State string kosong tidak dipakai ulang untuk itu: `""` tetap berarti menolak semua orang.

---

## Lapis: DTLS 1.2 (di `src/tls/`)

Sembilan berkas, prefix datar `dtls_`, bersebelahan dengan kode TLS yang primitifnya dipakai bersama.

### dtls_record.zig

Header 13 byte, epoch, sequence 48 bit, AEAD, anti-replay, plus `writePlaintext` untuk epoch 0.

- Anti-replay harus **isNew sebelum AEAD, lalu accept sesudahnya**. Menggabungkannya jadi satu langkah membuat sequence palsu yang jauh di depan membersihkan window.

### dtls_handshake.zig

Header 12 byte, `Fragmenter`, dan `Reassembler` yang aman terhadap tumpang tindih.

- Perakitan ulang melacak **byte mana yang sudah datang** dengan bitmap, bukan berapa banyak, karena fragment yang tumpang tindih itu sah.

### dtls_hello.zig

ClientHello dengan field cookie, plus HelloVerifyRequest.

- ClientHello DTLS membawa vector cookie di antara `session_id` dan `cipher_suites`, jadi parser TLS salah mengurainya.

### dtls_cookie.zig

Cookie HMAC stateless dengan rotasi.

### dtls_flight.zig

Timer retransmit dan state machine RFC 6347 bagian 4.2.4.

### dtls_exporter.zig

Ekspor keying material RFC 5705 plus pemisahan kunci SRTP RFC 5764.

- RFC 5705 punya **dua** bentuk seed dan DTLS-SRTP memakai bentuk **tanpa context**. Mengoper slice kosong menambahkan dua byte nol dan diam-diam merusak interop.

### dtls_use_srtp.zig

Ekstensi `use_srtp` RFC 5764. Ia tinggal di `src/tls/` karena ia ekstensi TLS, bukan konsep WebRTC.

### dtls_connection.zig

Driver sisi server: flight 2, 4 dan 6.

- Ia menyusun flight-nya **sendiri** dan hanya memakai ulang primitif daun (`tls12_prf`, certificate plus penandatanganan ECDSA, ECDHE P-256). `tls12_connection.zig` tidak disentuh, karena berkas itu meng-hash byte berbingkai TLS sementara RFC 6347 bagian 4.2.6 menuntut transcript di atas header DTLS 12 byte seolah tidak terfragmentasi, tanpa ClientHello pertama dan HelloVerifyRequest.
- `HandshakeOptions.first_record_seq` ada karena pertukaran cookie tetap stateless dengan menjawab pada sequence tempat ClientHello-nya tiba, dan server flight setelah itu harus melanjutkan penomoran tersebut, bukan mulai lagi dari 0.
- Kunci SRTP diekspor di dalam `serverFinish` lewat `dtls_exporter.srtpKeys` ketika `use_srtp` dinegosiasikan.

### dtls_client.zig

Sisi client, supaya `examples/webrtc/webrtc_native_pair.zig` bisa memanggil. Ia **tidak** memvalidasi certificate: RFC 8122 membawa fingerprint di luar jalur dan belum ada yang memeriksanya.

---

## dtls_session.zig

Sequencer DTLS per peer, sisi WebRTC dari handshake.

- `Session.next_record_seq` dibawa melewati HelloVerifyRequest, itulah yang menjaga seluruh flight berada pada satu record sequence monoton.
- `acceptFragment` mereset reassembler hanya pada `message_seq` atau `msg_type` yang **berbeda**. Mereset sebelum setiap accept menghapus fragment pertama dari ClientHello dua fragment, yang tak terlihat terhadap OpenSSL (206 byte, satu record) dan fatal terhadap browser (sekitar 1500 byte, selalu dua).

---

## Lapis: SCTP

Dua puluh berkas di bawah `sctp/`, dikelompokkan berdasarkan concern, bukan bagian RFC. Jangan digabung kembali.

| Kelompok | Berkas |
| :- | :- |
| wire | `checksum`, `chunk`, `parameter`, `packet` |
| control | `init`, `cookie`, `error_cause`, `teardown`, `heartbeat` |
| data | `serial`, `data`, `sack`, `reassembly` |
| reliability | `rto`, `congestion`, `receive_queue`, `send_queue`, `forward_tsn` |
| driver | `reconfig`, `association` |

`association.zig` adalah driver-nya: handshake 4 arah penuh, aliran data, heartbeat, shutdown 3 langkah, dan abort. `Association.init` plus `connect` menentukan sisi mana yang ia perankan.

Jebakan yang perlu diingat:

- CRC32c masuk ke paket dalam **little endian** sementara setiap integer SCTP lain memakai network order (RFC 9260 Appendix A menukar byte lalu memanggil `htonl`, dan keduanya saling meniadakan). Polinomialnya **Castagnoli**, bukan IEEE yang dipakai FINGERPRINT STUN.
- zig 0.17 mengganti nama entri katalog `Crc32Iscsi` menjadi `@"CRC-32/ISCSI"`, dipilih dengan `@hasDecl` di `checksum.zig`. Perhatikan penggantian nama katalog lain pada setiap pemakaian `std.hash` yang baru.
- Gap ack block adalah **offset** dari cumulative TSN, bukan TSN.
- Missing report hanya dihitung **di bawah** TSN tertinggi yang baru di-ack. Menghitung di atasnya akan mengirim ulang data yang masih terbang.
- Algoritma Karn ditegakkan di `send_queue.zig`, karena `rto.zig` tidak bisa melihat retransmit.
- Ack yang hanya berupa gap block ditandai **belum dibebaskan**: peer boleh menarik kembali.
- Menolak menampung sebuah chunk berarti **tidak meng-ack TSN-nya**. Itulah satu kesalahan yang tidak bisa dipulihkan di sini.
- `cwnd` bertambah hanya selagi terpakai penuh.

`association.zig` juga membawa wiring rekonfigurasi yang digerakkan lapis data channel: `Outcome.reconfig`, `sendReconfig`, `resetOutboundStream`, `lastAssignedTsn`, `cumulativeTsn`, `peerInitialTsn` (urutan reset request dimulai dari TSN pertama peer) dan `supportsReconfig`.

---

## Lapis: data channel

Tujuh berkas di bawah `datachannel/`.

- `payload.zig`: tujuh PPID dan konvensi pesan kosong.
- `dcep.zig`: codec OPEN dan ACK.
- `stream_id.zig`: genap atau ganjil menurut role DTLS.
- `channel.zig`: satu channel plus pemetaan opsi DCEP ke SCTP.
- `registry.zig`: tabel dan admission control.
- `reset.zig`: driver RFC 6525.
- `peer.zig`: driver-nya, diuji dengan dua peer bicara di memori.

Jebakan yang perlu diingat:

- Payload pesan dari `nextEvent` mati pada panggilan **berikutnya**, karena reassembler membebaskannya.
- Pesan harus dilaporkan **sebelum** penutupan. Sebuah reset menunggu semua yang ada di depannya (RFC 6525 bagian 5.2.2), jadi melaporkan penutupan lebih dulu akan menghilangkan pesan terakhir.
- RE-CONFIG **tidak membawa TSN**, jadi ia menyalip DATA yang masih dikirim ulang. Itulah alasan pemrosesan reset ditunda.
- Role DTLS menentukan identifier genap atau ganjil, dan salah di sini tidak terlihat secara lokal: setiap open berhasil dan peer sungguhan menolak semuanya.
- Pesan kosong adalah satu byte nol di bawah PPID-nya sendiri, dan penerima membuang byte itu.

Keputusan: satu reset request menyebut **satu** stream (reader menerima daftar, karena peer boleh membundel). SSN Reset yang masuk dijawab DENIED, karena RFC 8831 bagian 6.7 menutup dengan mereset stream keluar milik **pengirim**. Penutupan yang ditolak akan memensiunkan identifier-nya, dan memanggil `closeChannel` lagi adalah cara meminta ulang. Tidak ada timer yang diciptakan untuk itu.

---

## Lapis: SDP

Delapan belas berkas di bawah `sdp/`, terbagi menjadi codec container dan codec media section.

| Berkas | Memiliki |
| :- | :- |
| `line.zig` | baris `x=value` dan kedua terminatornya |
| `attribute.zig` | bentuk flag dan value pada `a=` plus pencarian region |
| `address.zig` | `IN IP4 x` dan teks IPv6 RFC 5952 |
| `media.zig` | baris `m=` dan bentuk data channel |
| `session.zig` | level session terhadap media section |
| `fingerprint.zig` | RFC 8122, lima fungsi hash, hitung dari DER |
| `setup.zig` | role RFC 4145 |
| `candidate.zig` | `a=candidate` di atas model candidate ICE |
| `builder.zig` | line appender bersama |
| `direction.zig` | RFC 3264 bagian 6.1 |
| `rtpmap.zig`, `fmtp.zig`, `rtcp_feedback.zig`, `format.zig` | satu payload type yang terkumpul |
| `media_offer.zig`, `media_answer.zig` | membaca dan menulis satu media section |
| `offer.zig`, `answer.zig` | keseluruhan offer dan keseluruhan answer |

Jebakan yang perlu diingat:

- Terima CRLF **dan** LF telanjang saat membaca (RFC 8866 bagian 5 meminta toleransi, dan jalur signalling sering membuang CR). Tulis CRLF.
- Cari atribut **di media section lebih dulu**, baru level session. Browser meletakkan credential ICE dan fingerprint di section, RFC meletakkannya di level session.
- Port pada `m=` dan `a=sctp-port` adalah angka yang berbeda.
- Baris origin selalu menyebut `IN IP4 0.0.0.0` (RFC 8829 bagian 5.2.1 dan RFC 8828), tidak pernah alamat sebenarnya.
- `a=tls-id` ditulis hanya jika offer-nya punya (RFC 8842 bagian 5.3). Browser tidak mengirimnya.
- Nama fungsi hash **dan** transport candidate dibandingkan tanpa memperhatikan huruf besar kecil, karena RFC dan browser berbeda pendapat soal kapitalisasi.
- `a=sctp-port` yang hilang adalah error (RFC 8841 bagian 5.1). `a=max-message-size` yang hilang berdefault 64 KB, dan nilai 0 berarti ukuran bebas.
- `MAX_SESSION_ID` membatasi session id pada baris origin di 62 bit, karena RFC 8829 bagian 5.2.1 menuntut yang muat di integer 64 bit **bertanda**. `u64` rentang penuh membuat Firefox menolak seluruh answer sekitar separuh waktu.
- **`media_answer.zig` menulis `a=candidate` plus `end-of-candidates` di setiap section yang dibawa.** Browser membaca candidate remote dari section bertanda BUNDLE, yang berupa media section ketika media ditawarkan. Tanpa itu peer punya credential dan tidak punya alamat, lalu ICE gagal tanpa satu datagram pun terkirim.
- `offer.zig` mewajibkan adanya data channel section dan menjawab `error.ZixNoDataChannel` bila tidak ada, jadi halaman browser harus memanggil `createDataChannel` bersama media-nya.

Kebijakan: media ditolak secara default. Format yang ditawarkan **diulang, bukan dipilih**, karena engine ini tidak punya codec sehingga tidak punya pendapat. `rtx` (RFC 4588) dibuang, karena butuh riwayat paket yang tidak ada. Feedback dijawab hanya bila ia ditawarkan **dan** diimplementasikan, yaitu `nack` dan `nack pli` saja. `a=rtcp-mux` diwajibkan, karena socket-nya satu.

---

## Lapis: media

Enam belas berkas di bawah `media/`. Ekstensi `use_srtp` sendiri berupa `dtls_use_srtp.zig` di `src/tls/`, terhitung bersama berkas DTLS di atas, karena ia ekstensi TLS dan bukan konsep WebRTC.

| Berkas | Memiliki |
| :- | :- |
| `profile.zig` | tabel parameter RFC 5764 bagian 4.1.2 |
| `rtp.zig` | header RFC 3550 bagian 5.1 plus setter in-place |
| `mux.zig` | RFC 5761, RTP terhadap RTCP |
| `rtcp.zig`, `report.zig`, `feedback.zig` | framing compound, SR dan RR, NACK dan PLI RFC 4585 |
| `srtp_cipher.zig`, `srtp_key.zig`, `srtp_auth.zig`, `srtp_index.zig` | AES-CM, KDF, HMAC-SHA1 terpotong, ROC plus replay |
| `srtp.zig`, `srtcp.zig` | protect dan open untuk media dan control |
| `forward.zig` | `open`, `reseal`, dan `relay` sebagai komposisinya |
| `stream_set.zig` | satu `srtp.Session` per stream identifier, per arah |
| `route.zig` | sumber mana yang mengisi stream mana pada satu penerima |
| `peer_media.zig` | seluruh state media satu peer |

Inilah lapis dengan **bukti eksternal sungguhan**. Tiga vector terbit dipatok byte demi byte: RFC 3711 B.2 (keystream AES-CM sepanjang 3 blok, yang sekaligus membuktikan block counter maju), RFC 3711 B.3 (cipher key, salt, dan auth key 94 byte penuh sepanjang 6 blok), dan RFC 2202 kasus 1 (HMAC-SHA1, yang kuncinya 20 byte, persis panjang session auth key).

Jebakan yang perlu diingat:

- Byte label KDF di-XOR ke `master_salt` pada **byte 7**, karena key id 7 byte dan salt 14 byte disejajarkan di ujung bawahnya. Offset yang salah menghasilkan kunci yang tampak acak dan tidak cocok dengan apa pun.
- `SRTP_AES128_CM_HMAC_SHA1_32` punya **tag RTCP 80 bit dan tag RTP 32 bit**. Satu profile, dua panjang tag, dan memakai satu angka saja hanya merusak RTCP.
- ROC ditebak dan tidak pernah dikirim, jadi `estimate` bersifat murni dan `accept` adalah panggilan kedua **setelah** autentikasi. Kalau tidak, nomor urut palsu akan menyeret counter maju dan mengunci stream yang asli.
- SRTCP memberi tag **setelah** menambahkan word flag-dan-index.
- Index SRTCP **berhenti** di 2^31 alih-alih berputar, karena index yang dipakai ulang berarti counter block yang dipakai ulang.

### stream_set.zig

`MAX_STREAMS = 8` per arah per peer, `sessionFor(ssrc)` membuat saat pertama dipakai, `find`, `overhead`.

Satu session **per stream identifier**, bukan per peer, karena rollover counter dan daftar replay bersifat per-SSRC. Audio dan video yang berbagi satu session membaca nomor urut satu sama lain sebagai lubang atau wrap lalu menolak paket yang sah.

### route.zig

`MAX_ROUTES = 8` per peer penerima. Sebuah `Route` memegang `source_ssrc`, `forward.Mapping`-nya, sequence dan timestamp terakhir yang ia kirim, serta `started`.

`Table.admit(source_ssrc)` berdefault ke pemetaan identitas. `switchSource(carried_ssrc, source_ssrc, first)` melakukan swap-remove pada entri yang sudah mengisi carried SSRC itu, sehingga satu stream keluaran punya tepat satu sumber dan permintaan keyframe tidak pernah dikirim ke peer yang sudah berhenti.

### forward.zig

`relay` adalah komposisi dua paruh yang harus bisa dipisah:

- `open(source, buffer, packet_len)` membuka proteksi in-place.
- `reseal(destination, mapping, buffer, body_len)` menulis ulang SSRC, sequence dan timestamp lewat mapping, lalu memproteksi untuk tujuan tersebut.

Satu fan-out membuka **sekali** dan menyegel ulang untuk tiap penerima. Memanggil `open` dua kali pada paket yang sama adalah replay atas index yang sudah diterima stream sumber.

### peer_media.zig

Kedua stream set (`inbound` berkunci `client_write_*`, `outbound` berkunci `server_write_*`, karena zix selalu menjadi DTLS server), kedua session SRTCP, dan tabel route.

`sealFor(header, buffer, body_len)` menerima route-nya, memilih session outbound berdasarkan SSRC yang **dibawa**, menyegel ulang, lalu mencatat apa yang ia kirim.

---

## connection.zig

Satu peer yang menjawab, dan berkas yang mengikat semua lapis.

- `Options.srtp_profiles` kosong kecuali server membawa media. Ketika kosong, `media_buf` dialokasikan dengan panjang nol, jadi server yang hanya membawa data channel tidak membayar apa pun untuk jalur media.
- `Outcome` mendapat `media` dan `keyframe_requested` supaya worker bisa bertindak tanpa mengurai ulang.
- `isNewSource` bernilai true untuk tepat satu paket setelah sebuah route diterima, itulah yang memicu permintaan keyframe.
- `FORWARDER_SSRC` adalah identifier yang dipakai zix ketika ia berbicara RTCP atas namanya sendiri.
- Batch keluar **tidak** direset di awal `handle`. Melakukan itu menghilangkan balasan ketika driver menyerahkan beberapa datagram tanpa menguras di antaranya, dan itu cacat yang pernah dikirim engine ini.

---

## dispatch/

- `worker.zig` memegang loop untuk ketiga model: `serve`, `sweep`, `flush`, `waitMs`, `sweepDue`, plus `forwardMedia`, `forwardKeyframeRequest`, `requestKeyframe` dan `queueDatagram`. Urutan pengurasan adalah properti kebenaran, jadi ia tinggal di sini sekali saja.
- `common.zig` hanya substrate: `optionsFrom`, penyiapan socket, pengukuran buffer. `sendBufBytes` adalah `@max(max_recv_buf + srtp.MAX_OVERHEAD, path_max_bytes + DTLS_OVERHEAD + 64)`.
- `async.zig`, `epoll.zig`, `uring.zig` masing-masing memegang loop sungguhannya sendiri dan tidak lebih. URING mengirim 64 `recvmsg` one-shot plus satu timeout, dan pengiriman dikuras dengan `sendmmsg`. Multishot, provided buffer ring, dan send ring dua-buffer yang dibawa HTTP/3 sengaja tidak ada: belum ada pengukuran yang memintanya dan engine ini belum punya baseline untuk dipertahankan.
- `test_session.zig` adalah perancah khusus test yang memegang sisi pemanggil, dipakai bersama oleh kedua model Linux sehingga perbedaan di antara keduanya adalah perbedaan pada loop. Preseden untuk berkas khusus test di bawah `src/` adalah `src/driver/*/tests/`.

Badan loop tiap model adalah method `pass()` (satu tunggu plus apa pun yang ia bawa), sehingga sebuah test bisa mem-bind socket sungguhan dan menjalankan sesi utuh terhadapnya dengan `Dialer` sungguhan, di bawah `zig build test-all`, bukan hanya di leg runner.

---

## table.zig, timer.zig, fanout.zig

- `table.zig`: address ke connection, dan ia memiliki connection-nya. Pencarian berupa penelusuran atas `max_peers` (puluhan, bukan ribuan), jadi belum ada tabel peer berkunci hash.
- `timer.zig`: empat deadline, `DTLS_RETRANSMIT`, `SCTP_RETRANSMIT`, `ICE_CONSENT`, `IDLE`.
- `fanout.zig`: hanya `Sink` (`*anyopaque` plus satu fungsi deliver, idiom yang sama dengan `TlsSink` di `src/tcp/http1/core.zig`). Penelusurannya sendiri tinggal di `worker.zig`, karena tabel peer adalah milik worker dan `core.zig` tidak bisa mengimpornya (tabel mengimpor connection, yang mengimpor core).

---

## server.zig dan config.zig

`server.zig` memvalidasi sebelum bind apa pun, dengan urutan: port, credential ICE ada, credential ICE sah, TLS context ada, kunci ECDSA P-256, lalu dispatch model terhadap platform. `WebrtcServerImpl(handler)` memanggang handler di comptime, bentuk yang sama dengan engine lain.

`config.zig` mempublikasikan `SRTP_PROFILES` dengan tag 80 bit di depan. Profile 32 bit menghemat enam byte per paket dan menukarnya dengan kekuatan autentikasi, jadi ia hanya dijawab kepada peer yang tidak menawarkan yang lain. Profile NULL sama sekali tidak ada di daftar: ia mengautentikasi tanpa mengenkripsi, dan itu bukan sesuatu yang disetujui di jalur yang baru saja diberi certificate.

---

## Pengujian

| Tier | Berkas | Yang dicakup |
| :- | :- | :- |
| integration | `tests/integration/webrtc/exchange_test.zig` | gerbang exit CI, sesi utuh di memori dalam 435ms, tanpa port dan tanpa sleep |
| behaviour | `tests/behaviour/webrtc/session_test.zig` | permukaan sesi |
| edge | `tests/edge/webrtc/session_test.zig` | batas-batasnya |
| runner | `tests/runner/webrtc_client.zig` | satu loop pemanggilan socket, dipakai bersama runner agregat dan runner mandiri |

Tabel runner berisi satu baris per binary **server**, jadi `webrtc_datachannel_echo` punya baris dan `webrtc_native_pair` tidak: pair adalah client yang memanggil lalu keluar, dan pemeriksaannya menjalankan sesi yang sama in-process lewat `webrtc_client.zig`. Menjaga loop pemanggilan di satu berkas itulah yang mencegah example manual dan pemeriksaan otomatis saling menyimpang.

Skip menyebut alasannya lewat `std.log.info` lalu return biasa, tidak pernah `catch return` diam-diam dan tidak pernah `return error.SkipZigTest`, sehingga run-nya menyebut kenapa sebuah test sesi berhenti, bukan meninggalkan lubang di ringkasan.

`webrtc_native_pair` tidak bisa dijalankan dua kali dalam 30 detik terhadap echo server yang sama, dan itu memang diharapkan. Pemanggil mem-bind port lokal tetap dan server mengunci peer berdasarkan 4-tuple-nya, jadi jalannya yang kedua mendarat pada peer yang ditinggalkan jalan pertama, yang sudah lewat handshake dan mengabaikan ClientHello baru. Server melepaskannya pada `peer_idle_ms`. **Jangan** "memperbaiki" ini di engine dengan memulai ulang sesi begitu ada ClientHello: dengan credential ICE tetap, server tidak bisa membedakan restart dari replay, dan restart WebRTC sungguhan datang dengan credential baru.

---

## Menguji DTLS tanpa browser

`openssl s_client -dtls1_2 -connect <ip>:<port> -state` mencetak setiap state handshake, dan `connection.zig` merutekan DTLS **tanpa gerbang ICE**, jadi ia menjangkau DTLS server secara langsung. Keberhasilan terbaca sebagai `Cipher is ECDHE-ECDSA-AES128-GCM-SHA256`, plus satu baris di log engine. Error verifikasi self-signed adalah benar: RFC 8122 membawa fingerprint di SDP, dan belum ada yang memeriksa certificate terhadapnya.

---

###### end of lld-webrtc
