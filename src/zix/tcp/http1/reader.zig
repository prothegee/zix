//! ZIX Http1 reader
//!
//! ### file: src/zix/tcp/http1/reader.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Blocking reads off a connection: request head, body drain, socket tuning.
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
const builtin = @import("builtin");

// --------------------------------------------------------- //
// Private:

/// Bytes requested per drain read on the portable arm of drainBody. The Linux arm
/// asks for the whole remainder in one call, because MSG.TRUNC never writes a buffer.
const DRAIN_SCRATCH: usize = 4096;

/// Upper clamp on bytes requested in a single MSG.TRUNC drain recv. The kernel
/// never writes the buffer there, so a length past it is safe.
const MAX_DRAIN_RECV: usize = 1 << 30;

const RecvHeadResult = struct {
    body_offset: usize,
    filled: usize,
};

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 reader error
pub const Error = error {
    ZixHttp1_Reader_Closed,
    ZixHttp1_Reader_HeaderTooLarge,
    ZixHttp1_Reader_ReadFailed,
    ZixHttp1_Reader_SetBufFailed,
};

/// Read some bytes from fd: std.posix.read, or the platform shim where the
/// portable call is not the same one.
///
/// Return:
/// - usize (bytes read, 0 when the peer closed)
/// - read error otherwise
pub fn readOnceFD(fd: std.posix.fd_t, buf: []u8) Error!usize {
    return std.posix.read(fd, buf) catch |err| switch (err) {
        else => Error.ZixHttp1_Reader_ReadFailed,
    };
}

/// Bulk-read into buf until \r\n\r\n is found.
/// pre_filled bytes are already in buf from a previous iteration (keep-alive leftover).
///
/// Return:
/// - !RecvHeadResult
pub fn recvHead(fd: std.posix.fd_t, buf: []u8, pre_filled: usize) Error!RecvHeadResult {
    var filled = pre_filled;

    if (filled >= 4) {
        if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n")) |pos| {
            return .{ .body_offset = pos + 4, .filled = filled };
        }
    }

    while (true) {
        if (filled >= buf.len) return Error.ZixHttp1_Reader_HeaderTooLarge;
        const n = readOnceFD(fd, buf[filled..]) catch |err| switch (err) {
            else => return Error.ZixHttp1_Reader_ReadFailed,
        };
        if (n == 0) return Error.ZixHttp1_Reader_Closed;
        const search_from = if (filled > 3) filled - 3 else 0;
        filled += n;
        if (std.mem.indexOfPos(u8, buf[0..filled], search_from, "\r\n\r\n")) |pos| {
            return .{ .body_offset = pos + 4, .filled = filled };
        }
    }
}

/// Discard request-body bytes still sitting on the socket.
///
/// Note:
/// - Never writes into the buffer the handler is about to read. The drained
///   bytes are not part of the delivered body, so sharing one buffer hands the
///   handler the tail of the drain in place of the start of its request.
/// - Stops early on a peer that hangs up, which the caller sees as a returned
///   count short of what it asked for.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// owed - usize (body bytes still to consume)
///
/// Return:
/// - usize (bytes actually consumed off the socket)
pub fn drainBody(fd: std.posix.fd_t, owed: usize) usize {
    var remaining = owed;
    var consumed: usize = 0;
    var scratch: [DRAIN_SCRATCH]u8 = undefined;

    if (comptime builtin.target.os.tag == .linux) {
        // MSG.TRUNC drops the bytes inside the kernel: nothing is copied to
        // userspace and one call may ask for far more than scratch holds.
        const linux = std.os.linux;

        while (remaining > 0) {
            const want = @min(remaining, MAX_DRAIN_RECV);
            const rc = linux.recvfrom(fd, &scratch, want, linux.MSG.TRUNC, null, null);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    const n: usize = @intCast(rc);
                    if (n == 0) return consumed;

                    consumed += n;
                    remaining -= n;
                },
                .INTR => continue,
                else => return consumed,
            }
        }

        return consumed;
    }

    // Portable arm: a dedicated scratch buffer, never the handler's body buffer.
    while (remaining > 0) {
        const want = @min(remaining, scratch.len);
        const n = readOnceFD(fd, scratch[0..want]) catch |err| switch (err) {
            else => return consumed,
        };
        if (n == 0) return consumed;

        consumed += n;
        remaining -= n;
    }

    return consumed;
}

/// Widen the socket receive buffer (SO_RCVBUF) so a large request body drains in
/// fewer cycles. Applied only on the large-body path (a body bigger than the read
/// buffer), so ordinary small requests keep the kernel default and its
/// autotuning. bytes = 0 leaves the socket untouched.
///
/// Note:
/// - An explicit SO_RCVBUF disables receive autotuning for that socket, which is
///   why it is set only when a large body is actually detected, not at accept.
pub fn setRecvBuf(fd: std.posix.fd_t, bytes: usize) Error!void {
    if (bytes == 0) return;

    const val: c_int = @intCast(@min(bytes, std.math.maxInt(c_int)));
    std.posix.setsockopt(
        fd, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&val)
    ) catch |err| switch (err) {
        else => return Error.ZixHttp1_Reader_SetBufFailed,
    };
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
                const n: usize = @intCast(rc);
                if (n == 0) return error.TestWriteClosed;
                written += n;
            },
            .INTR => continue,
            else => return error.TestWriteFailed,
        }
    }
}

test "zix http1: reader, reads a head" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const request = "GET /path HTTP/1.1\r\nHost: zix\r\n\r\nBODY";
    try testWriteAll(fds[0], request);

    var buf: [256]u8 = undefined;
    const result = try recvHead(fds[1], &buf, 0);

    try std.testing.expectEqual(@as(usize, 33), result.body_offset);
    try std.testing.expectEqual(request.len, result.filled);
}

test "zix http1: reader, rejects an oversized head" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const request = "GET /path HTTP/1.1\r\nHost: zix\r\n\r\n";
    try testWriteAll(fds[0], request);

    var buf: [8]u8 = undefined;
    try std.testing.expectError(
        Error.ZixHttp1_Reader_HeaderTooLarge,
        recvHead(fds[1], &buf, 0),
    );
}

test "zix http1: reader, drains a body" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try testWriteAll(fds[0], "0123456789");

    try std.testing.expectEqual(@as(usize, 10), drainBody(fds[1], 10));
}

test "zix http1: reader, uses pre-filled leftover" {
    var buf: [64]u8 = undefined;
    const request = "GET / HTTP/1.1\r\n\r\n";
    @memcpy(buf[0..request.len], request);

    const result = try recvHead(0, &buf, request.len);

    try std.testing.expectEqual(request.len, result.body_offset);
    try std.testing.expectEqual(request.len, result.filled);
}

