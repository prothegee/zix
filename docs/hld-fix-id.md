# HLD: zix.Fix

Server protokol sesi FIX 4.x. Framing tag=value dengan delimiter SOH (0x01). Dibangun seluruhnya dalam Zig — tanpa C FFI, tanpa library eksternal.

---

## Status

Sudah diimplementasikan. Lihat ADR-024 untuk alasan desain.

---

## Tujuan

- Eksplisit bukan implisit: pola konfigurasi dan dispatch model yang sama dengan `zix.Tcp`.
- Framing berbasis delimiter SOH: tanpa length prefix; deteksi batas pesan berbasis delimiter.
- Lapisan sesi sudah terintegrasi: Logon / Logout / Heartbeat / TestRequest ditangani secara otomatis; semua pesan lainnya di-echo.
- Tidak ada heap allocation di `serveConn`: stack buffer digunakan di seluruh implementasi.
- Dispatch POOL, ASYNC, MIXED, dan EPOLL. Default: ASYNC (sesi FIX berumur panjang). EPOLL berjalan secara native di Linux (pola gRPC: single epoll accept loop, pool worker memegang setiap koneksi selama masa hidupnya). Fallback ke POOL di non-Linux.
- `io: std.Io` di dalam konfigurasi (tidak diteruskan ke `run()`).

---

## Struktur Berkas

```
src/tcp/fix/
    Fix.zig      // namespace aggregator
    core.zig     // parsing, building, checksum, serveConn, MsgType, FixContext, HandlerFn, FixRoute
    config.zig   // FixServerConfig, FixClientConfig
    server.zig   // FixServer — POOL, ASYNC, MIXED, and EPOLL (Linux-only) dispatch
    router.zig   // comptime FixRouter
    client.zig   // FixClient
```

Ekspor dari `src/zix.zig`:
```zig
pub const Fix = @import("tcp/fix/Fix.zig");
// zix.Fix.Server, zix.Fix.ServerConfig, zix.Fix.Client, zix.Fix.ClientConfig, zix.Fix.serveConn, ...
```

---

## API Publik

