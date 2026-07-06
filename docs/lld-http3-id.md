# LLD: zix.Http3

Detail implementasi internal untuk layer HTTP/3 (QUIC). Untuk rasional desain lihat [`docs/hld-http3-id.md`](hld-http3-id.md).

Engine ini berlapis, dan doc comment `//!` tiap file menandai layer-nya: C (dasar kripto), Q (transport QUIC), T (glue TLS-over-QUIC), P (QPACK), L (loss recovery), H (semantik HTTP/3). Setiap modul deterministik dibuktikan byte-exact terhadap worked example RFC di test in-file-nya.

---

## Layer C: crypto.zig

Dasar kripto deterministik dari stack QUIC (RFC 9001). Fungsi murni plus satu struct usage-accounting, tanpa state connection.

- `initial_salt` (RFC 9001 5.2) dan `initialSecrets(dcid)`: HKDF-Extract(salt, ikm=dcid), lalu `expandLabel` dengan `"client in"` / `"server in"` untuk memisah Initial secret client dan server.
- `expandLabel(out, secret, label, context)`: bentuk HKDF-Expand-Label TLS 1.3 (RFC 8446 7.1), prefix `"tls13 "` plus label.
- `AesKeys { key: [16]u8, iv: [12]u8, hp: [16]u8 }` dengan `fromSecret`: menurunkan packet key, IV, dan header-protection key via label `"quic key"` / `"quic iv"` / `"quic hp"` (RFC 9001 5.1). `ChaChaKeys` adalah saudara ChaCha20 yang lebih lebar (terimplementasi, belum diwire).
- `aeadNonce(iv, packet_number)`: XOR packet number ke byte rendah IV (RFC 9001 5.3).
- `headerMaskAes(hp, sample)`: mask header-protection, AES-ECB(hp, sample) (RFC 9001 5.4.1). `headerMaskChaCha` adalah bentuk ChaCha20 (belum diwire).
- Ditunda tetapi teruji: `retryTag` / `retryKeyNonce` (Retry integrity, RFC 9001 5.8), `nextKeyUpdateSecret` (key ratchet, 6.1), `KeyUsage` dengan `confidentialityLimit` / `integrityLimit` (AEAD usage limit, 6.6).

Jalur live AES-128-GCM saja.

---

## Layer Q: transport QUIC

### varint.zig

Variable-length integer QUIC (RFC 9000 bagian 16). Dua bit teratas byte pertama memberi log basis-2 dari panjang (1 / 2 / 4 / 8 byte), sisanya adalah nilai dalam network order.

- `Varint { value: u64, len: usize }`, `read(data)` mendekode, `write(out, value)` mengencode pada panjang minimal (`encodedLen` memilihnya), menyet bit prefix `0x00` / `0x40` / `0x80` / `0xc0`.

### packet.zig

Parsing long / short header dan packet number (RFC 9000 bagian 17).

- `parseLongHeader(data)`: memvalidasi bit Header Form, Fixed Bit (HARUS 1, jika tidak dibuang), membaca version 4-byte, DCID dan SCID (masing-masing panjang di-cap 20), dan mengembalikan `packet_type` (0 = Initial, 2 = Handshake) plus `rest` sisanya.
- `decodePacketNumber(largest_pn, truncated_pn, pn_nbits)`: rekonstruksi packet number RFC 9000 Appendix A.3. Menghitung `expected = largest_pn + 1`, half-window di sekitarnya, dan kandidat `(expected & ~mask) | truncated_pn`, lalu menyesuaikan sebesar satu window jika kandidat jatuh di luar half-window. Perbandingan window dilakukan dalam `i128` bertanda, bukan `u64`, sehingga packet number kecil tidak underflow. Ini adalah perbaikan correctness yang membuat connection bertahan melewati wrap packet-number pertama.
- `packetNumberLength`, `ShortHeader`, dan `parseShortHeader` adalah referensi full-RFC (terimplementasi dan teruji). Jalur live memakai aturan panjang packet-number inline yang lebih sederhana saat kirim dan mem-parse short header inline di `protection.zig`.

