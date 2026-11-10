//! ZIX Http2 writer
//!
//! ### file: src/zix/tcp/http2/writer.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Bytes to an HTTP/2 connection: direct writes and frame header writes.
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

/// ZIX Http2 writer error
pub const Error = error {
    ZixHttp2_Writer_BrokenPipe,
};

/// Whether frames for the stream in flight have already left for the peer.
///
/// Note:
/// - The `Response` builder tracks the same thing, but a handler may answer
///   through the fd writers instead, which hold no `Response`. Without this the
///   engine reads such a handler as never having answered and completes it a
///   second time.
/// - A threadlocal because the fd writers take an fd and nothing else. Cleared
///   by the core before each handler call.
pub threadlocal var tl_responded: bool = false;

/// Record that frames for the stream in flight left for the peer.
pub fn markResponded() void {
    tl_responded = true;
}

/// Whether the stream in flight has been answered through the fd writers.
///
/// Return:
/// - bool
pub fn respondedFD() bool {
    return tl_responded;
}

/// Write all of data to fd, retrying partial writes.
///
/// Note:
/// - A non-blocking socket with a full send buffer waits until writable, then
///   retries. A blocking socket never takes that branch.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// data - []const u8 (bytes to send, written in full on success)
///
/// Return:
/// - void when every byte was accepted
/// - error.ZixHttp2_Writer_BrokenPipe on a write error or a peer that went away
pub fn writeAllDirectFD(fd: std.posix.fd_t, data: []const u8) Error!void {
    var rem = data;

    while (rem.len > 0) {
        const rc = std.posix.system.write(fd, rem.ptr, rem.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const written: usize = @intCast(rc);
                if (written == 0) return Error.ZixHttp2_Writer_BrokenPipe;

                rem = rem[written..];
            },
            .INTR => continue,
            .AGAIN => {
                var pfd = [_]std.posix.pollfd{.{
                    .fd = fd,
                    .events = std.posix.POLL.OUT,
                    .revents = 0,
                }};
                _ = std.posix.poll(&pfd, -1) catch |err| switch (err) {
                    else => return Error.ZixHttp2_Writer_BrokenPipe,
                };
            },
            else => return Error.ZixHttp2_Writer_BrokenPipe,
        }
    }
}

/// Write frame bytes to fd, the canonical write behind every frame sender.
///
/// Note:
/// - Marks the stream in flight as answered, so a handler that writes here
///   directly is not completed a second time.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// data - []const u8 (bytes to send)
///
/// Return:
/// - void when every byte was accepted
/// - error.ZixHttp2_Writer_BrokenPipe on a write error
pub fn writeAllFD(fd: std.posix.fd_t, data: []const u8) Error!void {
    markResponded();

    return writeAllDirectFD(fd, data);
}

/// Encode one frame header and write it to fd.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// header - FrameHeader (the header to send)
///
/// Return:
/// - void when the 9 bytes were accepted
/// - error.ZixHttp2_Writer_BrokenPipe on a write error
pub fn writeFrameHeaderFD(fd: std.posix.fd_t, header: FrameHeader) Error!void {
    var buf: [frame.FRAME_HEADER_LEN]u8 = undefined;
    frame.encodeFrameHeader(&buf, header);

    return writeAllFD(fd, &buf);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

test "zix http2: writer, writeAllFD delivers data" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try writeAllFD(fds[1], "frame");

    var buf: [8]u8 = undefined;
    const got = try std.posix.read(fds[0], &buf);

    try std.testing.expectEqualStrings("frame", buf[0..got]);
}

test "zix http2: writer, writeAllFD marks the stream answered" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    tl_responded = false;
    defer tl_responded = false;

    try writeAllFD(fds[1], "x");

    try std.testing.expect(respondedFD());
}

test "zix http2: writer, writeAllDirectFD leaves the answered mark alone" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    tl_responded = false;

    try writeAllDirectFD(fds[1], "x");

    try std.testing.expect(!respondedFD());
}

test "zix http2: writer, writeAllFD with empty data writes nothing" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try writeAllFD(fds[1], "");
    try writeAllFD(fds[1], "z");

    var buf: [4]u8 = undefined;
    const got = try std.posix.read(fds[0], &buf);

    try std.testing.expectEqualStrings("z", buf[0..got]);
}

test "zix http2: writer, writeAllDirectFD to a closed peer is BrokenPipe" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const result = writeAllDirectFD(fds[1], "gone");

    try std.testing.expectError(Error.ZixHttp2_Writer_BrokenPipe, result);
}

test "zix http2: writer, writeFrameHeaderFD sends 9 encoded bytes" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const header: FrameHeader = .{
        .length = 8,
        .frame_type = frame.FRAME_TYPE_PING,
        .flags = frame.FLAG_ACK,
        .stream_id = 0,
    };
    try writeFrameHeaderFD(fds[1], header);

    var buf: [frame.FRAME_HEADER_LEN]u8 = undefined;
    const got = try std.posix.read(fds[0], &buf);

    try std.testing.expectEqual(frame.FRAME_HEADER_LEN, got);
    try std.testing.expectEqual(header, frame.parseFrameHeader(&buf));
}

