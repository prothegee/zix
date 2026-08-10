//! zix logger

const std = @import("std");
const builtin = @import("builtin");
const ZIG_SEMVER = @import("../lib.zig").ZIG_SEMVER;
const win_io = @import("../utils/windows_io.zig");

// --------------------------------------------------------- //

/// Stack buffer for formatting one log line before it is written.
const LINE_BUF_SIZE: usize = 4096;

/// Stack buffer for formatting one system() message before it is written.
const MSG_BUF_SIZE: usize = 2048;

/// Stack buffer for building the per-day log directory path (sentinel-terminated for mkdirat).
const DIR_PATH_BUF_SIZE: usize = 512;

/// Stack buffer for building the full log file path.
const FILE_PATH_BUF_SIZE: usize = 600;

/// What ends a record the buffer could not hold, so a short line is never read as a complete one.
const TRUNCATION_MARK = " ...[truncated]";

const Timestamp = struct {
    date: [10]u8,
    time: [12]u8,
};

fn getTimestamp() Timestamp {
    var secs: u64 = 0;
    var ms_part: u64 = 0;

    if (comptime builtin.target.os.tag == .linux) {
        var spec: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.REALTIME, &spec);
        secs = if (spec.sec >= 0) @intCast(spec.sec) else 0;
        ms_part = if (spec.nsec >= 0) @as(u64, @intCast(spec.nsec)) / 1_000_000 else 0;
    } else if (comptime builtin.target.os.tag == .windows) {
        const ns = win_io.wallClockNs();
        secs = ns / std.time.ns_per_s;
        ms_part = (ns % std.time.ns_per_s) / 1_000_000;
    } else {
        var spec: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(.REALTIME, &spec);
        secs = if (spec.sec >= 0) @intCast(spec.sec) else 0;
        ms_part = if (spec.nsec >= 0) @as(u64, @intCast(spec.nsec)) / 1_000_000 else 0;
    }

    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const day_secs = epoch_secs.getDaySeconds();
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const year: u16 = year_day.year;
    const month: u4 = month_day.month.numeric();
    const day: u5 = month_day.day_index + 1;
    const hour: u5 = day_secs.getHoursIntoDay();
    const minute: u6 = day_secs.getMinutesIntoHour();
    const second: u6 = day_secs.getSecondsIntoMinute();

    var timestamp: Timestamp = undefined;
    _ = std.fmt.bufPrint(&timestamp.date, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch {};
    _ = std.fmt.bufPrint(&timestamp.time, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ hour, minute, second, ms_part }) catch {};
    return timestamp;
}

/// Sentinel for "no log file open". Windows descriptors are opaque pointers, POSIX are ints.
const NO_FILE_FD: std.posix.fd_t = if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else -1;

/// Whether fd refers to an open log file (is not the NO_FILE_FD sentinel).
fn hasFileFd(fd: std.posix.fd_t) bool {
    if (comptime builtin.os.tag == .windows) return fd != std.os.windows.INVALID_HANDLE_VALUE;

    return fd >= 0;
}

/// Stderr descriptor for console output: the PEB handle on Windows, the POSIX
/// descriptor elsewhere.
fn stderrFd() std.posix.fd_t {
    if (comptime builtin.os.tag == .windows) return std.Io.File.stderr().handle;

    return std.posix.STDERR_FILENO;
}

