//! ZIX Logger
//!
//! ### file: src/zix/logger/Logger.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Structured, thread-safe event logger with buffered console and file output.
//!
//! ### note:
//!
//! Producers format a record and copy it into a double buffer. A background
//! flush thread owns every write syscall. `ERROR` records drain synchronously,
//! and `flush`/`deinit` are the two explicit durability boundaries.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const builtin = @import("builtin");
const Sink = @import("Sink.zig");
const Flusher = @import("Flusher.zig");
const FileSink = @import("FileSink.zig");
const Timestamp = @import("Timestamp.zig");
const format = @import("format.zig");

// --------------------------------------------------------- //
// Fields:

config: Config,
allocator: std.mem.Allocator,
/// Serializes buffer handoff and counters. Kept on its own cache line.
locked: std.atomic.Value(bool) align(64) = .init(false),
console_fd: std.posix.fd_t,
/// Bits of levels that reach the console.
console_mask: u8 = 0,
/// Bits of levels that reach the file.
file_mask: u8 = 0,
/// Whether a file destination was configured.
file_enabled: bool = false,
file: FileSink,
file_sink: Sink = .{},
console_sink: Sink = .{},
flusher: Flusher = .{},
/// Set when the flush thread could not spawn, so drains run inline.
flusher_unavailable: bool = false,

const Self = @This();

// --------------------------------------------------------- //
// Private:

const SinkKind = enum { CONSOLE, FILE };

/// Maximum sequence number in one day.
const MAX_FILE_SEQ: u32 = 999_999;

/// Spin passes before a waiting producer yields the CPU.
const WAIT_SPINS: usize = 64;

fn spinLock(self: *Self) void {
    while (self.locked.cmpxchgWeak(
        false,
        true,
        .acquire,
        .monotonic,
    ) != null) {
        std.atomic.spinLoopHint();
    }
}

fn spinUnlock(self: *Self) void {
    self.locked.store(false, .release);
}

fn ensureFlusherLocked(self: *Self) void {
    if (self.flusher.running() or self.flusher_unavailable) return;
    if (!self.console_sink.enabled() and !self.file_sink.enabled()) return;

    self.flusher.start(self, pumpTrampoline) catch |err| switch (err) {
        error.ZixLogger_Flusher_SpawnFailed => {
            self.flusher_unavailable = true;
        },
    };
}

fn pumpTrampoline(context: *anyopaque, urgent_only: bool) bool {
    const self: *Self = @ptrCast(@alignCast(context));

    return self.pump(urgent_only);
}

fn pump(self: *Self, urgent_only: bool) bool {
    self.spinLock();
    defer self.spinUnlock();

    const console_moved = self.pumpSinkLocked(
        &self.console_sink,
        .CONSOLE,
        urgent_only,
    );
    const file_moved = self.pumpSinkLocked(
        &self.file_sink,
        .FILE,
        urgent_only,
    );

    return console_moved or file_moved;
}

fn pumpSinkLocked(
    self: *Self,
    sink: *Sink,
    kind: SinkKind,
    urgent_only: bool,
) bool {
    if (!sink.enabled() or sink.isIdle()) return false;

    if (urgent_only and sink.pending == 0 and
        sink.fill * 2 < sink.capacity()) return false;

    if (sink.pending == 0) sink.swap();

    const bytes = sink.pendingBytes();
    const fd = self.fdFor(kind);

    self.spinUnlock();
    const failure = writeOut(kind, fd, bytes);
    self.spinLock();

    sink.pending = 0;
    sink.writes += 1;

    if (failure) |cause| {
        if (kind == .FILE) self.file.suspendFile(cause, self.config.save_path);
    }

    return true;
}

fn drainLocked(self: *Self) void {
    self.drainSinkLocked(&self.console_sink, .CONSOLE);
    self.drainSinkLocked(&self.file_sink, .FILE);
}

fn drainSinkLocked(self: *Self, sink: *Sink, kind: SinkKind) void {
    if (!sink.enabled()) return;

    self.waitPendingClearLocked(sink, kind);

    if (sink.fill == 0) return;

    sink.swap();
    self.writePendingLocked(sink, kind);
}

