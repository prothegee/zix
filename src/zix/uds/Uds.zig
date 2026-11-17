//! ZIX Uds
//!
//! ### file: src/zix/uds/Uds.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Zix Uds namespace: the Unix Domain Socket stream server surface.
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

// --------------------------------------------------------- //
// Public:

/// UDS stream server.
///
/// Usage:
/// ```zig
/// var server = try zix.Uds.Server.init(zix.Uds.echoHandler, .{
///     .io = io,
///     .allocator = allocator,
///     .path = "/tmp/app.sock",
/// });
/// defer server.deinit();
///
/// try server.run();
/// ```
pub const Server = @import("Server.zig");

/// Server config: socket path, backlog, frame cap, timeouts, logger.
pub const ServerConfig = @import("Config.zig");

/// Per-connection handler type: fn (stream, io) void.
pub const HandlerFn = @import("handler.zig").HandlerFn;

/// Default handler: reads length-prefixed frames and echoes each back.
pub const echoHandler = @import("handler.zig").echoHandler;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn probeHandler(_: std.Io.net.Stream, _: std.Io) void {}

test "zix uds: Uds, exposes the server" {
    try std.testing.expect(@hasDecl(@This().Server, "init"));
    try std.testing.expect(@hasDecl(@This().Server, "run"));
    try std.testing.expect(@hasDecl(@This().Server, "deinit"));
}

test "zix uds: Uds, ServerConfig is the Config record" {
    try std.testing.expect(@This().ServerConfig == @import("Config.zig"));
}

test "zix uds: Uds, ServerConfig keeps the default frame cap" {
    const config: @This().ServerConfig = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .path = "zix.sock",
    };

    try std.testing.expectEqual(@as(usize, 4 * 1024), config.max_recv_buf);
}

test "zix uds: Uds, HandlerFn takes a stream and io" {
    const handler: *const @This().HandlerFn = probeHandler;

    try std.testing.expect(handler == &probeHandler);
}

test "zix uds: Uds, echoHandler matches HandlerFn" {
    const handler: *const @This().HandlerFn = @This().echoHandler;

    try std.testing.expect(handler == &@import("handler.zig").echoHandler);
}

test "zix uds: Uds, Server init rejects an empty path" {
    const result = @This().Server.init(@This().echoHandler, .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .path = "",
    });

    try std.testing.expectError(@This().Server.Error.ZixUds_Server_PathEmpty, result);
}

