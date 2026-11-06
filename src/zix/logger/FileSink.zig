//! ZIX Logger FileSink
//!
//! ### file: src/zix/logger/FileSink.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The log file: day directory, append handle, rotation state, suspend, and
//! raw descriptor writes.
//!
//! ### note:
//!
//! Rotation is driven by the owning `Logger`, which also owns the file
//! `Sink`. This type owns only the descriptor and its file identity.
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
const format = @import("format.zig");
const windows_file = @import("windows_file.zig");

// --------------------------------------------------------- //
// Fields:

/// Open descriptor, or NO_FILE_FD.
fd: std.posix.fd_t = NO_FILE_FD,
/// `YYYY-MM-DD` of the open file.
current_date: [10]u8 = "0000-00-00".*,
/// Sequence counter for rotation.
file_seq: u32 = 0,
/// Lines written to the current file.
line_count: u64 = 0,
/// Set once after an unrecoverable file error.
suspended: std.atomic.Value(bool) = .init(false),
save_path: []const u8,
save_file: []const u8,
max_lines: u64,
console_fd: std.posix.fd_t,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Stack buffer for the day directory path.
const DIR_PATH_BUF_SIZE: usize = 512;

/// Stack buffer for the full log file path.
const FILE_PATH_BUF_SIZE: usize = 600;

fn openPosix(self: *Self, date: *const [10]u8) void {
    var dir_buf: [DIR_PATH_BUF_SIZE:0]u8 = undefined;
    const dir_z = std.fmt.bufPrintSentinel(
        &dir_buf,
        "{s}/{s}",
        .{ self.save_path, date },
        0,
    ) catch |err| switch (err) {
        else => {
            self.suspendFile(
                "the day directory path is longer than the logger allows",
                self.save_path,
            );

            return;
        },
    };

    const mkdir_rc = std.posix.system.mkdirat(
        @as(i32, std.posix.AT.FDCWD),
        dir_z,
        0o755,
    );
    switch (std.posix.errno(mkdir_rc)) {
        .SUCCESS, .EXIST => {},
        else => |errno| {
            self.suspendFile(@tagName(errno), dir_z);

            return;
        },
    }

    var file_buf: [FILE_PATH_BUF_SIZE]u8 = undefined;
    const file_path = std.fmt.bufPrint(
        &file_buf,
        "{s}/{s}/{s}-{d:0>6}.log",
        .{ self.save_path, date, self.save_file, self.file_seq },
    ) catch |err| switch (err) {
        else => {
            self.suspendFile(
                "the log file path is longer than the logger allows",
                self.save_path,
            );

            return;
        },
    };

    self.fd = std.posix.openat(
        @as(std.posix.fd_t, std.posix.AT.FDCWD),
        file_path,
        .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
            .CLOEXEC = true,
        },
        0o644,
    ) catch |err| switch (err) {
        else => {
            self.suspendFile(@errorName(err), file_path);

            return;
        },
    };
}

fn openWindows(self: *Self, date: *const [10]u8) void {
    var dir_buf: [DIR_PATH_BUF_SIZE]u8 = undefined;
    const dir_path = std.fmt.bufPrint(
        &dir_buf,
        "{s}/{s}",
        .{ self.save_path, date },
    ) catch |err| switch (err) {
        else => {
            self.suspendFile(
                "the day directory path is longer than the logger allows",
                self.save_path,
            );

            return;
        },
    };

    windows_file.createDir(dir_path) catch |err| switch (err) {
        else => {
            self.suspendFile(@errorName(err), dir_path);

            return;
        },
    };

    var file_buf: [FILE_PATH_BUF_SIZE]u8 = undefined;
    const file_path = std.fmt.bufPrint(
        &file_buf,
        "{s}/{s}/{s}-{d:0>6}.log",
        .{ self.save_path, date, self.save_file, self.file_seq },
    ) catch |err| switch (err) {
        else => {
            self.suspendFile(
                "the log file path is longer than the logger allows",
                self.save_path,
            );

            return;
        },
    };

    self.fd = windows_file.openAppend(file_path) catch |err| switch (err) {
        else => {
            self.suspendFile(@errorName(err), file_path);

            return;
        },
    };
}

// --------------------------------------------------------- //
// Public:

/// Sentinel for "no log file open".
pub const NO_FILE_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

/// Whether fd refers to an open log file.
pub fn hasFileFd(fd: std.posix.fd_t) bool {
    if (comptime builtin.os.tag == .windows) {
        return fd != std.os.windows.INVALID_HANDLE_VALUE;
    }

    return fd >= 0;
}

/// Stderr descriptor for console output.
pub fn stderrFd() std.posix.fd_t {
    if (comptime builtin.os.tag == .windows) {
        return std.Io.File.stderr().handle;
    }

    return std.posix.STDERR_FILENO;
}