| Simbol | Tipe | Deskripsi |
| :- | :- | :- |
| `zix.Fix.Server` | struct | `init(routes, config)` / `deinit()` / `run()` — routes bertipe `[]const zix.Fix.Route` |
| `zix.Fix.ServerConfig` | struct | Lihat Field Konfigurasi Server di bawah |
| `zix.Fix.ServeOpts` | struct | `{ logger, heartbeat_timeout_ms, connection_timeout_ms, handler_timeout_ms, routes }` — opsi untuk `serveConn` |
| `zix.Fix.Client` | struct | `connect(config, io)` / `deinit(io)` / `logon(io, heart_bt_int)` / `logout(io)` / `sendMessage(io, msg_type, extra)` / `recvMessage(io)` |
| `zix.Fix.ClientConfig` | struct | Lihat Field Konfigurasi Client di bawah |
| `zix.Fix.DispatchModel` | enum(u8) | Re-export dari `zix.Tcp.DispatchModel` |
| `zix.Fix.Tag` | enum(u16) | Enum nonexhaustive dari nomor tag FIX 4.x standar. Gunakan `@enumFromInt` untuk tag kustom yang tidak terdaftar |
| `zix.Fix.MsgType` | struct | Namespace konstanta string compile-time untuk nilai MsgType (tag 35) FIX. Lihat bagian Konstanta MsgType |
| `zix.Fix.HandlerFn` | tipe | `*const fn (fields: []const Field, ctx: *Context) void` — handler pesan aplikasi |
| `zix.Fix.Route` | struct | `{ msg_type: []const u8, handler: HandlerFn, timeout_ms: u32 = 0 }` — satu rute pesan aplikasi |
| `zix.Fix.Context` | struct | Konteks per-koneksi yang diteruskan ke setiap handler. Field: `sender_comp_id`, `target_comp_id`, `deadline_ns`. Method: `sendMessage`, `isExpired` |
| `zix.Fix.Router(routes)` | comptime fn | Menghasilkan tipe dispatch comptime dengan `dispatch(fields, ctx, server_timeout_ms)` |
| `zix.Fix.wallClockNs` | fn | `std.os.linux.clock_gettime(.REALTIME)` menghasilkan u64 nanosecond (sama dengan `zix.Grpc.wallClockNs`) |
| `zix.Fix.Field` | struct | `{ tag: Tag, value: []const u8 }` — zero-copy slice ke receive buffer |
| `zix.Fix.BuildField` | struct | `{ tag: Tag, value: []const u8 }` — input untuk `buildMessage` |
| `zix.Fix.SOH` | u8 | `0x01` — delimiter field |
| `zix.Fix.VERSION` | []const u8 | `"FIX.4.2"` |
| `zix.Fix.MAX_FIELDS` | usize | 64 — jumlah field maksimum yang diparse per pesan |
| `zix.Fix.MAX_MSG_SIZE` | usize | 8192 — byte pesan maksimum |
| `zix.Fix.findMessageEnd` | fn | Memindai buf untuk akhir pesan FIX pertama yang lengkap; mengembalikan indeks setelah SOH terakhir atau null |
| `zix.Fix.parseFields` | fn | Mengurai byte mentah menjadi `[]Field` (zero-copy slice ke buf) |
| `zix.Fix.getField` | fn | Mengembalikan value field pertama dengan `Tag` yang diberikan, atau null |
| `zix.Fix.computeChecksum` | fn | Jumlah semua byte mod 256 |
| `zix.Fix.verifyChecksum` | fn | Mengembalikan true jika checksum tag-10 sesuai dengan nilai yang dihitung |
| `zix.Fix.buildMessage` | fn | Membangun pesan FIX lengkap ke dalam output buffer yang disediakan pemanggil |
| `zix.Fix.serveConn` | fn | Handler sesi: `serveConn(stream, io, comp_id, opts)` — membaca pesan, mendispatch Logon/Logout/Heartbeat, merutekan pesan aplikasi |

---

## Field Konfigurasi Server

| Field | Default | Deskripsi |
| :- | :- | :- |
| `io` | wajib | Backend Io. Disediakan pemanggil; harus melampaui masa hidup server |
| `ip` | wajib | Alamat bind |
| `port` | wajib | Port bind. Harus bukan nol |
| `comp_id` | wajib | SenderCompID server (tag 49) |
| `dispatch_model` | `.ASYNC` | POOL, ASYNC, MIXED, atau EPOLL (Linux-only: epoll native. Non-Linux fallback ke POOL) |
| `kernel_backlog` | 1024 | TCP listen backlog |
| `workers` | 0 (cpu_count) | Jumlah accept thread. Diabaikan oleh ASYNC |
| `pool_size` | 0 (otomatis) | Pool thread (`max(10, cpu_count * 2)`). Hanya digunakan oleh POOL |
| `logger` | null | Logger opsional untuk event siklus hidup dan sesi per-pesan |
| `heartbeat_timeout_ms` | 0 | Heartbeat timeout dalam ms. 0 = dinonaktifkan. Ketika bernilai non-zero: setelah interval ini tanpa pesan masuk, TestRequest (35=1) dikirim. Jika tidak ada respons yang datang dalam interval berikutnya, Logout (35=5) dikirim dan koneksi ditutup. Hanya berlaku setelah Logon; sebelum Logon, timeout menutup koneksi secara diam-diam. |
| `connection_timeout_ms` | 0 | Idle connection timeout dalam ms. 0 = dinonaktifkan. Ketika bernilai non-zero: jika tidak ada pesan yang datang dalam interval ini (meski heartbeat dinonaktifkan), koneksi ditutup. Berbeda dari `heartbeat_timeout_ms` — tidak ada TestRequest dance, langsung tutup. |
| `handler_timeout_ms` | 0 | Batas waktu pemrosesan handler server-wide dalam ms. 0 = tanpa batas. Diperketat per-rute oleh `Route.timeout_ms`. Mengatur `Context.deadline_ns` sebelum dispatch. |

