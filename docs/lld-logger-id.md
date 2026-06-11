# LLD: zix.Logger (internal)

Struktur data internal dan algoritma untuk implementasi logger.

---

## Struktur Data

```zig
pub const Logger = struct {
    config: Config,
    allocator: std.mem.Allocator,
    locked: std.atomic.Value(bool),   // spinlock

    file_fd: std.posix.fd_t,          // -1 when no file is open
    current_date: [10]u8,             // "YYYY-MM-DD" of currently open file
    file_seq: u32,                    // sequence counter for file rotation
    line_count: u64,                  // lines written to current file
    file_suspended: bool,             // true after unrecoverable file I/O error

    buf: []u8,                        // 64 KB write buffer (heap, nil if save_path == "")
    buf_pos: usize,                   // bytes written into buf
};
```

---

## Alur Penulisan

Semua metode log mengikuti pola yang sama:

1. Turunkan level (disediakan pemanggil untuk `system()`, dihitung untuk yang lain).
2. Periksa `consoleActive(level)` dan `fileActive(level)`: keluar lebih awal jika keduanya tidak aktif.
3. Format `line` ke dalam stack buffer 4096 byte melalui `std.fmt.bufPrint`.
4. `spinLock()`.
5. Jika console aktif: `rawWrite(STDERR_FILENO, line + "\n")`.
6. Jika file aktif: `ensureFileLocked(&ts.date)` lalu `writeLineLocked(line)`.
7. `spinUnlock()`.

Semua pemformatan terjadi sebelum lock diperoleh. Waktu tahan lock sebanding dengan `memcpy` ke dalam write buffer, biasanya beberapa ratus nanodetik.

---

## rawWrite

Syscall POSIX `write` langsung dalam retry loop hingga semua byte terkirim atau error dikembalikan:

```zig
fn rawWrite(fd: std.posix.fd_t, data: []const u8) void {
    var rem = data;
    while (rem.len > 0) {
        const rc = std.posix.system.write(fd, rem.ptr, rem.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => { rem = rem[@intCast(rc)..]; },
            else => return,
        }
    }
}
```

Tidak ada `std.Io`: aman dari OS thread manapun termasuk thread yang di-spawn melalui `std.Thread.spawn`. Ini disengaja: `std.debug.print` melewati `std.Options.debug_io` (sebuah global singleton) dan bersaing dengan IPC test runner di background thread. `rawWrite` ke STDERR_FILENO tidak memiliki global state semacam itu.

---

## Spinlock

CAS loop pada `locked: std.atomic.Value(bool)`:
- Lock: `cmpxchgWeak(false, true, .acquire, .monotonic)`, mencoba ulang dengan `spinLoopHint()` saat gagal.
- Unlock: `store(false, .release)`.
- `spinLoopHint()` dipetakan ke `pause`/`yield` pada x86/ARM.

Spinlock benar di bawah konkurensi tinggi karena waktu tahan lock dibatasi oleh `memcpy` ke dalam staging buffer ditambah satu syscall `rawWrite` per baris. Di bawah throughput logging tinggi yang berkelanjutan, kontesi diserialisasi tetapi setiap penulisan adalah syscall berukuran kecil yang tetap.

---

## Write Buffer

Dialokasikan oleh `init()` hanya saat `save_path != ""` (`WRITE_BUF_SIZE = 64 KB`).

`writeLineLocked(line: []const u8)`:
1. Jika `buf_pos + line.len + 1 > buf.len`: panggil `flushLocked()` terlebih dahulu.
2. `@memcpy` byte baris ke dalam `buf[buf_pos..]`.
3. Tambahkan `'\n'` di `buf[buf_pos + line.len]`.
4. `buf_pos += line.len + 1`.
5. `line_count += 1`.
6. `flushLocked()`: selalu flush setelah setiap baris.

`flushLocked()`: `rawWrite(file_fd, buf[0..buf_pos])` lalu `buf_pos = 0`.

Flush dipicu oleh:
- Setiap baris yang ditulis (di dalam `writeLineLocked`).
- Pergantian tanggal atau rotasi urut (di dalam `ensureFileLocked`).
- Pemanggilan eksplisit `logger.flush()`.
- `logger.deinit()`.

---

## Algoritma Rotasi

`ensureFileLocked(date: *const [10]u8)` dipanggil sebelum setiap penulisan ke berkas:

```
if file_suspended: return

if file_fd < 0:
    open initial file for *date*
    return

if date changed:
    flush + close
    reset seq=0, line_count=0
    open new file in new date directory
    return

if line_count >= max_lines:
    if seq >= 999_999:
        flush + close
        file_suspended = true
        rawWrite(STDERR, warning)
        return
    flush + close
    seq += 1, line_count = 0
    open new file (same date directory)
```

Path berkas: `<save_path>/<YYYY-MM-DD>/<save_file>-<NNNNNN>.log` (nomor urut 6 digit dengan zero-padding).

Direktori tanggal dibuat dengan `mkdirat` di setiap pembukaan berkas. `mkdirat` bersifat idempoten: "sudah ada" bukan error di level system call.

---

## Timestamp

`getTimestamp()` memanggil `clock_gettime(.REALTIME)` melalui `std.os.linux.clock_gettime` (syscall langsung). Field kalender dihitung menggunakan `std.time.epoch`. Output:
- `date`: `"YYYY-MM-DD"` (10 byte, stack)
- `time`: `"HH:MM:SS.mmm"` (12 byte, stack)

Milidetik berasal dari `nsec / 1_000_000`. Tidak ada alokasi, tidak ada `std.Io`.

---

## consoleActive / fileActive

```zig
fn consoleActive(self, level) bool:
    .OFF           -> false
    .DEBUG_ONLY    -> comptime mode == .Debug and level >= console_min_level
    .ALWAYS        -> level >= console_min_level

fn fileActive(self, level) bool:
    save_path.len > 0
    and not file_suspended
    and level >= save_min_level
```

Keduanya diperiksa sebelum pemformatan apapun untuk memotong pemanggilan no-op dengan biaya nol.

---

###### end of lld-logger