fn writePendingLocked(self: *Self, sink: *Sink, kind: SinkKind) void {
    const failure = writeOut(kind, self.fdFor(kind), sink.pendingBytes());

    sink.pending = 0;
    sink.writes += 1;

    if (failure) |cause| {
        if (kind == .FILE) self.file.suspendFile(cause, self.config.save_path);
    }
}

fn waitPendingClearLocked(self: *Self, sink: *Sink, kind: SinkKind) void {
    var spins: usize = 0;

    while (sink.pending != 0) {
        if (!self.flusher.running()) {
            self.writePendingLocked(sink, kind);

            return;
        }

        self.spinUnlock();
        if (spins < WAIT_SPINS) {
            std.atomic.spinLoopHint();
            spins += 1;
        } else {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        self.spinLock();
    }
}

fn appendLocked(self: *Self, sink: *Sink, kind: SinkKind, line: []const u8) void {
    if (!sink.enabled() or !sink.couldEverFit(line)) return;

    while (!sink.tryAppend(line)) {
        if (sink.pending != 0) {
            sink.stalls += 1;
            self.waitPendingClearLocked(sink, kind);
        }

        sink.swap();
    }
}

fn ensureFileLocked(self: *Self, date: *const [10]u8) void {
    if (self.file.isSuspended()) return;

    if (!self.file.hasFd()) {
        self.file.open(date, 0);

        return;
    }

    if (!std.mem.eql(u8, &self.file.current_date, date)) {
        self.drainSinkLocked(&self.file_sink, .FILE);
        self.file.close();
        self.file.open(date, 0);

        return;
    }

    if (self.file.line_count < self.config.max_lines) return;

    self.drainSinkLocked(&self.file_sink, .FILE);
    self.file.close();

    if (self.file.file_seq >= MAX_FILE_SEQ) {
        self.file.suspendFile(
            "the day's file sequence is exhausted at 999999",
            self.config.save_path,
        );

        return;
    }

    self.file.open(date, self.file.file_seq + 1);
}

fn emit(self: *Self, level: Level, date: *const [10]u8, line: []const u8) void {
    self.spinLock();
    defer self.spinUnlock();

    self.ensureFlusherLocked();

    const bit = @as(u8, 1) << @as(u3, @intCast(@backingInt(level)));

    if ((self.console_mask & bit) != 0) {
        self.appendLocked(&self.console_sink, .CONSOLE, line);
    }

    if (self.file_enabled and !self.file.isSuspended() and
        (self.file_mask & bit) != 0)
    {
        self.ensureFileLocked(date);
        if (!self.file.isSuspended()) {
            self.appendLocked(&self.file_sink, .FILE, line);
            self.file.line_count += 1;
        }
    }

    if (level == .ERROR) self.drainLocked();
}

fn consoleActive(self: *const Self, level: Level) bool {
    const bit = @as(u8, 1) << @as(u3, @intCast(@backingInt(level)));

    return (self.console_mask & bit) != 0;
}

fn fileActive(self: *const Self, level: Level) bool {
    if (!self.file_enabled or self.file.isSuspended()) return false;

    const bit = @as(u8, 1) << @as(u3, @intCast(@backingInt(level)));

    return (self.file_mask & bit) != 0;
}

fn fdFor(self: *const Self, kind: SinkKind) std.posix.fd_t {
    return switch (kind) {
        .CONSOLE => self.console_fd,
        .FILE => self.file.fd,
    };
}

fn levelMask(min_level: Level) u8 {
    const shift: u3 = @intCast(@backingInt(min_level));

    return @as(u8, 0xF) & (@as(u8, 0xF) << shift);
}

fn consoleMask(config: Config) u8 {
    return switch (config.console) {
        .OFF => 0,
        .DEBUG_ONLY => if (builtin.mode == .debug)
            levelMask(config.console_min_level)
        else
            0,
        .ALWAYS => levelMask(config.console_min_level),
    };
}

fn writeOut(kind: SinkKind, fd: std.posix.fd_t, bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0) return null;

    if (kind == .CONSOLE) {
        _ = FileSink.writeAll(fd, bytes);

        return null;
    }

    if (!FileSink.hasFileFd(fd)) return null;

    if (FileSink.writeAll(fd, bytes)) |errno| return @tagName(errno);

    return null;
}

