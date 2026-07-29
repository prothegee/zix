//! zix static send: move cached static file bytes to a socket.
//!
//! Two ways out, picked by the caller. On Linux a cleartext response hands the
//! file straight to the kernel with sendfile, so the bytes never enter user
//! space and never grow resident memory. Everything else (TLS, a non-Linux
//! target) copies through a stack buffer and writes with the engine's own write
//! function, so the response still travels that engine's sink and TLS path.
//!
//! Only the transfer lives here. What to serve, and the header in front of it,
//! belong to the static cache and to each engine's static file. See ADR-064.

const std = @import("std");
const builtin = @import("builtin");

// --------------------------------------------------------- //

pub const SendError = error{BrokenPipe};

/// An engine's canonical socket write. The copy path goes through it rather than
/// writing the fd directly, so a copied body is coalesced and encrypted exactly
/// like every other response that engine sends.
pub const WriteFn = *const fn (fd: std.posix.fd_t, data: []const u8) SendError!void;

/// Bytes moved per iteration on the copy path. One buffer is enough because the
/// read is positional, so a range never needs a separate skip pass.
const COPY_BUF_SIZE: usize = 16 * 1024;

// --------------------------------------------------------- //

/// Block until the socket accepts more bytes. A full send buffer on a
/// non-blocking socket is normal back pressure, not an error, and this matches
/// what the engines' own direct writes already do.
fn waitWritable(sock: std.posix.fd_t) SendError!void {
    var poll_fds = [_]std.posix.pollfd{.{ .fd = sock, .events = std.posix.POLL.OUT, .revents = 0 }};

    _ = std.posix.poll(&poll_fds, -1) catch return error.BrokenPipe;
}

/// Hand len bytes of the file to the kernel, starting at offset.
///
/// Note:
/// - sendfile advances its own offset cursor, so the loop only has to retry.
/// - A return of 0 before the range is done means the peer went away.
fn sendFileLinux(sock: std.posix.fd_t, file_fd: std.posix.fd_t, offset: u64, len: u64) SendError!void {
    var cursor: i64 = @intCast(offset);
    const end: i64 = @intCast(offset + len);

    while (cursor < end) {
        const remaining: usize = @intCast(end - cursor);
        const rc = std.os.linux.sendfile(sock, file_fd, &cursor, remaining);

        switch (std.posix.errno(rc)) {
            .SUCCESS => if (rc == 0) return error.BrokenPipe,
            .INTR => {},
            .AGAIN => try waitWritable(sock),
            else => return error.BrokenPipe,
        }
    }
}

/// Read len bytes of the file from offset and write them through write.
fn copyBody(
    sock: std.posix.fd_t,
    io: std.Io,
    file: std.Io.File,
    offset: u64,
    len: u64,
    write: WriteFn,
) SendError!void {
    var buf: [COPY_BUF_SIZE]u8 = undefined;
    var sent: u64 = 0;

    while (sent < len) {
        const want: usize = @intCast(@min(len - sent, buf.len));
        const read = file.readPositionalAll(io, buf[0..want], offset + sent) catch return error.BrokenPipe;
        if (read == 0) return error.BrokenPipe;

        try write(sock, buf[0..read]);
        sent += read;
    }
}

/// Send a byte range of an open file to a socket.
///
/// Note:
/// - zero_copy must be false whenever the response is encrypted or otherwise
///   transformed, because sendfile writes the socket directly and would bypass
///   the TLS record path entirely.
/// - The zero-copy path also bypasses an engine's coalescing sink, so a caller
///   that stages its header there must flush before calling with zero_copy set,
///   otherwise the body overtakes its own header on the wire.
/// - On a non-Linux target zero_copy is ignored and the copy path runs, so no
///   platform loses static serving.
///
/// Param:
/// sock - std.posix.fd_t (destination socket)
/// io - std.Io (used by the copy path only)
/// file - std.Io.File (open, shared, read positionally so the offset is untouched)
/// offset - u64 (first byte of the range)
/// len - u64 (how many bytes to send)
/// zero_copy - bool (true only for a cleartext response)
/// write - WriteFn (the engine's own socket write, used by the copy path)
///
/// Return:
/// - void when the whole range was accepted
/// - error.BrokenPipe when the peer went away or the file could not be read
pub fn sendBody(
    sock: std.posix.fd_t,
    io: std.Io,
    file: std.Io.File,
    offset: u64,
    len: u64,
    zero_copy: bool,
    write: WriteFn,
) SendError!void {
    if (len == 0) return;

    if (comptime builtin.os.tag == .linux) {
        if (zero_copy) return sendFileLinux(sock, file.handle, offset, len);
    }

    return copyBody(sock, io, file, offset, len, write);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const testing = std.testing;

/// Placeholder socket for the copy-path tests, which never touch it: the write function under test
/// receives it and ignores it. Windows descriptors are opaque pointers, POSIX are ints.
const TEST_FD: std.posix.fd_t = if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else 0;

/// Collects everything a WriteFn is handed, so the copy path can be checked
/// without a socket.
var test_sink: [4096]u8 = undefined;
var test_sink_len: usize = 0;

fn testCollect(fd: std.posix.fd_t, data: []const u8) SendError!void {
    _ = fd;
    if (test_sink_len + data.len > test_sink.len) return error.BrokenPipe;

    @memcpy(test_sink[test_sink_len..][0..data.len], data);
    test_sink_len += data.len;
}

fn testFail(fd: std.posix.fd_t, data: []const u8) SendError!void {
    _ = fd;
    _ = data;

    return error.BrokenPipe;
}

/// Write a fixture into a test directory and open it for reading.
fn openFixture(dir: std.Io.Dir, name: []const u8, data: []const u8) std.Io.File {
    dir.writeFile(testing.io, .{ .sub_path = name, .data = data }) catch @panic("fixture write failed");

    return dir.openFile(testing.io, name, .{}) catch @panic("fixture open failed");
}

test "zix static_send: copy path writes the whole body through the engine write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = openFixture(tmp.dir, "body.txt", "abcdefghij");
    defer file.close(testing.io);

    test_sink_len = 0;
    try sendBody(TEST_FD, testing.io, file, 0, 10, false, testCollect);

    try testing.expectEqualStrings("abcdefghij", test_sink[0..test_sink_len]);
}

