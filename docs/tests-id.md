# Pengujian: zix

---

## Cara Menjalankan

```sh
# hanya pengujian unit (tidak ada output saat berhasil)
zig build unit-test

# pengujian integrasi: komponen dihubungkan, tanpa server aktif
zig build integration-test

# pengujian perilaku: kontrak API yang dapat diamati
zig build behaviour-test

# pengujian edge: kondisi batas dan jalur error
zig build edge-test

# semua langkah di atas sekaligus
zig build test-all
```

`zig build` saja **tidak** menjalankan pengujian: langkah pengujian adalah langkah bernama tersendiri yang tidak terhubung ke langkah install default.

Perilaku platform: dengan `-Dtarget` foreign, setiap suite ter-compile untuk target itu dan eksekusi dilewati dengan warning. Di host non-Linux, tes yang menguji jalur EPOLL / URING (Linux-only) mencetak warn lalu skip, dan tes yang berpijak pada syscall Linux-only skip tanpa pesan. Langkah `test-runner-*` berperilaku sama: target foreign meng-compile runner beserta server-nya lalu lolos, dan di host non-Linux setiap skenario EPOLL / URING melaporkan baris PASS dengan warn alih-alih berjalan.

---

## Pengujian Unit

Sumber: `src/lib.zig`. Setiap modul diuji melalui `std.testing.refAllDecls`, yang memverifikasi bahwa setiap deklarasi publik berhasil dikompilasi dan setiap blok `test` inline lolos.

### zix.Tcp (raw)

| Modul | Cakupan |
| :- | :- |
| `tcp/config.zig` | `refAllDecls` + perilaku: default `TcpServerConfig` (kernel_backlog=4096, max_recv_buf=4096, workers=0) dengan dispatch_model wajib (disetel eksplisit), nilai backing `DispatchModel` gapless dengan hanya tiga model yang dirawat, nama POOL / MIXED yang dilepas tidak lagi resolve, default `TcpClientConfig` (max_recv_buf=4096) |
| `tcp/server.zig` | `refAllDecls` + perilaku: port nol menghasilkan `error.ZixPortNotConfigured`, konfigurasi valid berhasil dan deinit aman, konfigurasi EPOLL valid berhasil dan deinit aman |
| `tcp/client.zig` | `refAllDecls` |

### zix.Http1

| Modul | Cakupan |
| :- | :- |
| `tcp/http1/method.zig` | `refAllDecls` + round-trip semua code termasuk `QUERY` (RFC 10008), QUERY diselesaikan dari token wire-nya dan tidak pernah dilaporkan sebagai GET, pencocokan case-sensitive, `codeFromString` melaporkan token tak dikenal sebagai null, token melebihi `MAX_TOKEN_LEN` ditolak oleh length switch, `enumFromString` mempertahankan fallback GET |
| `tcp/http1/content.zig` | `refAllDecls` + round-trip: `typeFromString` / `stringFromEnum` untuk setiap varian enum, query type RFC 10008 diselesaikan dari string-nya, media type terpanjang 33 byte muat di buffer huruf kecil, nilai melebihi `MAX_TYPE_LEN` melaporkan tidak ada kecocokan alih-alih panic, `typeFromHeader` melepas parameter dan tetap case-insensitive |
| `tcp/http1/core.zig` | `refAllDecls` + perilaku: parseHead (field GET, pemisahan query dari path, POST Content-Length, default keep_alive HTTP/1.0 + override Connection, Expect 100-continue), getHeader case-insensitive, queryParam, parseRange, percentDecode, buildSimpleHeaderInto, sendSimpleFD ke RespSink aktif tanpa bounce buffer, cache no-op / store-lalu-hit / pemisahan key per path dan query, walk chunkedFrame (minta lebih di tengah body, panjang terminator, malformed vs too-large vs belum selesai, data yang mengeja terminator, berhenti di request pipelined), decodeChunkedInBuf (decode di tempat, source tak tersentuh selama belum selesai), jalur body ASYNC serveConn (pengantaran body muat dan over-large dengan pelaporan bodyReceived / bodyComplete, awal body dan bukan sisa drain, drain menjaga request pipelined, 413 dideklarasikan dan chunked melewati buffer, 400 chunked malformed, 100 Continue, chunked tiba setelah head, request pipelined di belakang body chunked) |
| `tcp/http1/request.zig` | `refAllDecls` + perilaku: body mengembalikan slice yang diantar engine, bodyReceived default ke panjang slice dan menerima override engine, bodyComplete default true dan menerima override engine, fromRaw mem-parse buffer mentah dengan body |
| `tcp/http1/server.zig` | `refAllDecls` + perilaku: validasi config (ASYNC / EPOLL / URING), serveEpollConn menjawab burst pipelined secara berurutan, cache EPOLL miss-lalu-hit + plafon memori effectiveCacheEntries, siklus hidup slab ConnTable + sizing ws_recv_buf, serveEpollWs men-drain ke EAGAIN, parseGetFastPath (GET / query / menolak POST dan HTTP/1.0 / raw headers), initUringRing menghasilkan ring yang dapat dipakai |
| `tcp/http1/dispatch/epoll.zig` (Linux) | perilaku jalur body: drain-lalu-sajikan melaporkan total terhitung, drain tepat menjaga request pipelined tetap utuh, peer yang berhenti di tengah drain tidak pernah dilayani, body yang muat menunggu hitungan penuh, 413 untuk body yang dideklarasikan melewati limit dan body chunked melewati body buffer, 400 pada chunked malformed, satu 100 Continue selagi body masih berdatangan |
| `tcp/http1/dispatch/uring.zig` (Linux) | perilaku jalur body: body chunked yang hadir penuh ter-decode, body oversized ditunda dan disajikan dengan total terhitung, request yang ditunda tetap parkir selama drain-nya belum selesai, body yang muat menunggu hitungan penuh, 413 dideklarasikan dan chunked, 400 chunked malformed, 100 Continue selagi body masih berdatangan |
| `tcp/http1/websocket.zig` | `refAllDecls` + perilaku: acceptKey vektor RFC 6455, round-trip buildFrame/parseFrame, SIMD unmask cocok dengan scalar (dan tail bytes), prefix buildHeader, pump echo lewat socketpair, pumpRing stage lalu melaporkan close, broadcast fan-out (+ skip fd mati, list kosong) |
| `tcp/http1/router.zig` | `refAllDecls` + perilaku: matchParam, router comptime |
| `tcp/http1/config.zig` | `refAllDecls` (nilai default diuji oleh `tests/behaviour/http1/config_test.zig`) |

### zix.Udp

| Modul | Cakupan |
| :- | :- |
| `udp/config.zig` | `refAllDecls` + default: `UdpServerConfig`, `UdpClientConfig`, default `allow_args`, dan nilai backing enum `Endianness` |
| `udp/packet.zig` | `refAllDecls` + perilaku: NATIVE tanpa operasi, array u8 tidak ditukar, round-trip LITTLE/BIG, non-native menukar elemen integer dan float array, semua varian `FeedbackResult` |
| `udp/server.zig` | `refAllDecls` + perilaku: port nol menghasilkan `error.ZixPortNotConfigured`, port bukan-nol berhasil, field konfigurasi tersimpan |
| `udp/client.zig` | `refAllDecls` |

### zix.Uds

| Modul | Cakupan |
| :- | :- |
| `uds/config.zig` | `refAllDecls` + default: `UdsServerConfig` (kernel_backlog=128, max_recv_buf=4096), `UdsClientConfig` |
| `uds/server.zig` | `refAllDecls` + perilaku: path kosong menghasilkan `error.ZixPathEmpty`, path valid berhasil dan deinit aman |
| `uds/client.zig` | `refAllDecls` |

### zix.Channel

| Modul | Cakupan |
| :- | :- |
| `channel/channel.zig` | `refAllDecls` + perilaku: kapasitas dan jumlah init `Channel(u32)`, aritmetika tail ring buffer |

### zix.Fix

| Modul | Cakupan |
| :- | :- |
| `tcp/fix/config.zig` | `refAllDecls` + perilaku: field wajib `FixServerConfig` (ip, port, comp_id), dispatch_model wajib (disetel eksplisit), workers default 0, kernel_backlog default 1024, heartbeat_timeout_ms default 0, field wajib `FixClientConfig` (ip, port, comp_id, target_comp_id) |
| `tcp/fix/core.zig` | `refAllDecls` + perilaku: round-trip `parseFields`, pencarian `getField` dan kasus null, vektor `computeChecksum` yang diketahui, `verifyChecksum` valid/terpotong/salah, `findMessageEnd` lengkap/parsial/tanpa-terminator, `buildMessage` menghasilkan checksum valid |
| `tcp/fix/server.zig` | `refAllDecls` + perilaku: port nol menghasilkan `error.ZixPortNotConfigured`, konfigurasi valid berhasil, deinit aman |
| `tcp/fix/client.zig` | `refAllDecls` + perilaku: `FixClient.connect` port nol menghasilkan `error.ZixPortNotConfigured` |
| `tcp/fix/router.zig` | `refAllDecls` + perilaku: dispatch memanggil handler yang cocok, tanpa kecocokan handler tidak dipanggil, timeout route menyetel `deadline_ns` |

### zix.Http2

