//! ZIX utils static
//!
//! ### file: src/zix/utils/static/static.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Move a byte range of an open static file to a socket.
//!
//! ### note:
//!
//! On Linux a cleartext response uses sendfile, so the bytes never enter user
//! space. Every other case copies through a stack buffer and the engine's own
//! write function, so the bytes travel that engine's sink.
//! sendfile bypasses the engine's sink: flush it before a zero-copy send, or
//! the body overtakes its own header.
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

/// Bytes moved per copy iteration. The read is positional, so a range needs
/// no skip pass.
const COPY_BUF_SIZE: usize = 16 * 1024;

/// Block until the socket takes more bytes. A full send buffer is back
/// pressure, not an error.
fn waitWritable(sock: std.posix.fd_t) Error!void {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = sock,
        .events = std.posix.POLL.OUT,
        .revents = 0,
    }};

    _ = std.posix.poll(&poll_fds, -1) catch |err| switch (err) {
        else => return Error.ZixUtils_Static_BrokenPipe,
    };
}

/// Hand len bytes of the file to the kernel, starting at offset.
fn sendFileLinux(
    sock: std.posix.fd_t,
    file_fd: std.posix.fd_t,
    offset: u64,
    len: u64,
) Error!void {
    var cursor: i64 = @intCast(offset);
    const end: i64 = @intCast(offset + len);

    while (cursor < end) {
        const remaining: usize = @intCast(end - cursor);
        const rc = std.os.linux.sendfile(sock, file_fd, &cursor, remaining);

        switch (std.posix.errno(rc)) {
            .SUCCESS => if (rc == 0) return Error.ZixUtils_Static_FileTruncated,
            .INTR => {},
            .AGAIN => try waitWritable(sock),
            .IO, .NOMEM => return Error.ZixUtils_Static_FileUnreadable,
            else => return Error.ZixUtils_Static_BrokenPipe,
        }
    }
}

/// Read len bytes from offset and write them through write.
fn copyBody(
    sock: std.posix.fd_t,
    io: std.Io,
    file: std.Io.File,
    offset: u64,
    len: u64,
    write: WriteFn,
) Error!void {
    var buf: [COPY_BUF_SIZE]u8 = undefined;
    var sent: u64 = 0;

    while (sent < len) {
        const want: usize = @intCast(@min(len - sent, buf.len));
        const read_result = file.readPositionalAll(io, buf[0..want], offset + sent);
        const read = read_result catch |err| switch (err) {
            else => return Error.ZixUtils_Static_FileUnreadable,
        };
        if (read == 0) return Error.ZixUtils_Static_FileTruncated;

        try write(sock, buf[0..read]);
        sent += read;
    }
}

// --------------------------------------------------------- //
// Public:

/// ZIX utils static error
///
/// Note:
/// - BrokenPipe is the peer leaving, which is ordinary. The file errors are a
///   broken deployment, so they keep their own names.
pub const Error = error {
    ZixUtils_Static_BrokenPipe,
    ZixUtils_Static_FileUnreadable,
    ZixUtils_Static_FileTruncated,
};

/// An engine's socket write, used by the copy path.
pub const WriteFn = *const fn (fd: std.posix.fd_t, data: []const u8) Error!void;

/// Send a byte range of an open file to a socket.
///
/// Note:
/// - zero_copy is ignored outside Linux, the copy path runs instead.
///
/// Param:
/// sock - std.posix.fd_t (destination socket)
/// io - std.Io (copy path read)
/// file - std.Io.File (open and shared, read positionally)
/// offset - u64 (first byte of the range)
/// len - u64 (bytes to send)
/// zero_copy - bool (true only when nothing transforms the bytes)
/// write - WriteFn (the engine's socket write, copy path only)
///
/// Return:
/// - void when the whole range was accepted
/// - Error.ZixUtils_Static_BrokenPipe when the peer went away
/// - Error.ZixUtils_Static_FileUnreadable when the file cannot be read
/// - Error.ZixUtils_Static_FileTruncated when the file ends inside the range
pub fn sendBody(
    sock: std.posix.fd_t,
    io: std.Io,
    file: std.Io.File,
    offset: u64,
    len: u64,
    zero_copy: bool,
    write: WriteFn,
) Error!void {
    if (len == 0) return;

    if (comptime builtin.os.tag == .linux) {
        if (zero_copy) return sendFileLinux(sock, file.handle, offset, len);
    }

    return copyBody(sock, io, file, offset, len, write);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Placeholder socket for the copy path, which never touches it.
const TEST_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    0;

threadlocal var test_sink: [4096]u8 = undefined;
threadlocal var test_sink_len: usize = 0;

fn testCollect(fd: std.posix.fd_t, data: []const u8) Error!void {
    _ = fd;

    if (test_sink_len + data.len > test_sink.len) return Error.ZixUtils_Static_BrokenPipe;

    @memcpy(test_sink[test_sink_len..][0..data.len], data);
    test_sink_len += data.len;
}

fn testFail(fd: std.posix.fd_t, data: []const u8) Error!void {
    _ = fd;
    _ = data;

    return Error.ZixUtils_Static_BrokenPipe;
}

fn openFixture(tmp: *std.testing.TmpDir, name: []const u8, data: []const u8) std.Io.File {
    tmp.dir.writeFile(std.testing.io, .{
        .sub_path = name,
        .data = data,
    }) catch |err| switch (err) {
        else => @panic("fixture write failed"),
    };

    return tmp.dir.openFile(std.testing.io, name, .{}) catch |err| switch (err) {
        else => @panic("fixture open failed"),
    };
}

fn linuxPair() ![2]std.posix.fd_t {
    var pair: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(
        std.os.linux.AF.UNIX,
        std.os.linux.SOCK.STREAM,
        0,
        &pair,
    );
    try std.testing.expectEqual(@as(usize, 0), rc);

    return pair;
}

test "zix utils static: static, copy path writes the whole body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = openFixture(&tmp, "body.txt", "abcdefghij");
    defer file.close(std.testing.io);

    test_sink_len = 0;
    try sendBody(TEST_FD, std.testing.io, file, 0, 10, false, testCollect);

    try std.testing.expectEqualStrings("abcdefghij", test_sink[0..test_sink_len]);
}

