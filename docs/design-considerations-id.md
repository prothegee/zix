## Pertimbangan Desain

Catatan layout dan struktur: pilihan yang sudah diambil, plus arah yang perlu ditinjau ulang. Bukan tugas aktif.

**CT (Compile Time):**<br>
Zix mendorong pekerjaan ke `comptime` setiap kali input-nya tetap saat build time. Route table dipartisi dan dispatch dispesialisasi per set route (`Router(comptime routes)`, `HttpServerImpl(comptime stack_threshold, comptime routes)`), dan perbedaan versi di-gate keluar dengan `ZIG_SEMVER` (`comptime ZIG_SEMVER.MINOR == 16`) sehingga hanya branch yang aktif yang dikompilasi. Trade-off-nya: pekerjaan build-time dan ukuran binary ditukar dengan nol branching runtime di hot path.

> Gunakan ketika sebuah input diketahui saat build time: pilih parameter atau branch comptime alih-alih field atau pengecekan runtime.

<br>

**AoS (Array of Structures):**<br>
Situs-situs yang tersisa (`extra_buf`, `fields`, `conns`, ...). Ketika salah satunya menjadi bottleneck throughput, layout SoA adalah kandidat pengganti. Route table sudah dipartisi saat comptime ke dalam grup exact / prefix / param (`router.zig`), sehingga dispatch hanya memindai jenis yang relevan, bukan satu list campuran.

> Pindahkan sebuah situs ke SoA ketika profil menunjukkan satu field yang dipindai di banyak record mendominasi.

<br>

**OoP (Object-oriented Patterns):**<br>
Sebagian besar struct (`Request`, `Response`, `Router`, `Context`, `ConnQueue`, `MultipartParser`, ...) mengikuti pola ini. Idiomatis di Zig dan baik-baik saja sebagai baseline.

> Pertahankan sebagai default. Gunakan alternatifnya hanya ketika enkapsulasi muncul sebagai biaya throughput.

<br>

**DoD (Data-Oriented Design):**<br>
Arah yang akan dituju ketika layout data lebih penting daripada enkapsulasi. Untuk lapisan HTTP, ini dimulai sebagai `zix.Http1`: engine ramping berorientasi data yang dispatch EPOLL / URING-nya mengukir buffer koneksi dari satu contiguous demand-paged slab (`http1/dispatch/`, `multiplexers/slab.zig`). `zix.Http` penuh masih memakai baseline OoP.

> Tinjau ulang DoD core untuk `zix.Http` ketika baseline OoP benar-benar mencapai batasnya.

<br>

**Arena (Per-Request Arena Allocation):**<br>
Setiap koneksi `zix.Http` mendapat sebuah arena (kapasitas awal dapat dikonfigurasi, tumbuh sesuai kebutuhan). Scratch per-request dan buffer body diukir darinya dan dilepaskan dalam satu bulk reset, bukan free per-objek.

> Gunakan ketika alokasi hidup persis selama request atau koneksi berlangsung.

<br>

**Slab (Contiguous Demand-Paged Slab):**<br>
Connection table EPOLL / URING `zix.Http1` mengalokasikan satu slab virtual `MAX_FD * buf_size` per worker (demand-paged di Linux) dan menetapkan buffer tiap koneksi darinya tanpa heap call per-accept. Slot yang belum disentuh tidak memakan memori fisik, dan slot kosong cukup ditandai `buf.len == 0` (`multiplexers/slab.zig`).

> Gunakan ketika alokasi heap per-accept muncul di hot path dan jumlah entry terbatas.

<br>

---

## Design Patterns

**Type-Per-Domain Methods (Namespace Struct):**<br>
Setiap protokol adalah namespace file-as-struct Zig tersendiri yang diekspor dari `lib.zig` (`zix.Http`, `zix.Http1`, `zix.Grpc`, `zix.Tcp`, `zix.Fix`, `zix.Udp`, `zix.Uds`, `zix.Channel`, `zix.Logger`), hanya mengekspos method domain tersebut (`Server.init`, `run`, ...).

> Gunakan ketika sebuah subsistem punya permukaan yang mandiri: beri satu namespace type alih-alih free function yang berserakan.

<br>

**Flat Config (No Builder):**<br>
Setiap config struct menyimpan semua field di level teratas, tanpa sub-config bersarang dan tanpa fluent builder (`*/config.zig`).

> Tetap flat: tambahkan field di level teratas alih-alih method builder atau objek config bersarang.

<br>

**Shared-Nothing / Thread-Per-Core:**<br>
Setiap worker EPOLL / URING memiliki satu listener `SO_REUSEPORT` dan event loop privat, tanpa shared queue dan tanpa handoff fd lintas thread (`http1/dispatch/epoll.zig`, `tcp/server.zig`).

> Gunakan untuk jumlah koneksi tinggi ketika contention queue, bukan CPU, yang menjadi batas.

<br>

**Reactor (Readiness-Based Loop):**<br>
Loop `epoll_wait` melaporkan fd yang siap dan worker menangani masing-masing secara inline (`http1/dispatch/epoll.zig`, `grpc/server.zig`).

> Gunakan ketika notifikasi readiness plus I/O inline sudah cukup.

<br>

**Proactor (Completion-Based Loop):**<br>
SQE io_uring di-submit dan CQE dipanen, membatch sebagian besar transisi syscall ke dalam ring (`http1/dispatch/uring.zig`, ADR-037).

> Gunakan ketika biaya syscall-entry atau cache locality per-request yang menjadi pengungkit.

<br>

