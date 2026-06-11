# LLD: zix.Logger (internal)

Internal data structures and algorithms for the logger implementation.

---

## Data Structures

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

## Write Path

All log methods follow the same pattern:

1. Derive level (caller-supplied for `system()`, computed for all others).
2. Check `consoleActive(level)` and `fileActive(level)`: early exit if both inactive.
3. Format `line` into a 4096-byte stack buffer via `std.fmt.bufPrint`.
4. `spinLock()`.
5. If console active: `rawWrite(STDERR_FILENO, line + "\n")`.
6. If file active: `ensureFileLocked(&ts.date)` then `writeLineLocked(line)`.
7. `spinUnlock()`.

All formatting happens before the lock is acquired. Lock hold time is proportional to `memcpy` into the write buffer, typically a few hundred nanoseconds.

---

## rawWrite

Direct POSIX `write` syscall in a retry loop until all bytes are sent or an error is returned:

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

No `std.Io`: safe from any OS thread including threads spawned via `std.Thread.spawn`. This is intentional: `std.debug.print` routes through `std.Options.debug_io` (a global singleton) and races with the test runner IPC on background threads. `rawWrite` to STDERR_FILENO has no such global state.

---

## Spinlock

CAS loop on `locked: std.atomic.Value(bool)`:
- Lock: `cmpxchgWeak(false, true, .acquire, .monotonic)`, retries with `spinLoopHint()` on failure.
- Unlock: `store(false, .release)`.
- `spinLoopHint()` maps to `pause`/`yield` on x86/ARM.

The spinlock is correct under high concurrency because lock hold time is bounded by a `memcpy` into the staging buffer plus one `rawWrite` syscall per line. Under sustained high logging throughput, contention is serialized but each write is a small fixed-size syscall.

---

## Write Buffer

Allocated by `init()` only when `save_path != ""` (`WRITE_BUF_SIZE = 64 KB`).

`writeLineLocked(line: []const u8)`:
1. If `buf_pos + line.len + 1 > buf.len`: `flushLocked()` first.
2. `@memcpy` line bytes into `buf[buf_pos..]`.
3. Append `'\n'` at `buf[buf_pos + line.len]`.
4. `buf_pos += line.len + 1`.
5. `line_count += 1`.
6. `flushLocked()`: always flush after every line.

`flushLocked()`: `rawWrite(file_fd, buf[0..buf_pos])` then `buf_pos = 0`.

Flush is triggered by:
- Every line written (inside `writeLineLocked`).
- Date rollover or sequence rotation (inside `ensureFileLocked`).
- Explicit `logger.flush()` call.
- `logger.deinit()`.

---

## File Rotation

`ensureFileLocked(date: *const [10]u8)` is called before every file write:

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

File path: `<save_path>/<YYYY-MM-DD>/<save_file>-<NNNNNN>.log` (6-digit zero-padded sequence).

The date directory is created with `mkdirat` at each open. `mkdirat` is idempotent: "already exists" is not an error at the system call level.

---

## Timestamp

`getTimestamp()` calls `clock_gettime(.REALTIME)` via `std.os.linux.clock_gettime` (direct syscall). Calendar fields are computed using `std.time.epoch`. Output:
- `date`: `"YYYY-MM-DD"` (10 bytes, stack)
- `time`: `"HH:MM:SS.mmm"` (12 bytes, stack)

Milliseconds come from `nsec / 1_000_000`. No allocation, no `std.Io`.

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

Both are checked before any formatting to short-circuit no-op calls at zero cost.

---

###### end of lld-logger
