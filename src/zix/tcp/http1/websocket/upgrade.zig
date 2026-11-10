//! ZIX http1 websocket upgrade
//!
//! ### file: src/zix/tcp/http1/websocket/upgrade.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Writes the 101 Switching Protocols response that completes the WebSocket
//! handshake.
//!
//! ### note:
//!
//! The response goes through writer.writeAllFD, so on .EPOLL and .URING it
//! lands in the batch before any frame the handler sends next.
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
// Private:

/// Room for the 101 response with a 28-byte accept value.
const UPGRADE_RESPONSE_SIZE: usize = 256;

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 WebSocket upgrade error
pub const Error = error {
    ZixHttp1_WebSocketUpgrade_NoSpaceLeft,
    ZixHttp1_WebSocketUpgrade_BrokenPipe,
    ZixHttp1_WebSocketUpgrade_HeadBuild,
};

/// Write the 101 Switching Protocols response to fd.
///
/// Param:
/// fd - std.posix.fd_t
/// accept - []const u8 (value from frame.acceptKey)
///
/// Return:
/// - void
/// - error.ZixHttp1_WebSocketUpgrade_NoSpaceLeft when accept is too long
/// - error.ZixHttp1_WebSocketUpgrade_BrokenPipe when the write fails
pub fn upgrade(fd: std.posix.fd_t, accept: []const u8) Error!void {
    var response_buf: [UPGRADE_RESPONSE_SIZE]u8 = undefined;
    const response = std.fmt.bufPrint(
        &response_buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept},
    ) catch |err| switch (err) {
        error.NoSpaceLeft => return Error.ZixHttp1_WebSocketUpgrade_NoSpaceLeft,
    };

    writer.writeAllFD(fd, response) catch |err| switch (err) {
        error.ZixHttp1_Writer_BrokenPipe => return Error.ZixHttp1_WebSocketUpgrade_BrokenPipe,
        error.ZixHttp1_Writer_HeadBuild => return Error.ZixHttp1_WebSocketUpgrade_HeadBuild,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../../utils/socket/pair.zig");
const reader = @import("../reader.zig");

test "zix http1 websocket: upgrade, writes the 101 response" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try upgrade(fds[0], "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");

    var out: [256]u8 = undefined;
    const len = try reader.readOnceFD(fds[1], &out);
    const expected =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n";

    try std.testing.expectEqualStrings(expected, out[0..len]);
}

test "zix http1 websocket: upgrade, rejects an accept too long" {
    const accept: [UPGRADE_RESPONSE_SIZE]u8 = @splat('a');

    try std.testing.expectError(
        Error.ZixHttp1_WebSocketUpgrade_NoSpaceLeft,
        upgrade(-1, &accept),
    );
}

test "zix http1 websocket: upgrade, reports a broken pipe" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    _ = std.posix.system.close(fds[1]);

    try std.testing.expectError(
        Error.ZixHttp1_WebSocketUpgrade_BrokenPipe,
        upgrade(fds[0], "abc"),
    );
}