### frame.zig

Parsing frame transport QUIC (RFC 9000 bagian 12 / 19).

- `parseFrame(data)` membaca satu frame: `0x00` PADDING (menggabung run byte nol), `0x01` PING, `0x06` CRYPTO (offset + length + data), `0x07` NEW_TOKEN (divalidasi, non-empty), `0x08..0x0f` STREAM (skema bit-flag OFF / LEN / FIN). Frame type tak dikenal adalah `FrameEncodingError`.
- `Space` (initial / handshake / zero_rtt / one_rtt) dan `framePermittedIn` memodelkan matriks izin per-space RFC 9000 Table 3. Terimplementasi dan teruji, belum dienforce di jalur serve.

File ini frame transport-QUIC saja. ACK ada di `flow.zig`, close frame di `close.zig`, frame HTTP/3 di `h3.zig` / `response.zig`.

### flow.zig

Flow control, ACK, dan path validation (RFC 9000 4 / 19.3 / 19.17).

- `FlowLimit { limit, used }`: `consume(end)` mengangkat `FlowControlError` melewati limit, `advertise(new_limit)` hanya pernah naik.
- `parseAck(data, ack_delay_exponent)`: mem-parse ACK type 0x02 / 0x03 (0x03 membawa hitungan ECN), menyelesaikan encoding range relatif (smallest = largest - range, next largest = previous smallest - gap - 2) menjadi `Range` inklusif absolut, dan mendekode delay dengan ack-delay exponent.
- `parsePathData` / `pathValidates`: echo PATH_CHALLENGE / PATH_RESPONSE (terimplementasi, belum didorong jalur migration).

Penanganan frame MAX_DATA (0x10) / MAX_STREAM_DATA (0x11) ada di `dispatch/common.zig` (`applyStreamCredit`), dan rolling credit MAX_STREAMS ada di `connection.zig` (`replenishBidiStreams`).

### stream.zig (ditunda)

Namespace stream id dan state machine send / receive (RFC 9000 2 / 3 / 5.1.1), plus connection-id pool dengan `active_connection_id_limit`.

- `streamType(id)` berdasarkan `id & 0x03`: client_bidi (0), server_bidi (1), client_uni (2), server_uni (3).
- `sendTransition` / `recvTransition`: state machine Figure 2 / Figure 3 sebagai fungsi transisi murni (hasil `null` adalah event ilegal).
- `ConnIdPool` dan `parseNewConnectionId`: CID pooling untuk migration.

Terimplementasi dan diuji-unit, belum diwire ke jalur serve (engine v1 tidak migrasi atau pool CID). NEW_CONNECTION_ID saat ini dilewati saat mem-parse request.

### close.zig

Connection close, stateless reset, dan anti-amplification (RFC 9000 19.19 / 10.2 / 10.3 / 8.1).

- `parseConnectionClose`: type `0x1c` (QUIC, membawa field Frame Type) atau `0x1d` (application, tanpa Frame Type).
- `CloseState` (open / closing / draining / closed) dan `closeTransition(state, event)`: state machine terminasi RFC 9000 10.2. `maySendInState` false untuk draining.
- `AntiAmplification { received, sent, validated }`: `maySend(bytes)` adalah `validated or sent + bytes <= 3 * received`, cap 3x sebelum address validation (RFC 9000 8.1). `initialDatagramValid(size)` mengenforce floor 1200-byte Initial client.
- `isStatelessReset` / `resetSizeAllowed`: deteksi stateless-reset dan guard amplifikasinya sendiri.

---

## Layer T: TLS over QUIC

### keyschedule.zig