---

## Field Konfigurasi Client

| Field | Deskripsi |
| :- | :- |
| `ip` | wajib — alamat server |
| `port` | wajib — port server. Harus bukan nol |
| `comp_id` | wajib — SenderCompID client ini (tag 49) |
| `target_comp_id` | wajib — TargetCompID server (tag 56) |

---

## Ikhtisar Protokol

FIX (Financial Information eXchange) 4.x menggunakan SOH (0x01) sebagai delimiter field. Setiap field berformat `tag=value\x01`. Pesan lengkap dimulai dari tag-8 (BeginString) dan diakhiri dengan tag-10 (Checksum) diikuti SOH terakhir:

```
8=FIX.4.2\x019=26\x0135=A\x0149=CLIENT\x0156=SERVER\x0134=1\x0198=0\x01108=30\x0110=NNN\x01
```

Tag standar utama:

| Tag | Nama | Peran |
| :- | :- | :- |
| 8 | BeginString | Selalu `FIX.4.2` dalam implementasi ini |
| 9 | BodyLength | Jumlah byte dari tag-35 hingga akhir nilai tag-10 (sebelum SOH terakhir) |
| 35 | MsgType | `A`=Logon, `5`=Logout, `0`=Heartbeat, `1`=TestRequest, `D`=NewOrderSingle, dll. |
| 49 | SenderCompID | Identitas pihak pengirim |
| 56 | TargetCompID | Identitas pihak penerima |
| 34 | MsgSeqNum | Nomor urut per sesi (dimulai dari 1) |
| 10 | Checksum | Jumlah semua byte pesan mod 256, diformat sebagai desimal 3 digit |

---

## Enum Tag

Nomor tag FIX dikirimkan sebagai integer ASCII di jaringan (misalnya `35`, `49`, `108`). Membaca literal numerik dalam kode mengharuskan menghafal spesifikasi FIX. `zix.Fix.Tag` adalah `enum(u16)` nonexhaustive yang memetakan nomor tag standar ke konstanta bernama — format jaringan tidak berubah.

```zig
pub const Tag = enum(u16) {
    MsgType      = 35,
    SenderCompID = 49,
    TargetCompID = 56,
    MsgSeqNum    = 34,
    HeartBtInt   = 108,
    // ... 54 tags total
    _,  // catch-all: any u16 is a valid Tag value
};
```

### Tag yang dicakup

Lapisan sesi: `BeginString` (8), `BodyLength` (9), `CheckSum` (10), `MsgSeqNum` (34), `MsgType` (35), `SenderCompID` (49), `SenderSubID` (50), `SendingTime` (52), `TargetCompID` (56), `TargetSubID` (57), `PossDupFlag` (43), `PossResend` (97), `EncryptMethod` (98), `HeartBtInt` (108), `TestReqID` (112), `OrigSendingTime` (122), `GapFillFlag` (123), `LastMsgSeqNumProcessed` (369).

Order dan eksekusi: `Account` (1), `AvgPx` (6), `ClOrdID` (11), `CumQty` (14), `Currency` (15), `ExecID` (17), `ExecTransType` (20), `HandlInst` (21), `LastPx` (31), `LastShares` (32), `OrderID` (37), `OrderQty` (38), `OrdStatus` (39), `OrdType` (40), `OrigClOrdID` (41), `Price` (44), `Side` (54), `StopPx` (99), `TimeInForce` (59), `TransactTime` (60), `ExecType` (150), `LeavesQty` (151).

Instrumen: `SecurityID` (48), `SecurityIDSource` (22), `Symbol` (55), `Text` (58), `ExDestination` (100), `SecurityType` (167), `MaturityMonthYear` (200), `SecurityExchange` (207), `TradeDate` (75).