| Modul | Cakupan |
| :- | :- |
| `tcp/http2/frame.zig` | PREFACE adalah preface 24-byte, nilai type / flag / error code / settings id sesuai RFC 7540, `MAX_FRAME_SIZE_LIMIT` adalah u24 terbesar, round-trip header / big endian / length dan stream id terbesar, bit reserved dibuang, frame type tak dikenal diteruskan |
| `tcp/http2/FrameHeader.zig` | menyimpan field-nya, menampung length dan stream id terbesar |
| `tcp/http2/writer.zig` | `writeAllFD` mengirim data / menandai stream terjawab / data kosong tidak menulis, `writeAllDirectFD` tidak menyentuh tanda / peer tertutup BrokenPipe, `writeFrameHeaderFD` mengirim 9 byte, `sendResponseFD` tanpa body END_STREAM di HEADERS / body kecil satu DATA / tepat `SEND_STAGE_BODY_MAX` satu DATA / melewati stage jalur vectored / melewati max frame size dipecah / menandai terjawab / content-type melewati scratch BufferFull, `sendResponseEncodedFD` peer tertutup BrokenPipe, write hook default null / menerima byte `writeAllFD` / menandai stream terjawab / tanpa context menulis ke socket, `writeAllDirectFD` melewati hook, body vectored `sendResponseFD` masuk ke hook |
| `tcp/http2/reader.zig` | `readOnceFD` mengembalikan yang tiba / 0 setelah close, `recvExact` mengisi / buffer kosong / kurang data Closed, `readFrameHeader` parse / terpotong Closed |
| `tcp/http2/control.zig` | `sendSettingsFD` kosong / setiap param / melewati 24-bit TooManySettings, `sendSettingsAckFD` ACK tanpa payload, `sendPingAckFD` memantulkan payload, `sendGoawayFD` last stream dan code, `sendRstStreamFD` menuju stream, `sendWindowUpdateFD` increment / bit atas bersih, peer tertutup BrokenPipe |
| `tcp/http2/hpack/Header.zig` | menyimpan field-nya, menampung value kosong |
| `tcp/http2/hpack/HuffSym.zig` | menyimpan field-nya, menampung code 30-bit terpanjang |
| `tcp/http2/hpack/huffman_table.zig` | code yang diketahui untuk spasi, `a`, byte 255, setiap code muat di bit length-nya |
| `tcp/http2/hpack/static_table.zig` | indeks 0 kosong, indeks 2 `:method GET`, indeks 8 `:status 200`, indeks 16, indeks terakhir, setiap nama lowercase |
| `tcp/http2/hpack/huffman.zig` | round-trip ascii dan setiap byte, vektor RFC 7541 C.4.1 / C.4.2, input kosong, OutputTooSmall saat encode dan decode, padding lebih dari 7 bit / deretan bit 1 panjang InvalidCode |
| `tcp/http2/hpack/integer.zig` | vektor RFC 7541 C.1.1 / C.1.2, decode mengabaikan bit representasi, round-trip lintas ukuran prefix, UnexpectedEOF kosong dan di tengah continuation, Overflow melewati 64 bit, BufferFull |
| `tcp/http2/hpack/DynamicTable.zig` | add menjadi indeks 1, terbaru di depan, overhead 32-byte, byte disalin, di luar rentang null, eviksi melewati max_size, entry kebesaran mengosongkan, `evictTo` 0 mengosongkan, compaction menjaga entry terbaca, buffer byte penuh melewati entry |
| `tcp/http2/hpack/HpackDecoder.zig` | `:method GET` terindeks, RFC 7541 C.3.1 dan C.4.2, literal tanpa indexing, output di scratch, size update mengeviksi, `evictTo` diteruskan, InvalidIndex (tak dikenal, 0), TooManyHeaders, ScratchFull, UnexpectedEOF, InvalidCode |
| `tcp/http2/hpack/HpackEncoder.zig` | static match persis satu byte, indeks nama static, nama literal, nama case-insensitive, round-trip lewat decoder, melewati scratch Huffman jadi literal biasa, BufferFull (penuh, kosong) |
| `tcp/http2/hpack/RespPrefix.zig` | triple sama cocok, status / content-encoding lain tidak cocok, triple kosong cocok |
| `tcp/http2/hpack/response_block.zig` | sama byte demi byte dengan `writeHeader`, prefix cache byte sama / encode ulang length, content-encoding, length null tanpa content-length, round-trip lewat decoder, status lima digit, content-type panjang melewati cache, dst kecil BufferFull |
| `tcp/http2/ServeOpts.zig` | default, limit eksplisit |
| `tcp/http2/Stream.zig` | `open` me-reset dan mengeset id, `appendBody` mengakumulasi / melewati batas tidak menambah apa pun / menerima payload kosong, `headerList` mencakup `header_count` |
| `tcp/http2/UpgradeHead.zig` | `settings` default kosong |
| `tcp/http2/stream_state.zig` | `IDLE` adalah nilai nol, nama tag sesuai enum |
| `tcp/http2/stream_slot.zig` | `claim` entry kosong pertama / melewati batas mengembalikan null, `find` entry hidup / melewati entry yang dibebaskan, `requestInFlight` stream belum selesai / semua selesai / tabel kosong |
| `tcp/http2/declared.zig` | `LENGTH` membawa jumlah byte, `ABSENT` dan `BROKEN` berbeda |
| `tcp/http2/stream_body.zig` | tanpa content-length selalu utuh, hanya pada jumlah tepat, nol dengan body, bukan desimal murni, melewati u64, digit kebanyakan, nilai sama berulang dihitung sekali, nilai berbeda, nama case-insensitive |
| `tcp/http2/stream_invoke.zig` | `buildRequest` pseudo-header dan fallback, body utuh sampai ke handler, body kurang di-reset |
| `tcp/http2/handler.zig` | error tanpa jawaban menjadi satu 500, tidak ada response kedua setelah jawaban fd atau `Response`, error yang ditelan tidak mendapat apa pun, context membawa opts dan frame size peer, timeout nol tanpa deadline, access record ditulis / dilewati tanpa logger |
| `tcp/http2/cache.zig` | default ttl, key tidak pernah nol, key memisahkan body, miss tanpa cache, simpan lalu hit, path lain miss, path kosong tidak menyimpan, miss tanpa io, `effectiveCacheEntries` tanpa ceiling mempertahankan jumlah / dibatasi ceiling / ceiling longgar mempertahankan jumlah / ceiling kecil 1 / value bytes nol dihitung 1, `installWorker` mati membersihkan / hidup memasang slot, `uninstallWorker` membersihkan slot |
| `tcp/http2/upgrade.zig` | `headerValue` case dan trim / melewati request line / tidak ada, `isH2cUpgrade` case apa pun / protokol lain / tanpa header, `decodeSettings` valid / malformed / terlalu besar, `requestLine` split dan fallback, `accept` menjawab 101 / 400 tanpa h2c / head terlalu besar / peer menutup di tengah head |
| `tcp/http2/serve.zig` | `serveConn` prior knowledge / preface buruk GOAWAY / upgrade h2c stream 1, body kurang di-reset, body cocok dilayani, body melewati buffer stream 413, hang-up belum selesai GOAWAY, hang-up idle tanpa GOAWAY, PING ACK |
| `tcp/http2/send_best_effort.zig` | `goaway` kode, `rstStream` stream dan kode, `windowUpdate` increment, `sendTooLarge` 413 dengan END_STREAM, fd tertutup diabaikan |
| `tcp/http2/frame_payload.zig` | `headerBlock` strip padding dan priority / tanpa flag / padding melewati payload / padded kosong, `dataBlock` strip padding / tanpa flag / padding melewati payload |
| `tcp/http2/peer_settings.zig` | `apply` max frame size valid / di luar rentang menyimpan yang terakhir / ukuran tabel HPACK / melaporkan initial window / null tanpanya / mengabaikan parameter parsial, `sendServerSettings` satu frame SETTINGS / fd tertutup BrokenPipe |
| `tcp/http2/mux/conn_outcome.zig` | `keep_alive` dan `close` berbeda |
| `tcp/http2/mux/mux_phase.zig` | mulai dengan menunggu preface |
| `tcp/http2/mux/MuxStream.zig` | default idle, `reset` menyimpan buffer ter-pool, `open` mengeset id dan send window, `appendBody` mengisi pas / melewati buffer tidak menambahkan apa pun, `headerList` kosong sebelum decode |
| `tcp/http2/mux/stream_pool.zig` | `acquire` mengukur buffer, release lalu acquire memakai ulang stream yang sama ter-reset, stream ter-pool yang terlalu kecil diganti, dua peminjaman berbeda |
| `tcp/http2/mux/MuxConn.zig` | `init` menunggu preface, `rbuf` memuat satu frame melewati floor, `claimSlot` window peer / melewati `max_streams` null, `releaseSlot` membebaskan untuk dipakai ulang, slot ter-pool lintas koneksi, `requestInFlight` terbuka / selesai, `setPeerInitialWindow` selisih, `compact` kosong / frame parsial / masih ada ruang |
| `tcp/http2/mux/flow.zig` | `pumpBody` dipacu send window / dibatasi max frame size peer / tanpa window memarkir semua / tanpa end stream tetap terbuka / socket rusak memarkir sisanya, `resumeStream` tidak terparkir menyimpan slot, `resumeAll` menguras setiap stream terparkir |
| `tcp/http2/mux/send_stream.zig` | tanpa koneksi mux tanpa meter, memarkir melewati send window dengan content-length penuh, body kosong END_STREAM pada HEADERS, stream tidak dikenal tanpa meter, blok header terlalu besar RST `INTERNAL_ERROR` |
| `tcp/http2/mux/mux_upgrade.zig` | head h2c 101, non-h2c 400 dan tutup, head parsial menunggu, head memenuhi buffer menutup |
| `tcp/http2/mux/mux_dispatch.zig` | request utuh sampai ke handler dengan `active_conn` terpasang, body kurang di-reset sebelum handler, respons terparkir menyimpan slot-nya, `hangupGoaway` in-flight GOAWAY / idle tidak ada / terparkir tidak ada |
| `tcp/http2/mux/frame_loop.zig` | GET dilayani, frame parsial menunggu, accept-encoding sampai ke handler, CONTINUATION melengkapi / stream tidak dikenal menutup, stream berselang-seling dilayani, WINDOW_UPDATE me-resume, grant koneksi saja membiarkan stream terparkir, setiap stream terparkir di-resume, SETTINGS initial window / max frame size, DATA pada frame size default peer, PING ACK / ukuran salah, WINDOW_UPDATE ukuran salah, frame melewati batas, HEADERS stream 0 / id dipakai ulang / melewati `max_streams`, DATA melewati buffer 413 / pas mengisi dilayani / stream tidak dikenal, content-length kurang / lebih / tidak pernah tiba / cocok, RST_STREAM membebaskan slot terparkir, GOAWAY peer menutup, tipe frame tidak dikenal diabaikan |
| `tcp/http2/mux/process.zig` | `onReadable` prior knowledge dilayani / hang-up di tengah request GOAWAY / socket non-blocking idle tetap hidup, preface buruk GOAWAY, preface parsial menunggu, byte kurang dari peek menunggu, `processRing` menjalankan frame setelah preface, upgrade h2c lalu preface mencapai h2, preface buruk setelah upgrade menutup |
| `tcp/http2/Config.zig` | field wajib, dispatch model eksplisit, default worker / buffer / stream dan frame, response cache mati, logger null, `handler_timeout_ms` nol, static serving mati, `serveOpts` membawa knob stream dan frame / buffer / cache / handler timeout / public dir / mempertahankan default |
| `tcp/http2/Context.zig` | init menyimpan fd dan stream id, tanpa static dir dan frame 16 KiB, tanpa deadline di awal, `withTimeout` nol expired / masa depan belum expired / original tidak tersentuh, `withDeadline` lampau expired, `setTimeout` mengganti deadline |
| `tcp/http2/Request.zig` | `splitPath` path dan query / tanpa query / `?` di akhir, `header` case-insensitive / pseudo-header / tidak ada, `queryParam` value / tanpa value / tidak ada / query kosong, `queryParams` pasangan / melewati pasangan kosong / kosong / out of memory, `pathSegments` split / root / out of memory |
| `tcp/http2/Response.zig` | default 200 tanpa content type, `setStatus`, `setContentType`, `send` sama dengan `writer.sendResponseFD` / mencatat sent dan bytes_written / peer tertutup BrokenPipe, `sendJson`, `sendText`, `sendNoContent` 204 |
| `tcp/http2/Server.zig` | init menyimpan input dan dispatch model, deinit tanpa logger, port 0 `PortNotConfigured` / diperiksa sebelum model, `IOCP` / `KQUEUE` tidak didukung, `EPOLL` / `URING` di luar Linux tidak didukung / diterima di Linux, model tak didukung ditolak sebelum `public_dir`, `public_dir` tidak ada `PublicDirNotFound`, `gatePublicDir` kosong / file / direktori yang ada, `installStaticCache` tanpa `public_dir` / ttl 0 / memiliki tabel yang dibangunnya, `dispatchError` memetakan ResolveFailed / ListenFailed / AcceptFailed, `ASYNC` ip tak ter-resolve `ResolveFailed`, `dispatchEpollError` dan `dispatchUringError` memetakan ResolveFailed / ListenFailed / kegagalan setup, `EPOLL` / `URING` ip tak ter-resolve `ResolveFailed` |
| `tcp/http2/log.zig` | `logSystem` menulis ke logger terpasang / jatuh ke std.log tanpa logger |
| `tcp/http2/CoalesceSink.zig` | default kosong, `reset` membuang byte yang di-stage, `append` men-stage write kecil / melewati buffer flush dulu, `flush` mengirim berurutan / tanpa stage tidak menulis, peer tertutup mengeset failed |
| `tcp/http2/coalesce.zig` | `beginCoalesce` memasang hook, `endCoalesce` melepas hook / melaporkan write gagal, satu batch keluar sebagai satu write |
| `tcp/http2/dispatch/async.zig` | `installCache` mati membersihkan / hidup memasang, `connEntry` melayani satu koneksi end to end, signature dispatch `run` / ip tak ter-resolve `ResolveFailed` |
| `tcp/http2/dispatch/epoll.zig` | `workerCount` eksplisit / nol minimal 1, `setNonBlock` mengeset O_NONBLOCK, `serveEvent` menjawab satu request / melepas write hook / HUP close / peer hang-up close, `acceptAll` tanpa koneksi tertunda / meregistrasi koneksi, `closeConn` membebaskan slot, `run` ip tak ter-resolve `ResolveFailed` / di luar Linux `Unsupported`, worker melayani satu koneksi end to end |
| `tcp/http2/dispatch/uring.zig` | round trip `user_data` / fd negatif, `workerCount` eksplisit / nol minimal 1, `handleAccept` meregistrasi / error membiarkan tabel kosong, `handleRecv` menjawab satu request / melepas write hook / hang-up menutup / generation basi diabaikan, `run` ip tak ter-resolve `ResolveFailed` / di luar Linux `Unsupported`, worker melayani satu koneksi end to end |
| `tcp/http2/Http2.zig` | mengekspos tipe engine, `HandlerFn` menerima trio, `HpackEntry` adalah `Header`, mengekspos `sendResponseStreamFD`, round trip frame header, `DEFAULT_WINDOW_SIZE` 65535, `MAX_PAYLOAD` 16384, berbagi dispatch model, round trip Huffman |
| `tcp/http2/router.zig` | terbangun saat comptime, exact match, EXACT di atas PREFIX, PREFIX terpanjang, PREFIX pada path prefix itu sendiri, PREFIX melewati batas segment 404, path tak dikenal Not Found, static mati dengan `public_dir` kosong, fallback static menyajikan file / menandai response terkirim |
| `tcp/http2/static.zig` | `zeroCopyAllowed` fd sentinel ditolak / fd asli di Linux, `rangeAsk` FULL (tidak ada, malformed) / UNSATISFIABLE / PARTIAL, `renderContentRange` dan `encodeHead` / `encodeUnsatisfiable` buffer kecil, `serve` traversal / hilang / direktori / melebihi `PUBLIC_PATH_MAX` false, HEADERS plus DATA, MIME type, dipotong sesuai frame size, file kosong END_STREAM di HEADERS, 206 Content-Range / panjang range, range terbuka, 416 / END_STREAM di HEADERS, Range malformed 200, range dipotong sesuai frame size, cache mati, 206 dari cache saat hit ulang, sibling brotli dari cache, `acquireHit` resident saat zero copy ditolak / tidak dibaca untuk sendfile, `fallback` tanpa root / path root / membuang slash, saat write hook diset: `zeroCopyAllowed` menolak / `acquireHit` mengambil byte resident / body resident di-frame lewat hook / sibling brotli lewat hook |