/// Write every byte of data to fd.
///
/// Note:
/// - .INTR and .AGAIN are retried rather than treated as the end. A signal arriving mid-write, or a
///   pipe that is momentarily full, is not a reason to lose the line.
/// - A write of zero bytes is reported as .IO rather than looped on, because retrying it forever
///   would spin the caller.
///
/// Param:
/// fd - std.posix.fd_t (the log file, or stderr for the console sink)
///
/// Return:
/// - null when the whole slice went out
/// - the errno that stopped it otherwise, for the caller to report once
fn rawWrite(fd: std.posix.fd_t, data: []const u8) ?std.posix.E {
    if (comptime builtin.os.tag == .windows) {
        // File logging is suspended on Windows (openFileLocked), so every rawWrite
        // targets stderr regardless of fd. The std.debug lock writer is the portable
        // no-allocation stderr path there.
        const stderr = std.debug.lockStderr(&.{});
        defer std.debug.unlockStderr();

        stderr.file_writer.interface.writeAll(data) catch return .IO;

        return null;
    }

    var remaining = data;
    while (remaining.len > 0) {
        const write_result = std.posix.system.write(fd, remaining.ptr, remaining.len);
        switch (std.posix.errno(write_result)) {
            .SUCCESS => {
                const n: usize = @intCast(write_result);
                if (n == 0) return .IO;

                remaining = remaining[n..];
            },
            .INTR, .AGAIN => continue,
            else => |errno| return errno,
        }
    }

    return null;
}

/// Format one record into buf, keeping a truncated line rather than dropping it.
///
/// Note:
/// - A dropped record is worse than a short one: the reader loses the fact that anything happened
///   at all. What does not fit is replaced by TRUNCATION_MARK, so a short line is always readable
///   as short.
/// - buf has to be wider than the mark, which every caller's buffer is by hundreds of bytes.
///
/// Param:
/// buf - []u8 (the caller's stack buffer)
///
/// Return:
/// - the formatted slice, marked when it did not all fit
fn formatRecord(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    const room = buf.len - TRUNCATION_MARK.len;

    var writer = std.Io.Writer.fixed(buf[0..room]);
    writer.print(fmt, args) catch {
        const kept = writer.buffered().len;
        @memcpy(buf[kept..][0..TRUNCATION_MARK.len], TRUNCATION_MARK);

        return buf[0 .. kept + TRUNCATION_MARK.len];
    };

    return writer.buffered();
}

// --------------------------------------------------------- //