Key schedule handshake QUIC (secret tree RFC 8446 7.1 + label quic RFC 9001 5.1). Memakai ulang `src/tls/key_schedule.zig` (`Transcript`, `HkdfSha256`, `deriveSecret`) untuk machinery TLS 1.3, lalu melapisi derivasi key per-level QUIC di atasnya via `crypto.AesKeys.fromSecret`.

- `handshakeKeys(shared, transcript_hash)`: `early = Extract(0, 0)`, `derived = deriveSecret(early, "derived", "")`, `handshake_secret = Extract(derived, shared)`, lalu traffic secret `"s hs traffic"` / `"c hs traffic"`, mengembalikan `HandshakeKeys { server, client, handshake_secret, server_traffic, client_traffic }`.
- `applicationKeys(handshake_secret, transcript_through_finished)`: master secret 1-RTT dan application secret `"s ap traffic"` / `"c ap traffic"`, mengembalikan `AppKeys { server, client }`.

### tls.zig (glue, sebagian ditunda)

Sambungan antara handshake TLS 1.3 dan QUIC (RFC 9001 bagian 4): pesan handshake menumpang CRYPTO frame, bukan TLS record.

- `CryptoStream { buf: [4096]u8, present: [4096]bool }`: mereassembly CRYPTO frame berdasarkan offset (`insert`, `readableLen`, `readable`), idempoten pada overlap / duplikat. Ini live (stream level-Initial ada di `Connection`).
- `quicKey`, `clientInitialSecret`, `tlsVersionAcceptable`, `InitialKeys` (tracker discard Initial-key 4.9.1), dan `ZeroRttPolicy` (0-RTT ditolak default) terimplementasi dan teruji tetapi belum menggerbang jalur serve.

### serverhello.zig

Generasi ServerHello, awal jalur kirim server.

- `buildServerHelloInitial(...)`: dari ClientHello terparse, jalankan sisi server X25519 ECDHE, `handshake.negotiate` + `handshake.serializeServerHello` (memakai ulang `src/tls`), bungkus ServerHello dalam CRYPTO frame pada offset 0, dan `protection.sealInitial`. Memperbarui transcript dengan ClientHello + ServerHello dan menurunkan Handshake keys via `keyschedule.handshakeKeys`. Mengembalikan byte packet plus shared secret ECDHE. Menangani jalur X25519 umum (default curl).

### flight.zig

Handshake-level TLS flight server.

- `encodeTransportParams(...)`: transport parameter QUIC (RFC 9000 18.2): `original_destination_connection_id` (0x00) dan `initial_source_connection_id` (0x0f) membawa DCID pertama client dan SCID server byte-exact (curl memvalidasinya), plus `max_idle_timeout` (0x01), `initial_max_data` (0x04), ketiga `initial_max_stream_data_*` (0x05 / 0x06 / 0x07), dan `initial_max_streams_bidi` / `_uni` (0x08 / 0x09).
- `buildEncryptedExtensions(...)`: EncryptedExtensions dengan ekstensi ALPN `h3` dan ekstensi `quic_transport_parameters` (0x0039), dibangun manual di sini karena QUIC butuh keduanya, yang dihilangkan TLS record layer.
- `buildHandshakeFlight(...)`: EncryptedExtensions + `certificate.buildCertificate` + `buildCertificateVerify` + `buildFinished` (dari `src/tls/certificate.zig`), masing-masing dimasukkan ke transcript, dibungkus dalam satu CRYPTO frame dan di-seal dengan Handshake keys (`protection.sealHandshake`).

### transport_params.zig

Parsing transport parameter client (RFC 9000 18). Server harus menghormati limit yang diiklankan client sebelum mengirim.

- `parse(ext_body)` menelusuri entri (id, length, value) berframe-varint dan menarik empat yang dibutuhkan jalur response: `initial_max_data` (0x04), `initial_max_stream_data_bidi_local` (0x05, limit untuk balasan server pada request stream bidi yang diinisiasi client), `ack_delay_exponent` (0x0a, default 3, di-clamp 0..20), dan `max_udp_payload_size` (0x03, di-floor pada 1200). Setiap parameter lain dilewati.
- `fromClientHello(client_hello)` menemukan ekstensi 0x0039 dengan menelusuri struktur ClientHello secara manual.

