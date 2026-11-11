//! ZIX Http2 Grpc ReplyStage
//!
//! ### file: src/zix/tcp/http2/grpc/ReplyStage.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Cork buffer for one reply: HEADERS, DATA, and the trailer are staged and
//! written to the connection in one write.
//!
//! ### note:
//!
//! Staged bytes are written after the handler returns, so a write failure is
//! kept in `failed` and reported by the next send, not by the append that
//! staged them.
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

/// The connection the staged bytes go to.
fd: std.posix.fd_t,
/// Staging storage, owned by the caller.
buf: []u8,
/// Bytes staged in buf.
len: usize = 0,
/// Set once a write for this reply failed.
failed: bool = false,

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn writeOrFail(self: *Self, bytes: []const u8) void {
    writer.writeAllFD(self.fd, bytes) catch |err| switch (err) {
        error.ZixHttp2_Writer_BrokenPipe,
        error.ZixHttp2_Writer_UnexpectedEOF,
        error.ZixHttp2_Writer_Overflow,
        error.ZixHttp2_Writer_BufferFull,
        => self.failed = true,
    };
}

// --------------------------------------------------------- //
// Public:

/// Stage bytes. A chunk past the free room flushes first, and a chunk past
/// the whole buffer is written straight through, so wire order is kept.
///
/// Param:
/// bytes - []const u8 (frame bytes to send)
///
/// Return:
/// - void
pub fn append(self: *Self, bytes: []const u8) void {
    if (bytes.len > self.buf.len - self.len) {
        self.flush();

        if (bytes.len > self.buf.len) {
            self.writeOrFail(bytes);

            return;
        }
    }

    @memcpy(self.buf[self.len..][0..bytes.len], bytes);
    self.len += bytes.len;
}

/// Write the staged bytes and empty the buffer.
pub fn flush(self: *Self) void {
    if (self.len == 0) return;

    self.writeOrFail(self.buf[0..self.len]);
    self.len = 0;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const pair = @import("../../../utils/socket/pair.zig");

const TEST_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

fn isLinux() bool {
    if (comptime builtin.target.os.tag == .linux) return true;

    std.log.info("this test drives a Linux socket pair, test skipped", .{});

    return false;
}

fn openPair() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);

    return fds;
}

fn closePair(fds: [2]std.posix.fd_t) void {
    _ = std.posix.system.close(fds[0]);
    _ = std.posix.system.close(fds[1]);
}

test "zix http2 grpc: ReplyStage, append keeps bytes until flush" {
    var backing: [64]u8 = undefined;
    var stage: Self = .{
        .fd = TEST_FD,
        .buf = &backing,
    };

    stage.append("hello");
    stage.append(" world");

    try std.testing.expectEqualStrings("hello world", stage.buf[0..stage.len]);
    try std.testing.expect(!stage.failed);
}

test "zix http2 grpc: ReplyStage, flush writes the staged bytes" {
    if (!isLinux()) return;

    const fds = try openPair();
    defer closePair(fds);

    var backing: [64]u8 = undefined;
    var stage: Self = .{
        .fd = fds[1],
        .buf = &backing,
    };

    stage.append("hello");
    stage.append(" world");
    stage.flush();

    var out: [16]u8 = undefined;
    const n = try std.posix.read(fds[0], &out);

    try std.testing.expectEqualStrings("hello world", out[0..n]);
    try std.testing.expectEqual(@as(usize, 0), stage.len);
}

test "zix http2 grpc: ReplyStage, overflow flushes and keeps buffering" {
    if (!isLinux()) return;

    const fds = try openPair();
    defer closePair(fds);

    var backing: [4]u8 = undefined;
    var stage: Self = .{
        .fd = fds[1],
        .buf = &backing,
    };

    stage.append("abcd");
    stage.append("ef");

    try std.testing.expectEqualStrings("ef", stage.buf[0..stage.len]);

    stage.flush();

    var out: [16]u8 = undefined;
    const n = try std.posix.read(fds[0], &out);

    try std.testing.expectEqualStrings("abcdef", out[0..n]);
}

test "zix http2 grpc: ReplyStage, chunk past the buffer writes straight through" {
    if (!isLinux()) return;

    const fds = try openPair();
    defer closePair(fds);

    var backing: [4]u8 = undefined;
    var stage: Self = .{
        .fd = fds[1],
        .buf = &backing,
    };

    stage.append("hello world");

    try std.testing.expectEqual(@as(usize, 0), stage.len);

    var out: [16]u8 = undefined;
    const n = try std.posix.read(fds[0], &out);

    try std.testing.expectEqualStrings("hello world", out[0..n]);
}

test "zix http2 grpc: ReplyStage, a dead peer sets failed" {
    if (!isLinux()) return;

    const fds = try openPair();
    _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var backing: [8]u8 = undefined;
    var stage: Self = .{
        .fd = fds[1],
        .buf = &backing,
    };

    stage.append("abc");
    stage.flush();

    try std.testing.expect(stage.failed);
}

test "zix http2 grpc: ReplyStage, flush with nothing staged keeps failed clear" {
    var backing: [8]u8 = undefined;
    var stage: Self = .{
        .fd = TEST_FD,
        .buf = &backing,
    };

    stage.flush();

    try std.testing.expect(!stage.failed);
}

