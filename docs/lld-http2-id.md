# LLD: zix.Http2 (h2c HTTP/2)

Detail implementasi internal. Untuk rasional desain lihat [`docs/hld-http2-id.md`](hld-http2-id.md), ADR-043 (split `dispatch/` per-engine), dan ADR-052 (TLS multiplex).

Model blocking (`.ASYNC`) memakai satu jalur koneksi (`serve.serveConn` -> `serveLoop`). Model `.EPOLL` dan `.URING` menggerakkan state machine terpisah, resumable, non-blocking (`mux/`) yang menjadi fokus utama dokumen ini. Keduanya bermuara ke satu `Router` comptime. Jalur TLS (`config.tls != null`) terminasi di tempat, baik secara multiplex (`tls_mux.zig`, untuk `.EPOLL` / `.URING`) atau thread-per-connection (`tls_serve.zig`, yang juga melayani TLS 1.2).

---

## mux/

State machine h2c resumable untuk `.EPOLL` / `.URING`, satu file per concern:

| file | isi |
| :- | :- |
| `MuxStream.zig` | satu stream ter-pool: header, body, send window, body terparkir |
| `MuxConn.zig` | state per-fd: read buffer, decoder HPACK, slot, window. Klaim, cari, dan lepas slot |
| `stream_pool.zig` | freelist `MuxStream` threadlocal per-worker: `acquire`, `release` |
| `conn_outcome.zig` | `ConnOutcome`: `keep_alive` atau `close` |
| `mux_phase.zig` | `MuxPhase`: `await_preface`, `await_upgrade`, `await_preface2`, `h2` |
| `flow.zig` | flow control sisi-kirim: `pumpBody`, `resumeStream`, `resumeAll` |
| `send_stream.zig` | `active_conn` dan `sendResponseStreamFD` |
| `mux_upgrade.zig` | `handleUpgrade`: upgrade h2c pada jalur mux (hanya 101) |
| `mux_dispatch.zig` | `dispatchWhole`, `hangupGoaway` |
| `frame_loop.zig` | `run`: satu frame utuh sekaligus, satu fungsi `on*` per tipe frame |
| `process.zig` | fase preface, `onReadable` (`.EPOLL`), `processRing` (`.URING`) |

Satu `MuxConn` per fd. Read accumulator `rbuf` persisten lintas event readable dan menyimpan frame parsial sampai sisanya tiba, sehingga satu worker menggerakkan banyak koneksi. Frame koneksi dan respons ditulis langsung ke fd lewat `writer` dan `control` (yang poll saat EAGAIN untuk socket non-blocking), dan handler berjalan inline pada worker, jadi seperti mux gRPC ia harus tetap bounded.

### MuxStream (MuxStream.zig)

Satu stream di dalam koneksi, dipinjam dari pool per-worker selama terbuka.

```zig
id: u31 = 0,
state: StreamState = .IDLE,                     // IDLE | OPEN | HALF_CLOSED_REMOTE | CLOSED
headers: [frame.MAX_HEADERS]Header = undefined, // inline, MAX_HEADERS = 64
header_count: usize = 0,
header_scratch: []u8 = &.{},                    // buffer ter-pool, berukuran opts.max_header_scratch
body: []u8 = &.{},                              // buffer ter-pool, berukuran opts.max_body
body_len: usize = 0,
end_headers: bool = false,
end_stream: bool = false,
send_window: i64 = 65535,        // sisa receive window peer untuk stream ini (RFC 7540 6.9)
pending_body: []const u8 = &.{}, // ekor body yang belum terkirim karena dibatasi window
pending_end: bool = false,
next_free: ?*Self = null,        // link freelist, hanya valid selama idle di pool
```

`reset` mengembalikan setiap field ke default dan menyimpan dua buffer ter-pool. `open(sid, send_window)` me-reset, lalu menandai id, `OPEN`, dan send window awal. `appendBody` mengembalikan false dan tidak menambahkan apa pun saat data tidak muat. `isParked` true selama `pending_body` tidak kosong. `pending_body` menunjuk ke memori milik pemanggil yang harus hidup lebih lama dari stream (static cache), jadi slot tetap dipinjam sampai terkuras.

### MuxConn (MuxConn.zig)

State h2 per-koneksi milik heap, satu per fd, privat untuk worker pemiliknya.

```zig
fd: std.posix.fd_t,
opts: ServeOpts,
io: std.Io,                 // dibawa ke Context pada setiap pemanggilan handler
rbuf: []u8,                 // read accumulator, byte yang belum diproses adalah rbuf[rstart..rend]
rstart: usize,
rend: usize,
hpack_dec: HpackDecoder,
streams: []*MuxStream,      // array pointer: koneksi idle memesan max_streams pointer, bukan buffer
slots: []bool,
last_stream_id: u31,
phase: MuxPhase,
send_window: i64,           // send window level-koneksi (semua DATA kita), mulai dari 65535
peer_init_window: i64,      // SETTINGS_INITIAL_WINDOW_SIZE peer, send window stream baru
peer_max_frame_size: u32,   // SETTINGS_MAX_FRAME_SIZE peer, mulai dari 16384
```