/// Write every byte of data to fd.
///
/// Return:
/// - null when the whole slice went out
/// - the errno that stopped it otherwise
pub fn writeAll(fd: std.posix.fd_t, data: []const u8) ?std.posix.E {
    if (comptime builtin.os.tag == .windows) {
        if (fd != stderrFd()) {
            windows_file.writeAll(fd, data) catch |err| switch (err) {
                else => return .IO,
            };

            return null;
        }

        const stderr = std.debug.lockStderr(&.{});
        defer std.debug.unlockStderr();

        stderr.file_writer.interface.writeAll(data) catch |err| switch (err) {
            else => return .IO,
        };

        return null;
    }

    var remaining = data;
    while (remaining.len > 0) {
        const rc = std.posix.system.write(fd, remaining.ptr, remaining.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return .IO;

                remaining = remaining[n..];
            },
            .INTR, .AGAIN => continue,
            else => |errno| return errno,
        }
    }

    return null;
}

/// Build a file sink. No file is opened until `open`.
pub fn init(
    save_path: []const u8,
    save_file: []const u8,
    max_lines: u64,
    console_fd: std.posix.fd_t,
) Self {
    return .{
        .save_path = save_path,
        .save_file = save_file,
        .max_lines = max_lines,
        .console_fd = console_fd,
    };
}

pub fn deinit(self: *Self) void {
    self.close();
}

pub fn isSuspended(self: *const Self) bool {
    return self.suspended.load(.acquire);
}

pub fn hasFd(self: *const Self) bool {
    return hasFileFd(self.fd);
}

/// Open the file for `date` and `seq`, resetting the line count.
///
/// Note:
/// - A failure suspends the file sink and reports once. It does not return
///   an error, because the caller has no destination left to fail into.
pub fn open(self: *Self, date: *const [10]u8, seq: u32) void {
    self.current_date = date.*;
    self.file_seq = seq;
    self.line_count = 0;

    if (comptime builtin.os.tag == .windows) {
        self.openWindows(date);
        return;
    }

    self.openPosix(date);
}

pub fn close(self: *Self) void {
    if (!hasFileFd(self.fd)) return;

    if (comptime builtin.os.tag == .windows) {
        windows_file.closeFile(self.fd);
    } else {
        _ = std.posix.system.close(self.fd);
    }

    self.fd = NO_FILE_FD;
}

/// Stop writing to the file and report the cause once.
pub fn suspendFile(self: *Self, cause: []const u8, subject: []const u8) void {
    if (self.suspended.swap(true, .acq_rel)) return;

    var report_buf: [FILE_PATH_BUF_SIZE + 192]u8 = undefined;
    const line = if (subject.len > 0)
        format.formatRecord(
            &report_buf,
            "zix: logger: {s}: {s}, file logging suspended, " ++
                "console logging continues\n",
            .{ cause, subject },
        )
    else
        format.formatRecord(
            &report_buf,
            "zix: logger: {s}, file logging suspended, " ++
                "console logging continues\n",
            .{cause},
        );

    _ = writeAll(self.console_fd, line);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix logger: FileSink, open creates the day file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(
        &root_buf,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );

    var sink = Self.init(root, "log", 1_000_000, stderrFd());
    defer sink.deinit();

    const timestamp = @import("Timestamp.zig").now();
    sink.open(&timestamp.date, 0);

    try std.testing.expect(sink.hasFd());
    try std.testing.expect(!sink.isSuspended());

    sink.close();
    try std.testing.expect(!sink.hasFd());
}

test "zix logger: FileSink, writeAll appends bytes to the open file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(
        &root_buf,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );

    var sink = Self.init(root, "log", 1_000_000, stderrFd());
    defer sink.deinit();

    const timestamp = @import("Timestamp.zig").now();
    sink.open(&timestamp.date, 0);
    try std.testing.expectEqual(@as(?std.posix.E, null), writeAll(sink.fd, "hello\n"));
    sink.close();

    var day = try tmp.dir.openDir(std.testing.io, &sink.current_date, .{});
    defer day.close(std.testing.io);

    const content = try day.readFileAlloc(
        std.testing.io,
        "log-000000.log",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(content);

    try std.testing.expectEqualStrings("hello\n", content);
}

test "zix logger: FileSink, a bad save_path suspends and reports once" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var capture = try tmp.dir.createFile(
        std.testing.io,
        "console-capture.log",
        .{},
    );
    defer capture.close(std.testing.io);

    var root_buf: [96]u8 = undefined;
    const root = try std.fmt.bufPrint(
        &root_buf,
        ".zig-cache/tmp/{s}/absent",
        .{tmp.sub_path},
    );

    var sink = Self.init(root, "log", 1_000_000, capture.handle);
    defer sink.deinit();

    const timestamp = @import("Timestamp.zig").now();
    sink.open(&timestamp.date, 0);
    try std.testing.expect(sink.isSuspended());
    try std.testing.expect(!sink.hasFd());

    sink.open(&timestamp.date, 0);
    try std.testing.expect(sink.isSuspended());

    const content = try tmp.dir.readFileAlloc(
        std.testing.io,
        "console-capture.log",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.startsWith(u8, content, "zix: logger: "));
    try std.testing.expect(std.mem.endsWith(u8, content, "console logging continues\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "\n"));
}