---

## protection.zig: packet protection (open + seal)

Menghapus / menerapkan header protection dan AEAD, pasangan invers di sekitar packet number (RFC 9001 5.3 / 5.4). AES-128-GCM di seluruhnya.

Open (receive):
- `openInitial` (packet_type 0), `openHandshake` (packet_type 2), `openShort` (1-RTT). Masing-masing mengambil sampel 16 byte ciphertext pada `pn_offset + 4`, menghitung mask dengan `crypto.headerMaskAes`, membuka mask byte pertama (4 bit rendah untuk long header, 5 bit untuk short header) dan byte packet-number, membangun nonce, dan AEAD-decrypt dengan header tak-terproteksi sebagai associated data. `openShort` merekonstruksi packet number dengan `packet.decodePacketNumber` saat `largest_pn` dilacak, jika tidak memakai nilai wire terpotong (packet pertama tak punya largest sebelumnya).

Seal (send):
- `sealInitial`, `sealHandshake`, `sealShort`: membangun header, mengambil sampel dan mask, AEAD-encrypt. `short_seal_overhead_max` membatasi overhead 1-RTT (`1 + 20 + 4 + tag_length`).

---

## Layer P: kompresi header QPACK

### qpack.zig (live, static-only)

Field line static-table QPACK (RFC 9204). Field section static-only memakai prefix Required-Insert-Count-0 / Base-0 (dua byte nol).

- `decodePrefixedInt` / `encodePrefixedInt`: prefixed integer RFC 7541 5.1 yang ditumpangi setiap representasi.
- `static_table`: 44 entri terdepan (indeks 0..43) dari RFC 9204 Appendix A, mencakup pseudo-header plus field umum (`:method` GET/POST/dll pada 17..21, `:status` 200/304/404/503 pada 25..28, `:path` pada 1, `:authority` pada 0), dan entri content-negotiation yang dipakai jalur serve: `accept-encoding` (indeks 31, input request) dan `content-encoding` br / gzip (indeks 42 / 43, output response).
- `decodeIndexedFieldLine` (RFC 9204 4.5.2) dan `decodeLiteralNameRef` (4.5.4) untuk decode, `encodeStaticIndexedFieldLine` untuk encode.
- `StreamRegistry`: pengecekan at-most-one encoder / decoder stream (terimplementasi, belum dienforce).

### qpack_dynamic.zig (ditunda)

Dynamic table dan instruksi decoder-stream (RFC 9204 3.2 / 4.4). `DynamicTable` (append-with-eviction, overhead 32-byte per entri, `setCapacity`), transform Required-Insert-Count / Base, dan instruksi decoder Section Acknowledgment / Stream Cancellation / Insert Count Increment, plus error code QPACK. Terimplementasi penuh dan diuji-unit, belum diwire: tidak ada config dynamic-capacity non-zero, jadi jalur live static-only.

### huffman.zig (live)

Decoder Huffman RFC 7541 Appendix B yang QPACK bagi dengan HPACK, dipakai untuk string literal (`:path` request datang ter-Huffman-encode).

- `decode(out, input)`: menelusuri bitstream MSB-first, memancarkan symbol begitu bit terakumulasi cocok dengan code panjang persis itu. Tabel code 256-symbol di-bucket dan diurut berdasarkan panjang bit dalam blok comptime (`HuffmanIndex`), jadi decode hanya memindai bucket untuk panjang bit saat ini. Bit trailing all-ones adalah padding EOS, diabaikan. Mengembalikan `null` pada overflow output atau code tak-terpecahkan melewati 30 bit. Decode live dipanggil dari `dispatch/common.zig` (`decodePath`) ke `path_scratch` connection saat request membawa flag Huffman.