| fungsi | peran |
| :- | :- |
| `init(fd, opts, io)` | satu alokasi masing-masing untuk conn, `rbuf`, `streams`, `slots`. Mengembalikan `Error!*Self` (`ZixHttp2_MuxConn_OutOfMemory`) |
| `deinit` | mengembalikan setiap stream yang masih terbuka ke pool, lalu membebaskan array. Pemanggil tetap memiliki dan menutup fd |
| `buffered` / `compact` | byte yang belum diproses, dan memberi ruang untuk read berikutnya (reset buffer kosong, atau pindahkan frame parsial ke depan buffer yang penuh) |
| `claimSlot(sid)` | slot bebas pertama, meminjam stream lewat `stream_pool.acquire` dan membukanya dengan `peer_init_window`. Null pada `max_streams` atau saat pool tidak bisa tumbuh, pemanggil lalu mengirim `RST_STREAM REFUSED_STREAM` |
| `findSlot(sid)` / `releaseSlot(slot)` | mencari stream hidup berdasarkan id, membebaskan slot dan mengembalikan stream-nya ke pool |
| `requestInFlight` | true selama ada stream hidup yang belum melihat END_STREAM. Slot yang hanya dipegang respons terparkir tidak dihitung |
| `setPeerInitialWindow(value)` | RFC 7540 6.9.2: menggeser send window setiap stream terbuka sebesar selisihnya |

`rbuf` berukuran `max(opts.conn_read_buf_min, opts.max_frame_size + frame.FRAME_PAYLOAD_SLACK + 9)`. Karena `streams` berisi pointer, state per-stream yang berat tidak dipesan saat koneksi dibuka, ia dipinjam dari pool saat stream dibuka. Pencarian slot adalah scan linear atas `max_streams`.

### Pool stream per-worker (stream_pool.zig)

Strategi alokasi kuncinya. Satu worker menggerakkan banyak koneksi dari satu thread, dan setiap koneksi meminjam `MuxStream` hanya selama stream terbuka, lalu mengembalikannya saat ditutup. Freelist-nya threadlocal (shared-nothing per worker, tanpa atomic), sehingga memori stream resident mengikuti stream konkuren pada worker, bukan koneksi kali `max_streams`. Buffer dialokasikan sekali per stream ter-pool dan dipakai ulang lintas peminjaman, sehingga kondisi tunak tidak melakukan alokasi per-stream.

- `acquire(opts) Error!*MuxStream`: mengambil dari freelist dan mengembalikan stream itu saat buffer-nya memenuhi `opts.max_body` / `opts.max_header_scratch`. Stream ter-pool yang lebih kecil (serve options campuran pada satu worker) dibebaskan, dan `MuxStream` baru beserta dua buffer-nya dialokasikan. Kehabisan memori adalah `ZixHttp2_StreamPool_OutOfMemory`.
- `release(stream)`: `reset` (buffer disimpan), lalu push LIFO, sehingga stream yang panas dipakai ulang lebih dulu.
- Stream ter-pool tidak pernah dibebaskan. Ia hidup sampai worker-nya keluar.

### process.zig

`process` adalah mesin fase handshake, lalu loop frame:

- `await_preface`: butuh 3 byte. Jika bukan `"PRI"`, set `await_upgrade` dan panggil `mux_upgrade.handleUpgrade`. Selain itu butuh `PREFACE` 24-byte, validasi (GOAWAY `PROTOCOL_ERROR` dan tutup saat salah), kirim SETTINGS server (`peer_settings.sendServerSettings`), set `h2`.
- `await_upgrade`: `handleUpgrade` (akumulasi sampai `\r\n\r\n`, balas `400` saat `upgrade.isH2cUpgrade` false, `101` saat true, lalu `await_preface2`, dan request stream-1 tidak dilayani). Head yang memenuhi `rbuf` menutup koneksi.
- `await_preface2`: setelah `101`, validasi preface, kirim SETTINGS, set `h2`.
- `h2`: `frame_loop.run`.

`onReadable` (`.EPOLL`) berulang: `compact`, tutup saat `rbuf` masih penuh, `read` ke `rbuf[rend..]` (WouldBlock -> `keep_alive`, error -> `close`, 0 -> `hangupGoaway` lalu `close`), lalu `process`, mengulang sampai EAGAIN. Epoll level-triggered memicu ulang bila ada lagi. `processRing` (`.URING`) adalah pass pemrosesan yang sama tanpa loop baca: ring memiliki recv dan meng-arm ulang setelah ini kembali.

### frame_loop.zig

`run` berjalan atas byte ter-buffer selama satu frame utuh tersedia:

```
loop:
    if buffered < 9 -> return .keep_alive
    header = parseFrameHeader(rbuf[rstart..][0..9])
    if header.length > max_payload -> GOAWAY FRAME_SIZE_ERROR, return .close
    if buffered < 9 + header.length -> return .keep_alive
    maju melewati header + payload
    switch header.frame_type:
        SETTINGS      -> onSettings: lewati ACK; peer_settings.apply (HEADER_TABLE_SIZE,
                         MAX_FRAME_SIZE), setPeerInitialWindow saat INITIAL_WINDOW_SIZE datang;
                         kirim ACK + satu WINDOW_UPDATE koneksi
        WINDOW_UPDATE -> onWindowUpdate: payload bukan 4 byte -> GOAWAY FRAME_SIZE_ERROR;
                         stream 0: send_window += inc, resumeAll; selain itu findSlot,
                         stream.send_window += inc, resumeStream
        HEADERS       -> onHeaders: guard id; claimSlot; frame_payload.headerBlock;
                         decode hpack ke header_scratch; saat END_HEADERS + END_STREAM
                         -> dispatchWhole
        CONTINUATION  -> onContinuation: findSlot (tidak dikenal -> GOAWAY PROTOCOL_ERROR);
                         append-decode; dispatch saat END
        DATA          -> onData: findSlot (tidak dikenal -> RST_STREAM STREAM_CLOSED);
                         frame_payload.dataBlock; appendBody, shed dengan 413 saat tidak
                         muat; WINDOW_UPDATE(0) + WINDOW_UPDATE(sid); dispatch saat END_STREAM
        RST_STREAM    -> onRstStream: findSlot -> releaseSlot
        PING          -> onPing: lewati ACK; payload bukan 8 byte -> GOAWAY FRAME_SIZE_ERROR;
                         sendPingAckFD
        GOAWAY        -> return .close
        lainnya       -> abaikan
```

Kegagalan decode mengirim `RST_STREAM COMPRESSION_ERROR` dan membebaskan slot. SETTINGS server mengiklankan `MAX_CONCURRENT_STREAMS`, `INITIAL_WINDOW_SIZE` 65535, `MAX_FRAME_SIZE`, dan `ENABLE_PUSH` 0.

### mux_dispatch.zig

- `dispatchWhole(handler_fn, conn, slot)`: stream yang body-nya tidak cocok dengan content-length miliknya (`stream_body.isWhole`) di-reset dengan `PROTOCOL_ERROR` dan slot-nya dibebaskan. Selain itu ia di-dispatch.
- Dispatch membangun request dengan `stream_invoke.buildRequest(headers, body)`, mencatat `cache.tl_req_path` / `tl_req_body` / `tl_req_io` hanya saat response cache terpasang, mengeset `send_stream.active_conn = conn`, dan memanggil `handler.invokeHandler` dengan `conn.peer_max_frame_size`. Setelah handler kembali, slot dibebaskan kecuali body respons terparkir pada window, dalam hal itu `WINDOW_UPDATE` berikutnya me-resume dan membebaskannya.
- `hangupGoaway(conn)`: GOAWAY `PROTOCOL_ERROR` saat sebuah request masih in-flight, tidak ada apa pun pada koneksi idle. Mengembalikan apakah ia menulis.

### flow.zig dan send_stream.zig

Flow control sisi-kirim. `active_conn` adalah threadlocal yang mengikat pengiriman handler yang sedang berjalan ke window koneksinya.

- `pumpBody(conn, stream, body, end)`: menulis DATA sampai `min(conn.send_window, stream.send_window)` dan `peer_max_frame_size` milik **peer**, mengurangi kedua window per chunk, mengeset END_STREAM hanya pada chunk terakhir setelah seluruh body keluar, dan memarkir sisanya di `pending_body` / `pending_end`. Write yang gagal menghentikan pengiriman dan memarkir sisanya.
- `resumeStream(conn, slot)`: setelah window tumbuh, `pumpBody` ekor yang terparkir dan membebaskan slot saat terkuras penuh.
- `resumeAll(conn)`: setelah window koneksi tumbuh, me-resume setiap stream yang terparkir.
- `sendResponseStreamFD(fd, sid, status, content_type, content_encoding, body)`: entry respons ber-flow-control. Tanpa `active_conn`, fd lain, atau tanpa slot yang cocok ia jatuh kembali ke `writer.sendResponseEncodedFD` (langsung, tanpa meter). Selain itu ia menulis HEADERS (`response_block.respHeaderBlock`, `content-length` selalu ada, END_STREAM pada HEADERS untuk body kosong) lalu `pumpBody(..., true)`. Blok header yang tidak muat me-reset stream dengan `INTERNAL_ERROR` dan tidak mengirim DATA. Body direferensikan, bukan disalin, jadi harus hidup lebih lama dari stream (cache berumur proses).

Note: hook batching frame (`writer.write_hook`) dan sink coalescing tidak ada di `mux/`. Mux lama tidak pernah memasang hook itu, `dispatch/common.zig` yang memasangnya di sekitar setiap batch readable, jadi keduanya masuk bersama model dispatch Linux.

---

## hpack/

Codec HPACK, satu file per concern:

| File | Isi |
| :- | :- |
| `Header.zig` | `{ name, value }`, juga entry static table dan dynamic table |
| `HuffSym.zig` | `{ code: u32, bits: u5 }` |
| `huffman_table.zig` | `HUFF: [256]HuffSym` (RFC 7541 appendix B), digabung saat comptime dari array code dan array bit-length |
| `static_table.zig` | `HPACK_STATIC: [62]Header` (RFC 7541 appendix A), index 0 tidak dipakai |
| `huffman.zig` | `huffEncode`, `huffDecode` |
| `integer.zig` | `encodeInt`, `decodeInt` (prefix integer, RFC 7541 section 5.1) |
| `DynamicTable.zig` | entry dynamic table, eviction, compaction |
| `HpackDecoder.zig` | `decode`, `evictTo`, `max_size` |
| `HpackEncoder.zig` | `writeHeader`, `encoded` |
| `RespPrefix.zig` | satu prefix respons yang di-cache |
| `response_block.zig` | `respHeaderBlock` plus cache prefix |