### zix.Grpc

| Modul | Cakupan |
| :- | :- |
| `tcp/http2/grpc/status.zig` | setiap kode sesuai nilai kanoniknya, setiap nilai kanonik kembali ke kodenya, OK adalah nilai nol, kode tak dikenal di atas 16 / u8 maksimum mempertahankan nilainya |
| `tcp/http2/grpc/frame/GrpcPrefix.zig` | menyimpan field-nya, menampung panjang pesan terbesar |
| `tcp/http2/grpc/frame/prefix.zig` | round-trip mempertahankan panjang pesan / flag compress, panjang big-endian, panjang u32 maksimum round-trip, byte flag bukan nol dibaca terkompresi, hanya membaca 5 byte pertama, 4 byte / body kosong TooShort |
| `tcp/http2/grpc/frame/reply_block.zig` | `HEADERS_PROTO_BLOCK` didekode menjadi status 200 dan content-type default, `TRAILER_OK_BLOCK` didekode menjadi grpc-status 0, keduanya sama dengan encoder dinamis |
| `tcp/http2/grpc/frame/builder.zig` | HEADERS dengan END_HEADERS, tipe default menyalin blok cache, tipe lain didekode menjadi status dan tipe, HEADERS gzip membawa grpc-encoding gzip, panjang DATA menghitung prefix, prefix memuat panjang pesan, compress memasang flag 1, `MAX_DATA_MSG_LEN` mengisi u24, trailer OK menyalin blok cache, trailer membawa status dan pesan, pesan kosong tanpa grpc-message, status u8 maksimum dienkode 255, error membawa status 200 dan content-type, error mengakhiri stream, out terlalu kecil / blok melewati scratch BufferFull, panjang melewati `MAX_DATA_MSG_LEN` Overflow |
| `tcp/http2/grpc/frame/send.zig` | frame HEADERS tertulis, DATA menulis prefix lalu pesan, pesan kosong hanya mengirim head, trailer mengakhiri stream, error menyertakan header `content-type`, pesan melewati scratch BufferFull, peer tertutup BrokenPipe |
| `tcp/http2/grpc/frame/gzip.zig` | round-trip memulihkan pesan, prefix hasil dekompresi ber-flag 0, pesan besar round-trip utuh, pesan kosong round-trip, pesan tanpa kompresi diteruskan, pesan campuran tetap berurutan, body kosong / sisa pendek tidak menulis apa pun, pesan melewati body / panjang u32 maksimum TruncatedBody, gzip rusak DecompressFailed, out terlalu kecil BufferTooSmall, keluaran diawali magic gzip, headroom muat untuk data tak terkompresi, out terlalu kecil CompressFailed |
| `tcp/http2/grpc/proto/wire_type.zig` | id sesuai encoding protobuf |
| `tcp/http2/grpc/proto/varint.zig` | 1 menjadi satu byte, 300 menjadi dua byte, u64 maksimum menjadi `MAX_LEN` byte, round-trip lintas ukuran, decode berhenti di byte akhir pertama, encode ke buf kosong / melewati buf BufferFull, input kosong / terpotong UnexpectedEOF, byte ke-10 melewati bit 0 / 11 byte Overflow |
| `tcp/http2/grpc/proto/field.zig` | string meng-encode tag, panjang, dan byte, string kosong panjang nol, int32 150 field varint, int32 negatif 10 byte nilai, round-trip double positif / negatif, string / int32 / double / buf kosong BufferFull |
| `tcp/http2/grpc/proto/ProtoField.zig` | menampung field varint, payload menunjuk ke sumbernya |
| `tcp/http2/grpc/proto/MessageReader.zig` | buf kosong null, membaca field string / varint / double / I32, membaca field secara berurutan, LEN melewati buf / LEN u64 maksimum / I64 pendek / I32 pendek / varint terpotong UnexpectedEOF, tipe wire group UnknownWireType, tag melewati 64 bit Overflow, nomor field melewati u32 FieldNumberTooLarge |
| `tcp/http2/grpc/timeout.zig` | setiap satuan diskalakan ke nanodetik, nol di depan mempertahankan nilai, digit sebanyak `MAX_DIGITS` diterima, nilai menit terbesar muat di u64, kosong / satuan tanpa digit InvalidFormat, melewati `MAX_DIGITS` TooManyDigits, bukan angka / tanda plus / tanda minus / underscore InvalidNumber, nol / semua digit nol NotPositive, satuan tak dikenal / s huruf kecil InvalidUnit, jam melewati u64 Overflow |
| `tcp/http2/grpc/window.zig` | stream window 16 MiB, stream window muat di batas maksimum RFC9113, connection bump 1 GiB, ambang replenish di bawah bump |
| `tcp/http2/grpc/GrpcPath.zig` | menyimpan kedua bagian |
| `tcp/http2/grpc/path.zig` | `parsePath` memisahkan service dan method, mempertahankan service bertingkat, tanpa service / slash di akhir / tanpa slash di depan / terlalu pendek / service kosong null, `headerPath` menemukan path, tanpa path kembali ke root |
| `tcp/http2/grpc/content_type.zig` | proto, json, tanpa subtype adalah PROTO, nama header tidak peka huruf besar-kecil, nilai bukan gRPC / tanpa header UNKNOWN |
| `tcp/http2/grpc/encoding.zig` | `headersHaveGzipEncoding` melihat gzip, mengabaikan identity, false tanpa header, `headersAcceptGzip` menemukan gzip dalam daftar, false tanpa gzip, `maybeDecompressBody` tanpa gzip mempertahankan body, meng-gunzip pesan terkompresi, rusak kembali ke body |
| `tcp/http2/grpc/deadline.zig` | `tighter` tanpa deadline saat ini mengambil kandidat, mempertahankan yang lebih awal, `tightenMs` nol membiarkan deadline, memasang deadline mendatang, mempertahankan deadline yang lebih awal, `computeDeadline` tanpa budget null, mengambil budget server, mengambil grpc-timeout yang lebih ketat, mempertahankan budget server yang lebih ketat, mengabaikan grpc-timeout rusak |
| `tcp/http2/grpc/cache.zig` | mulai tanpa cache, `setCache` menyimpan ttl, key tidak pernah nol, key membedakan path / body berbeda, key stabil, `nowMillis` tidak mundur, `installWorker` mati membersihkan cache / hidup memasang slot / mematuhi memory ceiling, `uninstallWorker` membersihkan slot |
| `tcp/http2/grpc/ServeOpts.zig` | default stream dan frame / buffer / handler, response cache mati |
| `tcp/http2/grpc/Stream.zig` | default IDLE dan kosong, `open` me-reset request, `appendBody` mengumpulkan body, melewati batas tidak menyalin apa pun, `headerList` mencakup header hasil dekode |
| `tcp/http2/grpc/stream_slot.zig` | `claim` mengambil entri kosong pertama, melewati batas null, `find` mengembalikan entri hidup, melewati entri yang dibebaskan, `requestInFlight` melihat stream yang belum berakhir, false saat semua stream berakhir / tabel kosong |
| `tcp/http2/grpc/ReplyStage.zig` | `append` menyimpan byte sampai flush, `flush` menulis byte yang di-stage, overflow melakukan flush lalu lanjut buffering, chunk melewati buffer ditulis langsung, peer mati memasang failed, flush tanpa isi membiarkan failed bersih |
| `tcp/http2/grpc/ConnReader.zig` | `take` menyajikan byte ter-buffer secara berurutan, `ensure` memadatkan buffer penuh, melewati buffer TooLarge, peer menutup di tengah baca Closed |
| `tcp/http2/grpc/ConnMutex.zig` | `create` mulai tidak terkunci dengan satu referensi, lock lalu unlock melepas kunci, `retain` menambah referensi, `streamingActive` mengikuti counter |
| `tcp/http2/grpc/Context.zig` | `init` menyimpan fd, stream id, dan body, `recvMessage` body kosong null, membaca satu / dua pesan berurutan, melewati body null, mulai tanpa deadline, `withTimeout` nol kedaluwarsa / mendatang belum kedaluwarsa, `withDeadline` lampau kedaluwarsa, `setTimeout` mengganti deadline, `sendHeaders` men-stage HEADERS sekali, balasan unary men-stage HEADERS, DATA, dan trailer, `finish` sebelum pesan adalah trailers-only, `finishIfOpen` menutup call yang terbuka, membiarkan call yang sudah selesai, stage gagal / peer mati BrokenPipe, content_type melewati scratch BufferFull, balasan gzip memasang flag compress, streaming memadatkan banyak pesan ke satu frame DATA, pack mematuhi batas frame, pesan melewati pack mendapat frame sendiri, frame DATA kecil satu write, DATA melewati inline cap dua write, `serveCached` tanpa cache / dengan path kosong miss, `sendCached` menyimpan dan `serveCached` memutar ulang |
| `tcp/http2/grpc/Request.zig` | `header` tidak peka huruf besar-kecil, tidak ada null, `recvMessage` membaca lewat context |
| `tcp/http2/grpc/Response.zig` | `sendMessage` diteruskan ke context, `finish` meneruskan status, stage mati BrokenPipe, `serveCached` tanpa cache miss |
| `tcp/http2/grpc/handler.zig` | `invoke` memanggil handler sekali, error dengan call terbuka menutupnya dengan INTERNAL, error setelah finish mempertahankan status handler, `rpcStart` tanpa logger null, `writeRpcRecord` tanpa logger tidak menulis apa pun |
| `tcp/http2/grpc/router.zig` | `Route` timeout_ms nol, is_server_streaming false, `dispatch` memanggil handler yang cocok, memasang deadline route, mempertahankan deadline yang lebih ketat, path tak dikenal UNIMPLEMENTED, `route_slice` membuka tabel, `routeIsStreaming` membaca flag route, path tak dikenal false |
| `tcp/http2/grpc/DispatchTask.zig` | `copyHeaders` mengarahkan header ke salinan, mempertahankan string static table, melewati scratch task menolak, `copyBody` menyalin body, melewati buffer task menolak, `spawn` menjalankan handler di thread |
| `tcp/http2/grpc/stream_dispatch.zig` | `dispatchInline` menjawab dalam satu balasan, `dispatchWhole` me-reset body pendek, melayani body utuh, route streaming berjalan di task |
| `tcp/http2/grpc/serve.zig` | `serveConn` prior knowledge menjawab satu call, preface rusak GOAWAY, upgrade h2c menjawab stream 1, method tak dikenal UNIMPLEMENTED, body pendek di-reset, body cocok dilayani, body melewati max_body RESOURCE_EXHAUSTED, frame melewati max_frame_size GOAWAY, hang-up dengan call belum selesai GOAWAY, hang-up idle tanpa GOAWAY, PING ACK dengan payload sama |
| `tcp/http2/grpc/Config.zig` | menyimpan field wajib, menyimpan dispatch model eksplisit, default worker / buffer / stream dan frame, handler_timeout_ms nol, compress mati, response cache mati, logger null, menyimpan port / kernel backlog terbesar, `serveOpts` membawa knob stream dan frame / buffer / handler / cache |
| `tcp/http2/grpc/server.zig` | `init` menyimpan config, port 0 `PortNotConfigured` / dicek sebelum model, `EPOLL` / `URING` di luar Linux dan `IOCP` tidak didukung, ip tak ter-resolve `ResolveFailed` (ASYNC, serta EPOLL / URING di Linux), pemetaan `dispatchEpollError` / `dispatchUringError` |
| `tcp/http2/grpc/log.zig` | `logSystem` menulis ke logger yang terpasang / jatuh ke std.log tanpa logger |
| `tcp/http2/grpc/dispatch/async.zig` | `installCache` mati mengosongkan / nyala memasang, `ConnEntry` melayani satu koneksi end to end, `run` ip tak ter-resolve `ResolveFailed` |
| `tcp/http2/grpc/dispatch/epoll.zig` (Linux) | `workerCount` eksplisit / nol, `setNonBlock`, `serveEvent` menjawab satu call / HUP dan ERR menutup / hang-up peer menutup, `acceptAll` mendaftarkan koneksi yang menunggu / tidak ada yang menunggu, `closeConn` membebaskan slot, `run` ip tak ter-resolve `ResolveFailed` / di luar Linux `Unsupported`, worker melayani satu call end to end lewat socket sungguhan |
| `tcp/http2/grpc/dispatch/uring.zig` (Linux) | `user_data` bolak-balik dan fd negatif, `workerCount` eksplisit / nol, `handleAccept` mendaftarkan / error membiarkan tabel kosong, `handleRecv` men-stage balasan dan mengirimnya lewat ring / hang-up saat idle menutup / hang-up di tengah request mengirim GOAWAY sebelum menutup / generation basi diabaikan, `handleSend` send parsial mengirim ulang sisanya / error menutup, `run` ip tak ter-resolve `ResolveFailed` / di luar Linux `Unsupported`, worker melayani satu call end to end lewat socket sungguhan |
| `tcp/http2/grpc/Grpc.zig` | mengekspos tipe engine, `HandlerFn` menerima trio, `Server.init` membangun server untuk Router, `Status` menyimpan nilai kode, `writePrefix` round trip lewat `readPrefix`, `encodeString` terbaca lagi lewat `MessageReader`, `parseTimeout` detik jadi nanodetik, `parsePath` memisah service dan method, berbagi dispatch model |
| `tcp/http2/grpc/mux/stream_pool.zig` | `acquire` mengukur buffer, release lalu acquire memakai ulang stream yang sama dalam keadaan reset, stream yang diambil lepas dari freelist, stream pool yang terlalu kecil diganti, dua pinjaman berbeda |
| `tcp/http2/grpc/mux/settings_frame.zig` | frame 33 byte, header SETTINGS di stream 0, membawa `max_streams` / window stream gRPC / `max_frame_size`, push mati |
| `tcp/http2/grpc/mux/stage_frame.zig` | `append` men-stage header lalu payload / payload kosong hanya header, `windowUpdate` membawa increment, `goaway` membawa last stream dan kode, `rstStream` membawa stream dan kode |
| `tcp/http2/grpc/mux/tcp_cork.zig` | socket pair menolak TCP_CORK, socket TCP menerimanya |
| `tcp/http2/grpc/mux/MuxConn.zig` | `init` menunggu preface / stage memakai buffer sendiri / membangun SETTINGS server, `rbuf` menampung satu frame melewati floor, `claimSlot` membuka stream / melewati `max_streams` null, `findSlot` tidak menemukan stream tak dikenal, `releaseSlot` membebaskan untuk dipakai ulang, slot di-pool antar koneksi, `requestInFlight` true saat terbuka / false setelah selesai, `compact` me-reset buffer kosong / memindah frame parsial / membiarkan buffer yang masih ada ruang |
| `tcp/http2/grpc/mux/mux_upgrade.zig` | head h2c 101 / pindah ke await_preface2, non-h2c 400 lalu tutup, head parsial menunggu, head yang memenuhi buffer menutup |
| `tcp/http2/grpc/mux/mux_dispatch.zig` | `dispatch` men-stage reply unary, reply streaming memadatkan pesan dalam satu DATA, `dispatchWhole` me-reset body pendek / berlebih / melayani body yang cocok, `hangupGoaway` GOAWAY saat request in flight / idle tidak ada apa-apa |
| `tcp/http2/grpc/mux/frame_loop.zig` | SETTINGS ACK dan window bump, SETTINGS ACK tidak men-stage apa pun, PING ACK, PING pendek / frame melewati batas `FRAME_SIZE_ERROR`, frame parsial menunggu, HEADERS di stream 0 `PROTOCOL_ERROR`, call utuh di-dispatch dan slot dibebaskan, CONTINUATION melengkapi / stream tak dikenal `PROTOCOL_ERROR`, id dipakai ulang `STREAM_CLOSED`, melewati `max_streams` `REFUSED_STREAM`, DATA melewati `max_body` RESOURCE_EXHAUSTED / DATA berikutnya `STREAM_CLOSED`, content-length pendek di-reset, RST_STREAM membebaskan slot, GOAWAY peer menutup |
| `tcp/http2/grpc/mux/process.zig` | `onReadable` prior knowledge dilayani / hang-up di tengah request GOAWAY / hang-up idle tanpa GOAWAY / upgrade h2c lalu preface, `processRing` men-stage tanpa write / preface parsial menunggu / preface rusak GOAWAY |
| `tcp/http2/grpc/client.zig` | `refAllDecls` + perilaku: `GrpcClient.connect` port nol menghasilkan `error.ZixPortNotConfigured` |

