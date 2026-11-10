//! ZIX http1 websocket send sink
//!
//! ### file: src/zix/tcp/http1/websocket/WsSendSink.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Stages every frame sent during one pump pass, so a pipelined burst goes
//! out in one write instead of one write per frame.
//!
//! ### note:
//!
//! Bytes larger than buf skip staging and are written straight through, so
//! correctness never depends on the buffer size. A failed write sets failed
//! and the pump closes the connection.
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
const writer = @import("../writer.zig");

// --------------------------------------------------------- //
// Fields:

/// Connection the staged bytes belong to.
fd: std.posix.fd_t,
/// Staging buffer.
buf: []u8,
/// Staged bytes in buf.
len: usize = 0,
/// A write to fd failed.
failed: bool = false,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Write bytes to fd, and mark the sink failed when the write does not land.
fn writeOut(self: *Self, bytes: []const u8) void {
    writer.writeAllFD(self.fd, bytes) catch |err| switch (err) {
        error.ZixHttp1_Writer_BrokenPipe,
        error.ZixHttp1_Writer_HeadBuild,
        => self.failed = true,
    };
}

// --------------------------------------------------------- //
// Public:

/// Stage bytes, flushing first when they would overflow buf.
///
/// Param:
/// bytes - []const u8 (frame bytes to send)
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

/// Write every staged byte and empty the buffer.
pub fn flush(self: *Self) void {
    if (self.len == 0) return;

    self.writeOut(self.buf[0..self.len]);
    self.len = 0;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../../utils/socket/pair.zig");
const reader = @import("../reader.zig");

fn testReadExact(fd: std.posix.fd_t, out: []u8) !void {
    var got: usize = 0;
    while (got < out.len) {
        const n = try reader.readOnceFD(fd, out[got..]);
        if (n == 0) return error.TestReadClosed;
        got += n;
    }
}

test "zix http1 websocket: WsSendSink, append stages without writing" {
    var buf: [16]u8 = undefined;
    var sink: Self = .{
        .fd = -1,
        .buf = &buf,
    };

    sink.append("abc");

    try std.testing.expectEqual(@as(usize, 3), sink.len);
    try std.testing.expect(!sink.failed);
}

test "zix http1 websocket: WsSendSink, flush writes staged bytes once" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var buf: [16]u8 = undefined;
    var sink: Self = .{
        .fd = fds[0],
        .buf = &buf,
    };

    sink.append("ab");
    sink.append("cd");
    sink.flush();

    var out: [4]u8 = undefined;
    try testReadExact(fds[1], &out);

    try std.testing.expectEqualStrings("abcd", &out);
    try std.testing.expectEqual(@as(usize, 0), sink.len);
}

test "zix http1 websocket: WsSendSink, overflow flushes before staging" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var buf: [4]u8 = undefined;
    var sink: Self = .{
        .fd = fds[0],
        .buf = &buf,
    };

    sink.append("abc");
    sink.append("de");

    var out: [3]u8 = undefined;
    try testReadExact(fds[1], &out);

    try std.testing.expectEqualStrings("abc", &out);
    try std.testing.expectEqual(@as(usize, 2), sink.len);
}

test "zix http1 websocket: WsSendSink, oversize bytes write straight through" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var buf: [2]u8 = undefined;
    var sink: Self = .{
        .fd = fds[0],
        .buf = &buf,
    };

    sink.append("hello");

    var out: [5]u8 = undefined;
    try testReadExact(fds[1], &out);

    try std.testing.expectEqualStrings("hello", &out);
    try std.testing.expectEqual(@as(usize, 0), sink.len);
}

test "zix http1 websocket: WsSendSink, failed write sets failed" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    _ = std.posix.system.close(fds[1]);

    var buf: [8]u8 = undefined;
    var sink: Self = .{
        .fd = fds[0],
        .buf = &buf,
    };

    sink.append("abc");
    sink.flush();

    try std.testing.expect(sink.failed);
}

test "zix http1 websocket: WsSendSink, flush on empty does nothing" {
    var buf: [8]u8 = undefined;
    var sink: Self = .{
        .fd = -1,
        .buf = &buf,
    };

    sink.flush();

    try std.testing.expect(!sink.failed);
}