---

## Layer H: semantik HTTP/3

### request.zig (live)

Mendekode request dari payload 1-RTT terdekripsi.

- `parseRequests(payload, out)`: memindai STREAM frame bidi yang diinisiasi client (`stream.id & 0x03 == 0`), mendekode masing-masing dalam urutan kedatangan sampai `max_requests_per_packet` (96). `parseRequest` mengembalikan yang pertama.
- `decodeRequestStream` menelusuri frame HTTP/3 di dalam data stream untuk HEADERS frame pertama (type 0x01), dan `decodeHeaders` mendekode-QPACK field section-nya, membaca prefix RIC / Base lalu field line indexed atau literal-name-ref. Ia menangkap `:method` dan `:path` (pseudo-header, di depan) dan `accept-encoding` (field biasa, jadi scan berlanjut melewati pseudo-header untuk mencapainya), berhenti begitu ketiganya di tangan.
- `DecodedRequest { method, path, path_huffman, accept_encoding, accept_encoding_huffman }` membawa flag Huffman, diperluas belakangan oleh `decodePath` / `decodeAcceptEncoding`.

### response.zig (live)

Menserialisasi payload QUIC 1-RTT penuh.

- `buildResponse(...)` merakit, berurutan: ACK frame opsional (`buildAck` / `buildAckRanges`), HANDSHAKE_DONE opsional (0x1e), control stream server opsional (stream id 3) membawa byte stream-type 0x00 plus SETTINGS frame kosong `{0x04, 0x00}`, MAX_STREAMS opsional (`buildMaxStreams`, type 0x12), lalu isi request-stream, dan opsional application CONNECTION_CLOSE (0x1d, H3_NO_ERROR = 0x0100).
- `buildRequestStreamContent`: HTTP/3 HEADERS frame (type 0x01) dengan prefix QPACK static-only (RIC 0 / Base 0) plus indexed `:status` line (`statusIndexedFieldLine` memetakan 103/200/304/404/503 ke indeks static 24..28, default 200) dan, saat handler menyetelnya, indexed `content-encoding` line (`contentEncodingFieldLine` memancarkan indeks static 42 untuk br / 43 untuk gzip, tidak ada untuk identity), diikuti DATA frame (type 0x00) dengan body, dibungkus dalam STREAM frame dengan FIN. `buildStreamPrefix` (jalur large-body) mengambil `content_encoding` yang sama, jadi body multi-packet yang di-resume tetap membawa header-nya. Engine memancarkan field tapi tidak pernah mengompresi: handler yang memiliki body ter-coded.

### h3.zig (ditunda)

Framing dan semantik HTTP/3 penuh (RFC 9114): enum `FrameType` (data 0x00, headers 0x01, cancel_push 0x03, settings 0x04, push_promise 0x05, goaway 0x07, max_push_id 0x0d), state machine control-stream `settings-first` (`ControlStream`), state machine urutan frame request (`requestFrameTransition`), validasi pesan penuh (`validateMessage`: nama lowercase, urutan pseudo-header, pseudo-header wajib / terlarang, Content-Length vs jumlah DATA), tracker monotonisitas GOAWAY / MAX_PUSH_ID, dan 17 error code HTTP/3 plus range grease. Terimplementasi dan diuji-unit, belum diwire: jalur request live menangani framing minimal inline di `dispatch/common.zig`.

---

## connection.zig: state per-connection

`Connection` mengikat layer bersama: Initial keys, stream reassembly CRYPTO, RTT estimator dan congestion controller, budget anti-amplification dan close state, serta control stream HTTP/3. Ukurannya tetap (tanpa heap per-packet), disimpan di dalam slot CID table.