### zix.Http3

Layer HTTP/3 (QUIC) adalah pure-Zig dari RFC, jadi tiap modul membawa worked example dari spec-nya sendiri sebagai test in-file. `zix.Http3` juga mengekspor ini sebagai primitive (mengikuti `zix.Http2`), dan round trip live digerakkan oleh client native yang hand-rolled dari primitive itu di `test-runner-http3` / `test-runner-all`.

| Modul | Cakupan |
| :- | :- |
| `udp/http3/crypto.zig` | `refAllDecls` + perilaku: Initial secret / key AES-128-GCM dari connection id cocok dengan worked example RFC 9001 Appendix A.1, helper AEAD nonce dan header-mask |
| `udp/http3/protection.zig` | `refAllDecls` + perilaku: round-trip seal-lalu-open untuk packet Initial / Handshake / 1-RTT, header protection diterapkan dan dilepas, satu byte yang di-flip gagal AEAD |
| `udp/http3/keyschedule.zig` | `refAllDecls` + perilaku: handshake key dari ECDHE + transcript, application key 1-RTT dari handshake secret + transcript sampai Finished |
| `udp/http3/qpack.zig` | `refAllDecls` + perilaku: encode / decode prefixed-integer, indexed field line, literal-with-name-reference, entri static table |
| `udp/http3/huffman.zig` | `refAllDecls` + perilaku: decode vector `www.example.com` RFC 7541 Appendix C.4 dan sebuah request path dengan digit dan simbol |
| `udp/http3/varint.zig` / `packet.zig` / `frame.zig` | `refAllDecls` + perilaku: round-trip read / write varint, parse long / short header, parse frame CRYPTO dan STREAM |
| `udp/http3/request.zig` / `response.zig` | `refAllDecls` + perilaku: `parseRequest` memulihkan `:method` / `:path` melewati ACK di depan, `streamBytes` menjumlah byte payload stream lintas stream dan melewati frame non-stream, `buildResponse` membawa control SETTINGS plus balasan HEADERS / DATA dan menumpangkan grant MAX_STREAMS / MAX_DATA yang jatuh tempo (encode `buildMaxStreams` / `buildMaxData`) |
| `udp/http3/connection.zig` | `refAllDecls` + perilaku: `init` menurunkan Initial key dari connection id (RFC 9001 A.1), cap anti-amplification 3x, `sendDatagramSize` meng-clamp ke config / client / ceiling, `replenishBidiStreams` dan `replenishMaxData` menaikkan grant melewati allowance sekali-pakai, batas pool `reserveSendStream`, pelacakan lubang `AckTracker`, sampling RTT `onAckFrame` |
| `udp/http3/router.zig` | `refAllDecls` + perilaku: dispatch memanggil handler yang cocok, query di-strip sebelum matching, tidak ada match mengembalikan 404 |
| `udp/http3/config.zig` / `server.zig` | `refAllDecls` + perilaku: field config wajib dan default, `Tls.Context` null ditolak saat run |
| `udp/http3/static.zig` | `refAllDecls` + perilaku: content-encoding hanya memetakan yang bisa dikirim jalur respons, serve menolak ketika caching mati (body harus hidup lebih lama dari handler, jadi hanya bisa dari cache), respons diisi dari byte cache dan pin DITAHAN, body tetap terbaca setelah frame handler hilang, sibling `.br` dipilih dan dinamai, traversal dan file hilang ditolak, tepat satu pin ditahan dan `releasePin` mengembalikannya, pin yang dilepas membuat entry bisa di-reclaim, body in-flight kebal terhadap file yang ditulis ulang di tempat |

### zix.Webrtc

Setiap lapis WebRTC ditulis dari RFC-nya sendiri, jadi setiap berkas membawa test-nya di dalam
berkas dan lapis yang punya vector terbit dipatok byte demi byte terhadapnya. `zix.Webrtc` juga
mengekspor lapisnya sebagai primitif, sehingga peer atau harness test bisa membangun sisi seberang.