### respHeaderBlock + cache response-header

`respHeaderBlock(dst, status, content_type, content_encoding, content_length)` mengenkode satu blok header respons penuh. Prefix `[:status, content-type, content-encoding]` dilayani dari cache append-only global-proses, hanya `content_length` (yang bervariasi) yang dienkode per panggilan. `content_length` yang null menghilangkan field itu (respons END_STREAM tanpa body). `dst` yang terlalu kecil untuk blok mengembalikan `ZixHttp2_ResponseBlock_BufferFull`.

Cache-nya adalah `prefix_cache: [32]RespPrefix` dengan count yang di-publish secara release dan sebuah spinlock (`prefix_lock`). Reader men-scan `0..count` lock-free, spinlock hanya men-serialize insert yang langka (satu per triple berbeda). Ia byte-identik pada setiap koneksi karena `HpackEncoder` stateless: tabel statik plus literal-without-indexing, tidak pernah dynamic table atau size update, jadi byte ter-cache plus content-length per-panggilan adalah HPACK yang valid. Triple yang terlalu panjang atau cache penuh jatuh kembali ke encode langsung, jadi kebenaran tidak pernah bergantung pada hit. Sebuah test menegaskan `respHeaderBlock` cocok dengan panggilan `writeHeader` byte-per-byte.

### DynamicTable

```zig
entries: [128]Header = undefined, // terbaru dulu, entries[0] adalah dynamic index 1
count: usize = 0,
size: usize = 0,                  // name.len + value.len + 32 per entry
buf: [8192]u8 = undefined,        // entry selalu menunjuk ke sini, tidak pernah ke scratch per-panggilan
buf_pos: usize = 0,
```

`add(name, value, max_size)` menyalin entry ke `buf` (seumur-koneksi), jadi lookup indexed tetap valid setelah scratch sebuah slot stream dipakai ulang. `evictTo(target)` membuang entry tertua sampai tabel muat. Saat `buf` habis, `compact` memadatkan ulang entry hidup di depan dengan forward copy (sumber dan tujuan bisa overlap). Entry yang lebih besar dari `max_size` mengosongkan tabel dan tidak disimpan.

### HpackDecoder

```zig
table: DynamicTable = .{},
max_size: usize = 4096,
```

`decode(block, out, scratch)` menangani representasi indexed, literal-with-incremental-indexing, dynamic-table-size-update, dan literal-without-indexing. Setiap slice yang di-decode menunjuk ke `scratch` milik pemanggil, termasuk lookup tabel. `evictTo(target)` diteruskan ke tabel, jadi pemanggil yang menerapkan SETTINGS_HEADER_TABLE_SIZE tetap memakai `max_size` dan `evictTo`. Literal Huffman lewat `huffDecode`.

### HpackEncoder

`init(buf)` atas buffer pemanggil, `writeHeader(name, value)`: kecocokan persis static-table dienkode sebagai indexed, kecocokan nama saja sebagai literal ber-index nama (tidak pernah ditambahkan ke dynamic table), selain itu literal penuh. `writeString` memilih Huffman saat lebih pendek dan memberi tipe `?usize` pada hasil Huffman agar evaluasi comptime (blok ter-cache) tetap mempertahankan optional meski cabang error tidak terjangkau secara statis. Stateless: tanpa dynamic table, tanpa size update.

---

## frame.zig, writer.zig, reader.zig, control.zig

`frame.zig` memegang konstanta (`FRAME_TYPE_*`, `FLAG_*`, `ERR_*`, `SETTINGS_*`, `PREFACE`, `FRAME_HEADER_LEN` 9, `DEFAULT_MAX_FRAME_SIZE` 16384, `HPACK_ENCODE_SCRATCH` 512, `SEND_STAGE_BODY_MAX` 4096) dan codec header. `FrameHeader.zig` adalah `{ length: u24, frame_type: u8, flags: u8, stream_id: u31 }`. `parseFrameHeader` / `encodeFrameHeader` tidak melakukan I/O (untuk write ter-buffer atau ter-stage).

`writer.zig` adalah sisi write. `writeAllFD` menandai stream sudah dijawab (`tl_responded`) dan memanggil `writeAllDirectFD`, write-all blocking yang poll pada `POLL.OUT` untuk EAGAIN socket non-blocking dan retry saat INTR. `write_hook` threadlocal (jalur seal TLS, atau sink coalescing) masuk bersama model dispatch Linux: `writeAllFD` akan menyerahkan plaintext ke hook saat diset, dan `writeAllDirectFD` tetap menjadi jalur flush milik hook itu sendiri, jadi flush coalescing tidak masuk ulang ke hook. `writeFrameHeaderFD` mengenkode dan menulis satu header.