Fase handshake dilacak oleh flag yang diset di jalur kirim (di `dispatch/common.zig`) alih-alih satu enum: `server_hello_sent`, `handshake_ready` (Handshake keys diturunkan), `app_ready` (1-RTT keys diturunkan), lalu `close_state`.

Field dan method kunci:
- `dcid`, `our_scid`, `peer_scid`, `peer_addr` (ditimpa per datagram diterima, jadi perubahan 4-tuple secara transparan mentargetkan-ulang kiriman), `initial_client` / `initial_server`, `hs_keys`, `app_keys`, `handshake_transcript`.
- `AckTracker { largest_pn, received_mask: u64 }`: bitmask geser 64-bit dari packet number yang diterima (bit 0 = largest), jadi server memancarkan range ACK yang jujur.
- `SendStream` (sampai 64 per connection): body response yang distream lintas packet (`stream_id`, `body`, `content_encoding`, `sent`, `high_water`, `unacked`, `stream_limit`). Prefix dibangun ulang per packet, jadi `content_encoding` disimpan agar header `content-encoding` tetap konsisten lintas body yang di-resume.
- Ring `SentRange` (128 entri): loss-detection log. `recordSentRange` menimpa slot tertua, mengurangi `bytes_in_flight` dan `unacked` stream pemilik dulu jika masih in-flight (mencegah leak / truncation).
- `replenishBidiStreams(highest_bidi_id, window)`: rolling credit MAX_STREAMS. Melacak request stream tertinggi client, dan begitu ia memakai lebih dari separuh window saat ini, menaikkan grant kumulatif ke `high_water + window` dan mengembalikan nilai baru (jika tidak `null`), jadi connection tak pernah stall setelah allowance awal habis.
- `onAckFrame(ack, now_us)`: mengambil sampel RTT dari packet yang cocok dengan `ack.largest`, memensiunkan range yang di-ack, mengkredit `cc.onAckedBytes`, mereset PTO backoff, dan mendeklarasikan loss untuk range terdahulu yang masih outstanding (`recovery.packetLost`), memundurkan stream-stream itu dan memanggil `cc.onCongestionEvent()` sekali per ACK jika ada loss.
- `onMaintenance(now_us, max_idle_us)`: sweep time-driven. Pada Probe Timeout ia mendeklarasikan range outstanding hilang dan memundurkan stream untuk retransmit, tetapi TIDAK memotong congestion window (PTO bukan sinyal congestion, RFC 9002 6.2). Loss tak pernah mengevict connection. Ia melaporkan `idle = true` hanya pada keheningan idle-timeout atau close state `draining` / `closed` (CONNECTION_CLOSE yang diterima mengevict segera).

---

## Layer L: recovery.zig

Loss detection dan congestion control sisi-pengirim (RFC 9002). Mikrodetik integer dan byte integer di seluruhnya, jadi tiap nilai eksak.

- `RttEstimator.onSample`: EWMA RFC 9002 5.1..5.3 (`smoothed = (7*smoothed + adjusted)/8`, `rttvar = (3*rttvar + |smoothed - adjusted|)/4`), dengan penyesuaian ack-delay.
- `packetLost`: hilang saat `largest_acked - packet_number >= 3` (threshold reordering) atau time-since-sent melewati `lossTimeThreshold` (`9/8 * max(smoothed, latest)`, di-floor pada granularity 1ms).
- `computePto` (`smoothed + max(4*rttvar, granularity) + max_ack_delay`) dan `ptoWithBackoff` (`base << backoff`, di-cap pada backoff 64x).
- `CongestionController` (NewReno): `congestion_window` mulai pada `max(initial window config, 2 * max_datagram_size)`, `onAckedBytes` menumbuhkannya (slow start menambah byte yang di-ack, congestion avoidance menambah `mds * acked / cwnd`), `onCongestionEvent` memangkasnya setengah ke `ssthresh`, `onPersistentCongestion` meruntuhkannya ke minimum. Window membatasi `pumpStream` terhadap `bytes_in_flight`.

