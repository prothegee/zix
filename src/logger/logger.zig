//! zix logger

const std = @import("std");
const builtin = @import("builtin");

// --------------------------------------------------------- //

pub const Level = enum(u8) {
    DEBUG = 0,
    INFO  = 1,
    WARN  = 2,
    ERROR = 3,
};

pub const ConsoleMode = enum(u8) {
    OFF        = 0,
    DEBUG_ONLY = 1,
    ALWAYS     = 2,
};

pub const LoggerConfig = struct {
    /// Console output mode.
    console: ConsoleMode = .OFF,
    /// Minimum level for console output.
    console_min_level: Level = .INFO,
    /// Directory for log files. Must already exist — caller's responsibility. Empty string disables file logging.
    save_path: []const u8 = "",
    /// Base name for log files (e.g. "log" → "log-000000.log").
    save_file: []const u8 = "log",
    /// Minimum level for file output.
    save_min_level: Level = .INFO,
    /// Lines per file before rotating to the next sequence number.
    max_lines: u64 = 1_000_000,
};

// --------------------------------------------------------- //

const WRITE_BUF_SIZE: usize = 64 * 1024;

const Timestamp = struct {
    date: [10]u8,
    time: [12]u8,
};

fn getTimestamp() Timestamp {
    var spec: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &spec);
    const secs: u64 = if (spec.sec >= 0) @intCast(spec.sec) else 0;
    const ms_part: u64 = if (spec.nsec >= 0) @as(u64, @intCast(spec.nsec)) / 1_000_000 else 0;

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

    var ts: Timestamp = undefined;
    _ = std.fmt.bufPrint(&ts.date, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch {};
    _ = std.fmt.bufPrint(&ts.time, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ hour, minute, second, ms_part }) catch {};
    return ts;
}

fn levelLabel(level: Level) *const [5]u8 {
    return switch (level) {
        .DEBUG => "DEBUG",
        .INFO  => "INFO ",
        .WARN  => "WARN ",
        .ERROR => "ERROR",
    };
}

fn statusLevel(status: u16) Level {
    return if (status >= 500) .ERROR
    else if (status >= 400) .WARN
    else if (status >= 200) .INFO
    else .DEBUG;
}

fn rawWrite(fd: std.posix.fd_t, data: []const u8) void {
    var rem = data;
    while (rem.len > 0) {
        const rc = std.posix.system.write(fd, rem.ptr, rem.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return;
                rem = rem[n..];
            },
            else => return,
        }
    }
}

// --------------------------------------------------------- //

