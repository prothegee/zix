//! ZIX Http2 Grpc ConnReader
//!
//! ### file: src/zix/tcp/http2/grpc/ConnReader.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Buffered frame reader for one gRPC connection, so a batch of small frames
//! costs one read.
//!
//! ### note:
//!
//! A slice from take points into buf and is valid only until the next ensure.
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
const reader = @import("../reader.zig");

// --------------------------------------------------------- //
// Fields:

/// The connection to read from.
fd: std.posix.fd_t,
/// Read storage, owned by the caller.
buf: []u8,
/// First unread byte in buf.
start: usize = 0,
/// One past the last read byte in buf.
end: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Read once into the free tail, moving unread bytes to the front first when
/// the tail is full.
fn fillSome(self: *Self) Error!void {
    if (self.start == self.end) {
        self.start = 0;
        self.end = 0;
    } else if (self.end == self.buf.len) {
        const unread = self.end - self.start;
        std.mem.copyForwards(u8, self.buf[0..unread], self.buf[self.start..self.end]);
        self.start = 0;
        self.end = unread;
    }

    const got = reader.readOnceFD(self.fd, self.buf[self.end..]) catch |err| switch (err) {
        error.ZixHttp2_Reader_Closed => return Error.ZixHttp2_GrpcConnReader_Closed,
        error.ZixHttp2_Reader_ReadFailed => return Error.ZixHttp2_GrpcConnReader_ReadFailed,
    };
    if (got == 0) return Error.ZixHttp2_GrpcConnReader_Closed;

    self.end += got;
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc conn reader error
pub const Error = error {
    ZixHttp2_GrpcConnReader_Closed,
    ZixHttp2_GrpcConnReader_ReadFailed,
    ZixHttp2_GrpcConnReader_TooLarge,
};

/// Block until at least need bytes are buffered.
///
/// Param:
/// need - usize (bytes wanted)
///
/// Return:
/// - void
/// - error.ZixHttp2_GrpcConnReader_TooLarge when need is past buf.len
/// - error.ZixHttp2_GrpcConnReader_Closed when the peer closed first
/// - error.ZixHttp2_GrpcConnReader_ReadFailed on a read error
pub fn ensure(self: *Self, need: usize) Error!void {
    if (need > self.buf.len) return Error.ZixHttp2_GrpcConnReader_TooLarge;

    while (self.end - self.start < need) try self.fillSome();
}

/// The next len buffered bytes, then advance past them. Call ensure(len) first.
pub fn take(self: *Self, len: usize) []u8 {
    const slice = self.buf[self.start..][0..len];
    self.start += len;

    return slice;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const pair = @import("../../../utils/socket/pair.zig");
const writer = @import("../writer.zig");

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

test "zix http2 grpc: ConnReader, take serves buffered bytes in order" {
    if (!isLinux()) return;

    const fds = try openPair();
    defer closePair(fds);

    try writer.writeAllDirectFD(fds[0], "abcdef");

    var backing: [16]u8 = undefined;
    var conn_reader: Self = .{
        .fd = fds[1],
        .buf = &backing,
    };

    try conn_reader.ensure(6);

    try std.testing.expectEqualStrings("abc", conn_reader.take(3));
    try std.testing.expectEqualStrings("def", conn_reader.take(3));
}

test "zix http2 grpc: ConnReader, ensure compacts a full buffer" {
    if (!isLinux()) return;

    const fds = try openPair();
    defer closePair(fds);

    try writer.writeAllDirectFD(fds[0], "abcd");

    var backing: [4]u8 = undefined;
    var conn_reader: Self = .{
        .fd = fds[1],
        .buf = &backing,
    };

    try conn_reader.ensure(4);
    _ = conn_reader.take(3);

    try writer.writeAllDirectFD(fds[0], "efg");
    try conn_reader.ensure(4);

    try std.testing.expectEqualStrings("defg", conn_reader.take(4));
}

test "zix http2 grpc: ConnReader, ensure past the buffer is too large" {
    var backing: [4]u8 = undefined;
    var conn_reader: Self = .{
        .fd = TEST_FD,
        .buf = &backing,
    };

    try std.testing.expectError(Error.ZixHttp2_GrpcConnReader_TooLarge, conn_reader.ensure(5));
}

test "zix http2 grpc: ConnReader, peer close mid-read is closed" {
    if (!isLinux()) return;

    const fds = try openPair();
    defer _ = std.posix.system.close(fds[1]);

    try writer.writeAllDirectFD(fds[0], "ab");
    _ = std.posix.system.close(fds[0]);

    var backing: [8]u8 = undefined;
    var conn_reader: Self = .{
        .fd = fds[1],
        .buf = &backing,
    };

    try std.testing.expectError(Error.ZixHttp2_GrpcConnReader_Closed, conn_reader.ensure(4));
}

