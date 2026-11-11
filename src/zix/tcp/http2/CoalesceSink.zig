//! ZIX Http2 coalesce sink
//!
//! ### file: src/zix/tcp/http2/CoalesceSink.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Write buffer that collects the frames of one readable batch, so they leave
//! as one write instead of one write per frame.
//!
//! ### note:
//!
//! - A write that would overflow the buffer flushes it first. A write larger
//!   than the whole buffer goes straight to the socket after that flush, so
//!   wire order is kept and no size is too large.
//! - Writes go through writer.writeAllDirectFD, never the write hook, or the
//!   sink would call itself.
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
const writer = @import("writer.zig");

// --------------------------------------------------------- //
// Fields:

fd: std.posix.fd_t = NO_FD,
/// Staged bytes in buf.
len: usize = 0,
/// Set when a write failed. The worker closes the connection.
failed: bool = false,
buf: [BUF_SIZE]u8 = undefined,

const Self = @This();

// --------------------------------------------------------- //
// Private:

const NO_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

/// Write bytes to the socket, marking the sink failed when they do not land.
fn writeOut(self: *Self, bytes: []const u8) void {
    writer.writeAllDirectFD(self.fd, bytes) catch |err| switch (err) {
        error.ZixHttp2_Writer_BrokenPipe,
        error.ZixHttp2_Writer_UnexpectedEOF,
        error.ZixHttp2_Writer_Overflow,
        error.ZixHttp2_Writer_BufferFull,
        => self.failed = true,
    };
}

// --------------------------------------------------------- //
// Public:

/// Staging buffer size in bytes.
pub const BUF_SIZE: usize = 64 * 1024;

/// Point the sink at a connection and drop anything staged.
///
/// Param:
/// fd - std.posix.fd_t (the connection the batch writes to)
///
/// Return:
/// - void
pub fn reset(self: *Self, fd: std.posix.fd_t) void {
    self.fd = fd;
    self.len = 0;
    self.failed = false;
}

/// Stage bytes, flushing first when they do not fit.
///
/// Param:
/// bytes - []const u8 (frame bytes in wire order)
///
/// Return:
/// - void (a failed write sets failed)
pub fn append(self: *Self, bytes: []const u8) void {
    if (bytes.len > self.buf.len) {
        self.flush();
        self.writeOut(bytes);

        return;
    }

    if (self.len + bytes.len > self.buf.len) self.flush();

    @memcpy(self.buf[self.len..][0..bytes.len], bytes);
    self.len += bytes.len;
}

/// Write every staged byte to the socket and empty the buffer.
///
/// Return:
/// - void (a failed write sets failed)
pub fn flush(self: *Self) void {
    if (self.len == 0) return;

    self.writeOut(self.buf[0..self.len]);
    self.len = 0;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

/// Read from fd until want bytes arrived or the peer closed.
fn testReadAll(fd: std.posix.fd_t, out: []u8, want: usize) usize {
    var got: usize = 0;

    while (got < want) {
        const read = std.posix.read(fd, out[got..]) catch |err| switch (err) {
            else => break,
        };
        if (read == 0) break;

        got += read;
    }

    return got;
}

/// Drain a large write on its own thread, keeping only the first bytes.
fn testDrainCount(fd: std.posix.fd_t, head: []u8, total: *usize) void {
    var scratch: [4096]u8 = undefined;
    var got: usize = 0;

    while (true) {
        const read = std.posix.read(fd, &scratch) catch |err| switch (err) {
            else => break,
        };
        if (read == 0) break;

        if (got < head.len) {
            const take = @min(head.len - got, read);
            @memcpy(head[got..][0..take], scratch[0..take]);
        }
        got += read;
    }

    total.* = got;
}

test "zix http2: CoalesceSink, defaults are empty" {
    const sink: Self = .{};

    try std.testing.expectEqual(@as(usize, 0), sink.len);
    try std.testing.expect(!sink.failed);
}

test "zix http2: CoalesceSink, reset drops staged bytes" {
    var sink: Self = .{};
    sink.len = 7;
    sink.failed = true;

    sink.reset(NO_FD);

    try std.testing.expectEqual(@as(usize, 0), sink.len);
    try std.testing.expect(!sink.failed);
}

test "zix http2: CoalesceSink, append stages small writes" {
    var sink: Self = .{};
    sink.reset(NO_FD);

    sink.append("AAAA");
    sink.append("BBBB");

    try std.testing.expectEqual(@as(usize, 8), sink.len);
    try std.testing.expectEqualStrings("AAAABBBB", sink.buf[0..sink.len]);
}

test "zix http2: CoalesceSink, flush sends staged bytes in order" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var sink: Self = .{};
    sink.reset(fds[1]);
    sink.append("AAAA");
    sink.append("BBBB");
    sink.flush();

    var recv: [16]u8 = undefined;
    const got = testReadAll(fds[0], &recv, 8);

    try std.testing.expectEqualStrings("AAAABBBB", recv[0..got]);
    try std.testing.expectEqual(@as(usize, 0), sink.len);
}

test "zix http2: CoalesceSink, flush with nothing staged writes nothing" {
    var sink: Self = .{};
    sink.reset(NO_FD);

    sink.flush();

    try std.testing.expect(!sink.failed);
}

test "zix http2: CoalesceSink, append past the buffer flushes first" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    var sink: Self = .{};
    sink.reset(fds[1]);
    sink.append("PFX");

    var head: [3]u8 = undefined;
    var total: usize = 0;
    const drain = try std.Thread.spawn(.{}, testDrainCount, .{
        fds[0],
        &head,
        &total,
    });

    var big: [BUF_SIZE + 16]u8 = undefined;
    @memset(&big, 'Z');
    sink.append(&big);

    _ = std.posix.system.close(fds[1]);
    drain.join();

    try std.testing.expectEqualStrings("PFX", &head);
    try std.testing.expectEqual(@as(usize, 3 + big.len), total);
    try std.testing.expectEqual(@as(usize, 0), sink.len);
}

test "zix http2: CoalesceSink, a write to a closed peer sets failed" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var sink: Self = .{};
    sink.reset(fds[1]);
    sink.append("gone");
    sink.flush();

    try std.testing.expect(sink.failed);
}