| Modul | Cakupan |
| :- | :- |
| `udp/webrtc/demux.zig` | `refAllDecls` + perilaku: setiap byte pertama dirutekan ke kind RFC 7983 bagian 7 miliknya, termasuk rentang yang belum ada di teks RFC 5764 |
| `udp/webrtc/stun/message.zig` | `refAllDecls` + perilaku: vector XOR-MAPPED-ADDRESS `192.0.2.1:32853` byte demi byte, framing ketat (byte sisa dan attribute terakhir tanpa padding ditolak), MESSAGE-INTEGRITY di atas panjang header yang ditulis ulang |
| `udp/webrtc/stun/binding.zig` | `refAllDecls` + perilaku: aturan request RFC 8489 bagian 6.3.1, silent discard dan buffer terlalu kecil sama-sama melaporkan null |
| `udp/webrtc/ice/*.zig` | `refAllDecls` + perilaku: sample request RFC 5769 bagian 2.1 memaku MAC, CRC dan dua tipe atribut sekaligus, pemisahan USERNAME dengan ufrag agent ini di depan, 487 untuk setiap tiebreaker, 400 dan 401 tanpa tanda tangan berbanding 420 dan 487 yang ditandatangani |
| `udp/webrtc/sctp/*.zig` | `refAllDecls` + perilaku di 20 berkas: CRC32c ditulis little endian dengan polinomial Castagnoli, gap ack block sebagai offset, missing report hanya dihitung di bawah TSN tertinggi yang baru di-ack, handshake 4 arah penuh plus data, heartbeat, shutdown dan abort antara dua association di memori |
| `udp/webrtc/datachannel/*.zig` | `refAllDecls` + perilaku: tujuh payload type, round-trip DCEP OPEN dan ACK, paritas stream identifier menurut role DTLS, pesan dilaporkan mendahului penutupan, pemrosesan reset yang ditunda, dua peer bicara di memori |
| `udp/webrtc/sdp/*.zig` | `refAllDecls` + perilaku di 18 berkas: CRLF dan LF telanjang sama-sama terbaca, pencarian media section mendahului level session, `a=sctp-port` yang hilang ditolak, session id dibatasi 62 bit, dan candidate ditulis di setiap media section yang dibawa |
| `udp/webrtc/media/*.zig` | `refAllDecls` + perilaku: RFC 3711 B.2 dan B.3 serta RFC 2202 kasus 1 dipatok byte demi byte, label KDF di-XOR pada byte 7, satu profile membawa dua panjang tag, estimate ROC dipisah dari accept, index SRTCP berhenti alih-alih berputar |
| `udp/webrtc/dispatch/*.zig` | `refAllDecls` + perilaku: `pass()` tiap model menjalankan sesi utuh terhadap socket sungguhan yang di-bind dengan `Dialer` sungguhan, sehingga perbedaan antar model adalah perbedaan pada loop |
| `udp/webrtc/config.zig` / `server.zig` | `refAllDecls` + perilaku: setiap penolakan `run()` berurutan (port, credential ICE ada, credential ICE sah, TLS ada, kunci ECDSA P-256, dispatch model terhadap platform) |
| `tls/dtls_*.zig` | `refAllDecls` + perilaku: anti-replay diperiksa sebelum AEAD dan diperbarui sesudahnya, perakitan ulang dilacak bitmap sehingga fragment tumpang tindih tetap sah, record sequence dibawa melewati HelloVerifyRequest, ekspor RFC 5705 dalam bentuk seed tanpa context |

### zix.Logger

| Modul | Cakupan |
| :- | :- |
| `logger/logger.zig` | `refAllDecls` + perilaku: init dan deinit tanpa save_path, system() di bawah save_min_level tidak menghasilkan output, access() di bawah save_min_level tidak menghasilkan output, pemetaan statusLevel (100=DEBUG 200=INFO 301=INFO 404=WARN 500=ERROR), conn/packet/frame/session/rpc di bawah save_min_level tidak menghasilkan output |

### zix.Utils

| Modul | Cakupan |
| :- | :- |
| `utils/file.zig` | `refAllDecls` + perilaku: exists melaporkan path yang ada dan tidak ada, extension mengembalikan suffix setelah titik terakhir, save dan load bolak-balik, load menolak file di atas max_bytes, load menamai path yang hilang dan direktori, save menolak path yang terlalu panjang |
| `utils/Multipart.zig` | perilaku: mem-parse field form dan field file, getField mengembalikan null untuk nama yang tidak dikenal, menjaga byte file berupa CR atau LF, menerima boundary penutup tanpa CRLF, menjaga konten yang mengeja boundary, melewati preamble, melewati part tanpa nama atau tanpa akhir header, membaca nama ber-quote saat filename datang lebih dulu, data file meminjam body, mem-parse body dengan banyak part. Edge: body kosong atau body tanpa boundary adalah missing boundary, body terpotong unterminated, quote nama yang tidak ditutup membuat part tanpa nama, gagal alokasi adalah out of memory |
| `utils/MultipartField.zig` | menyimpan part file, part form tidak punya filename |
| `utils/media_type.zig` | `refAllDecls` + perilaku: `stripParameters` melepas parameter charset, membiarkan nilai polos apa adanya, memangkas spasi sebelum parameter, menjaga boundary multipart keluar dari hasil, menangani lebih dari satu parameter, menghasilkan kosong untuk nilai kosong atau titik koma tunggal. `equalIgnoreParameters` mengabaikan case, menolak subtype berbeda, dan menolak prefix yang bukan keseluruhan type |
| `utils/cache/ResponseCache.zig` | perilaku: menyimpan dan kedaluwarsa, menolak value melewati batas slot, `hitSlot` menolak slice asing, jumlah entry dibulatkan turun ke power of two, ukuran nol turun ke satu slot |
| `utils/cache/CacheSize.zig` | menyimpan jumlah slot dan batas value, menyimpan nilai nol apa adanya |
| `utils/cache/CacheEntry.zig` | menyimpan cache dan generation, menampung generation maksimum |
| `utils/cache/CacheRegistry.zig` | mulai kosong dan tidak terkunci, lock / unlock / lock ulang, lock mengecualikan thread lain, `freeUpTo` tidak membebaskan apa pun saat kosong atau di bawah semua generation / membebaskan generation lama termasuk yang persis sama / menjaga generation lebih baru / melepas list hanya saat kosong |
| `utils/cache/async.zig` | `acquire` memakai ulang satu cache per thread (satu per thread, bukan per panggilan), cache yang diambil menyimpan dan hit, build yang gagal tidak diulang dalam satu generation tapi diulang di generation baru, `reclaim` langsung membebaskan tanpa koneksi aktif / menunggu koneksi aktif / tidak membebaskan apa pun pada kali kedua / menjaga generation lebih baru, `release` terakhir membebaskan hanya setelah semua hold selesai, `acquire` setelah `reclaim` membangun generation baru |
| `utils/static/StaticCache.zig` | `init` dibulatkan turun ke power of two (nol entry tetap memberi satu slot), `acquire` meng-cache file sekali dan hit membaca byte file, file yang hilang tidak meng-cache apa pun, ttl 0 tidak pernah menyentuh tabel, traversal null, sibling precompressed dinegosiasi, entry kedaluwarsa dibuka ulang, slot yang di-pin selamat dari lookup kedaluwarsa, tabel penuh yang ter-pin null, tabel penuh menyapu entry yang tidak di-pin, `release` melepas pin, `acquireMapped` membawa byte resident dan memetakan sibling terpilih |
| `utils/static/StaticCacheRegistry.zig` | mulai tanpa tabel, ttl 0 nonaktif, `install` membangun tabel, setelan sama berbagi tabel, setelan lain MISMATCHED, `shutdown` membersihkan tabel dan no-op tanpa tabel |
| `utils/static/StaticSlot.zig` | slot nol tidak live, pin pada slot mati gagal, pin / unpin menghitung, pin melewati batas ditolak, `tryKill` gagal saat di-pin dan berhasil saat tidak, `isFresh` di dalam window dan stale di ujungnya, `openVariants` menemukan sibling (false tanpa identity), `hit` memilih br saat diterima dan turun ke identity tanpa sibling |
| `utils/static/StaticVariant.zig` | `open` membaca ukuran dan type, me-render header, mengambil type dari type_path, false untuk file yang hilang atau direktori, `map` men-snapshot byte (file kosong jadi slice kosong), false tanpa file atau melewati SNAPSHOT_MAX_BYTES, `close` membersihkan present |
| `utils/static/StaticHit.zig` | bytes default null, menyimpan encoding terpilih |
| `utils/static/StaticSibling.zig` | brotli lebih dulu, gzip kedua, tanpa sibling identity atau deflate |
| `utils/static/cache_path.zig` | `resolve` menggabungkan root dan path serta menjaga path bersarang, null untuk path kosong, traversal di awal atau di dalam, path absolut, atau melewati PUBLIC_PATH_MAX. `hash` stabil, beda per path, tidak pernah nol |
| `utils/static/cache_header.zig` | `render` diawali baris 200, menyebut panjang, identity membawa Vary tanpa Content-Encoding, br menyebut coding-nya, buffer terlalu kecil null, bentuk terpanjang muat di HEADER_MAX. `variantIndex` memisahkan tiga coding, deflate turun ke identity |
| `utils/static/cache_descriptor.zig` | ceiling tetap di atas atau sama dengan floor, `fromLimit` mengambil seperempat, limit kecil memakai floor, limit tidak diketahui turun ke fallback, limit besar dibatasi u32 max |
| `utils/static/install_result.zig` | punya empat outcome, outcome berbeda satu sama lain |
| `utils/static/static.zig` | jalur copy menulis seluruh body, menghormati offset dan panjang, loop melewati buffer, panjang nol tidak menulis apa pun, tulis gagal jadi BrokenPipe, file lebih pendek dari range jadi FileTruncated. Khusus Linux: zero copy mengirim byte, menghormati offset dan panjang, peer tertutup jadi BrokenPipe |
| `utils/dispatch_support.zig` | belum di-port |
| `utils/socket_poll.zig` | belum di-port |
| `utils/counter_scale.zig` | belum di-port |

### multiplexers (src/multiplexers/, internal)

| Modul | Cakupan |
| :- | :- |
| `multiplexers/ring.zig` | `refAllDecls` + perilaku: round-trip `user_data` io_uring mempertahankan `{ op, gen, fd }`, setiap varian `OpKind` (`accept` / `recv` / `send` / `timeout` / `close`) ter-decode kembali, generation maksimum tidak bocor ke field fd |
| `multiplexers/reuseport.zig` | `steeringProgram` memuat cpu / mengambil modulo ukuran grup / mengembalikan accumulator, layout C `SockFilter` dan `SockFprog`, grup kosong tidak bisa steer, listener reuseport menerima program |
| `multiplexers/cpu_affinity.zig` | `orderPhysicalCoresFirst` core berbeda lebih dulu / key unik mempertahankan urutan / list kosong, `maskCpus` terendah dulu / berhenti di panjang out, `readTopologyValue` cpu hilang null, `availableCpuCount` minimal 1, `pinToCpu` thread tetap jalan |

---

## Pengujian Integrasi

Sumber: `tests/integration/`. Setiap berkas adalah executable pengujian mandiri yang dikompilasi dengan modul `zix` yang diimpor. Pengujian ini menguji komponen yang dihubungkan terhadap input tiruan, tanpa socket aktif, tanpa scheduler `std.Io`.

### tests/integration/tcp/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `TcpServer.init` konfigurasi valid | init dengan ip dan port nyata berhasil, deinit aman |
| `TcpServer.init` dispatch model EPOLL | init dengan dispatch model `.EPOLL` berhasil, deinit aman |
| `TcpServer.init` port nol | menghasilkan `error.ZixPortNotConfigured` |
| Pemeriksaan tipe `HandlerFn` | `zix.Tcp.echoHandler` memenuhi `zix.Tcp.HandlerFn` |
| `TcpClient.connect` port nol | menghasilkan `error.ZixPortNotConfigured` sebelum pemanggilan socket apa pun |

### tests/integration/http1/

#### `server_test.zig`

| Tes | Yang diverifikasi |
| :- | :- |
| `Http1Server.init` config valid, deinit aman | init berhasil dan deinit tidak error |
| `Http1Server.init` dispatch model URING | model diterima dan disimpan |
| `Http1Server.init` dispatch model EPOLL | model diterima dan disimpan |
| `Http1Server.init` dispatch model URING | model diterima dan disimpan |

#### `router_test.zig`

| Tes | Yang diverifikasi |
| :- | :- |
| Dispatch router mengarah ke handler yang cocok | path exact sampai ke handler-nya |
| Dispatch router memilih route yang benar di antara beberapa | handler yang tepat menang saat beberapa terdaftar |
| Dispatch router path tak dikenal menulis 404 | tanpa kecocokan jatuh ke 404 |

#### `tls_dual_test.zig`