pub const Logger = struct {
    config: LoggerConfig,
    allocator: std.mem.Allocator,
    locked: std.atomic.Value(bool) = .init(false),

    file_fd: std.posix.fd_t = -1,
    current_date: [10]u8 = undefined,
    file_seq: u32 = 0,
    line_count: u64 = 0,
    file_suspended: bool = false,

    buf: []u8 = &.{},
    buf_pos: usize = 0,

    const Self = @This();

    // --------------------------------------------------------- //

    pub fn init(allocator: std.mem.Allocator, config: LoggerConfig) !Self {
        var self = Self{
            .config = config,
            .allocator = allocator,
        };
        if (config.save_path.len > 0) {
            self.buf = try allocator.alloc(u8, WRITE_BUF_SIZE);
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
        if (self.buf_pos == 0 or self.file_fd < 0) return;
        rawWrite(self.file_fd, self.buf[0..self.buf_pos]);
        self.buf_pos = 0;
    }

    fn closeFileLocked(self: *Self) void {
        if (self.file_fd >= 0) {
            _ = std.posix.system.close(self.file_fd);
            self.file_fd = -1;
        }
    }

    fn openFileLocked(self: *Self, date: *const [10]u8) void {
        // YYYY-MM-DD subdirectory inside save_path (internal rotation structure).
        // save_path itself must already exist — that is the caller's responsibility.
        var dir_buf: [512:0]u8 = undefined;
        const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}/{s}", .{ self.config.save_path, date }) catch return;
        _ = std.posix.system.mkdirat(@as(i32, std.posix.AT.FDCWD), dir_z, 0o755);

        var file_buf: [600]u8 = undefined;
        const file_path = std.fmt.bufPrint(
            &file_buf,
            "{s}/{s}/{s}-{d:0>6}.log",
            .{ self.config.save_path, date, self.config.save_file, self.file_seq },
        ) catch return;

        self.file_fd = std.posix.openat(
            @as(std.posix.fd_t, std.posix.AT.FDCWD),
            file_path,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
            0o644,
        ) catch {
            self.file_suspended = true;
            rawWrite(std.posix.STDERR_FILENO, "zix: logger: failed to open log file, ensure save_path exists, file logging suspended\n");
            return;
        };
    }

    fn ensureFileLocked(self: *Self, date: *const [10]u8) void {
        if (self.file_suspended) return;

        if (self.file_fd < 0) {
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
                self.file_suspended = true;
                rawWrite(std.posix.STDERR_FILENO, "zix: logger: file sequence exhausted, file logging suspended\n");
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
    }

    fn consoleActive(self: *const Self, level: Level) bool {
        return switch (self.config.console) {
            .OFF => false,
            .DEBUG_ONLY => blk: {
                if (comptime builtin.mode != .Debug) break :blk false;
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
    /// Absent ua or origin should be passed as empty string; they log as "-".
    pub fn access(
        self: *Self,
        method: []const u8,
        path: []const u8,
        status: u16,
        bytes: usize,
        ua: []const u8,
        origin: []const u8,
    ) void {
        const level = statusLevel(status);
        if (!self.consoleActive(level) and !self.fileActive(level)) return;

        const ts = getTimestamp();
        const ua_out = if (ua.len > 0) ua else "-";
        const origin_out = if (origin.len > 0) origin else "-";

        var line_buf: [4096]u8 = undefined;
        const line = std.fmt.bufPrint(
            &line_buf,
            "{s} {s} {s}  {s} {s} {d} {d} \"{s}\" \"{s}\"",
            .{ &ts.date, &ts.time, levelLabel(level), method, path, status, bytes, ua_out, origin_out },
        ) catch return;

        self.spinLock();
        defer self.spinUnlock();

        if (self.consoleActive(level)) {
            rawWrite(std.posix.STDERR_FILENO, line);
            rawWrite(std.posix.STDERR_FILENO, "\n");
        }

        if (self.fileActive(level)) {
            self.ensureFileLocked(&ts.date);
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

        const ts = getTimestamp();

        var msg_buf: [2048]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;

        var line_buf: [4096]u8 = undefined;
        const line = std.fmt.bufPrint(
            &line_buf,
            "{s} {s} {s}  [{s}] {s}",
            .{ &ts.date, &ts.time, levelLabel(level), component, msg },
        ) catch return;

        self.spinLock();
        defer self.spinUnlock();

        if (self.consoleActive(level)) {
            rawWrite(std.posix.STDERR_FILENO, line);
            rawWrite(std.posix.STDERR_FILENO, "\n");
        }

        if (self.fileActive(level)) {
            self.ensureFileLocked(&ts.date);
            if (!self.file_suspended) {
                self.writeLineLocked(line);
            }
        }
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: Logger -- init and deinit, no file" {
    const allocator = std.testing.allocator;
    var logger = try Logger.init(allocator, .{});
    defer logger.deinit();
}

test "zix test: Logger -- system call below min_level is silent" {
    const allocator = std.testing.allocator;
    var logger = try Logger.init(allocator, .{ .save_min_level = .ERROR });
    defer logger.deinit();
    logger.system(.DEBUG, "test", "should not panic", .{});
    logger.system(.INFO, "test", "should not panic", .{});
    logger.system(.WARN, "test", "should not panic", .{});
}

test "zix test: Logger -- access call below min_level is silent" {
    const allocator = std.testing.allocator;
    var logger = try Logger.init(allocator, .{ .save_min_level = .ERROR });
    defer logger.deinit();
    logger.access("GET", "/", 200, 0, "", "");
}

test "zix test: Logger -- status to level mapping" {
    try std.testing.expectEqual(Level.DEBUG, statusLevel(100));
    try std.testing.expectEqual(Level.INFO,  statusLevel(200));
    try std.testing.expectEqual(Level.INFO,  statusLevel(301));
    try std.testing.expectEqual(Level.WARN,  statusLevel(404));
    try std.testing.expectEqual(Level.ERROR, statusLevel(500));
}