Jumlah repeating group: `NoRelatedSym` (146), `NoMDEntries` (268), `NoPartyIDs` (453), `NoUnderlyings` (539), `NoLegs` (555).

### Cara penggunaan

Membaca field berdasarkan nama:

```zig
const msgtype  = zix.Fix.getField(fslice, .MsgType)      orelse return;
const sender   = zix.Fix.getField(fslice, .SenderCompID) orelse "";
const seq_str  = zix.Fix.getField(fslice, .MsgSeqNum)    orelse "0";
```

Membangun pesan dengan field bernama:

```zig
try client.sendMessage(io, "D", &[_]zix.Fix.BuildField{
    .{ .tag = .ClOrdID,  .value = "ORD-001" },
    .{ .tag = .Symbol,   .value = "AAPL" },
    .{ .tag = .Side,     .value = "1" },
    .{ .tag = .OrderQty, .value = "100" },
    .{ .tag = .OrdType,  .value = "2" },
    .{ .tag = .Price,    .value = "185.50" },
});
```

### Tag kustom dan ekstensi

Enum bersifat nonexhaustive (`_`). Semua `u16` adalah nilai `Tag` yang valid — gunakan `@enumFromInt` untuk tag yang tidak terdaftar:

```zig
const my_tag: zix.Fix.Tag = @enumFromInt(9999);
const extra = [_]zix.Fix.BuildField{
    .{ .tag = @enumFromInt(9001), .value = "custom-data" },
};
```

`parseFields` mengonversi integer jaringan ke `Tag` melalui `@enumFromInt` secara otomatis — tidak diperlukan konversi saat membaca field yang diterima.

### Pertimbangan

- Tipe backing adalah `u16`, sesuai dengan field `Field.tag` dan `BuildField.tag`. Tidak ada biaya runtime dibanding menyimpan `u16` mentah.
- Tag yang tidak dikenal yang diterima dari jaringan (`parseFields`) menjadi nilai enum nonexhaustive — keduanya dibandingkan dengan benar menggunakan `==` dan dicetak sebagai nilai integernya.
- Enum tidak memvalidasi nilai tag atau memberlakukan pembatasan versi FIX. Semua validasi semantik tetap menjadi tanggung jawab aplikasi.
- `getField` menerima `Tag` — meneruskan literal integer mentah secara langsung tidak lagi dapat dikompilasi. Gunakan konstanta bernama atau `@enumFromInt(n)`.

---

## Lapisan Sesi

`serveConn` mengimplementasikan lapisan sesi FIX secara otomatis. Tidak ada handler callback — semua logika sesi ada di dalam `serveConn`:

| MsgType (tag 35) | Tindakan server |
| :- | :- |
| `A` (Logon) | Merespons dengan Logon (`A`), CompID dibalik, seq=1 |
| `5` (Logout) | Merespons dengan Logout (`5`), kemudian menutup koneksi |
| `0` (Heartbeat) | Merespons dengan Heartbeat (`0`) |
| `1` (TestRequest) | Merespons dengan Heartbeat (`0`) |
| lainnya (routes non-kosong) | Dispatch ke `Route.handler` yang sesuai via `FixRouter`. Jika tidak ada rute yang cocok, pesan diabaikan |
| lainnya (routes kosong) | Echo pesan kembali tanpa perubahan (mode echo, backward-compatible) |

Checksum yang salah menutup koneksi tanpa memberikan respons.

---

## Konstanta MsgType

Nilai MsgType FIX (tag 35) adalah string ASCII, bukan integer. `zix.Fix.MsgType` adalah namespace struct berisi 47 konstanta string compile-time yang mencakup FIX 4.0–4.4. Gunakan konstanta ini sebagai pengganti string literal mentah untuk menghindari kesalahan ketik.