**Strategy (Pluggable Dispatch):**<br>
Enum `DispatchModel` memilih `runAsync` / `runPool` / `runMixed` / `runEpoll` / `runUring` saat startup, per engine (`*/server.zig`).

> Gunakan ketika satu engine harus menawarkan beberapa bentuk eksekusi runtime di balik satu field config.

<br>

**Comptime Route Table:**<br>
`Router(comptime routes)` memartisi route ke dalam grup exact / prefix / param saat compile time, sehingga dispatch hanya memindai jenis yang relevan (`http/router.zig`).

> Gunakan ketika set route diketahui saat build time dan matching per-request bersifat hot.

<br>

**Callback Handler (Function Pointer):**<br>
Handler request, frame, dan session adalah function pointer biasa (`HandlerFn`, `FrameFn`, callback session FIX) (`fix/core.zig`).

> Gunakan ketika engine memiliki loop-nya dan pengguna hanya menyediakan body per-event.

<br>

**Shared-Primitive Multiplexer:**<br>
Hanya primitive yang byte-identical yang diangkat ke `src/multiplexers/` (codec `user_data` ring, slab), sementara tiap engine menyimpan dispatch loop-nya sendiri (ADR-042).

> Bagikan sebuah primitive hanya ketika ia harus sama persis lintas engine, selain itu simpan per-engine.

<br>

**Slab (Inline Demand-Paged Slots):**<br>
Connection table EPOLL / URING mengukir buffer tiap koneksi dari satu contiguous demand-paged slab, tanpa heap call per-accept (`multiplexers/slab.zig`).

> Gunakan ketika alokasi per-accept bersifat hot dan jumlah entry terbatas.

<br>

**Arena (Bulk-Reset Allocation):**<br>
Scratch per-connection dan per-request diambil dari arena dan dilepaskan dalam satu reset (`http/request.zig`).

> Gunakan ketika alokasi berbagi satu lifetime.

<br>

**Object Pool (Idle-Conn Reclaim):**<br>
Ring URING menyimpan pool koneksi idle dengan reclaim LRU-tail alih-alih membebaskan pada setiap close (`http1/dispatch/uring.zig`, ADR-041).

> Gunakan ketika churn koneksi mendominasi dan biaya re-acquire penting.

<br>

**Generation-Tagged Slot (Handle Map):**<br>
Codec `user_data` io_uring mengemas slot ber-key fd yang dijaga oleh sebuah generation, sehingga completion yang basi terdeteksi dan dibuang (`multiplexers/ring.zig`).

> Gunakan ketika completion async bisa hidup lebih lama dari slot yang dirujuknya.

<br>

**Resumable State Machine:**<br>
H2 termultipleks (gRPC) dan session FIX menyimpan state per-connection yang resumable, sehingga satu worker menggerakkan banyak koneksi (`grpc/server.zig`, `fix/core.zig`).

> Gunakan ketika sebuah protokol membentang banyak round-trip pada satu koneksi non-blocking.

<br>

**Memoization (Response Cache):**<br>
Respons terkomputasi per-key diputar ulang tanpa encoding ulang (`utils/response_cache.zig`).

> Gunakan ketika body respons yang sama dilayani berulang dan encoding terukur.

<br>

**Write Coalescing (Batched Sink):**<br>
Beberapa write dalam satu pass di-stage dan di-flush sebagai satu `send` (`http1/core.zig`, `websocket.zig`).

> Gunakan ketika sebuah respons atau pump pass mengeluarkan beberapa write kecil.

<br>

**Backpressure (EPOLLOUT Arming):**<br>
Ketika sebuah send akan blok, fd di-arm untuk writable dan sisanya di-flush pada event berikutnya (`http/response.zig`, `http1/dispatch/epoll.zig`).

> Gunakan ketika klien lambat tidak boleh memarkir worker pada write yang blocking.

<br>

**Baked Response Prefix:**<br>
Prefix header terkomputasi dikeluarkan dengan satu memcpy alih-alih memformat per-request (`http1/core.zig`).

> Gunakan ketika prefix respons konstan lintas request.

<br>

## Konvensi Penamaan

**Casing member enum:**<br>
Member enum default-nya UPPER_CASE. Pengecualiannya bukan pilihan bebas, melainkan mengikuti sumber yang dimodelkan enum tersebut:

| Jenis enum | Casing | Contoh |
| :- | :- | :- |
| Domain, public, atau config | UPPER_CASE | `DispatchModel` (.ASYNC / .EPOLL / .URING), `Content.Type`, `RouteKind` (EXACT / PREFIX / PARAM), `Version` (HTTP_1 / HTTP_2 / HTTP_3), logger `Level` (DEBUG / INFO / WARN / ERROR), `GrpcStatus`, compression `Encoding` (IDENTITY / GZIP / DEFLATE / BR) |
| Protocol-mirroring | ikuti spec sumber | WebSocket `Opcode` mengikuti RFC 6455 (continuation, text, binary, ping, pong), FIX `Tag` mengikuti nama field FIX (ClOrdID, MsgSeqNum, BeginString) |
| Internal control-flow | lower_case snake | `ConnOutcome` / `ReqOutcome` / `FrameOutcome` (keep_alive, close), `MuxPhase`, ring `OpKind` (accept, recv, send) |

> FIX `Tag` PascalCase secara sengaja: member-nya adalah nama field spec FIX verbatim, jadi tidak boleh di-rename sampai komunitas FIX memperbarui spec (lihat catatan pada `Tag` di `tcp/fix/core.zig`).