pub const Logger = struct {
    pub const Level = enum(u8) {
        DEBUG = 0,
        INFO = 1,
        WARN = 2,
        ERROR = 3,
    };

    pub const ConsoleMode = enum(u8) {
        OFF = 0,
        DEBUG_ONLY = 1,
        ALWAYS = 2,
    };

    /// Transfer direction for packet() and frame() log calls.
    pub const Dir = enum(u8) {
        RECV = 0,
        SEND = 1,
    };

    pub const Config = struct {
        /// Console output mode.
        console: ConsoleMode = .OFF,
        /// Minimum level for console output.
        console_min_level: Level = .INFO,
        /// Directory for log files. Must already exist, caller's responsibility. Empty string disables file logging.
        save_path: []const u8 = "",
        /// Base name for log files (e.g. "log" -> "log-000000.log").
        save_file: []const u8 = "log",
        /// Minimum level for file output.
        save_min_level: Level = .INFO,
        /// Lines per file before rotating to the next sequence number.
        max_lines: u64 = 1_000_000,
        /// File write-buffer size in bytes. Larger batches more log lines per write() to disk.
        write_buf_size: usize = 64 * 1024,
    };

    // --------------------------------------------------------- //

    config: Config,
    allocator: std.mem.Allocator,
    locked: std.atomic.Value(bool) = .init(false),

    file_fd: std.posix.fd_t = NO_FILE_FD,
    current_date: [10]u8 = undefined,
    file_seq: u32 = 0,
    line_count: u64 = 0,
    file_suspended: bool = false,

    buf: []u8 = &.{},
    buf_pos: usize = 0,

    const Self = @This();

    // --------------------------------------------------------- //

    fn statusLevel(status: u16) Level {
        return if (status >= 500) .ERROR else if (status >= 400) .WARN else if (status >= 200) .INFO else .DEBUG;
    }

    fn levelLabel(level: Level) *const [5]u8 {
        return switch (level) {
            .DEBUG => "DEBUG",
            .INFO => "INFO ",
            .WARN => "WARN ",
            .ERROR => "ERROR",
        };
    }

    // --------------------------------------------------------- //

    pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
        var self = Self{
            .config = config,
            .allocator = allocator,
        };
        if (config.save_path.len > 0) {
            self.buf = try allocator.alloc(u8, config.write_buf_size);
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.spinLock();
        defer self.spinUnlock();
        self.flushLocked();
        self.closeFileLocked();
        if (self.buf.len > 0) {
            self.allocator.free(self.buf);
            self.buf = &.{};
        }
    }

    pub fn flush(self: *Self) void {
        self.spinLock();
        defer self.spinUnlock();
        self.flushLocked();
    }

    // --------------------------------------------------------- //

    fn spinLock(self: *Self) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn spinUnlock(self: *Self) void {
        self.locked.store(false, .release);
    }

    fn flushLocked(self: *Self) void {
        if (self.buf_pos == 0 or !hasFileFd(self.file_fd)) return;

        // A write that fails here used to vanish, so a full disk read as a log that simply stopped.
        if (rawWrite(self.file_fd, self.buf[0..self.buf_pos])) |errno| {
            self.suspendFileLocked(@tagName(errno), self.config.save_path);
        }

        self.buf_pos = 0;
    }

    fn closeFileLocked(self: *Self) void {
        // No log file ever opens on Windows (openFileLocked suspends), and the
        // POSIX close below needs libc there, so this stays out of analysis.
        if (comptime builtin.os.tag == .windows) return;

        if (hasFileFd(self.file_fd)) {
            _ = std.posix.system.close(self.file_fd);
            self.file_fd = NO_FILE_FD;
        }
    }

    fn openFileLocked(self: *Self, date: *const [10]u8) void {
        if (comptime builtin.os.tag == .windows) {
            // File logging is not ported to Windows yet: console logging still works.
            self.suspendFileLocked("file logging is not supported on Windows yet", "");
            return;
        }

        var dir_buf: [DIR_PATH_BUF_SIZE:0]u8 = undefined;
        const dir_z = if (comptime ZIG_SEMVER.MINOR == 16)
            std.fmt.bufPrintZ(&dir_buf, "{s}/{s}", .{ self.config.save_path, date }) catch {
                // Without the suspend the logger would rebuild this same path for every record and
                // fail the same way, silently, for the life of the process.
                self.suspendFileLocked("the day directory path is longer than the logger allows", self.config.save_path);
                return;
            }
        else
            std.fmt.bufPrintSentinel(&dir_buf, "{s}/{s}", .{ self.config.save_path, date }, 0) catch {
                self.suspendFileLocked("the day directory path is longer than the logger allows", self.config.save_path);
                return;
            };

        const mkdir_rc = std.posix.system.mkdirat(@as(i32, std.posix.AT.FDCWD), dir_z, 0o755);
        switch (std.posix.errno(mkdir_rc)) {
            .SUCCESS, .EXIST => {},
            else => |errno| {
                self.suspendFileLocked(@tagName(errno), dir_z);
                return;
            },
        }

        var file_buf: [FILE_PATH_BUF_SIZE]u8 = undefined;
        const file_path = std.fmt.bufPrint(
            &file_buf,
            "{s}/{s}/{s}-{d:0>6}.log",
            .{ self.config.save_path, date, self.config.save_file, self.file_seq },
        ) catch {
            self.suspendFileLocked("the log file path is longer than the logger allows", self.config.save_path);
            return;
        };

        self.file_fd = std.posix.openat(
            @as(std.posix.fd_t, std.posix.AT.FDCWD),
            file_path,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
            0o644,
        ) catch |err| {
            self.suspendFileLocked(@errorName(err), file_path);
            return;
        };
    }

    /// Stop writing to the log file and say why, once, on stderr.
    ///
    /// Note:
    /// - stderr is the only destination left: the thing that failed IS the log file. The old line
    ///   guessed one cause ("ensure save_path exists") for every failure and never printed the
    ///   path, so a permission problem and a typo read the same.
    /// - file_suspended is what makes this once. Every later record skips the file sink.
    ///
    /// Param:
    /// cause - []const u8 (the errno or error name, or a sentence when there is no errno)
    /// subject - []const u8 (the path it happened to, empty when there is none)
    fn suspendFileLocked(self: *Self, cause: []const u8, subject: []const u8) void {
        self.file_suspended = true;

        var report_buf: [FILE_PATH_BUF_SIZE + 192]u8 = undefined;
        const line = if (subject.len > 0)
            formatRecord(&report_buf, "zix: logger: {s}: {s}, file logging suspended, console logging continues\n", .{ cause, subject })
        else
            formatRecord(&report_buf, "zix: logger: {s}, file logging suspended, console logging continues\n", .{cause});

        _ = rawWrite(stderrFd(), line);
    }

    fn ensureFileLocked(self: *Self, date: *const [10]u8) void {
        if (self.file_suspended) return;

        if (!hasFileFd(self.file_fd)) {
            self.current_date = date.*;
            self.file_seq = 0;
            self.line_count = 0;
            self.openFileLocked(date);
            return;
        }

        const date_changed = !std.mem.eql(u8, &self.current_date, date);
        if (date_changed) {
            self.flushLocked();
            self.closeFileLocked();
            self.current_date = date.*;
            self.file_seq = 0;
            self.line_count = 0;
            self.openFileLocked(date);
            return;
        }

        if (self.line_count >= self.config.max_lines) {
            if (self.file_seq >= 999_999) {
                self.flushLocked();
                self.closeFileLocked();
                self.suspendFileLocked("the day's file sequence is exhausted at 999999", self.config.save_path);
                return;
            }
            self.flushLocked();
            self.closeFileLocked();
            self.file_seq += 1;
            self.line_count = 0;
            self.openFileLocked(date);
        }
    }

    fn writeLineLocked(self: *Self, line: []const u8) void {
        const needed = line.len + 1;
        if (needed > self.buf.len) return;
        if (self.buf_pos + needed > self.buf.len) {
            self.flushLocked();
        }
        @memcpy(self.buf[self.buf_pos..][0..line.len], line);
        self.buf_pos += line.len;
        self.buf[self.buf_pos] = '\n';
        self.buf_pos += 1;
        self.line_count += 1;
        self.flushLocked();
    }

    fn consoleActive(self: *const Self, level: Level) bool {
        return switch (self.config.console) {
            .OFF => false,
            .DEBUG_ONLY => blk: {
                if (comptime if (ZIG_SEMVER.MINOR == 16) builtin.mode != .Debug else builtin.mode != .debug) break :blk false;
                break :blk @intFromEnum(level) >= @intFromEnum(self.config.console_min_level);
            },
            .ALWAYS => @intFromEnum(level) >= @intFromEnum(self.config.console_min_level),
        };
    }

    fn fileActive(self: *const Self, level: Level) bool {
        return self.config.save_path.len > 0 and
            !self.file_suspended and
            @intFromEnum(level) >= @intFromEnum(self.config.save_min_level);
    }

    // --------------------------------------------------------- //

    /// Log an HTTP access entry.
    /// Derives log level from status: 2xx/3xx=INFO, 4xx=WARN, 5xx=ERROR, other=DEBUG.
    /// Absent client_ip, ua, or origin should be passed as empty string. They log as "-".
    /// client_ip: real client address. Pass X-Forwarded-For or X-Real-IP value when behind a proxy.
    pub fn access(
        self: *Self,
        method: []const u8,
        path: []const u8,
        status: u16,
        bytes: usize,
        client_ip: []const u8,
        ua: []const u8,
        origin: []const u8,
    ) void {
        const level = statusLevel(status);
        if (!self.consoleActive(level) and !self.fileActive(level)) return;

        const timestamp = getTimestamp();
        const client_ip_out = if (client_ip.len > 0) client_ip else "-";
        const ua_out = if (ua.len > 0) ua else "-";
        const origin_out = if (origin.len > 0) origin else "-";

        var line_buf: [LINE_BUF_SIZE]u8 = undefined;
        const line = formatRecord(&line_buf, "{s} {s} {s}  {s} {s} {d} {d} \"{s}\" \"{s}\" \"{s}\"", .{ &timestamp.date, &timestamp.time, levelLabel(level), method, path, status, bytes, client_ip_out, ua_out, origin_out });

        self.spinLock();
        defer self.spinUnlock();

        if (self.consoleActive(level)) {
            _ = rawWrite(stderrFd(), line);
            _ = rawWrite(stderrFd(), "\n");
        }

        if (self.fileActive(level)) {
            self.ensureFileLocked(&timestamp.date);
            if (!self.file_suspended) {
                self.writeLineLocked(line);
            }
        }
    }

    /// Log a TCP connection lifecycle event.
    /// peer: "1.2.3.4:54321" or "-" when unavailable.
    /// dur_ms: connection duration in milliseconds.
    /// err: null for a clean close. Non-null error tag string (e.g. "read_fail") otherwise.
    /// Level: INFO on clean close, WARN on error.
    pub fn conn(
        self: *Self,
        peer: []const u8,
        dur_ms: u64,
        err: ?[]const u8,
    ) void {
        const level: Level = if (err == null) .INFO else .WARN;
        if (!self.consoleActive(level) and !self.fileActive(level)) return;

        const timestamp = getTimestamp();
        const err_out = err orelse "-";

        var line_buf: [LINE_BUF_SIZE]u8 = undefined;
        const line = formatRecord(&line_buf, "{s} {s} {s}  [tcp:conn] {s} dur={d}ms {s}", .{ &timestamp.date, &timestamp.time, levelLabel(level), peer, dur_ms, err_out });

        self.spinLock();
        defer self.spinUnlock();

        if (self.consoleActive(level)) {
            _ = rawWrite(stderrFd(), line);
            _ = rawWrite(stderrFd(), "\n");
        }

        if (self.fileActive(level)) {
            self.ensureFileLocked(&timestamp.date);
            if (!self.file_suspended) {
                self.writeLineLocked(line);
            }
        }
    }

    /// Log a UDP datagram event.
    /// dir: RECV or SEND.
    /// peer: "1.2.3.4:5000".
    /// size: datagram size in bytes.
    /// err: null on success. Non-null error tag string otherwise.
    /// Level: INFO on success, WARN on error.
    pub fn packet(
        self: *Self,
        dir: Dir,
        peer: []const u8,
        size: usize,
        err: ?[]const u8,
    ) void {
        const level: Level = if (err == null) .INFO else .WARN;
        if (!self.consoleActive(level) and !self.fileActive(level)) return;

        const timestamp = getTimestamp();
        const dir_out: []const u8 = if (dir == .RECV) "recv" else "send";
        const err_out = err orelse "-";

        var line_buf: [LINE_BUF_SIZE]u8 = undefined;
        const line = formatRecord(&line_buf, "{s} {s} {s}  [udp:pkt] {s} {s} size={d} {s}", .{ &timestamp.date, &timestamp.time, levelLabel(level), dir_out, peer, size, err_out });

        self.spinLock();
        defer self.spinUnlock();

        if (self.consoleActive(level)) {
            _ = rawWrite(stderrFd(), line);
            _ = rawWrite(stderrFd(), "\n");
        }

        if (self.fileActive(level)) {
            self.ensureFileLocked(&timestamp.date);
            if (!self.file_suspended) {
                self.writeLineLocked(line);
            }
        }
    }

    /// Log a UDS frame event.
    /// dir: RECV or SEND.
    /// sock_path: socket filesystem path (e.g. "/var/run/zix.sock").
    /// size: frame payload size in bytes.
    /// err: null on success. Non-null error tag string otherwise.
    /// Level: INFO on success, WARN on error.
    pub fn frame(
        self: *Self,
        dir: Dir,
        sock_path: []const u8,
        size: usize,
        err: ?[]const u8,
    ) void {
        const level: Level = if (err == null) .INFO else .WARN;
        if (!self.consoleActive(level) and !self.fileActive(level)) return;

        const timestamp = getTimestamp();
        const dir_out: []const u8 = if (dir == .RECV) "recv" else "send";
        const err_out = err orelse "-";

        var line_buf: [LINE_BUF_SIZE]u8 = undefined;
        const line = formatRecord(&line_buf, "{s} {s} {s}  [uds:frame] {s} {s} size={d} {s}", .{ &timestamp.date, &timestamp.time, levelLabel(level), dir_out, sock_path, size, err_out });

        self.spinLock();
        defer self.spinUnlock();

        if (self.consoleActive(level)) {
            _ = rawWrite(stderrFd(), line);
            _ = rawWrite(stderrFd(), "\n");
        }

        if (self.fileActive(level)) {
            self.ensureFileLocked(&timestamp.date);
            if (!self.file_suspended) {
                self.writeLineLocked(line);
            }
        }
    }

    /// Log a FIX session message event. Always INFO level.
    /// msg_type: tag 35 value (e.g. "A", "D", "5", "0").
    /// sender: SenderCompID from the message (tag 49).
    /// target: our TargetCompID (tag 56).
    /// seq: MsgSeqNum from the message (tag 34).
    /// state: label (e.g. "Logon", "Logout", "Heartbeat", "msg").
    pub fn session(
        self: *Self,
        msg_type: []const u8,
        sender: []const u8,
        target: []const u8,
        seq: u64,
        state: []const u8,
    ) void {
        const level: Level = .INFO;
        if (!self.consoleActive(level) and !self.fileActive(level)) return;

        const timestamp = getTimestamp();

        var line_buf: [LINE_BUF_SIZE]u8 = undefined;
        const line = formatRecord(&line_buf, "{s} {s} {s}  [fix:sess] 35={s} sender={s} target={s} seq={d} {s}", .{ &timestamp.date, &timestamp.time, levelLabel(level), msg_type, sender, target, seq, state });

        self.spinLock();
        defer self.spinUnlock();

        if (self.consoleActive(level)) {
            _ = rawWrite(stderrFd(), line);
            _ = rawWrite(stderrFd(), "\n");
        }

        if (self.fileActive(level)) {
            self.ensureFileLocked(&timestamp.date);
            if (!self.file_suspended) {
                self.writeLineLocked(line);
            }
        }
    }

    /// Log a gRPC RPC event. Called once per dispatched stream.
    /// peer: "1.2.3.4:54321" or "-" when unavailable.
    /// path: full gRPC path (e.g. "/location.Location/SendLocationAndSave").
    /// grpc_status: numeric status code. 0=OK -> INFO, non-zero -> WARN.
    /// recv_bytes: total request body bytes buffered from all DATA frames.
    /// sent_bytes: total response body bytes sent by the handler.
    /// dur_ms: handler wall-clock duration in milliseconds.
    pub fn rpc(
        self: *Self,
        peer: []const u8,
        path: []const u8,
        grpc_status: u8,
        recv_bytes: usize,
        sent_bytes: usize,
        dur_ms: u64,
    ) void {
        const level: Level = if (grpc_status == 0) .INFO else .WARN;
        if (!self.consoleActive(level) and !self.fileActive(level)) return;

        const timestamp = getTimestamp();

        var line_buf: [LINE_BUF_SIZE]u8 = undefined;
        const line = formatRecord(&line_buf, "{s} {s} {s}  [grpc:rpc] {s} {s} status={d} recv={d} sent={d} dur={d}ms", .{ &timestamp.date, &timestamp.time, levelLabel(level), peer, path, grpc_status, recv_bytes, sent_bytes, dur_ms });

        self.spinLock();
        defer self.spinUnlock();

        if (self.consoleActive(level)) {
            _ = rawWrite(stderrFd(), line);
            _ = rawWrite(stderrFd(), "\n");
        }

        if (self.fileActive(level)) {
            self.ensureFileLocked(&timestamp.date);
            if (!self.file_suspended) {
                self.writeLineLocked(line);
            }
        }
    }

    /// Log a system event.
    /// component identifies the source (e.g. "http", "udp", "payment").
    /// fmt and args follow std.fmt.bufPrint conventions.
    pub fn system(
        self: *Self,
        level: Level,
        component: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (!self.consoleActive(level) and !self.fileActive(level)) return;

        const timestamp = getTimestamp();

        var msg_buf: [MSG_BUF_SIZE]u8 = undefined;
        const msg = formatRecord(&msg_buf, fmt, args);

        var line_buf: [LINE_BUF_SIZE]u8 = undefined;
        const line = formatRecord(&line_buf, "{s} {s} {s}  [{s}] {s}", .{ &timestamp.date, &timestamp.time, levelLabel(level), component, msg });

        self.spinLock();
        defer self.spinUnlock();

        if (self.consoleActive(level)) {
            _ = rawWrite(stderrFd(), line);
            _ = rawWrite(stderrFd(), "\n");
        }

        if (self.fileActive(level)) {
            self.ensureFileLocked(&timestamp.date);
            if (!self.file_suspended) {
                self.writeLineLocked(line);
            }
        }
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix logger: Logger init and deinit, no file" {
    const allocator = std.testing.allocator;
    var logger = try Logger.init(allocator, .{});
    defer logger.deinit();
}

test "zix logger: Logger.Config write_buf_size default" {
    const cfg = Logger.Config{};
    try std.testing.expectEqual(@as(usize, 64 * 1024), cfg.write_buf_size);
}

test "zix logger: Logger system call below min_level is silent" {
    const allocator = std.testing.allocator;
    var logger = try Logger.init(allocator, .{ .save_min_level = .ERROR });
    defer logger.deinit();
    logger.system(.DEBUG, "test", "should not panic", .{});
    logger.system(.INFO, "test", "should not panic", .{});
    logger.system(.WARN, "test", "should not panic", .{});
}

test "zix logger: Logger access call below min_level is silent" {
    const allocator = std.testing.allocator;
    var logger = try Logger.init(allocator, .{ .save_min_level = .ERROR });
    defer logger.deinit();
    logger.access("GET", "/", 200, 0, "", "", "");
}

test "zix logger: Logger access does not panic with empty client_ip" {
    const allocator = std.testing.allocator;
    var logger = try Logger.init(allocator, .{});
    defer logger.deinit();
    logger.access("GET", "/", 200, 0, "", "", "");
}

test "zix logger: Logger access does not panic with non-empty client_ip" {
    const allocator = std.testing.allocator;
    var logger = try Logger.init(allocator, .{});
    defer logger.deinit();
    logger.access("GET", "/", 200, 0, "10.0.0.1", "Mozilla/5.0", "https://example.com");
}

test "zix logger: Logger rpc call below min_level is silent" {
    const allocator = std.testing.allocator;
    var logger = try Logger.init(allocator, .{ .save_min_level = .ERROR });
    defer logger.deinit();
    logger.rpc("-", "/svc.Svc/Method", 0, 0, 0, 1);
}

test "zix logger: formatRecord returns the whole record when it fits" {
    var buf: [64]u8 = undefined;
    const line = formatRecord(&buf, "{s}:{d}", .{ "port", 8080 });

    try std.testing.expectEqualStrings("port:8080", line);
}

test "zix logger: formatRecord keeps a marked short line instead of dropping the record" {
    var buf: [32]u8 = undefined;
    const line = formatRecord(&buf, "{s}", .{"0123456789012345678901234567890123456789"});

    // The record survives: what fits, then the mark, and nothing longer than the buffer.
    try std.testing.expect(line.len <= buf.len);
    try std.testing.expect(std.mem.endsWith(u8, line, TRUNCATION_MARK));
    try std.testing.expect(std.mem.startsWith(u8, line, "0123456789"));
}

test "zix logger: formatRecord marks a record that only just overflows" {
    var buf: [24]u8 = undefined;
    const room = buf.len - TRUNCATION_MARK.len;

    const exact = formatRecord(&buf, "{s}", .{"abcdefghi"});
    try std.testing.expectEqualStrings("abcdefghi", exact);
    try std.testing.expect(exact.len <= room);

    var over_buf: [24]u8 = undefined;
    const over = formatRecord(&over_buf, "{s}", .{"abcdefghijklmnop"});
    try std.testing.expect(std.mem.endsWith(u8, over, TRUNCATION_MARK));
}

test "zix logger: system writes an oversize message as a marked line, not as nothing" {
    if (comptime builtin.os.tag == .windows) {
        std.log.info("logger file output is not ported to Windows, test skipped", .{});
        return;
    }

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    var logger = try Logger.init(std.testing.allocator, .{ .console = .OFF, .save_path = root, .save_min_level = .DEBUG });
    defer logger.deinit();

    var long_buf: [MSG_BUF_SIZE * 2]u8 = undefined;
    @memset(&long_buf, 'x');

    logger.system(.ERROR, "test", "{s}", .{&long_buf});
    logger.flush();

    const written = try readLoggedLine(tmp.dir, std.testing.allocator);
    defer std.testing.allocator.free(written);

    try std.testing.expect(std.mem.indexOf(u8, written, "ERROR") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, TRUNCATION_MARK) != null);
}