```zig
// Sesi
zix.Fix.MsgType.Heartbeat                   // "0"
zix.Fix.MsgType.TestRequest                 // "1"
zix.Fix.MsgType.ResendRequest               // "2"
zix.Fix.MsgType.Reject                      // "3"
zix.Fix.MsgType.SequenceReset               // "4"
zix.Fix.MsgType.Logout                      // "5"
zix.Fix.MsgType.Logon                       // "A"

// Aplikasi (satu karakter)
zix.Fix.MsgType.ExecutionReport             // "8"
zix.Fix.MsgType.OrderCancelReject           // "9"
zix.Fix.MsgType.IOIAcknowledgement          // "6"
zix.Fix.MsgType.IOI                         // "C"
zix.Fix.MsgType.NewOrderSingle              // "D"
zix.Fix.MsgType.NewOrderList                // "E"
zix.Fix.MsgType.OrderCancelRequest          // "F"
zix.Fix.MsgType.OrderCancelReplaceRequest   // "G"
zix.Fix.MsgType.OrderStatusRequest          // "H"
zix.Fix.MsgType.Allocation                  // "J"
// ... dan lainnya (Quote, MarketData*, Security*, TradingSession*, dll.)

// Aplikasi (dua karakter, FIX 4.3-4.4)
zix.Fix.MsgType.TradeCaptureReport          // "AE"
zix.Fix.MsgType.OrderMassStatusRequest      // "AF"
```

Penggunaan dalam tabel rute dan `sendMessage`:

```zig
&[_]zix.Fix.Route{
    .{ .msg_type = zix.Fix.MsgType.NewOrderSingle,    .handler = handleNewOrder },
    .{ .msg_type = zix.Fix.MsgType.OrderCancelRequest, .handler = handleCancel },
},

// di dalam handler:
ctx.sendMessage(zix.Fix.MsgType.ExecutionReport, &[_]zix.Fix.BuildField{ ... });

// di client:
try client.sendMessage(io, zix.Fix.MsgType.NewOrderSingle, &order_fields);
```

---

## Router dan Dispatch Pesan Aplikasi

Routes diteruskan saat `Fix.Server.init()`. Pesan sesi (Logon/Logout/Heartbeat/TestRequest) selalu ditangani secara internal oleh `serveConn`. Hanya pesan aplikasi (lainnya) yang mencapai router.

```zig
var server = try zix.Fix.Server.init(
    &[_]zix.Fix.Route{
        .{ .msg_type = zix.Fix.MsgType.NewOrderSingle,    .handler = handleNewOrder,   .timeout_ms = 500 },
        .{ .msg_type = zix.Fix.MsgType.OrderCancelRequest, .handler = handleCancel,     .timeout_ms = 500 },
    },
    .{
        .io                    = process.io,
        .ip                    = "0.0.0.0",
        .port                  = 9500,
        .comp_id               = "BROKER",
        .dispatch_model        = .ASYNC,
        .connection_timeout_ms = 60_000,
        .handler_timeout_ms    = 200,
    },
);
```

Routes kosong (`&.{}`) mengaktifkan mode echo (backward-compatible: semua pesan non-sesi di-echo).

### HandlerFn

```zig
fn handleNewOrder(fields: []const zix.Fix.Field, ctx: *zix.Fix.Context) void {
    if (ctx.isExpired()) return;
    const symbol = zix.Fix.getField(fields, .Symbol) orelse return;
    ctx.sendMessage(zix.Fix.MsgType.ExecutionReport, &[_]zix.Fix.BuildField{
        .{ .tag = .Symbol,    .value = symbol },
        .{ .tag = .OrdStatus, .value = "0" },
    });
}
```

### Field FixContext

| Field | Tipe | Deskripsi |
| :- | :- | :- |
| `sender_comp_id` | `[]const u8` | SenderCompID peer dari session Logon |
| `target_comp_id` | `[]const u8` | comp_id server (identitas kita) |
| `deadline_ns` | `?u64` | Deadline absolut (nanosecond CLOCK_REALTIME). Diatur dari yang paling ketat antara `handler_timeout_ms` dan `Route.timeout_ms`. Null = tanpa deadline |