`sendResponseFD` -> `sendResponseEncodedFD` (juga di `writer.zig`) adalah respons langsung tanpa meter (tanpa flow control): HEADERS via `respHeaderBlock`, lalu body di-frame dalam chunk DATA `<= DEFAULT_MAX_FRAME_SIZE` dengan END_STREAM pada yang terakhir (atau pada HEADERS saat body kosong). Body di atau di bawah `SEND_STAGE_BODY_MAX` (4 KiB) keluar sebagai satu staged write, yang lebih besar sebagai satu vectored write per chunk DATA (blok HEADERS menumpang chunk pertama, write hook menerima tiap pasangan sebagai dua append). Body besar yang mungkin melebihi window peer memakai `mux/send_stream.sendResponseStreamFD` sebagai gantinya.

`reader.zig` adalah sisi read: `readOnceFD`, `recvExact` (mengisi buffer atau mengembalikan `Closed`), dan `readFrameHeader`.

`control.zig` memegang `sendSettingsFD` / `sendSettingsAckFD` / `sendPingAckFD` / `sendGoawayFD` / `sendRstStreamFD` / `sendWindowUpdateFD`, masing-masing mengenkode satu control frame. Control frame berukuran tetap keluar sebagai satu write.

---

## Blocking core (serve.zig dan bagiannya)

Pemrosesan request bersama dan jalur koneksi blocking, dipecah per tanggung jawab. `send_best_effort`, `frame_payload`, `peer_settings`, `buildRequest`, dan helper upgrade dipakai bersama dengan `mux/`:

| file | isi |
| :- | :- |
| `ServeOpts.zig` | knob serving per-koneksi |
| `serve.zig` | `serveConn`: preface atau upgrade, lalu satu frame sekaligus |
| `upgrade.zig` + `UpgradeHead.zig` | sisi HTTP/1.1 dari upgrade h2c (`accept`, menjawab 101). `isH2cUpgrade`, `HEAD_END`, `BAD_REQUEST`, `SWITCHING_PROTOCOLS` publik, upgrade mux memakainya ulang |
| `Stream.zig` | satu stream request: header yang sudah di-decode dan body |
| `stream_state.zig` | `StreamState` (RFC 7540 section 5.1) |
| `stream_slot.zig` | tabel stream `claim`, `find`, `requestInFlight` |
| `declared.zig` + `stream_body.zig` | content-length terhadap byte DATA (`declared`, `isWhole`) |
| `stream_invoke.zig` | `invokeWhole`: stream selesai menjadi `Request`, lalu handler. `buildRequest(headers, body)` publik, mux memakainya ulang |
| `send_best_effort.zig` | `goaway`, `rstStream`, `windowUpdate`, `sendTooLarge`: write yang gagal dibuang, read berikutnya melihat socket yang rusak |
| `frame_payload.zig` | `headerBlock`, `dataBlock`: strip padding dan priority, null saat padding melewati payload |
| `peer_settings.zig` | `apply` (HEADER_TABLE_SIZE, MAX_FRAME_SIZE di 16384..16777215, mengembalikan INITIAL_WINDOW_SIZE terakhir atau null), `sendServerSettings` |
| `handler.zig` | `HandlerFn`, `invokeHandler`, `setAccessLogger` |
| `cache.zig` | response cache per-worker |

### ServeOpts

`ServeOpts` menyimpan tuning per-koneksi dengan default berikut:

| field | default |
| :- | :- |
| `max_streams` | 128 |
| `max_frame_size` | 16384 (`DEFAULT_MAX_FRAME_SIZE`) |
| `max_header_scratch` | 4096 |
| `max_body` | 16384 |
| `logger` | null (tidak mencatat apa pun) |
| `conn_read_buf_min` | 32 * 1024 |
| `tls_write_buf_initial` | 16 * 1024 |
| `response_cache` | false |
| `cache_max_entries` | 256 |
| `cache_max_value_bytes` | 16 * 1024 |
| `cache_ttl_ms` | 1000 |
| `cache_max_total_bytes` | 0 (tanpa batas) |
| `handler_timeout_ms` | 0 (tanpa deadline) |
| `public_dir` | "" (kosong menonaktifkan fallback static) |

### handler.zig

`HandlerFn` adalah `fn(req: *Request, res: *Response, ctx: *Context) anyerror!void` (trio ADR-063, dibangun saat dispatch oleh `handler.invokeHandler`). `invokeHandler` adalah satu-satunya tempat handler dipanggil, jadi setiap dispatch model membangun trio dengan cara yang sama. Saat handler error, ia mengirim satu 500, tapi hanya jika belum ada yang ditulis: bukan `Response.sent` dan bukan `writer.respondedFD()`. Lalu ia menulis access record jika `setAccessLogger` sudah memasang logger.

`invokeHandler` menerima `peer_max_frame_size: u32` sebagai parameter eksplisit lalu menyalinnya ke `Context.max_frame_size`, yang dipakai fallback static untuk mengukur frame DATA. Ia sengaja dipisahkan dari `ServeOpts.max_frame_size`: field itu adalah iklan sisi-terima server ini, dan memakainya sebagai batas keluar justru yang dijawab peer patuh dengan `FRAME_SIZE_ERROR`. Tiga call site memasok nilai yang benar:

