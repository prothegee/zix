//! ZIX Http2 coalesce
//!
//! ### file: src/zix/tcp/http2/coalesce.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Per-worker frame batching for the .EPOLL and .URING models: install the
//! worker's CoalesceSink as the frame write hook around one readable batch.
//!
//! ### note:
//!
//! - One sink per worker thread, reused by every connection it serves. Only
//!   one batch is in flight per worker, so no lock is needed.
//! - Always pair beginCoalesce with endCoalesce, or every later frame of the
//!   worker stays staged.
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
const writer = @import("writer.zig");
const CoalesceSink = @import("CoalesceSink.zig");

// --------------------------------------------------------- //
// Private:

/// This worker's sink.
threadlocal var tl_sink: CoalesceSink = .{};

/// The write hook: stage the bytes in the sink passed as ctx.
fn hookWrite(ctx: *anyopaque, bytes: []const u8) void {
    const sink: *CoalesceSink = @ptrCast(@alignCast(ctx));

    sink.append(bytes);
}

// --------------------------------------------------------- //
// Public:

/// Start staging every frame write of this worker for one connection.
///
/// Param:
/// fd - std.posix.fd_t (the connection of this batch)
///
/// Return:
/// - void
pub fn beginCoalesce(fd: std.posix.fd_t) void {
    tl_sink.reset(fd);

    writer.write_hook = hookWrite;
    writer.write_hook_ctx = &tl_sink;
}

/// Flush the staged batch and remove the write hook.
///
/// Return:
/// - true when a write of the batch failed, so the connection must close
/// - false when every byte left
pub fn endCoalesce() bool {
    writer.write_hook = null;
    writer.write_hook_ctx = null;

    tl_sink.flush();

    return tl_sink.failed;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

const TEST_FD: std.posix.fd_t = if (@import("builtin").os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

test "zix http2: coalesce, beginCoalesce installs the write hook" {
    beginCoalesce(TEST_FD);
    defer _ = endCoalesce();

    try std.testing.expect(writer.write_hook != null);
    try std.testing.expect(writer.write_hook_ctx != null);
}

test "zix http2: coalesce, endCoalesce removes the write hook" {
    beginCoalesce(TEST_FD);
    _ = endCoalesce();

    try std.testing.expect(writer.write_hook == null);
    try std.testing.expect(writer.write_hook_ctx == null);
}

test "zix http2: coalesce, frames of a batch leave as one write" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    beginCoalesce(fds[1]);
    try writer.writeAllFD(fds[1], "one");
    try writer.writeAllFD(fds[1], "two");

    try std.testing.expectEqual(@as(usize, 6), tl_sink.len);
    try std.testing.expect(!endCoalesce());

    var buf: [16]u8 = undefined;
    const got = try std.posix.read(fds[0], &buf);

    try std.testing.expectEqualStrings("onetwo", buf[0..got]);
}

test "zix http2: coalesce, endCoalesce reports a failed write" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    beginCoalesce(fds[1]);
    try writer.writeAllFD(fds[1], "gone");

    try std.testing.expect(endCoalesce());
}