| Tes | Yang diverifikasi |
| :- | :- |
| Dual listener EPOLL melayani cleartext di port | kaki cleartext menjawab di `port` |
| Dual listener EPOLL melayani TLS di tls_port dengan route yang sama | kaki TLS melayani tabel route yang sama |
| Dual listener URING melayani cleartext di port | kaki cleartext menjawab di bawah ring |
| Dual listener URING melayani TLS on-ring di tls_port | kaki TLS berjalan di ring |
| Dual listener ASYNC melayani cleartext di port | kaki cleartext menjawab di model thread |
| Dual listener ASYNC melayani TLS via accept thread tambahan | kaki TLS mendapat accept thread sendiri |
| `tls_port` sama dengan `port` ditolak saat run | mengembalikan `error.ZixTlsPortConflict` |

#### `static_cache_test.zig`

Menjalankan jalur router sungguhan lewat socketpair, jadi yang diuji adalah byte yang diterima klien.

| Tes | Yang diverifikasi |
| :- | :- |
| Router menyajikan path tak cocok dari static cache | 200 dengan content type dan body yang benar |
| Router tetap 404 untuk path tak cocok tanpa file di baliknya | file yang tidak ada tetap 404 |
| Router menjaga path ber-route di depan static cache | handler ber-route menang atas file yang akan menutupinya |
| Router mengulang file yang di-cache byte demi byte antar request | header dan body yang diputar ulang identik dengan respons dingin |
| Router menyajikan file yang sama tanpa cache ketika tidak ada cache terpasang | default bawaan tetap melayani lewat jalur lama |

### tests/integration/websocket/

#### `websocket_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `parseFrame` opcode binary | round-trip FIN, opcode, payload |
| `parseFrame` ping dengan payload | opcode, konten payload |
| `parseFrame` opcode pong | opcode |
| `parseFrame` close dengan payload kosong | opcode, payload panjang nol |
| Round-trip semua opcode | buildFrame -> parseFrame untuk text, binary, ping, pong, close |

### tests/integration/udp/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `UdpServer.init` konfigurasi valid | init dengan ip dan port nyata berhasil |
| `UdpServer.init` port nol | menghasilkan `error.ZixPortNotConfigured` |
| `UdpClient.init` bind_port nol | menghasilkan `error.ZixPortNotConfigured` sebelum pemanggilan socket apa pun |

#### `packet_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Round-trip LITTLE | `toEndian` -> `fromEndian` memulihkan byte asli |
| Round-trip BIG | sama untuk endian BIG |
| Nilai `FeedbackResult.packet` | varian `.packet` menyimpan dan mengembalikan packet lengkap |

### tests/integration/uds/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `UdsServer.init` path valid | berhasil dan `deinit` aman |
| Pemeriksaan tipe `HandlerFn` | `zix.Uds.echoHandler` memenuhi `zix.Uds.HandlerFn` |

### tests/integration/logger/

#### `logger_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `Logger.system()` menulis baris ke berkas | tag `[component]` dan teks pesan muncul di berkas log |
| `Logger.access()` menulis baris ke berkas | method, path, status, bytes semuanya muncul di berkas log |
| UA dan origin yang tidak ada dicatat sebagai strip | argumen `""` kosong menghasilkan `"-"` di field yang dikutip |
| UA yang ada muncul di berkas | string UA tidak kosong ditulis apa adanya |
| Status 5xx dipetakan ke level ERROR | `access()` dengan status 500 menulis label `ERROR` |
| Argumen `anyerror` diformat dengan benar | format `{}` dari nilai error menghasilkan nama error |

### tests/integration/fix/

#### `server_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `FixServer` init dan deinit tidak error | konfigurasi valid berhasil, deinit aman |
| `FixServer` init port nol | menghasilkan `error.ZixPortNotConfigured` |
| Handshake Logon dan round-trip echo berhasil | kirim Logon, terima balasan Logon dengan MsgType=A kirim NewOrderSingle, terima echo, kirim Logout, terima balasan Logout |
| Beberapa pesan berurutan semuanya di-echo | tiga pesan NewOrderSingle di-echo dengan ClOrdID tersimpan di semua |

### tests/integration/http2/

#### `server_test.zig`

Port: 18082-18085.

| Pengujian | Yang diverifikasi |
| :- | :- |
| `Http2Server.init` dan deinit tidak error | konfigurasi valid berhasil, deinit aman |
| `Http2Server.init` port nol | menghasilkan `error.ZixPortNotConfigured` |
| Tipe `Http2 HandlerFn` adalah function pointer | penugasan `zix.Http2.HandlerFn` berhasil dikompilasi |
| Http2 GET / mengembalikan Hello World melalui h2c direct | round-trip h2c preface PRI + HEADERS + DATA mengembalikan body response |
| Http2 POST /echo mengembalikan body request | POST dengan frame DATA body, server meng-echo body kembali |
| Http2 dua stream berurutan pada koneksi yang sama | stream ID 1 dan 3 masing-masing menerima response yang benar |
| Http2 h2c upgrade GET / mengembalikan Hello World | HTTP/1.1 `Upgrade: h2c` -> 101 Switching Protocols -> response h2c |

### tests/integration/http3/

#### `static_test.zig`

Membangun trio yang dibangun engine lalu memanggil `Router.dispatch`, jadi yang diuji adalah respons
yang akan dibingkai engine, termasuk pin cache yang dikembalikannya.

| Tes | Yang diverifikasi |
| :- | :- |
| Router menyajikan path tak cocok dari static cache | 200, body dan content type benar, dan `static_slot` dikembalikan masih ter-pin |
| Router 404 untuk path tak cocok tanpa file di baliknya | file yang tidak ada adalah 404 dan tidak ada pin diambil |
| Router menjaga path ber-route di depan fallback static | handler ber-route menang atas file yang akan menutupinya |
| Router 404 untuk path static ketika caching mati | file-nya ada, tapi engine ini tidak punya sumber body yang aman tanpa cache |
| Router menyajikan body multi-paket yang hidup lebih lama dari panggilan dispatch | body 64 KiB terbaca utuh setelah Context hilang |

### tests/integration/webrtc/

#### `exchange_test.zig`

Gerbang exit CI untuk engine ini: satu sesi utuh antara dua peer di memori, tanpa port dan tanpa
sleep. Inilah yang membuktikan delapan lapis sans-I/O sepakat ketika dua instance independen bertemu.

| Test | Yang diverifikasi |
| :- | :- |
| Dialer dan answerer membawa satu pesan dari ujung ke ujung | ICE, DTLS, SCTP dan DCEP semuanya selesai, dan payload selamat pulang pergi |
| Answerer menominasikan pair asal check tersebut | agent ice-lite memilih berdasarkan check terverifikasi, bukan candidate karangannya sendiri |
| Channel mendarat di identifier genap karena dialer yang membukanya | role DTLS menentukan paritas, dan salah di sini tidak terlihat terhadap peer yang berbagi kesalahan yang sama |
| Tidak ada peer yang ditinggali deadline yang tidak akan pernah terpenuhi | setiap timer yang dipasang sesi itu terpenuhi atau dipensiunkan |

### tests/integration/grpc/

#### `server_test.zig`

Port: 18200-18206.

| Pengujian | Yang diverifikasi |
| :- | :- |
| `GrpcServer.init` dan deinit tidak error | konfigurasi valid berhasil, deinit aman |
| `GrpcServer.init` port nol | menghasilkan `error.ZixPortNotConfigured` |
| gRPC unary mengembalikan salam | `greetHandler` membaca satu pesan, membalas `"Hello, world!"` |
| gRPC server streaming mengirim beberapa response | `echoHandler` mengirim dua pesan, client menerima keduanya berurutan |
| gRPC client streaming mengumpulkan semua pesan | `collectHandler` menyangga tiga pesan, membalas dengan jumlah `"got 3"` |
| gRPC bidirectional meng-echo setiap pesan | `echoHandler` meng-echo `"ping"` lalu `"pong"` dari dua pesan client |
| gRPC method tidak dikenal mengembalikan UNIMPLEMENTED | `dispatchHandler` membalas dengan `GrpcStatus.UNIMPLEMENTED` untuk path tidak dikenal |
| gRPC error trailers-only diterima sebagai INVALID_ARGUMENT | `errorOnlyHandler` memanggil `res.finish(INVALID_ARGUMENT, ...)` tanpa mengirim data, client menerima status error |
| gRPC dua stream pada koneksi yang sama keduanya mengembalikan OK | dua RPC unary berurutan pada satu koneksi, kedua stream menerima respons yang benar |

### tests/integration/channel/

#### `channel_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Kapasitas init `Channel(u32)` | `buf.len == 8`, `count == 0`, `head == 0` |
| `Channel([]const u8)` berhasil dikompilasi | tipe elemen slice diterima |
| `Channel(struct)` berhasil dikompilasi | tipe elemen struct diterima |
| Round-trip send dan recv `Channel(u32)` | send lalu recv mengembalikan nilai yang dikirim |
| `Channel(u32)` drain setelah close | kirim dua item, close, recv keduanya, recv ketiga menghasilkan `error.ZixClosed` |

---

## Pengujian Perilaku

Sumber: `tests/behaviour/`. Setiap berkas memverifikasi kontrak API yang dapat diamati yang diandalkan oleh pemanggil: properti "apa yang selalu dilakukan ini".

### tests/behaviour/dispatch/

#### `platform_gate_test.zig`

Kontrak platform `DispatchModel` lintas-engine (ADR-065), dipastikan sekali untuk seluruh tree.

| Pengujian | Yang diverifikasi |
| :- | :- |
| `DispatchModel` adalah satu tipe bersama | setiap namespace engine (Tcp, Http, Http1, Http2, Grpc, Fix, Udp, Http3) mengekspor ulang tipe yang sama |
| `DispatchModel` berisi tepat ASYNC, EPOLL, URING | switch exhaustive tanpa arm else, jadi varian keempat merusak build |
| nama POOL dan MIXED yang dilepas tidak lagi resolve | `std.meta.stringToEnum` mengembalikan null untuk keduanya |
| nilai backing gapless dengan ASYNC sebagai nol | 0 / 1 / 2, dan config zero-init mendarat di model portabel |
| `isSupported` menerima ASYNC di mana pun | model portabel tidak pernah ditolak |
| `isSupported` menggerbangi EPOLL dan URING pada os target | true hanya pada target Linux |
| model yang ditolak dinamai di baris log | `rejectedName` mengembalikan tag model, jadi operator melihat mana yang ditolak |
| config ASYNC diterima setiap engine | init menyimpan model portabel tanpa memulai accept loop |
| engine grpc menerima model bersama di server ber-tipe Router | `Grpc.Server.init(Router(&routes), ...)` menyimpan `.ASYNC` |

### tests/behaviour/tcp/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Default dispatch_model `TcpServerConfig` | `.ASYNC` (nilai nol) |
| Default kernel_backlog `TcpServerConfig` | 4096 |
| Default max_recv_buf `TcpServerConfig` | 4096 |
| Default workers `TcpServerConfig` | 0 (otomatis) |
| Default max_recv_buf `TcpClientConfig` | 4096 |
| Header panjang frame TCP | u32 big-endian 4-byte di-encode dan di-decode dengan benar |
| Payload panjang nol frame TCP | di-encode sebagai empat byte nol |
| Ukuran header frame TCP | selalu tepat 4 byte |
| `DispatchModel.ASYNC` adalah nilai nol | `@intFromEnum(.ASYNC) == 0` |

### tests/behaviour/http1/

#### `config_test.zig`

| Tes | Yang diverifikasi |
| :- | :- |
| `dispatch_model` wajib dan disimpan apa adanya | field round-trip |
| `workers` default nol (auto) | nol berarti auto-size |
| Default `kernel_backlog` 1024 | default bawaan |
| Default ukuran buffer | `max_recv_buf` 6 KiB, `compression_max_out` 256 KiB |
| Default kompresi | mati, `min_size` 256, `max_out` 256 KiB |
| Nilai backing integer `DispatchModel` | `ASYNC` adalah nilai nol |
| Static cache mati secara default | `public_dir_cache_ttl_ms` 0, `public_dir_cache_max_entries` 256 |
| Field static cache disimpan apa adanya | keduanya round-trip |
| Knob static cache independen dari knob response cache | kedua cache tidak berbagi state |