| call site | sumber nilai peer |
| :- | :- |
| `mux/mux_dispatch.zig` (`.EPOLL` / `.URING`) | `conn.peer_max_frame_size`, yang memang dilacak mux untuk `pumpBody` |
| `serve.serveLoop` (model blocking) | variabel lokal berjalan, diperbarui dari setiap frame SETTINGS oleh `peer_settings.apply` dengan cek 16384..16777215 (`MAX_FRAME_SIZE_LIMIT`), karena peer boleh menaikkannya di tengah koneksi |
| `serve.serveUpgrade` | didekode dari header base64 `HTTP2-Settings`, sehingga response stream-1 yang dibawa sudah benar sebelum satu frame pun dipertukarkan |

`Context.public_dir` diisi dari `ServeOpts.public_dir` di titik yang sama, jadi router mencapai root static tanpa threadlocal (berbeda dengan `zix.Http1`, yang tetap memakai `tl_static_dir`).

### Router / Route (router.zig)

`Route` adalah `{ path, handler, kind = .EXACT }` dengan `RouteKind` `EXACT | PREFIX`. `Router(comptime routes)` membangun tabel comptime: route `EXACT` di-resolve lewat `StaticStringMap` (O(1)), route `PREFIX` mencocokkan prefix terdaftar terpanjang pada batas segment-path, query string dibuang dulu, path yang tak cocok mencoba `static.fallback`, dan path yang tetap tak cocok mengirim `404 text/plain`. `Router(routes).dispatch` sendiri cocok persis dengan `HandlerFn`, jadi `Server.init` menerima `router.dispatch` sebagai nilai runtime biasa, bukan tabel route.

### cache.zig

Response cache per-worker (ADR-036): `tl_cache`, `setCache`, `cacheTtl`, `serveCached` / `sendCachedFD`, dan `requestKey` (Wyhash atas path + body). Cache menyimpan body tanpa frame, jadi hit di-frame ulang untuk stream yang meminta dan satu entry melayani stream id mana pun. Handler tidak mengoper request-nya, jadi dispatcher mencatat `tl_req_path` / `tl_req_body` / `tl_req_io` di sekitar setiap pemanggilan handler. Path kosong atau io null mengubah setiap pemanggilan menjadi send biasa.

### Jalur blocking (serveConn / serveLoop)

`serveConn` mengeset `TCP_NODELAY` dan memanggil `serveInner`, yang membaca 3 byte: `"PRI"` menjalankan preface h2c-direct (validasi, kirim SETTINGS, `serveLoop`), selain itu menjalankan `serveUpgrade` (`upgrade.accept` untuk handshake `Upgrade: h2c` HTTP/1.1, yang melayani request stream-1 awal lalu `serveLoop`). `serveLoop` mengalokasikan buffer payload (`max_frame_size + FRAME_PAYLOAD_SLACK`) plus tabel `[]Stream` dan flag `[]bool` used, keduanya sedalam `max_streams`, lalu membaca dengan `readFrameHeader` + `recvExact` blocking. Stream yang selesai lewat `stream_invoke.invokeWhole`.

- Satu `Stream` sekitar 70 KiB (`body: [BODY_BUF_SIZE]u8` 64 KiB, `header_scratch: [4096]u8`, sampai `MAX_HEADERS` 64 header), jadi tabelnya dialokasikan sekali per koneksi di heap dan setiap entry dipakai ulang, berbeda dengan buffer ter-pool milik mux yang berukuran sesuai serve options.
- Body yang melebihi kapasitas stream dibuang dengan 413, tidak pernah dipotong, jadi handler tidak pernah menerima body parsial.
- Stream yang kurang dari (atau melebihi) content-length-nya sendiri di-reset dengan PROTOCOL_ERROR dan tidak pernah sampai ke handler (RFC 9113 section 8.1.1).
- Peer yang menutup koneksi dengan request belum selesai mendapat GOAWAY PROTOCOL_ERROR. Peer yang menutup saat idle tidak mendapat apa pun, itu close biasa.

---

## static.zig

Fallback `public_dir` (ADR-064). `Router.dispatch` memanggil `fallback(req, ctx)` setelah semua route meleset dan sebelum 404. `fallback` mengembalikan false bila `ctx.public_dir` kosong atau path-nya `/`, selain itu ia membuang slash di depan lalu memanggil `serve(req, ctx, req_path, max_frame_size)`. `serve` mengembalikan false untuk percobaan traversal, path absolut, path melebihi `PUBLIC_PATH_MAX`, direktori, atau file yang tidak ada, lalu router mengirim 404-nya. Bila `fallback` mengembalikan true, router mengisi `res.sent`, sehingga jalur error handler tidak pernah menjawab stream itu dua kali.

`serve` mencoba `serveCached` lebih dulu dan jatuh ke `serveUncached` (open, stat, kirim) bila cache static tidak terpasang atau cache menolak path itu. Keduanya berakhir di `answer`, jadi `public_dir` berperilaku sama baik `public_dir_cache_ttl_ms` diatur maupun tidak.

