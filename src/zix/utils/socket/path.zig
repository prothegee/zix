//! ZIX utils socket path
//!
//! ### file: src/zix/utils/socket/path.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Builds the absolute path of a local (unix-domain) socket, so a server and its client
//! derive the same path on every supported platform.
//!
//! ### note:
//!
//! The path is always absolute: Windows AF_UNIX bind rejects a relative path.
//! It is the working directory plus the caller's directory, so both ends must run from
//! the same working directory.
//! The working directory comes from `std.process.currentPath`, not
//! `std.Io.Dir.realPath`, because realPath is not implemented on NetBSD and OpenBSD.
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

// --------------------------------------------------------- //
// Private:

/// Path separator of the target platform.
const SEPARATOR: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";

/// Longest working directory path resolve handles. A unix socket path is capped near
/// 108 bytes on POSIX, so a longer directory could not host a socket anyway.
const CWD_PATH_MAX: usize = 512;

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_SocketPath_DirectoryUnavailable,
    ZixUtils_SocketPath_PathTooLong,
};

/// Build the absolute path for a socket inside `dir_name`, and create that directory
/// when it does not exist yet.
///
/// Note:
/// - The returned slice points into buf.
///
/// Param:
/// io - std.Io (the io of the calling thread)
/// dir_name - []const u8 (directory relative to the working directory, e.g. "tmp")
/// file_name - []const u8 (socket file name, e.g. "zix.sock")
/// buf - []u8 (receives the joined path, 600 bytes covers any usable location)
///
/// Return:
/// - []const u8 (the absolute path, a slice of buf)
/// - Error.ZixUtils_SocketPath_DirectoryUnavailable when the directory cannot be created
///   or the working directory cannot be read
/// - Error.ZixUtils_SocketPath_PathTooLong when the path does not fit in buf
pub fn resolve(
    io: std.Io,
    dir_name: []const u8,
    file_name: []const u8,
    buf: []u8,
) Error![]const u8 {
    std.Io.Dir.cwd().createDirPath(io, dir_name) catch |err| switch (err) {
        else => return Error.ZixUtils_SocketPath_DirectoryUnavailable,
    };

    var cwd_path: [CWD_PATH_MAX]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_path) catch |err| switch (err) {
        else => return Error.ZixUtils_SocketPath_DirectoryUnavailable,
    };

    return std.fmt.bufPrint(buf, "{s}{s}{s}{s}{s}", .{
        cwd_path[0..cwd_len],
        SEPARATOR,
        dir_name,
        SEPARATOR,
        file_name,
    }) catch |err| switch (err) {
        error.NoSpaceLeft => Error.ZixUtils_SocketPath_PathTooLong,
    };
}

/// Remove a socket file left by an earlier run, so the next bind is not refused.
///
/// Note:
/// - Best effort: a missing file is the goal, and any other failure shows up at bind.
///
/// Param:
/// io - std.Io (the io of the calling thread)
/// path - []const u8 (an absolute path, as returned by resolve)
pub fn clear(io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
        // Best effort, see Note above.
        else => {},
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const TEST_DIR: []const u8 = "tmp";

test "zix utils: socket path, separator matches the target platform" {
    const expected = if (comptime builtin.os.tag == .windows) "\\" else "/";

    try std.testing.expectEqualStrings(expected, SEPARATOR);
}

test "zix utils: socket path, resolve is absolute" {
    var buf: [600]u8 = undefined;
    const path = try resolve(std.testing.io, TEST_DIR, "socket_path_abs.sock", &buf);

    if (comptime builtin.os.tag == .windows) {
        try std.testing.expect(path.len > 2 and path[1] == ':');
    } else {
        try std.testing.expect(path[0] == '/');
    }
}

test "zix utils: socket path, resolve gives the same path for the same input" {
    var first_buf: [600]u8 = undefined;
    var second_buf: [600]u8 = undefined;

    const first = try resolve(std.testing.io, TEST_DIR, "socket_path_same.sock", &first_buf);
    const second = try resolve(std.testing.io, TEST_DIR, "socket_path_same.sock", &second_buf);

    try std.testing.expectEqualStrings(first, second);
}

test "zix utils: socket path, resolve keeps the directory before the file name" {
    var buf: [600]u8 = undefined;
    var tail_buf: [64]u8 = undefined;

    const path = try resolve(std.testing.io, TEST_DIR, "socket_path_dir.sock", &buf);
    const tail = try std.fmt.bufPrint(&tail_buf, "{s}{s}{s}socket_path_dir.sock", .{
        SEPARATOR,
        TEST_DIR,
        SEPARATOR,
    });

    try std.testing.expect(std.mem.endsWith(u8, path, tail));
}

test "zix utils: socket path, resolve with a too small buffer returns PathTooLong" {
    var tiny: [4]u8 = undefined;

    try std.testing.expectError(
        Error.ZixUtils_SocketPath_PathTooLong,
        resolve(std.testing.io, TEST_DIR, "socket_path_tiny.sock", &tiny),
    );
}

test "zix utils: socket path, clear on a missing file does nothing" {
    const io = std.testing.io;

    var buf: [600]u8 = undefined;
    const path = try resolve(io, TEST_DIR, "socket_path_missing.sock", &buf);

    clear(io, path);

    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(io, TEST_DIR ++ "/socket_path_missing.sock", .{}),
    );
}

test "zix utils: socket path, clear removes a stale file" {
    const io = std.testing.io;

    var buf: [600]u8 = undefined;
    const path = try resolve(io, TEST_DIR, "socket_path_stale.sock", &buf);
    var file = try std.Io.Dir.cwd().createFile(io, TEST_DIR ++ "/socket_path_stale.sock", .{});
    file.close(io);

    clear(io, path);

    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(io, TEST_DIR ++ "/socket_path_stale.sock", .{}),
    );
}