test "zix logger: a save_path that cannot be opened suspends the file sink and keeps the console" {
    if (comptime builtin.os.tag == .windows) {
        std.log.info("logger file output is not ported to Windows, test skipped", .{});
        return;
    }

    // No such directory, so the open fails and the logger has to say so rather than retry forever.
    // This test prints one line to stderr on purpose: that line IS the behaviour under test, and it
    // cannot be captured because the report goes to the raw descriptor by design (the log file is
    // the thing that failed, so stderr is the only destination left).
    var logger = try Logger.init(std.testing.allocator, .{
        .console = .OFF,
        .save_path = ".zig-cache/tmp/zix-logger-absent-root",
        .save_min_level = .DEBUG,
    });
    defer logger.deinit();

    logger.system(.ERROR, "test", "first record", .{});

    try std.testing.expect(logger.file_suspended);
    try std.testing.expect(!logger.fileActive(.ERROR));

    // The second record must not try again: the suspend is what makes the report land once.
    logger.system(.ERROR, "test", "second record", .{});
    try std.testing.expect(logger.file_suspended);
}

test "zix logger: rawWrite reports the errno instead of dropping the write" {
    if (comptime builtin.os.tag == .windows) {
        std.log.info("this test drives a POSIX descriptor, test skipped", .{});
        return;
    }

    // A descriptor that was never opened: the write cannot succeed and the caller must learn why.
    const errno = rawWrite(@as(std.posix.fd_t, 4096), "line\n");

    try std.testing.expect(errno != null);
    try std.testing.expectEqual(std.posix.E.BADF, errno.?);
}

test "zix logger: rawWrite answers null when the whole slice went out" {
    if (comptime builtin.os.tag == .windows) {
        std.log.info("this test drives a POSIX descriptor, test skipped", .{});
        return;
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/raw.txt", .{tmp.sub_path}) catch unreachable;

    const fd = try std.posix.openat(
        @as(std.posix.fd_t, std.posix.AT.FDCWD),
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    defer _ = std.posix.system.close(fd);

    try std.testing.expectEqual(@as(?std.posix.E, null), rawWrite(fd, "one line\n"));
}

/// Read back the one log file written under a temp root, for the tests above.
fn readLoggedLine(root: std.Io.Dir, allocator: std.mem.Allocator) ![]u8 {
    var days = root.iterate();

    while (try days.next(std.testing.io)) |entry| {
        if (entry.kind != .directory) continue;

        var day = try root.openDir(std.testing.io, entry.name, .{});
        defer day.close(std.testing.io);

        const bytes = day.readFileAlloc(std.testing.io, "log-000000.log", allocator, .limited(64 * 1024)) catch continue;
        if (bytes.len > 0) return bytes;

        allocator.free(bytes);
    }

    return error.ZixNoLogLine;
}