---

## demux.zig: connection-id table

Sebuah connection QUIC dikunci oleh Destination Connection ID-nya, bukan oleh socket.

- `ConnId { bytes: [20]u8, len: u8 }` dengan `fromSlice` (memotong ke 20) dan `eql`.
- `Table(T, capacity)`: store berkapasitas tetap (tanpa alokasi, mengembalikan null saat overflow) dengan index hash open-addressing tertanam (load factor 0.5, dikunci Wyhash, penghapusan tombstone) untuk find O(1), jadi demux per-packet tidak berbiaya scan linear. `put` menyisipkan, `find` mencari, `addAlias` menambah key kedua yang menyelesaikan ke slot yang ada (dipakai untuk mengalias SCID server ke connection setelah ServerHello), `remove` men-tombstone tiap bucket yang menunjuk ke slot.
- Instance produksi: `demux.Table(Connection, 256)`, satu per worker, dialokasi heap. Connection baru dibuat saat long-header Initial packet (packet_type 0) datang untuk DCID tak dikenal.

Model `.ASYNC` engine v1 menjalankan satu worker yang memiliki seluruh table, jadi connection migration (perubahan 4-tuple) hanyalah peer address baru pada CID yang ada, tanpa routing antar-core.

---

## server.zig dan dispatch/

`Server.init(handler, config)` (server.zig) adalah facade tipis: `init` menyimpan config, `run` memvalidasi (`error.PortNotConfigured` pada port nol, `error.TlsRequired` pada TLS context null) lalu switch pada `config.dispatch_model` ke entry point per-model `dispatch/`. Semua model Linux-only.

- `dispatch/common.zig`: machinery bersama. `workerLoop` (recvmmsg masuk, `serveDatagram` per datagram, sendmmsg keluar), `runSingle` (satu worker di thread pemanggil, ASYNC), `runMulti` (satu thread SO_REUSEPORT per CPU, dipin, POOL / MIXED). `processDatagram` men-demux berdasarkan DCID dan mendekripsi (`openInitial` / `openHandshake` / `openShort`). `serveDatagram` menggerakkan langkah yang cocok: `sendServerHello` pada ClientHello lengkap, atau `sendResponse` pada request 1-RTT. `sendResponse` menerapkan ACK (memberi makan `onAckFrame`), mem-parse request, mengisi-ulang bidi stream credit, menggabung ACK + HANDSHAKE_DONE + SETTINGS + MAX_STREAMS + response kecil ke satu packet ter-seal (budget `COALESCE_PAYLOAD_MAX`), mendaftar body besar sebagai `SendStream`, dan `pumpStream` tiap stream aktif dalam congestion window. `sweepMaintenance` menjalankan `onMaintenance` per connection pada interval terbatas, meretransmit flight yang PTO-expired dan mengevict connection idle / closed.
- `dispatch/async.zig`, `pool.zig`, `mixed.zig`: wrapper tipis ke `runSingle` / `runMulti`.
- `dispatch/epoll.zig`: `workerLoopEpoll`, loop readiness epoll yang drain-to-EAGAIN pada bentuk per-core yang sama, memanggil `serveDatagram` / `sweepMaintenance` bersama. Ia mengarm timeout epoll sehingga sweep maintenance jalan selama I/O lull.
- `dispatch/uring.zig`: `workerLoopUring`, loop completion io_uring nyata (multishot recv pada provided buffer ring saat tersedia, jika tidak sebuah pool one-shot recv SQE), dengan jalur kirim double-buffered sehingga kiriman tak pernah memblok loop. Fold ke `epoll.workerLoopEpoll` per-worker saat io_uring init gagal.

Binding adalah `datagram.open(ip, port, reuse)` dari `src/udp/datagram.zig`, `reuse = true` (SO_REUSEPORT) untuk model per-core sehingga beberapa worker berbagi port.

---

###### end of lld-http3