#### `core_test.zig`

| Tes | Yang diverifikasi |
| :- | :- |
| `parseHead` mengekstrak method, path, dan versi | request line dipisah dengan benar |
| `parseHead` HTTP/1.1 default keep_alive true | persistensi default RFC |
| `parseHead` `Connection: close` mematikan keep_alive | header menimpa default |
| `getHeader` mengembalikan nilai tanpa peduli kapitalisasi | lookup header mengabaikan case |
| `queryParam` mengembalikan nilai untuk param bernama | parsing query berdasarkan nama |

#### `query_test.zig`

Dukungan QUERY RFC 10008 lewat permukaan publik `zix.Http1`.

| Pengujian | Yang diverifikasi |
| :- | :- |
| `parseHead` membaca QUERY dari request line | token method bertahan melewati parse |
| `Request.method` menyelesaikan request QUERY menjadi QUERY | kode bertipe, bukan fallback |
| Request QUERY bisa dibedakan dari GET | defect yang ditutup: token tak dikenal dulu jatuh ke GET |
| Request QUERY membawa content-nya seperti POST | framing Content-Length dan pengantaran `body()` |
| Request QUERY memaparkan Content-Type yang dideklarasikan | section 2 butuh handler bisa membacanya |
| QUERY tanpa Content-Type melaporkan tidak ada type | kasus 400 |
| Query content type yang tidak didukung melaporkan tidak ada kecocokan, tidak pernah ditebak | section 2.1 melarang menebak dari body |
| Semua query content type yang disebut RFC 10008 dikenali | sql, jsonpath, graphql, x-www-form-urlencoded, multipart/form-data |
| Response QUERY tidak pernah masuk request cache key | section 2.7, key-nya tidak membawa content |
| Menolak QUERY tidak membuat GET di path sama ikut tidak bisa di-cache | penolakan hanya untuk method itu |
| Query content type menyusun nilai Accept-Query yang valid | section 3, sf-list RFC 9651 berisi bare item |
| Method yang tidak diimplementasikan menarik 501, bukan jawaban salah | RFC 9110 section 15.6.2 |
| QUERY diimplementasikan, jadi ia di-parse dan bukan menarik 501 | gate yang menolak method tak dikenal meloloskan QUERY |

### tests/behaviour/websocket/

#### `websocket_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Bit FIN selalu diset | byte[0] & 0x80 untuk text, binary, ping, pong, close |
| Frame server tidak bermasker | byte[1] & 0x80 == 0 untuk semua opcode (RFC 6455 5.1) |

### tests/behaviour/udp/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `UdpServerConfig` conn_timeout_ms | default 5000 |
| `UdpServerConfig` poll_timeout_ms | default 2000 |
| `UdpServerConfig` auto_ack | default false |
| `UdpServerConfig` broadcast | default false |
| `UdpServerConfig` endianness | default LITTLE |
| `UdpServerConfig` allow_args | default false |
| Re-export `Udp.DispatchModel` | resolve ke enum dispatch bersama |
| `UdpClientConfig` endianness | default LITTLE |
| `UdpClientConfig` recv_timeout_ms | default 0 (nonaktif) |

#### `packet_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `toEndian` NATIVE adalah operasi tanpa efek | byte tidak berubah pada host apa pun |
| Field array u8 tidak pernah ditukar | `id [4]u8` tidak disentuh oleh LITTLE dan BIG |
| Non-native menukar field integer | field `i32` di-byte-swap |
| Non-native menukar elemen float array | elemen `[2]f64` masing-masing ditukar |

### tests/behaviour/uds/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Default backlog `UdsServerConfig` | 128 |
| Default max_recv_buf `UdsServerConfig` | 4096 |
| `UdsClientConfig` menyimpan path | field path tersimpan |
| Header panjang frame UDS | u32 big-endian 4-byte di-encode dan di-decode dengan benar |
| Payload panjang nol frame UDS | di-encode sebagai empat byte nol |
| Ukuran header frame UDS | selalu tepat 4 byte |

### tests/behaviour/fix/

#### `session_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Response Logon memiliki MsgType=A dan CompID ditukar | balasan tag-35="A", tag-49=SERVER, tag-56=CLIENT, tag-34=1 |
| Field body NewOrderSingle tersimpan dalam echo | tag-11 (ClOrdID), tag-55 (Symbol), tag-54 (Side), tag-38 (Qty) semuanya ada dalam echo |
| Logout bersih tidak menyebabkan error di sisi server | field error server adalah null setelah pertukaran Logout |

### tests/behaviour/logger/

#### `logger_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Nilai backing `Level` | DEBUG=0 INFO=1 WARN=2 ERROR=3 |
| Nilai backing `ConsoleMode` | OFF=0 DEBUG_ONLY=1 ALWAYS=2 |
| Default `Config` | console=OFF, console_min_level=INFO, save_path="", save_file="log", save_min_level=INFO, max_lines=1_000_000 |
| `Logger` init dan deinit tanpa save_path | tanpa crash atau leak |
| `Logger` flush tanpa save_path adalah operasi tanpa efek | tanpa crash |
| `Http.ServerConfig.logger` default ke null | invarian `cfg.logger == null` |
| `Http.Context.logger` default ke null | invarian `ctx.logger == null` |
| `Http.Response.bytes_written` default ke 0 | `res.bytes_written == 0` setelah `init()` |

### tests/behaviour/http2/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `Http2ServerConfig` dispatch_model wajib (tidak ada default) | pemanggil harus menyetelnya eksplisit |
| `Http2ServerConfig` max_streams default ke 128 | invarian `max_streams == 128` |
| `Http2ServerConfig` max_frame_size default ke 16384 | invarian `max_frame_size == 16384` |
| `Http2` HandlerFn dapat ditugaskan ke variabel lokal | penugasan tipe `zix.Http2.HandlerFn` berhasil dikompilasi |
| Panjang `Http2` PREFACE adalah 24 | `zix.Http2.PREFACE.len == 24` |
| `Http2` ERR_NO_ERROR adalah nol | `zix.Http2.ERR_NO_ERROR == 0` |
| `Http2` FLAG_END_STREAM dan FLAG_END_HEADERS berbeda | `FLAG_END_STREAM != FLAG_END_HEADERS` |

### tests/behaviour/http3/

#### `config_test.zig`

| Tes | Yang diverifikasi |
| :- | :- |
| Penyajian static mati secara default | `public_dir` kosong, ttl 0, 256 entry |
| Field static disimpan apa adanya | ketiganya round-trip |
| Penyajian static butuh caching, berbeda dari engine lain | mengunci asimetri yang disengaja: di Http3 ttl 0 mematikan penyajian static sepenuhnya, karena body respons hidup lebih lama dari handler-nya |

### tests/behaviour/webrtc/

#### `session_test.zig`

| Test | Yang diverifikasi |
| :- | :- |
| Peer menjawab connectivity check sebelum apa pun dinegosiasikan | ICE berjalan mendahului DTLS, jadi check dijawab pada peer yang belum punya sesi |
| Association baru ada setelah handshake selesai | SCTP berada di dalam DTLS, jadi tidak ada yang terbaca sebelum handshake selesai |
| Peer yang diam dilepas pada deadline idle-nya | `peer_idle_ms` ditegakkan, dan itulah yang menangani browser menutup tab |
| Setiap datagram mendorong mundur deadline idle | peer yang hidup tapi diam tidak ikut dilepas |
| Dialer terus bertanya sampai satu check dijawab | timer retransmit yang menggerakkan sisi client, bukan hitungan tetap |

### tests/behaviour/grpc/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Default `GrpcServerConfig` | dispatch_model=ASYNC, kernel_backlog=1024, workers=0, max_streams=128, max_frame_size=16384, max_body=16384 |
| Field dasar `GrpcClientConfig` | field ip dan port tersimpan |
| Nilai enum `GrpcStatus` | OK=0, CANCELLED=1, UNIMPLEMENTED=12, UNAUTHENTICATED=16 |
| `GrpcContext.recvMessage` body kosong | menghasilkan null segera |
| Round-trip `GrpcPrefix` | writePrefix -> readPrefix mempertahankan flag compress dan panjang pesan |
| `parsePath` path valid | `/helloworld.Greeter/SayHello` -> `package_service="helloworld.Greeter"`, `method="SayHello"` |
| `parseTimeout` detik | `"2S"` -> 2.000.000.000 nanodetik |

### tests/behaviour/channel/

#### `channel_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Field `closed` default ke false | invarian `init()` |
| `head` dimulai dari nol | invarian `init()` |
| Rumus tail ring adalah `(head + count) % buf.len` | state yang diset secara manual memverifikasi aritmetika |
| `send` menaikkan count | count naik dari 0 ke 1 setelah satu send |
| `recv` menurunkan count | count kembali ke 0 setelah recv |
| `close` mengeset field closed | `ch.closed == true` setelah close |

---

## Pengujian Edge

Sumber: `tests/edge/`. Setiap berkas memverifikasi kondisi batas dan jalur error.

### tests/edge/tcp/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `TcpServer.init` port nol | menghasilkan `error.ZixPortNotConfigured` |
| Nilai backing `DispatchModel` stabil | ASYNC=0, EPOLL=1, URING=2 |
| Nama `DispatchModel` yang dilepas hilang | `stringToEnum` mengembalikan null untuk POOL dan MIXED |
| Panjang frame TCP maksimum u32 | `maxInt(u32)` di-encode dan di-decode dengan benar melalui big-endian |

### tests/edge/websocket/

#### `websocket_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| 0 byte menghasilkan null | kurang dari 2 byte (tidak dapat membaca header) |
| 1 byte menghasilkan null | kurang dari 2 byte |
| Payload terpotong menghasilkan null | header menyatakan 5 byte tetapi hanya 3 yang ada |
| Panjang 16-bit extended (tier 126) | payload 130-byte: byte[1] membawa marker 126 |
| `acceptKey` key terlalu panjang menghasilkan `error.ZixKeyTooLong` | key >= 93 byte melebihi hash_input 128-byte |

### tests/edge/udp/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Port nol | `UdpServer.init` menghasilkan `error.ZixPortNotConfigured` |
| Port bukan-nol | `UdpServer.init` berhasil |

#### `packet_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Nilai backing enum `Endianness` stabil | NATIVE=0, LITTLE=1, BIG=2 |
| `FeedbackResult` ack/nack hanya tag | tag aktif cocok dengan .ack dan .nack |

### tests/edge/uds/

#### `config_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Path kosong menghasilkan `error.ZixPathEmpty` | `UdsServer.init(.{ .path = "" })` menghasilkan PathEmpty |

### tests/edge/logger/

#### `logger_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Batas `statusLevel` 2xx | `access()` tidak crash untuk setiap kelas status (100-599) |
| Pengurutan enum `Level` | DEBUG < INFO < WARN < ERROR melalui `@intFromEnum` |
| `system()` di bawah `save_min_level` tidak menghasilkan output | pemanggilan di bawah ambang tidak membuka berkas (`file_fd == -1`) |
| `access()` di bawah `save_min_level` tidak menghasilkan output | sama: `file_fd == -1` setelah pemanggilan yang difilter |
| `system()` dengan component kosong tidak panic | `component = ""` aman |
| `system()` dengan format kosong tidak panic | `fmt = ""` aman |
| `access()` dengan method dan path kosong tidak panic | string kosong aman |
| `init` dengan `save_path` kosong, `file_fd` tetap tidak valid | `file_fd == -1` dengan `save_path = ""` |
| Console OFF: tidak ada output atau panic untuk semua level | keempat level tidak menghasilkan crash dengan `console = .OFF` |

