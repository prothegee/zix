//! ZIX Http1 TLS stream sink
//!
//! ### file: src/zix/tcp/http1/TlsStreamSink.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Hands response bytes to a live TLS connection, which seals them into records
//! and sends them. Used for SSE, WebSocket, and responses past the staging buffer.
//!
//! ### note:
//!
//! Type-erased: writeFn casts ctx back to the concrete connection state, so the
//! TLS 1.3 and TLS 1.2 paths share one sink.
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

// --------------------------------------------------------- //
// Fields:

/// The concrete connection state behind writeFn.
ctx: *anyopaque,
/// Seal and send plaintext. False when the connection is gone.
writeFn: *const fn (ctx: *anyopaque, plaintext: []const u8) bool,
/// The connection socket. Only writes addressed to this fd go through the sink.
fd: std.posix.fd_t,
/// A write already failed. Every later write fails too.
failed: bool = false,
/// Plaintext already left for the request being served. Once set, the response
/// is committed: a later failure can only close the connection.
wrote: bool = false,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Seal and send bytes through the connection.
///
/// Return:
/// - bool (false when the connection is gone)
pub fn write(self: *Self, bytes: []const u8) bool {
    if (self.failed) return false;

    if (!self.writeFn(self.ctx, bytes)) {
        self.failed = true;

        return false;
    }

    self.wrote = true;

    return true;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Collector = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    refuse: bool = false,

    fn write(ctx: *anyopaque, plaintext: []const u8) bool {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        if (self.refuse or self.len + plaintext.len > self.buf.len) return false;

        @memcpy(self.buf[self.len..][0..plaintext.len], plaintext);
        self.len += plaintext.len;

        return true;
    }
};

test "zix http1: TlsStreamSink, write hands bytes to the connection" {
    var collector: Collector = .{};
    var sink: Self = .{
        .ctx = &collector,
        .writeFn = Collector.write,
        .fd = -1,
    };

    try std.testing.expect(sink.write("abc"));
    try std.testing.expect(sink.wrote);
    try std.testing.expectEqualStrings("abc", collector.buf[0..collector.len]);
}

test "zix http1: TlsStreamSink, a refused write marks the sink failed" {
    var collector: Collector = .{ .refuse = true };
    var sink: Self = .{
        .ctx = &collector,
        .writeFn = Collector.write,
        .fd = -1,
    };

    try std.testing.expect(!sink.write("abc"));
    try std.testing.expect(sink.failed);
    try std.testing.expect(!sink.wrote);
}

test "zix http1: TlsStreamSink, a failed sink refuses later writes" {
    var collector: Collector = .{};
    var sink: Self = .{
        .ctx = &collector,
        .writeFn = Collector.write,
        .fd = -1,
        .failed = true,
    };

    try std.testing.expect(!sink.write("abc"));
    try std.testing.expectEqual(@as(usize, 0), collector.len);
}