// --------------------------------------------------------- //
// Public:

/// ZIX Logger error
pub const Error = error{
    ZixLogger_Logger_OutOfMemory,
};

pub const Level = format.Level;

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
    /// Console descriptor. null means stderr.
    console_fd: ?std.posix.fd_t = null,
    /// Root directory for log files. Must already exist.
    save_path: []const u8 = "",
    /// Base name for log files.
    save_file: []const u8 = "log",
    /// Minimum level for file output.
    save_min_level: Level = .INFO,
    /// Lines per file before rotating.
    max_lines: u64 = 1_000_000,
    /// Bytes per write buffer, raised to fit one whole record.
    write_buf_size: usize = 64 * 1024,
};

/// Build a logger and open its day file immediately.
///
/// Return:
/// - Logger
/// - Error.ZixLogger_Logger_OutOfMemory when a buffer cannot be allocated
pub fn init(allocator: std.mem.Allocator, config: Config) Error!Self {
    const console_fd = config.console_fd orelse FileSink.stderrFd();
    var self = Self{
        .config = config,
        .allocator = allocator,
        .console_fd = console_fd,
        .console_mask = consoleMask(config),
        .file_mask = levelMask(config.save_min_level),
        .file_enabled = config.save_path.len > 0,
        .file = FileSink.init(
            config.save_path,
            config.save_file,
            config.max_lines,
            console_fd,
        ),
    };

    const each = @max(config.write_buf_size, format.LINE_BUF_SIZE + 1);

    if (self.console_mask != 0) {
        self.console_sink.alloc(allocator, each) catch |err| switch (err) {
            error.ZixLogger_Sink_OutOfMemory => return Error.ZixLogger_Logger_OutOfMemory,
        };
        errdefer self.console_sink.free(allocator);
    }

    if (self.file_enabled) {
        self.file_sink.alloc(allocator, each) catch |err| switch (err) {
            error.ZixLogger_Sink_OutOfMemory => return Error.ZixLogger_Logger_OutOfMemory,
        };
        errdefer self.file_sink.free(allocator);

        const timestamp = Timestamp.now();
        self.file.open(&timestamp.date, 0);
    }

    return self;
}

pub fn deinit(self: *Self) void {
    self.flusher.stop();

    self.spinLock();
    defer self.spinUnlock();

    self.drainLocked();
    self.file.close();

    self.file_sink.free(self.allocator);
    self.console_sink.free(self.allocator);
}

/// Write out everything logged so far before returning.
pub fn flush(self: *Self) void {
    self.spinLock();
    defer self.spinUnlock();

    self.drainLocked();
}

/// How many times a producer waited because both buffers were busy.
pub fn stallCount(self: *Self) u64 {
    self.spinLock();
    defer self.spinUnlock();

    return self.file_sink.stalls + self.console_sink.stalls;
}

/// Records buffered for the file, and batches written out for it.
pub fn fileBatchCounts(self: *Self) struct { lines: u64, writes: u64 } {
    self.spinLock();
    defer self.spinUnlock();

    return .{
        .lines = self.file_sink.lines,
        .writes = self.file_sink.writes,
    };
}

/// Whether a record at this level would reach any destination.
pub fn enabled(self: *const Self, level: Level) bool {
    return self.consoleActive(level) or self.fileActive(level);
}

/// Log an HTTP access entry.
pub fn access(
    self: *Self,
    component: []const u8,
    method: []const u8,
    path: []const u8,
    status: u16,
    bytes: usize,
    client_ip: []const u8,
    ua: []const u8,
    origin: []const u8,
) void {
    const level = format.statusLevel(status);
    if (!self.enabled(level)) return;

    const timestamp = Timestamp.now();
    const client_ip_out = if (client_ip.len > 0) client_ip else "-";
    const ua_out = if (ua.len > 0) ua else "-";
    const origin_out = if (origin.len > 0) origin else "-";

    var line_buf: [format.LINE_BUF_SIZE]u8 = undefined;
    const line = format.formatRecord(
        &line_buf,
        "{s} {s} {s}  [{s}:access] {s} {s} {d} {d} " ++
            "\"{s}\" \"{s}\" \"{s}\"",
        .{
            &timestamp.date,
            &timestamp.time,
            format.levelLabel(level),
            component,
            method,
            path,
            status,
            bytes,
            client_ip_out,
            ua_out,
            origin_out,
        },
    );

    self.emit(level, &timestamp.date, line);
}

