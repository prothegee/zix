//! Blocking read / write / close / readiness on a raw accepted descriptor.
//!
//! What:
//!   The thread-per-connection paths (https, the h2 terminator) hold a bare fd rather than a
//!   std.Io.net.Stream, and drive TLS records straight over it. This module is the one place
//!   that turns those operations into syscalls, so every caller gets the same platform coverage.
//!
//! Note:
//! - Three backends, selected at comptime: Windows through the ntdll shim, Linux through the
//!   direct syscall fast path, and every other POSIX target (macOS, FreeBSD, NetBSD, OpenBSD)
//!   through the libc layer. The Linux branch is kept separate on purpose and must not be
//!   merged into the POSIX one.
//! - Callers that own a std.Io.net.Stream should use the stream reader / writer instead. This
//!   module exists for the paths that only ever receive a descriptor.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const win_io = @import("windows_io.zig");

/// Windows keeps its own shim, Linux its direct syscalls, everything else goes through libc.
const is_windows = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;

pub const ReadError = error{ ReadFailed, ConnectionClosed };
pub const WriteError = error{WriteFailed};

// --------------------------------------------------------- //

/// Read exactly buf.len bytes, retrying a short read until the buffer is full.
///
/// Note:
/// - An interrupted syscall retries rather than failing, so a signal during a handshake does
///   not drop the connection.
///
/// Param:
/// fd - posix.fd_t (an accepted, blocking descriptor)
/// buf - []u8 (filled completely on success)
///
/// Return:
/// - void when the whole buffer was filled
/// - error.ConnectionClosed when the peer hung up mid-read
/// - error.ReadFailed on any other read error
pub fn readAll(fd: posix.fd_t, buf: []u8) ReadError!void {
    var read: usize = 0;

    while (read < buf.len) {
        const chunk = buf[read..];

        if (comptime is_windows) {
            const got = win_io.readOnce(fd, chunk) catch return error.ReadFailed;
            if (got == 0) return error.ConnectionClosed;

            read += got;
            continue;
        }

        const rc = if (comptime is_linux)
            std.os.linux.read(fd, chunk.ptr, chunk.len)
        else
            @as(usize, @bitCast(@as(isize, posix.system.read(fd, chunk.ptr, chunk.len))));

        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }

        if (rc == 0) return error.ConnectionClosed;

        read += rc;
    }
}

/// Read once, returning however many bytes arrived.
///
/// Note:
/// - Unlike readAll this reports a short read rather than looping, which is what a frame or
///   record loop wants: it needs to inspect what arrived before asking for more.
///
/// Param:
/// fd - posix.fd_t (an accepted, blocking descriptor)
/// buf - []u8 (filled up to its length)
///
/// Return:
/// - the byte count, where 0 means the peer hung up
/// - error.ReadFailed on a read error
pub fn readOnce(fd: posix.fd_t, buf: []u8) error{ReadFailed}!usize {
    while (true) {
        if (comptime is_windows) return win_io.readOnce(fd, buf) catch error.ReadFailed;

        const rc = if (comptime is_linux)
            std.os.linux.read(fd, buf.ptr, buf.len)
        else
            @as(usize, @bitCast(@as(isize, posix.system.read(fd, buf.ptr, buf.len))));

        switch (posix.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
}

/// Write every byte, retrying a short write until the slice is drained.
///
/// Param:
/// fd - posix.fd_t (an accepted, blocking descriptor)
/// bytes - []const u8 (written in full on success)
///
/// Return:
/// - void when every byte was accepted
/// - error.WriteFailed on a write error or a peer that went away
pub fn writeAll(fd: posix.fd_t, bytes: []const u8) WriteError!void {
    if (comptime is_windows) return win_io.writeAll(fd, bytes) catch error.WriteFailed;

    var written: usize = 0;

    while (written < bytes.len) {
        const chunk = bytes[written..];

        const rc = if (comptime is_linux)
            std.os.linux.write(fd, chunk.ptr, chunk.len)
        else
            @as(usize, @bitCast(@as(isize, posix.system.write(fd, chunk.ptr, chunk.len))));

        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.WriteFailed,
        }

        written += rc;
    }
}

/// Close an accepted descriptor. A close error is not actionable, so it is dropped.
///
/// Param:
/// fd - posix.fd_t
///
/// Return:
/// - void
pub fn close(fd: posix.fd_t) void {
    if (comptime is_windows) {
        win_io.close(fd);
        return;
    }

    if (comptime is_linux) {
        _ = std.os.linux.close(fd);
        return;
    }

    _ = posix.system.close(fd);
}

/// Block until fd is readable or the timeout elapses.
///
/// Note:
/// - The Windows read path blocks inside the ntdll shim, so there is no readiness wait to
///   perform there and the call reports readable straight away.
///
/// Param:
/// fd - posix.fd_t
/// timeout_ms - i32 (negative waits forever)
///
/// Return:
/// - true when the descriptor became readable
/// - false on timeout or a poll error
pub fn waitReadable(fd: posix.fd_t, timeout_ms: i32) bool {
    if (comptime is_windows) return true;

    var pending = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};

    // std.posix.poll retries an interrupted wait itself, so there is no INTR loop to run here.
    const ready = posix.poll(&pending, timeout_ms) catch return false;

    return ready > 0 and (pending[0].revents & posix.POLL.IN) != 0;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix utils: fd_io writeAll then readAll moves a whole buffer across a connected pair" {
    if (comptime is_windows) return error.SkipZigTest;

    var pair: [2]posix.fd_t = undefined;
    try testSocketPair(&pair);
    defer close(pair[0]);
    defer close(pair[1]);

    const payload = "fd_io round trip";
    try writeAll(pair[0], payload);

    var received: [payload.len]u8 = undefined;
    try readAll(pair[1], &received);

    try std.testing.expectEqualStrings(payload, &received);
}

test "zix utils: fd_io readAll reports ConnectionClosed when the peer hangs up early" {
    if (comptime is_windows) return error.SkipZigTest;

    var pair: [2]posix.fd_t = undefined;
    try testSocketPair(&pair);
    defer close(pair[1]);

    try writeAll(pair[0], "half");
    close(pair[0]);

    // asking for more than the peer ever sent must surface the hangup, not a short read
    var received: [16]u8 = undefined;
    try std.testing.expectError(error.ConnectionClosed, readAll(pair[1], &received));
}

test "zix utils: fd_io waitReadable sees pending bytes and times out on a quiet descriptor" {
    if (comptime is_windows) return error.SkipZigTest;

    var pair: [2]posix.fd_t = undefined;
    try testSocketPair(&pair);
    defer close(pair[0]);
    defer close(pair[1]);

    // quiet peer: the wait must expire rather than report readable
    try std.testing.expect(!waitReadable(pair[1], 10));

    try writeAll(pair[0], "x");

    try std.testing.expect(waitReadable(pair[1], 1000));
}

/// A connected descriptor pair for the tests above, on every POSIX target.
fn testSocketPair(fds: *[2]posix.fd_t) !void {
    if (comptime is_windows) return error.SkipZigTest;

    const rc = if (comptime is_linux)
        std.os.linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, fds)
    else
        @as(usize, @bitCast(@as(isize, posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, fds))));

    if (posix.errno(rc) != .SUCCESS) return error.SocketPairFailed;
}
