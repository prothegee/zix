//! ZIX utils ignore sigpipe
//!
//! ### file: src/zix/utils/ignore_sigpipe.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Ignores SIGPIPE for the whole process, so a write to a closed peer returns an
//! error instead of killing the server.
//!
//! ### note:
//!
//! The setting is process-wide, not per socket. Calling it again is harmless,
//! so every server `run()` calls it without a guard.
//! Windows has no SIGPIPE, the call does nothing there.
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
// Public:

/// Set the SIGPIPE action to ignore for the whole process.
///
/// Note:
/// - After this, a write to a peer that already closed its read side fails
///   with `PIPE` (BrokenPipe) instead of ending the process.
///
/// Return:
/// - void
pub fn ignoreSigpipe() void {
    if (comptime builtin.target.os.tag == .windows) return;

    std.posix.sigaction(std.posix.SIG.PIPE, &.{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testCurrentPipeHandler() ?std.posix.Sigaction.handler_fn {
    var current: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.PIPE, null, &current);

    return current.handler.handler;
}

test "zix utils: ignoreSigpipe, sets the SIGPIPE action to ignore" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    ignoreSigpipe();

    try std.testing.expectEqual(std.posix.SIG.IGN, testCurrentPipeHandler());
}

test "zix utils: ignoreSigpipe, second call keeps the action ignored" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    ignoreSigpipe();
    ignoreSigpipe();

    try std.testing.expectEqual(std.posix.SIG.IGN, testCurrentPipeHandler());
}

test "zix utils: ignoreSigpipe, write to a closed pipe returns PIPE" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    ignoreSigpipe();

    const fds = try std.Io.Threaded.pipe2(.{});
    _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const data: []const u8 = "x";
    const rc = std.posix.system.write(fds[1], data.ptr, data.len);

    try std.testing.expectEqual(std.posix.E.PIPE, std.posix.errno(rc));
}