/// Log a TCP connection lifecycle event.
pub fn conn(
    self: *Self,
    peer: []const u8,
    dur_ms: u64,
    err: ?[]const u8,
) void {
    const level: Level = if (err == null) .INFO else .WARN;
    if (!self.enabled(level)) return;

    const timestamp = Timestamp.now();
    const err_out = err orelse "-";

    var line_buf: [format.LINE_BUF_SIZE]u8 = undefined;
    const line = format.formatRecord(
        &line_buf,
        "{s} {s} {s}  [tcp:conn] {s} dur={d}ms {s}",
        .{
            &timestamp.date,
            &timestamp.time,
            format.levelLabel(level),
            peer,
            dur_ms,
            err_out,
        },
    );

    self.emit(level, &timestamp.date, line);
}

/// Log a UDP datagram event.
pub fn packet(
    self: *Self,
    dir: Dir,
    peer: []const u8,
    size: usize,
    err: ?[]const u8,
) void {
    const level: Level = if (err == null) .INFO else .WARN;
    if (!self.enabled(level)) return;

    const timestamp = Timestamp.now();
    const dir_out: []const u8 = if (dir == .RECV) "recv" else "send";
    const err_out = err orelse "-";

    var line_buf: [format.LINE_BUF_SIZE]u8 = undefined;
    const line = format.formatRecord(
        &line_buf,
        "{s} {s} {s}  [udp:pkt] {s} {s} size={d} {s}",
        .{
            &timestamp.date,
            &timestamp.time,
            format.levelLabel(level),
            dir_out,
            peer,
            size,
            err_out,
        },
    );

    self.emit(level, &timestamp.date, line);
}

/// Log a UDS frame event.
pub fn frame(
    self: *Self,
    dir: Dir,
    sock_path: []const u8,
    size: usize,
    err: ?[]const u8,
) void {
    const level: Level = if (err == null) .INFO else .WARN;
    if (!self.enabled(level)) return;

    const timestamp = Timestamp.now();
    const dir_out: []const u8 = if (dir == .RECV) "recv" else "send";
    const err_out = err orelse "-";

    var line_buf: [format.LINE_BUF_SIZE]u8 = undefined;
    const line = format.formatRecord(
        &line_buf,
        "{s} {s} {s}  [uds:frame] {s} {s} size={d} {s}",
        .{
            &timestamp.date,
            &timestamp.time,
            format.levelLabel(level),
            dir_out,
            sock_path,
            size,
            err_out,
        },
    );

    self.emit(level, &timestamp.date, line);
}

/// Log a FIX session message event.
pub fn session(
    self: *Self,
    msg_type: []const u8,
    sender: []const u8,
    target: []const u8,
    seq: u64,
    state: []const u8,
) void {
    const level: Level = .INFO;
    if (!self.enabled(level)) return;

    const timestamp = Timestamp.now();

    var line_buf: [format.LINE_BUF_SIZE]u8 = undefined;
    const line = format.formatRecord(
        &line_buf,
        "{s} {s} {s}  [fix:sess] 35={s} sender={s} target={s} seq={d} {s}",
        .{
            &timestamp.date,
            &timestamp.time,
            format.levelLabel(level),
            msg_type,
            sender,
            target,
            seq,
            state,
        },
    );

    self.emit(level, &timestamp.date, line);
}