test "zix utils static: static, copy path honours offset and length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = openFixture(&tmp, "range.txt", "0123456789");
    defer file.close(std.testing.io);

    test_sink_len = 0;
    try sendBody(TEST_FD, std.testing.io, file, 3, 4, false, testCollect);

    try std.testing.expectEqualStrings("3456", test_sink[0..test_sink_len]);
}

test "zix utils static: static, zero length writes nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = openFixture(&tmp, "empty.txt", "");
    defer file.close(std.testing.io);

    try sendBody(TEST_FD, std.testing.io, file, 0, 0, false, testFail);
}

test "zix utils static: static, copy path loops past the buffer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var payload: [COPY_BUF_SIZE + 1000]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast(index % 251);

    const file = openFixture(&tmp, "big.bin", &payload);
    defer file.close(std.testing.io);

    // The 4 KiB collector reports back pressure instead of overrunning.
    test_sink_len = 0;
    try std.testing.expectError(
        Error.ZixUtils_Static_BrokenPipe,
        sendBody(TEST_FD, std.testing.io, file, 0, payload.len, false, testCollect),
    );
}

test "zix utils static: static, failing write is BrokenPipe" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = openFixture(&tmp, "gone.txt", "payload");
    defer file.close(std.testing.io);

    try std.testing.expectError(
        Error.ZixUtils_Static_BrokenPipe,
        sendBody(TEST_FD, std.testing.io, file, 0, 7, false, testFail),
    );
}

test "zix utils static: static, file shorter than the range is FileTruncated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = openFixture(&tmp, "short.txt", "abc");
    defer file.close(std.testing.io);

    test_sink_len = 0;
    try std.testing.expectError(
        Error.ZixUtils_Static_FileTruncated,
        sendBody(TEST_FD, std.testing.io, file, 0, 64, false, testCollect),
    );
}

test "zix utils static: static, zero copy delivers the bytes" {
    if (comptime builtin.os.tag != .linux) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = openFixture(&tmp, "zero.txt", "kernel to kernel");
    defer file.close(std.testing.io);

    const pair = try linuxPair();
    defer {
        _ = std.os.linux.close(pair[0]);
        _ = std.os.linux.close(pair[1]);
    }

    try sendBody(pair[0], std.testing.io, file, 0, 16, true, testFail);

    var received: [64]u8 = undefined;
    const rc = std.os.linux.read(pair[1], &received, received.len);

    try std.testing.expectEqualStrings("kernel to kernel", received[0..rc]);
}

test "zix utils static: static, zero copy honours offset and length" {
    if (comptime builtin.os.tag != .linux) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = openFixture(&tmp, "zero-range.txt", "0123456789");
    defer file.close(std.testing.io);

    const pair = try linuxPair();
    defer {
        _ = std.os.linux.close(pair[0]);
        _ = std.os.linux.close(pair[1]);
    }

    try sendBody(pair[0], std.testing.io, file, 2, 5, true, testFail);

    var received: [16]u8 = undefined;
    const rc = std.os.linux.read(pair[1], &received, received.len);

    try std.testing.expectEqualStrings("23456", received[0..rc]);
}

test "zix utils static: static, zero copy closed peer is BrokenPipe" {
    if (comptime builtin.os.tag != .linux) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = openFixture(&tmp, "closed.txt", "gone");
    defer file.close(std.testing.io);

    const pair = try linuxPair();
    defer _ = std.os.linux.close(pair[0]);

    _ = std.os.linux.close(pair[1]);

    try std.testing.expectError(
        Error.ZixUtils_Static_BrokenPipe,
        sendBody(pair[0], std.testing.io, file, 0, 4, true, testFail),
    );
}

