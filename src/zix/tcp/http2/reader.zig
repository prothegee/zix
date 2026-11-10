//! ZIX Http2 reader
//!
//! ### file: src/zix/tcp/http2/reader.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Blocking reads off an HTTP/2 connection: exact reads and frame headers.
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
const frame = @import("frame.zig");
const FrameHeader = @import("FrameHeader.zig");

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 reader error
pub const Error = error {
    ZixHttp2_Reader_Closed,
    ZixHttp2_Reader_ReadFailed,
};

/// Read some bytes from fd.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// buf - []u8 (destination, filled up to its length)
///
/// Return:
/// - usize (bytes read, 0 when the peer closed)
/// - error.ZixHttp2_Reader_ReadFailed on a read error
pub fn readOnceFD(fd: std.posix.fd_t, buf: []u8) Error!usize {
    return std.posix.read(fd, buf) catch |err| switch (err) {
        else => Error.ZixHttp2_Reader_ReadFailed,
    };
}

/// Read exactly buf.len bytes, retrying short reads until buf is full.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// buf - []u8 (filled completely on success)
///
/// Return:
/// - void when the whole buffer was filled
/// - error.ZixHttp2_Reader_Closed when the peer closed before buf was full
/// - error.ZixHttp2_Reader_ReadFailed on a read error
pub fn recvExact(fd: std.posix.fd_t, buf: []u8) Error!void {
    var filled: usize = 0;

    while (filled < buf.len) {
        const got = try readOnceFD(fd, buf[filled..]);
        if (got == 0) return Error.ZixHttp2_Reader_Closed;

        filled += got;
    }
}

/// Read and parse one 9-byte frame header from fd.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
///
/// Return:
/// - FrameHeader
/// - error.ZixHttp2_Reader_Closed when the peer closed mid-header
/// - error.ZixHttp2_Reader_ReadFailed on a read error
pub fn readFrameHeader(fd: std.posix.fd_t) Error!FrameHeader {
    var buf: [frame.FRAME_HEADER_LEN]u8 = undefined;
    try recvExact(fd, &buf);

    return frame.parseFrameHeader(&buf);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

fn testWriteAll(fd: std.posix.fd_t, data: []const u8) !void {
    var written: usize = 0;

    while (written < data.len) {
        const rc = std.posix.system.write(fd, data[written..].ptr, data.len - written);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const accepted: usize = @intCast(rc);
                if (accepted == 0) return error.TestWriteClosed;

                written += accepted;
            },
            .INTR => continue,
            else => return error.TestWriteFailed,
        }
    }
}

test "zix http2: reader, readOnceFD returns what arrived" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try testWriteAll(fds[1], "ping");

    var buf: [8]u8 = undefined;
    const got = try readOnceFD(fds[0], &buf);

    try std.testing.expectEqualStrings("ping", buf[0..got]);
}

test "zix http2: reader, readOnceFD returns 0 after the peer closed" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    _ = std.posix.system.close(fds[1]);
    defer _ = std.posix.system.close(fds[0]);

    var buf: [8]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), try readOnceFD(fds[0], &buf));
}

test "zix http2: reader, recvExact fills the buffer" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try testWriteAll(fds[1], "abc");
    try testWriteAll(fds[1], "def");

    var buf: [6]u8 = undefined;
    try recvExact(fds[0], &buf);

    try std.testing.expectEqualStrings("abcdef", &buf);
}

test "zix http2: reader, recvExact with an empty buffer reads nothing" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var buf: [0]u8 = undefined;

    try recvExact(fds[0], &buf);
}

test "zix http2: reader, recvExact short of data is Closed" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    try testWriteAll(fds[1], "half");
    _ = std.posix.system.close(fds[1]);

    var buf: [16]u8 = undefined;

    try std.testing.expectError(Error.ZixHttp2_Reader_Closed, recvExact(fds[0], &buf));
}

test "zix http2: reader, readFrameHeader parses a sent header" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const header: FrameHeader = .{
        .length = 42,
        .frame_type = frame.FRAME_TYPE_HEADERS,
        .flags = frame.FLAG_END_HEADERS,
        .stream_id = 3,
    };
    var buf: [frame.FRAME_HEADER_LEN]u8 = undefined;
    frame.encodeFrameHeader(&buf, header);

    try testWriteAll(fds[1], &buf);

    try std.testing.expectEqual(header, try readFrameHeader(fds[0]));
}

test "zix http2: reader, readFrameHeader cut short is Closed" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    try testWriteAll(fds[1], &[_]u8{ 0x00, 0x00, 0x08 });
    _ = std.posix.system.close(fds[1]);

    try std.testing.expectError(Error.ZixHttp2_Reader_Closed, readFrameHeader(fds[0]));
}

