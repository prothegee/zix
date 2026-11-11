//! ZIX Http2 Grpc mux tcp_cork
//!
//! ### file: src/zix/tcp/http2/grpc/mux/tcp_cork.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Turn TCP_CORK on or off for a mux connection, so the many flushes of a
//! server-streaming reply leave in fewer TCP segments.
//!
//! ### note:
//!
//! Linux only and best effort: a no-op elsewhere, and a socket without
//! TCP_CORK (a test socket pair) is left as it is.
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

/// Set TCP_CORK on fd.
///
/// Param:
/// fd - std.posix.fd_t (a connected socket)
/// enable - bool (true holds partial segments until uncorked)
///
/// Return:
/// - bool (true when the kernel took the option)
pub fn set(fd: std.posix.fd_t, enable: bool) bool {
    if (comptime builtin.target.os.tag != .linux) return false;

    const linux = std.os.linux;
    const value: c_int = if (enable) 1 else 0;
    const bytes = std.mem.asBytes(&value);

    const rc = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.CORK, bytes, bytes.len);

    return switch (linux.errno(rc)) {
        .SUCCESS => true,
        // Best effort: an unsupported socket only loses the batching.
        else => false,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../../../utils/socket/pair.zig");

fn isLinux() bool {
    if (comptime builtin.target.os.tag == .linux) return true;

    std.log.info("TCP_CORK is Linux-only, test skipped", .{});

    return false;
}

test "zix http2 grpc mux: tcp_cork, a socket pair refuses TCP_CORK" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try std.testing.expect(!set(fds[1], true));
}

test "zix http2 grpc mux: tcp_cork, a TCP socket takes TCP_CORK" {
    if (!isLinux()) return;

    const linux = std.os.linux;
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;

    const fd: std.posix.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    try std.testing.expect(set(fd, true));
    try std.testing.expect(set(fd, false));
}