| fungsi | peran |
| :- | :- |
| `fallback` | pintu masuk router: `public_dir` kosong atau path root adalah false, selain itu membuang `/` di depan lalu memanggil `serve` dengan `ctx.max_frame_size` |
| `acquireHit` | membaca `accept-encoding`, lalu menanyakan cache. Bila `zeroCopyAllowed` menolak, ia menanyakan `acquireMapped` dulu (snapshot resident) dan jatuh ke hit descriptor biasa di atas `SNAPSHOT_MAX_BYTES`, sehingga file besar tetap memakai descriptor yang di-cache |
| `rangeAsk` | mengubah header `Range` menjadi `FULL` (tidak ada atau malformed, RFC 7233 bagian 3.1 meminta mengabaikannya), `PARTIAL` (range yang terpenuhi), atau `UNSATISFIABLE` (well-formed tapi melewati akhir file, dijawab 416) |
| `encodeHead` | meng-encode blok HEADERS: status, content type, content encoding, `content-length`, plus `content-range` dan `accept-ranges` untuk 206. Mengembalikan null bila tidak muat |
| `encodeUnsatisfiable` | meng-encode blok 416 dengan `Content-Range: bytes */length` |
| `answer` | memilih segment, meng-encode blok, lalu memanggil `sendFramed`. Blok 206 yang tidak muat jatuh ke file utuh sebagai 200. Bila blok 200 pun tidak muat, stream ditutup dengan RST_STREAM `INTERNAL_ERROR` (`resetStream`) |
| `sendFramed` | satu frame HEADERS, lalu frame DATA yang masing-masing dibatasi `max_frame_size`, yang terakhir berflag END_STREAM. Body resident dipotong dari byte-nya sendiri, selain itu `utils/static/static.sendBody` mengirim range-nya |
| `zeroCopyAllowed` | true di Linux untuk fd asli (`fd >= 0`), false di platform lain. Saat ini frame ditulis langsung ke socket, jadi `sendfile` tidak bisa mendahului frame HEADERS-nya sendiri |

`Source` membawa `{ file, size, content_type, content_encoding, bytes }` dan `Segment` membawa `{ offset, length, status, content_range }`, sehingga file dari cache maupun tanpa cache, dan 200 maupun 206, berbagi satu jalur framing. `Content-Length` membawa panjang segment, bukan ukuran file, kalau tidak client menunggu byte yang tidak pernah datang. File kosong menutup stream pada HEADERS tanpa frame DATA sama sekali.

Note: hook batching frame masuk bersama model dispatch Linux (bukan bersama `mux/`) dan men-stage frame di buffer. `zeroCopyAllowed` harus menolak selama hook itu terpasang, kalau tidak body mendahului frame yang sudah di-stage.

Parsing Range dipakai bersama engine lain: `utils/http/range_header.zig`. `parseSpec` (membaca header) dan `resolve` (clamp terhadap panjang yang diketahui) sengaja dipisah, karena satu hasil nullable tidak bisa membedakan "abaikan header" dari "jawab 416".

---

## dispatch/ dan tls_mux.zig

`Server.zig` adalah `zix.Http2.Server` publik (field `config` dan `handler` di file scope). `run()` menjalankan tiga gate, lalu switch model:

1. `gatePort`: port 0 menghasilkan `ZixHttp2_Server_PortNotConfigured`.
2. `gateDispatchModel`: `.IOCP` dan `.KQUEUE` selalu, `.EPOLL` dan `.URING` di luar Linux, menghasilkan `ZixHttp2_Server_DispatchModel_NotSupported` (ADR-065). Gate ini berjalan sebelum apa pun disiapkan, sehingga config yang ditolak tidak meninggalkan apa pun.
3. `gatePublicDir`: `public_dir` yang diatur tetapi tidak bisa dibuka menghasilkan `ZixHttp2_Server_PublicDirNotFound`, `PublicDirNotADirectory`, atau `PublicDirUnreadable`.

Lalu `installStaticCache` memasang static cache proses saat `public_dir` dan TTL diatur (install yang gagal hanya berupa warning). Hanya server yang membangun tabel itu yang menutupnya saat `run()` selesai.

Switch model memetakan `.ASYNC` ke `dispatch/async.zig` (lalu `serve.serveConn`), `.EPOLL` ke `dispatch/epoll.zig`, dan `.URING` ke `dispatch/uring.zig`. File-file itu belum di-port, jadi untuk sekarang setiap arm mengembalikan `ZixHttp2_Server_DispatchModel_NotSupported`. Cabang `config.tls != null` (`tls_mux.runTlsMux` untuk `.EPOLL` / `.URING`, selain itu `tls_serve.runTls`) juga belum ada di `Server.zig`.

`Http2.zig` adalah namespace `zix.Http2`. Ia me-re-export tipe dan fungsi publik dari file masing-masing dan mempertahankan nama lama `HpackEntry` (tipe yang sama dengan `Header`), `DEFAULT_WINDOW_SIZE`, dan `MAX_PAYLOAD`.

### dispatch/epoll.zig