### Method FixContext

| Method | Deskripsi |
| :- | :- |
| `sendMessage(msg_type, fields)` | Bangun dan kirim respons FIX pada koneksi ini (CompID dibalik) |
| `isExpired()` bool | Mengembalikan true ketika `deadline_ns` diatur dan sudah terlewati |

### Override Deadline

```zig
ctx.deadline_ns = zix.Fix.wallClockNs() + 2 * std.time.ns_per_s; // perpanjang ke 2 detik
ctx.deadline_ns = null;                                            // nonaktifkan
```

### FixRouter (comptime)

`FixRouter(routes)` menghasilkan fungsi `dispatch` comptime yang di-unroll menggunakan `inline for` saat kompilasi, tanpa overhead runtime.

Routes kosong (`&.{}`) melewati router sepenuhnya — semua pesan aplikasi di-echo.

---

## Format Frame

FIX menggunakan framing berbasis delimiter (SOH = 0x01), bukan framing length-prefix. Receive loop mengumpulkan byte melalui `takeByte` sampai `findMessageEnd` mendeteksi pesan yang lengkap. Cara ini menghindari deadlock `readSliceShort` yang terjadi ketika buffer besar diteruskan tetapi pesan lebih pendek dari kapasitas buffer (lihat bagian peringatan di CLAUDE.md).

```
recv_buf:  [complete message][leftover bytes][free]
                                      ^
                                      shifted after each message
```

---

## Model Dispatch

Sama seperti empat model di `zix.Http.Server`. Default adalah ASYNC (sesi FIX berumur panjang; POOL dapat menghabiskan thread di bawah beban berkelanjutan):

| Model | Accept thread | Catatan |
| :- | :- | :- |
| `.ASYNC` (default) | 1 | Sesi berumur panjang, deployment FIX standar |
| `.POOL` | cpu_count | Volume koneksi tinggi dengan sesi pendek |
| `.MIXED` | cpu_count | Throughput dan latensi yang seimbang |
| `.EPOLL` | 1 (Linux-only) | Single epoll accept loop. Pool worker memegang setiap koneksi selama masa hidupnya. Non-Linux fallback ke POOL. |

---

## Siklus Hidup Server

```
Fix.Server.init(config): validates port != 0, io taken from config
    -> .run(): dispatches via dispatch_model, blocks until error
Fix.Server.deinit(): no-op (resources released in run() via defer)
```

---

## Integrasi Logger

Ketika `config.logger` bernilai non-null:
- `system(.INFO, "fix", ...)` saat bind dan shutdown.
- `session(msg_type, sender, target, seq, state)` setelah setiap pesan diproses di dalam `serveConn`.

Lihat `docs/hld-logger-id.md` untuk detail format baris log.

---

## Contoh

| Berkas | Peran | Port |
| :- | :- | :- |
| `examples/fix_server_1_async.zig` | Server `.ASYNC` (mode echo) | 9500 |
| `examples/fix_server_2_pool.zig` | Server `.POOL` (mode echo) | 9500 |
| `examples/fix_server_3_mixed.zig` | Server `.MIXED` (mode echo) | 9500 |
| `examples/fix_server_4_epoll.zig` | Server `.EPOLL` (Linux-only: epoll native. Non-Linux fallback ke POOL) | 9500 |
| `examples/fix_server_trading.zig` | Server `.ASYNC` dengan router: NewOrderSingle + OrderCancelRequest, JSON append, logger, timeout | 9500 |
| `examples/fix_client.zig` | Client high-level `FixClient` | 9500 |
| `examples/fix_client_raw.zig` | Client primitif core mentah | 9500 |
| `examples/fix_client_trading.zig` | Client trading: buy/cancel/sell/cancel flow | 9500 |

---

###### end of hld-fix