/// Log a gRPC RPC event.
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
    if (!self.enabled(level)) return;

    const timestamp = Timestamp.now();

    var line_buf: [format.LINE_BUF_SIZE]u8 = undefined;
    const line = format.formatRecord(
        &line_buf,
        "{s} {s} {s}  [grpc:rpc] {s} {s} status={d} recv={d} " ++
            "sent={d} dur={d}ms",
        .{
            &timestamp.date,
            &timestamp.time,
            format.levelLabel(level),
            peer,
            path,
            grpc_status,
            recv_bytes,
            sent_bytes,
            dur_ms,
        },
    );

    self.emit(level, &timestamp.date, line);
}

/// Log a system event.
pub fn system(
    self: *Self,
    level: Level,
    component: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (!self.enabled(level)) return;

    const timestamp = Timestamp.now();

    var line_buf: [format.LINE_BUF_SIZE]u8 = undefined;
    const line = format.formatSystem(
        &line_buf,
        &timestamp,
        level,
        component,
        fmt,
        args,
    );

    self.emit(level, &timestamp.date, line);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Racer = struct {
    logger: *Self,
    id: usize,

    fn run(self: Racer) void {
        for (0..100) |seq| {
            self.logger.system(
                .INFO,
                "race",
                "thread={d} seq={d}",
                .{ self.id, seq },
            );
        }
    }
};

fn rootPath(buf: []u8, sub_path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{sub_path});
}

fn readDayFile(root: std.Io.Dir, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var days = root.iterate();

    while (try days.next(std.testing.io)) |entry| {
        if (entry.kind != .directory) continue;

        var day = try root.openDir(std.testing.io, entry.name, .{});
        defer day.close(std.testing.io);

        return day.readFileAlloc(
            std.testing.io,
            name,
            allocator,
            .limited(8 * 1024 * 1024),
        ) catch continue;
    }

    return error.ZixNoLogFile;
}

test "zix logger: Logger, config applies defaults" {
    const config = Config{};

    try std.testing.expectEqual(ConsoleMode.OFF, config.console);
    try std.testing.expectEqual(Level.INFO, config.console_min_level);
    try std.testing.expectEqual(@as(?std.posix.fd_t, null), config.console_fd);
    try std.testing.expectEqualStrings("", config.save_path);
    try std.testing.expectEqualStrings("log", config.save_file);
    try std.testing.expectEqual(Level.INFO, config.save_min_level);
    try std.testing.expectEqual(@as(u64, 1_000_000), config.max_lines);
    try std.testing.expectEqual(@as(usize, 64 * 1024), config.write_buf_size);
}

test "zix logger: Logger, no destination writes nothing" {
    var logger = try Self.init(std.testing.allocator, .{});
    defer logger.deinit();

    logger.system(.ERROR, "test", "nowhere to go", .{});
    logger.access("http1", "GET", "/", 200, 0, "", "", "");

    try std.testing.expect(!logger.flusher.running());
    try std.testing.expectEqual(@as(u64, 0), logger.console_sink.lines);
    try std.testing.expectEqual(@as(u64, 0), logger.file_sink.lines);
}

test "zix logger: Logger, init creates the day file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = try rootPath(&root_buf, &tmp.sub_path);

    var logger = try Self.init(std.testing.allocator, .{
        .console = .OFF,
        .save_path = root,
        .save_min_level = .DEBUG,
    });
    defer logger.deinit();

    const content = try readDayFile(
        tmp.dir,
        std.testing.allocator,
        "log-000000.log",
    );
    defer std.testing.allocator.free(content);

    try std.testing.expectEqual(@as(usize, 0), content.len);
    try std.testing.expect(!logger.file.isSuspended());
}

test "zix logger: Logger, system writes the expected line" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = try rootPath(&root_buf, &tmp.sub_path);

    var logger = try Self.init(std.testing.allocator, .{
        .console = .OFF,
        .save_path = root,
        .save_min_level = .DEBUG,
    });
    defer logger.deinit();

    logger.system(.INFO, "test", "hello {s}", .{"world"});
    logger.flush();

    const content = try readDayFile(
        tmp.dir,
        std.testing.allocator,
        "log-000000.log",
    );
    defer std.testing.allocator.free(content);

    try std.testing.expect(
        std.mem.indexOf(u8, content, " INFO   [test] hello world\n") != null,
    );
}

