//! ZIX utils socket pair
//!
//! ### file: src/zix/utils/socket/pair.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Opens two connected stream descriptors.
//! 
//! ### note:
//! 
//! n/a
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

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_SocketPair_Failed,
};

/// Open two connected stream descriptors.
///
/// Note:
/// - Anything written to one end is readable from the other, in both directions.
///
/// Param:
/// io - std.Io (only used by the Windows loopback path, ignored elsewhere)
/// fds - *[2]posix.fd_t (filled with the two connected ends)
///
/// Return:
/// - void on success
/// - error.ZixUtils_SocketPair_Failed when the pair could not be established
pub fn open(io: std.Io, fds: *[2]std.posix.fd_t) Error!void {
    _ = io;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, fds);

    if (std.posix.errno(rc) != .SUCCESS) return Error.ZixUtils_SocketPair_Failed;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testWriteAll(fd: std.posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const rc = std.posix.system.write(fd, data[written..].ptr, data.len - written);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.TestWriteClosed;
                written += n;
            },
            .INTR => continue,
            else => return error.TestWriteFailed,
        }
    }
}

test "zix utils: socket pair, carries bytes both ways" {
    var fds: [2]std.posix.fd_t = undefined;
    try open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try testWriteAll(fds[0], "ping");

    var buf: [4]u8 = undefined;
    const n = try std.posix.read(fds[1], &buf);

    try std.testing.expectEqualStrings("ping", buf[0..n]);
}

test "zix utils: socket pair, is bidirectional" {
    var fds: [2]std.posix.fd_t = undefined;
    try open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try testWriteAll(fds[1], "pong");

    var buf: [4]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);

    try std.testing.expectEqualStrings("pong", buf[0..n]);
}