test "zix static_send: copy path honours an offset and a partial length" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = openFixture(tmp.dir, "range.txt", "0123456789");
    defer file.close(testing.io);

    test_sink_len = 0;
    try sendBody(TEST_FD, testing.io, file, 3, 4, false, testCollect);

    try testing.expectEqualStrings("3456", test_sink[0..test_sink_len]);
}

test "zix static_send: a zero-length range writes nothing and never touches the socket" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = openFixture(tmp.dir, "empty.txt", "");
    defer file.close(testing.io);

    // testFail would report BrokenPipe if the send tried to write at all.
    test_sink_len = 0;
    try sendBody(TEST_FD, testing.io, file, 0, 0, false, testFail);

    try testing.expectEqual(@as(usize, 0), test_sink_len);
}

test "zix static_send: a body larger than the copy buffer arrives whole and in order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Longer than COPY_BUF_SIZE, so the copy path has to loop.
    var payload: [COPY_BUF_SIZE + 1000]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast(index % 251);

    const file = openFixture(tmp.dir, "big.bin", &payload);
    defer file.close(testing.io);

    // The collector holds 4 KiB, so a looping body must report back pressure
    // rather than overrun it.
    test_sink_len = 0;
    try testing.expectError(error.BrokenPipe, sendBody(TEST_FD, testing.io, file, 0, payload.len, false, testCollect));
}

test "zix static_send: a failing engine write surfaces as BrokenPipe" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = openFixture(tmp.dir, "peer-gone.txt", "payload");
    defer file.close(testing.io);

    try testing.expectError(error.BrokenPipe, sendBody(TEST_FD, testing.io, file, 0, 7, false, testFail));
}

test "zix static_send: zero-copy path delivers the exact bytes over a real socket" {
    if (comptime builtin.os.tag != .linux) {
        // sendfile is the Linux shape here, and every other target takes the
        // copy path, which the tests above already cover.
        return error.SkipZigTest;
    }

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = openFixture(tmp.dir, "zero-copy.txt", "kernel to kernel");
    defer file.close(testing.io);

    var pair: [2]std.posix.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &pair));
    defer {
        _ = std.os.linux.close(pair[0]);
        _ = std.os.linux.close(pair[1]);
    }

    try sendBody(pair[0], testing.io, file, 0, "kernel to kernel".len, true, testFail);

    var received: [64]u8 = undefined;
    const rc = std.os.linux.read(pair[1], &received, received.len);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(rc));
    try testing.expectEqualStrings("kernel to kernel", received[0..@intCast(rc)]);
}

test "zix static_send: zero-copy path honours an offset and a partial length" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = openFixture(tmp.dir, "zero-copy-range.txt", "0123456789");
    defer file.close(testing.io);

    var pair: [2]std.posix.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &pair));
    defer {
        _ = std.os.linux.close(pair[0]);
        _ = std.os.linux.close(pair[1]);
    }

    try sendBody(pair[0], testing.io, file, 2, 5, true, testFail);

    var received: [16]u8 = undefined;
    const rc = std.os.linux.read(pair[1], &received, received.len);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(rc));
    try testing.expectEqualStrings("23456", received[0..@intCast(rc)]);
}

test "zix static_send: a closed peer makes the zero-copy path report BrokenPipe" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = openFixture(tmp.dir, "closed-peer.txt", "gone");
    defer file.close(testing.io);

    var pair: [2]std.posix.fd_t = undefined;
    try testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &pair));
    defer _ = std.os.linux.close(pair[0]);

    _ = std.os.linux.close(pair[1]);

    try testing.expectError(error.BrokenPipe, sendBody(pair[0], testing.io, file, 0, 4, true, testFail));
}