`ConnTable` adalah map fd -> `*MuxConn` privat per-worker, ber-indeks berdasarkan fd atas `slab.mapZeroedSlots(MAX_FD = 1 << 16)` (kernel-zeroed, demand-paged), tidak dibagi antar worker. `acceptAll` menguras `accept4(NONBLOCK | CLOEXEC)` sampai EAGAIN, mengeset `TCP_NODELAY` dan busy-poll opsional, membangun `MuxConn`, dan meregistrasi `EPOLL.IN | RDHUP`. `epollMuxWorkerFn(routes)` mem-pin ke sebuah CPU, membuka listener `SO_REUSEPORT` privat plus instance epoll-nya sendiri dan response cache opsional, dan menjalankan `epoll_wait` (hingga 512 event): listener menggerakkan `acceptAll`, fd koneksi menjalankan `beginCoalesce` -> `process.onReadable` -> `endCoalesce` (tutup saat kegagalan write batch). `runEpoll` men-spawn `worker_count = workers` (0 = jumlah CPU tersedia) thread dan men-join mereka.

### dispatch/uring.zig

Bentuk io_uring dari loop yang sama (ADR-037 Phase 4). `initUringRing` meminta `SINGLE_ISSUER | DEFER_TASKRUN | CQSIZE | CLAMP` dan jatuh kembali ke ring tanpa flag. Sebuah worker meng-arm multishot accept, memegang tabel slot `[]?*UringConn` ber-indeks fd, dan menandai tiap `user_data` dengan `gen: u24` agar recv CQE basi untuk fd yang dipakai ulang dibuang (`lookup`). `armRecv` mengompaksi akumulator lalu mem-posting satu `prep_recv` ke `rbuf[rend..]` (satu recv in-flight per koneksi), dan `handleRecv` memajukan `rend`, menjalankan `beginCoalesce` -> `process.processRing` -> `endCoalesce`, lalu meng-arm ulang. Respons pergi direct-to-fd pada socket non-blocking (tanpa reply cork yang dikirim via ring). `runUring` menyelidiki ring saat startup dan jatuh kembali ke `runEpoll` saat io_uring tidak tersedia.

### dispatch/common.zig

`serveOpts(cfg)` memetakan `Config` (`Config.zig`) ke `ServeOpts` (`max_recv_buf` -> `conn_read_buf_min`, `tls_write_buf_initial_bytes` -> `tls_write_buf_initial`, plus field cache dan `public_dir`). Ia juga memuat `setNoDelay`, `setBusyPoll`, `pinToCpu` dan `getAvailableCpuCount` (keduanya sadar cgroup-mask), dan `effectiveCacheEntries` (menghormati `cache_max_total_bytes`).

Sink write-coalescing adalah primitif batching untuk mux cleartext: `MuxCoalesceSink` (threadlocal 64 KiB, satu per worker) dipasang sebagai `writer.write_hook` oleh `beginCoalesce(fd)` dan dibongkar oleh `endCoalesce()`. Selama terpasang, setiap frame yang mux tulis dalam satu batch readable (HEADERS, DATA, SETTINGS, WINDOW_UPDATE) di-stage ke satu buffer dan keluar sebagai satu write, sehingga batch banyak-stream menjadi satu segmen alih-alih satu segmen kecil per frame di bawah `TCP_NODELAY`. Ia flush saat penuh dan menulis frame kelewat besar langsung tembus, jadi kebenaran tidak pernah bergantung pada ukuran buffer. `endCoalesce` mengembalikan apakah sebuah write gagal selama batch.

### tls_mux.zig

h2 multiplex atas TLS 1.3 (ADR-052): satu listener `SO_REUSEPORT` plus satu instance epoll per worker, tiap koneksi menerminasi TLS di tempat via `tls_session.Session` resumable (tanpa socketpair, tanpa thread per koneksi). Sebuah `TlsConn` memegang session, state h2 `?*MuxConn` (dialokasikan begitu handshake terbentuk dan ALPN memilih h2), buffer backpressure ciphertext-keluar (`wbuf` / `woff` / `wlen`, di-flush saat EPOLLOUT), dan buffer staging `plain`. Pass-nya: recv ciphertext -> `session.feed` mendekripsi -> `feedMux` meng-append plaintext ke `h2.rbuf` dan menjalankan `process.processRing` -> frame reply mux di-route lewat `writer.write_hook = hookWrite` -> di-seal ke record TLS -> `sendRaw`.

`hookWrite` adalah gather seal-in-place. Ia mengakumulasi plaintext ke `plain`, dan kapan pun prefix ter-stage plus write baru melengkapi satu record penuh ia menyeal record itu langsung dari sumber dengan `sealGather` -> `conn.tls.encrypt2(prefix, tail, sealed)` (yang menembus ke `connection.writeAppData2` dan `record.protect2`), meng-gather prefix ter-stage dengan slice dari sumber. Ini menghindari penyalinan payload DATA besar ke `plain` dulu, hanya sisa sub-record yang di-stage. Toggle `seal_in_place` adalah `const` comptime agar jalur gather bisa di-A/B terhadap fallback accumulate-then-seal (`flushPlain` -> `encrypt`) tanpa mengubah perilaku lain. `sendRaw` menjaga urutan record (nonce AEAD adalah nomor urut record): jika ciphertext sudah ter-stage ia meng-append alih-alih menulis langsung, jadi record berikutnya tidak pernah menyalip yang ter-stage di wire.

---

###### end of lld-http2