test "zix logger: Logger, access renders the exact fields" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = try rootPath(&root_buf, &tmp.sub_path);

    var logger = try Self.init(std.testing.allocator, .{
        .console = .OFF,
        .save_path = root,
        .save_min_level = .DEBUG,
    });
    defer logger.deinit();

    logger.access(
        "http1",
        "GET",
        "/api/v1/items?page=2",
        200,
        4096,
        "203.0.113.7",
        "curl/8.5.0",
        "https://example.com",
    );
    logger.flush();

    const content = try readDayFile(
        tmp.dir,
        std.testing.allocator,
        "log-000000.log",
    );
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(
        u8,
        content,
        "[http1:access] GET /api/v1/items?page=2 200 4096 " ++
            "\"203.0.113.7\" \"curl/8.5.0\" \"https://example.com\"",
    ) != null);
}

test "zix logger: Logger, access renders absent fields as a dash" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = try rootPath(&root_buf, &tmp.sub_path);

    var logger = try Self.init(std.testing.allocator, .{
        .console = .OFF,
        .save_path = root,
        .save_min_level = .DEBUG,
    });
    defer logger.deinit();

    logger.access("http1", "HEAD", "/", 204, 0, "", "", "");
    logger.flush();

    const content = try readDayFile(
        tmp.dir,
        std.testing.allocator,
        "log-000000.log",
    );
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(
        u8,
        content,
        "[http1:access] HEAD / 204 0 \"-\" \"-\" \"-\"",
    ) != null);
}

test "zix logger: Logger, rotation splits files at max_lines" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = try rootPath(&root_buf, &tmp.sub_path);

    var logger = try Self.init(std.testing.allocator, .{
        .console = .OFF,
        .save_path = root,
        .save_min_level = .DEBUG,
        .max_lines = 10,
    });
    defer logger.deinit();

    for (0..25) |seq| {
        logger.system(.INFO, "rotate", "record {d}", .{seq});
    }
    logger.flush();

    var total: usize = 0;
    for (0..3) |seq| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(
            &name_buf,
            "log-{d:0>6}.log",
            .{seq},
        );

        const content = try readDayFile(tmp.dir, std.testing.allocator, name);
        defer std.testing.allocator.free(content);

        total += std.mem.count(u8, content, "\n");
    }

    try std.testing.expectEqual(@as(usize, 25), total);
}

test "zix logger: Logger, ERROR drains without an explicit flush" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = try rootPath(&root_buf, &tmp.sub_path);

    var logger = try Self.init(std.testing.allocator, .{
        .console = .OFF,
        .save_path = root,
        .save_min_level = .DEBUG,
    });
    defer logger.deinit();

    logger.system(.INFO, "quiet", "buffered first", .{});
    logger.system(.ERROR, "loud", "must not wait", .{});

    const content = try readDayFile(
        tmp.dir,
        std.testing.allocator,
        "log-000000.log",
    );
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "buffered first") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "must not wait") != null);
}

test "zix logger: Logger, deinit drains what was buffered" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = try rootPath(&root_buf, &tmp.sub_path);

    {
        var logger = try Self.init(std.testing.allocator, .{
            .console = .OFF,
            .save_path = root,
            .save_min_level = .DEBUG,
        });
        defer logger.deinit();

        for (0..20) |seq| {
            logger.system(.INFO, "closing", "record {d}", .{seq});
        }
    }

    const content = try readDayFile(
        tmp.dir,
        std.testing.allocator,
        "log-000000.log",
    );
    defer std.testing.allocator.free(content);

    try std.testing.expectEqual(@as(usize, 20), std.mem.count(u8, content, "\n"));
}

test "zix logger: Logger, console capture receives a record" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var capture = try tmp.dir.createFile(
        std.testing.io,
        "console-capture.log",
        .{},
    );
    defer capture.close(std.testing.io);

    var logger = try Self.init(std.testing.allocator, .{
        .console = .ALWAYS,
        .console_min_level = .DEBUG,
        .console_fd = capture.handle,
    });
    defer logger.deinit();

    logger.access("http1", "GET", "/", 200, 0, "", "", "");
    logger.flush();

    const content = try tmp.dir.readFileAlloc(
        std.testing.io,
        "console-capture.log",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(
        u8,
        content,
        "[http1:access] GET / 200 0",
    ) != null);
}

