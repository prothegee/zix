//! Where a local (unix-domain) socket lives, on every supported platform.
//!
//! What:
//!   A server and the client that talks to it must derive the exact same path, and that path
//!   must be one the platform will accept. POSIX takes a relative path happily. Windows does
//!   not: its AF_UNIX bind rejects a relative path outright, so the same relative string that
//!   works on Linux fails there.
//!
//! Note:
//! - Resolve the directory once, then build an absolute path from it. Both ends of a pair run
//!   from the same working directory, so both derive the same string with no shared state.
//! - Windows has supported AF_UNIX since build 17063. On an older build std reports
//!   error.AddressFamilyUnsupported at bind time, which is the honest answer rather than a
//!   silent downgrade.

const std = @import("std");
const builtin = @import("builtin");

/// Path separator for the target, so the joined path is one the platform's own APIs accept.
const separator: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";

/// Longest absolute directory path resolve() will handle. POSIX caps a unix socket path at 108
/// bytes anyway, so a directory beyond this could not host one.
const DIR_PATH_MAX: usize = 512;

pub const Error = error{ PathTooLong, DirectoryUnavailable };

// --------------------------------------------------------- //

/// Absolute path for a local socket inside dir_name, creating that directory if needed.
///
/// Note:
/// - The directory is created on first call, so a caller does not have to make it separately.
/// - The returned slice points into buf.
///
/// Param:
/// io - std.Io
/// dir_name - []const u8 (directory relative to the working directory, i.e. "tmp")
/// file_name - []const u8 (socket file name, i.e. "zix.sock")
/// buf - []u8 (receives the joined path, 600 bytes covers any usable location)
///
/// Return:
/// - the absolute path, a slice of buf
/// - error.DirectoryUnavailable when the directory could not be created or opened
/// - error.PathTooLong when the result does not fit in buf
pub fn resolve(io: std.Io, dir_name: []const u8, file_name: []const u8, buf: []u8) Error![]const u8 {
    std.Io.Dir.cwd().createDirPath(io, dir_name) catch return error.DirectoryUnavailable;

    var dir = std.Io.Dir.cwd().openDir(io, dir_name, .{}) catch return error.DirectoryUnavailable;
    defer dir.close(io);

    var dir_path: [DIR_PATH_MAX]u8 = undefined;
    const dir_len = dir.realPath(io, &dir_path) catch return error.DirectoryUnavailable;

    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ dir_path[0..dir_len], separator, file_name }) catch return error.PathTooLong;
}

/// Remove a socket file left behind by an earlier run, so a rebind is not refused.
///
/// Note:
/// - A missing file is not an error: this is called before binding, when absence is the goal.
///
/// Param:
/// io - std.Io
/// path - []const u8 (as returned by resolve)
///
/// Return:
/// - void
pub fn clear(io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix utils: socket_path separator matches the target platform" {
    if (comptime builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("\\", separator);
    } else {
        try std.testing.expectEqualStrings("/", separator);
    }
}

test "zix utils: socket_path resolve is absolute, ends with the file name, and is deterministic" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [600]u8 = undefined;
    const path = try resolve(io, "tmp", "socket_path_test.sock", &buf);

    try std.testing.expect(std.mem.endsWith(u8, path, "socket_path_test.sock"));

    // absolute, which is what the Windows bind requires and what makes both ends agree
    if (comptime builtin.os.tag == .windows) {
        try std.testing.expect(path.len > 2 and path[1] == ':');
    } else {
        try std.testing.expect(path[0] == '/');
    }

    // the same inputs must give the same string, else a server and its client would disagree
    var buf2: [600]u8 = undefined;
    const again = try resolve(io, "tmp", "socket_path_test.sock", &buf2);
    try std.testing.expectEqualStrings(path, again);
}

test "zix utils: socket_path resolve reports PathTooLong instead of truncating" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // a buffer far too small for any absolute path must error, never hand back a partial path
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.PathTooLong, resolve(io, "tmp", "socket_path_test.sock", &tiny));
}

test "zix utils: socket_path clear removes a stale socket file and tolerates a missing one" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [600]u8 = undefined;
    const path = try resolve(io, "tmp", "socket_path_clear_test.sock", &buf);

    // absent to begin with: clear must not complain
    clear(io, path);

    var file = try std.Io.Dir.cwd().createFile(io, "tmp/socket_path_clear_test.sock", .{});
    file.close(io);

    clear(io, path);

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, "tmp/socket_path_clear_test.sock", .{}));
}