### tests/edge/fix/

#### `session_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| `parseFields` menangani jumlah field maksimum tanpa panic | `MAX_FIELDS - 1` pasang tag=value di-parse tanpa overflow atau crash |
| `verifyChecksum` menghasilkan false untuk pesan terpotong | pesan yang tidak memiliki delimiter checksum SOH akhir |
| `findMessageEnd` menghasilkan null untuk pesan dengan nilai tag-10 tetapi tanpa SOH akhir | field checksum parsial menghasilkan null |
| `buildMessage` dengan nol field extra menghasilkan pesan valid | output lolos `verifyChecksum` dan round-trip `parseFields` |
| Pesan yang datang dalam dua segmen TCP dirakit dengan benar | Logon terpecah di dua flush, server tetap membalas dengan MsgType=A |
| Checksum yang buruk menyebabkan server menutup tanpa propagasi error di sisi server | byte pesan yang rusak menutup koneksi `ctx.err == null` |

### tests/edge/http1/

#### `body_test.zig`

Content-Length adalah yang dipakai setiap dispatch model untuk memutuskan apakah body diantar utuh, ditunggu, atau di-drain, sehingga nilai yang ditolak parser mengubah jalur yang diambil sebuah request.

| Tes | Yang diverifikasi |
| :- | :- |
| Content-Length absen mem-framing request sebagai tanpa body | tanpa header -> `content_length` 0, flag chunked false |
| Content-Length nol mem-framing request sebagai tanpa body | `Content-Length: 0` -> 0 |
| Content-Length non-numerik jatuh ke nol | `abc` -> 0 |
| Content-Length dengan spasi di akhir jatuh ke nol | `5 ` -> 0 |
| Content-Length melewati u64 jatuh ke nol | nilai 23 digit -> 0 |
| Content-Length dibaca case-insensitive | `cOnTeNt-LeNgTh` dihormati |
| request chunked menyalakan flag chunked di samping Content-Length | kedua nilai header disimpan |
| Expect 100-continue di-flag untuk request ber-body | `expect_continue` true |
| Request bodyReceived nol untuk request tanpa body | dan `body()` mengembalikan kosong |
| Request bodyReceived mengikuti slice yang diantar secara default | slice 4 byte -> 4 |
| Request bodyComplete true untuk request tanpa body | tidak ada yang dideklarasikan, tidak ada yang bisa kurang |
| Request bodyComplete tidak bergantung panjang yang diantar | slice pendek tetap complete, override engine membuatnya false |

#### `core_test.zig`

| Tes | Yang diverifikasi |
| :- | :- |
| `parseHead` tanpa terminator CRLF | mengembalikan `IncompleteHeader` |
| `parseHead` request line kosong | mengembalikan `InvalidRequest` |
| `parseHead` tanpa versi HTTP | mengembalikan `InvalidRequest` |
| `queryParam` key dengan nilai kosong | mengembalikan string kosong, bukan null |
| `queryParam` key tidak ada | mengembalikan null |
| `parseRange` start melebihi total | mengembalikan null |
| `parseRange` tanpa prefix `bytes=` | mengembalikan null |
| `percentDecode` spasi ter-encode | didekode di tempat |

#### `static_cache_test.zig`

Setiap kasus di sini berakhir dengan hit null, yang oleh engine diperlakukan sebagai "sajikan tanpa cache".

| Tes | Yang diverifikasi |
| :- | :- |
| Menolak path yang keluar dari public_dir | traversal, absolut, dan kosong ditolak sebelum open apa pun |
| Menolak path hasil resolve yang lebih panjang dari buffer-nya | path kepanjangan ditolak, bukan dipotong |
| Dengan ttl 0 tidak pernah menyimpan apa pun | default nonaktif tidak memakai slot |
| Menolak sebuah direktori | direktori bisa dibuka tapi tidak bisa disajikan, jadi tidak dipublikasikan |
| Menyajikan file nol byte sebagai hit sungguhan | `Content-Length: 0`, tetap sebuah hit |
| Kedaluwarsa persis di batas window | segar di `insert + ttl - 1`, kedaluwarsa di `insert + ttl` |
| Tetap melayani setelah tabel penuh oleh entry yang di-pin | tabel penuh menolak path baru dan membiarkan entry yang ditahan utuh |
| Negosiasi jatuh ke identity ketika klien menolak semuanya | menyajikan file polos lebih baik daripada menolaknya |
| Init selamat dari permintaan entry yang absurd | di-clamp terhadap budget descriptor, tetap power of two |

#### `query_test.zig`

Kondisi batas QUERY: dua nilai yang dikendalikan peer, yang dibawa QUERY ke jalur yang tak pernah dilewati method tanpa body.

| Pengujian | Yang diverifikasi |
| :- | :- |
| Token method huruf kecil ditolak, bukan dilipat | RFC 9110 section 9.1, nama method case-sensitive |
| Http1 dan Http menjawab method huruf kecil dengan cara yang sama | satu tabel method bersama, jadi kedua engine tidak bisa berpisah lagi |
| Token method melebihi maksimum yang dikenal ditolak, bukan dipotong | dibatasi oleh length switch |
| Method tak terimplementasi menjawab 501, request line rusak menjawab 400 | dua kegagalan tetap terpisah |
| Request line rusak tidak dilaporkan sebagai method tak dikenal | baris yang tidak pernah ter-tokenisasi tidak berkata apa pun soal method |
| QUERY dengan target minimal tetap di-parse | target root |
| Content-Length nol dan tidak ada sama-sama di-framing tanpa body | tidak ada yang dideklarasikan berarti tidak ada yang dibaca |
| QUERY chunked menyalakan flag chunked | framing chunked tidak bergantung method |
| QUERY boleh membawa Expect 100-continue | handshake untuk body besar |
| Body QUERY melebihi receive buffer melaporkan yang sudah tiba | `bodyReceived` vs `content_length`, kasus yang tidak bisa diungkapkan GET |
| QUERY menyimpan query string dan content sekaligus | parameter target tidak digantikan body |
| Query content type terpanjang dicocokkan, bukan dipotong | 33 byte, nilai yang dulu melampaui buffer |
| Content-Type absurd melaporkan tidak ada kecocokan alih-alih melampaui buffer | header ini dikendalikan peer |
| Nilai Content-Type kosong melaporkan tidak ada kecocokan | kosong, titik koma tunggal, spasi |
| Parameter boundary QUERY multipart tidak menggagalkan pencocokan | parameter dilepas lebih dulu |
| Penyimpanan QUERY ditolak walau response-nya muat di cache | bukan efek ukuran |
| Penyimpanan QUERY ter-encode juga ditolak di jalur terkompresi | slot per-encoding membawa penolakan yang sama |

### tests/edge/http2/

#### `server_test.zig`

Port: 18100.

| Pengujian | Yang diverifikasi |
| :- | :- |
| Preface PRI yang buruk menyebabkan server menutup koneksi | byte preface tidak valid -> server menutup koneksi dengan bersih |
| Client mengirim GOAWAY dan loop koneksi server keluar | frame GOAWAY -> server keluar dari frame loop tanpa error |
| `Http2Server.init` menolak port nol | menghasilkan `error.ZixPortNotConfigured` |
| Dekode `HpackDecoder` dari blok kosong menghasilkan nol header | `decode(&.{}, ...)` menghasilkan 0 header tanpa error |
| `writeFrameHeader` bit tinggi stream_id dihapus saat dibaca | `stream_id = 0x7FFF_FFFF` di-roundtrip dengan benar melalui pipe |

### tests/edge/http3/

#### `static_test.zig`

Batas-batas di mana engine harus menolak alih-alih menyerahkan body yang tidak bisa ia tahan ke jalur kirimnya.

| Tes | Yang diverifikasi |
| :- | :- |
| Menolak file melewati batas snapshot | di atas 8 MiB ditolak untuk byte, sementara jalur descriptor tetap me-resolve-nya untuk engine lain |
| Menyajikan file persis di batas snapshot | batasnya inklusif |
| Menyajikan file nol byte sebagai body kosong | slice kosong sudah stabil, tidak ada yang di-snapshot |
| Byte adalah snapshot, bukan jendela ke file | penulisan ulang di tempat tidak mengubah byte yang sudah diberikan |
| Byte selamat dari pemotongan ke file lebih pendek | bentuk berbahaya: file menyusut saat respons masih dikirim |
| Menolak setiap path tidak aman sebelum menyentuh disk | traversal, absolut, dan kosong |
| Byte di-snapshot sekali dan dipakai ulang antar request | satu salinan menopang respons konkuren, dan masing-masing menahan pin sendiri |

### tests/edge/webrtc/

#### `session_test.zig`

Semuanya datang di satu port lalu dipilah dari byte pertamanya, jadi batas-batas di sini soal apa
yang dilakukan peer terhadap datagram yang tidak bisa ia pakai.

| Test | Yang diverifikasi |
| :- | :- |
| Peer selamat menghadapi semua kemungkinan byte pertama | ke-256 nilai diklasifikasikan dan tidak ada yang panik |
| Datagram kosong dibuang dan tidak mengubah apa pun | tidak ada state yang bergerak pada receive berukuran nol |
| Record DTLS yang panjangnya melampaui ujung buffer tidak dibaca melewatinya | panjang yang dideklarasikan tidak pernah dipercaya melebihi buffer |
| Pesan STUN dengan byte pertama benar dan selebihnya kosong ditolak | routing bukan validasi, magic cookie tetap harus cocok |
| Application data sebelum handshake selesai tidak sampai ke mana pun | record epoch 1 ditolak sampai ada kunci epoch 1 |
| Sampah yang sama seribu kali tetap membiarkan peer hidup | datagram buruk berulang tidak menghabiskan apa pun |
| Dialer menolak respons yang membawa transaction milik orang lain | transaction id ikut diperiksa, bukan hanya tipe pesannya |

### tests/edge/grpc/

#### `server_test.zig`

Port: 18220-18221.

| Pengujian | Yang diverifikasi |
| :- | :- |
| `readGrpcPrefix` dengan 4 byte | menghasilkan `error.ZixHttp2_GrpcPrefix_TooShort` |
| `readGrpcPrefix` dengan slice kosong | menghasilkan `error.ZixHttp2_GrpcPrefix_TooShort` |
| `GrpcContext.recvMessage` body lebih pendek dari prefix | body memiliki 3 byte (butuh 5 untuk prefix): menghasilkan null |
| `GrpcContext.recvMessage` msg_len melebihi body | prefix mengklaim 100 byte tetapi body hanya memiliki 5: menghasilkan null |
| `parsePath` string kosong | menghasilkan null |
| `parsePath` tanpa slash awal | menghasilkan null |
| `parsePath` hanya slash | menghasilkan null |
| `detectContentType` tanpa header | menghasilkan UNKNOWN |
| `detectContentType` text/plain | menghasilkan UNKNOWN |
| `parseTimeout` karakter tunggal | menghasilkan null |
| `GrpcClient.connect` port nol | menghasilkan `error.ZixPortNotConfigured` |
| `serveConn` menutup dengan bersih saat client langsung memutus koneksi | server menerima, client memutus koneksi segera, tanpa crash atau error |
| gRPC handler finish-only menyampaikan status error ke client | handler hanya memanggil `res.finish(INVALID_ARGUMENT, ...)`, client menerima status error tanpa frame data apa pun |

### tests/edge/channel/

#### `channel_test.zig`

| Pengujian | Yang diverifikasi |
| :- | :- |
| Kapasitas 1 mengalokasikan tepat satu slot | `buf.len == 1`, `count == 0` |
| Head ring membungkus di `buf.len` | `(3+1) % 4 == 0` |
| Batas penuh: `count == buf.len` | indeks tail membungkus kembali ke head |
| `send` setelah close | menghasilkan `error.ZixClosed` |
| `recv` pada channel tertutup yang kosong | menghasilkan `error.ZixClosed` |

---

###### akhir pengujian