test "zix logger: Logger, an oversize message keeps a marked line" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = try rootPath(&root_buf, &tmp.sub_path);

    var logger = try Self.init(std.testing.allocator, .{
        .console = .OFF,
        .save_path = root,
        .save_min_level = .DEBUG,
    });
    defer logger.deinit();

    var long_buf: [format.LINE_BUF_SIZE * 2]u8 = undefined;
    @memset(&long_buf, 'x');

    logger.system(.ERROR, "test", "{s}", .{&long_buf});

    const content = try readDayFile(
        tmp.dir,
        std.testing.allocator,
        "log-000000.log",
    );
    defer std.testing.allocator.free(content);

    try std.testing.expect(
        std.mem.indexOf(u8, content, format.TRUNCATION_MARK) != null,
    );
}

test "zix logger: Logger, records reach the file in order" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = try rootPath(&root_buf, &tmp.sub_path);

    var logger = try Self.init(std.testing.allocator, .{
        .console = .OFF,
        .save_path = root,
        .save_min_level = .DEBUG,
    });
    defer logger.deinit();

    for (0..200) |seq| {
        logger.system(.INFO, "order", "seq={d}", .{seq});
    }
    logger.flush();

    const content = try readDayFile(
        tmp.dir,
        std.testing.allocator,
        "log-000000.log",
    );
    defer std.testing.allocator.free(content);

    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    var expected: usize = 0;
    while (lines.next()) |line| : (expected += 1) {
        var wanted_buf: [32]u8 = undefined;
        const wanted = try std.fmt.bufPrint(&wanted_buf, "seq={d}", .{expected});

        try std.testing.expect(std.mem.endsWith(u8, line, wanted));
    }

    try std.testing.expectEqual(@as(usize, 200), expected);
}

test "zix logger: Logger, four threads lose no record" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = try rootPath(&root_buf, &tmp.sub_path);

    var logger = try Self.init(std.testing.allocator, .{
        .console = .OFF,
        .save_path = root,
        .save_min_level = .DEBUG,
    });
    defer logger.deinit();

    const THREADS = 4;
    var threads: [THREADS]std.Thread = undefined;
    for (&threads, 0..) |*thread, id| {
        thread.* = try std.Thread.spawn(
            .{},
            Racer.run,
            .{Racer{
                .logger = &logger,
                .id = id,
            }},
        );
    }
    for (&threads) |*thread| thread.join();

    logger.flush();

    const content = try readDayFile(
        tmp.dir,
        std.testing.allocator,
        "log-000000.log",
    );
    defer std.testing.allocator.free(content);

    try std.testing.expectEqual(
        @as(usize, THREADS * 100),
        std.mem.count(u8, content, "\n"),
    );
}

test "zix logger: Logger, the write buffer batches records" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = try rootPath(&root_buf, &tmp.sub_path);

    var logger = try Self.init(std.testing.allocator, .{
        .console = .OFF,
        .save_path = root,
        .save_min_level = .DEBUG,
    });
    defer logger.deinit();

    const records = 2_000;
    for (0..records) |seq| {
        logger.system(.INFO, "batch", "record {d} of the run", .{seq});
    }
    logger.flush();

    const counts = logger.fileBatchCounts();
    try std.testing.expectEqual(@as(u64, records), counts.lines);
    try std.testing.expect(counts.writes * 10 < counts.lines);
}

test "zix logger: Logger, a narrow write buffer is widened" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = try rootPath(&root_buf, &tmp.sub_path);

    var logger = try Self.init(std.testing.allocator, .{
        .console = .OFF,
        .save_path = root,
        .save_min_level = .DEBUG,
        .write_buf_size = 64,
    });
    defer logger.deinit();

    try std.testing.expect(
        logger.file_sink.capacity() >= format.LINE_BUF_SIZE + 1,
    );

    logger.system(.INFO, "narrow", "record {d}", .{1});
    logger.flush();

    const content = try readDayFile(
        tmp.dir,
        std.testing.allocator,
        "log-000000.log",
    );
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "record 1") != null);
}

