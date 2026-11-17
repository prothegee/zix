//! ZIX Uds Config
//!
//! ### file: src/zix/uds/Config.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Server configuration for one Unix domain socket (UDS) stream server.
//!
//! ### note:
//!
//! The handler never reads this config. max_recv_buf is checked and logged by the
//! server only, the default echoHandler keeps its own buffer sizes.
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
const Logger = @import("../logger/Logger.zig");

// --------------------------------------------------------- //
// Fields:

/// Io backend for the server. Caller owns, must outlive the server.
io: std.Io,
/// Backing allocator. Caller owns, must outlive the server.
allocator: std.mem.Allocator,
/// Filesystem path of the socket file (max 107 bytes on Linux and macOS).
/// The server removes this path before bind and again when run() exits.
path: []const u8,
/// Pending connections the kernel queues before accept().
kernel_backlog: u31 = 128,
/// Max payload bytes per frame. Must not be 0. The server checks and logs it,
/// the handler does not receive it.
max_recv_buf: usize = 4 * 1024,
/// Receive timeout per accepted connection in milliseconds (SO_RCVTIMEO).
/// 0 disables it.
recv_timeout_ms: u32 = 0,
/// Send timeout per accepted connection in milliseconds (SO_SNDTIMEO).
/// 0 disables it.
send_timeout_ms: u32 = 0,
/// Lifecycle logger. Caller owns, must outlive the server.
logger: ?*Logger = null,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testConfig() Self {
    return .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .path = "zix.sock",
    };
}

test "zix uds: Config, keeps the caller path" {
    const config = testConfig();

    try std.testing.expectEqualStrings("zix.sock", config.path);
}

test "zix uds: Config, keeps the caller allocator" {
    const config = testConfig();

    try std.testing.expectEqual(std.testing.allocator.ptr, config.allocator.ptr);
}

test "zix uds: Config, kernel_backlog defaults to 128" {
    const config = testConfig();

    try std.testing.expectEqual(@as(u31, 128), config.kernel_backlog);
}

test "zix uds: Config, max_recv_buf defaults to 4 KiB" {
    const config = testConfig();

    try std.testing.expectEqual(@as(usize, 4 * 1024), config.max_recv_buf);
}

test "zix uds: Config, timeouts default to disabled" {
    const config = testConfig();

    try std.testing.expectEqual(@as(u32, 0), config.recv_timeout_ms);
    try std.testing.expectEqual(@as(u32, 0), config.send_timeout_ms);
}

test "zix uds: Config, logger defaults to null" {
    const config = testConfig();

    try std.testing.expectEqual(@as(?*Logger, null), config.logger);
}

test "zix uds: Config, keeps explicit overrides" {
    const config: Self = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .path = "/tmp/zix.sock",
        .kernel_backlog = 16,
        .max_recv_buf = 64 * 1024,
        .recv_timeout_ms = 250,
        .send_timeout_ms = 500,
    };

    try std.testing.expectEqual(@as(u31, 16), config.kernel_backlog);
    try std.testing.expectEqual(@as(usize, 64 * 1024), config.max_recv_buf);
    try std.testing.expectEqual(@as(u32, 250), config.recv_timeout_ms);
    try std.testing.expectEqual(@as(u32, 500), config.send_timeout_ms);
}

test "zix uds: Config, kernel_backlog accepts the u31 max" {
    var config = testConfig();
    config.kernel_backlog = std.math.maxInt(u31);

    try std.testing.expectEqual(@as(u31, std.math.maxInt(u31)), config.kernel_backlog);
}

test "zix uds: Config, timeouts accept the u32 max" {
    var config = testConfig();
    config.recv_timeout_ms = std.math.maxInt(u32);
    config.send_timeout_ms = std.math.maxInt(u32);

    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), config.recv_timeout_ms);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), config.send_timeout_ms);
}

test "zix uds: Config, accepts an empty path" {
    var config = testConfig();
    config.path = "";

    try std.testing.expectEqual(@as(usize, 0), config.path.len);
}

