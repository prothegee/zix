//! zix uds config

const std = @import("std");
const Logger = @import("../logger/logger.zig").Logger;

// --------------------------------------------------------- //

/// UDS stream server configuration.
pub const UdsServerConfig = struct {
    /// Filesystem path for the socket file (max 107 bytes on Linux/macOS).
    /// Server unlinks this path before binding and again when run() exits.
    path: []const u8,
    /// Backing allocator. Caller owns, must outlive the server.
    allocator: std.mem.Allocator,
    /// listen() kernel backlog: pending connections before the OS starts refusing.
    backlog: u31 = 128,
    /// Maximum payload bytes accepted per frame. Frames larger than this close the connection.
    max_msg_len: usize = 4096,
    /// Socket receive timeout per accepted connection in milliseconds (SO_RCVTIMEO). 0 = disabled.
    recv_timeout_ms: u32 = 0,
    /// Socket send timeout per accepted connection in milliseconds (SO_SNDTIMEO). 0 = disabled.
    send_timeout_ms: u32 = 0,
    /// Optional logger. When non-null, the server calls logger.system() for lifecycle events.
    /// Caller owns. Must outlive the server.
    logger: ?*Logger = null,
};

// --------------------------------------------------------- //

/// UDS stream client configuration.
pub const UdsClientConfig = struct {
    /// Filesystem path of the server socket to connect to.
    path: []const u8,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: UdsServerConfig, default field values" {
    const cfg = UdsServerConfig{
        .path = "/tmp/zix.sock",
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqualStrings("/tmp/zix.sock", cfg.path);
    try std.testing.expectEqual(std.testing.allocator.ptr, cfg.allocator.ptr);
    try std.testing.expectEqual(@as(u31, 128), cfg.backlog);
    try std.testing.expectEqual(@as(usize, 4096), cfg.max_msg_len);
    try std.testing.expectEqual(@as(u32, 0), cfg.recv_timeout_ms);
    try std.testing.expectEqual(@as(u32, 0), cfg.send_timeout_ms);
}

test "zix test: UdsClientConfig, default field values" {
    const cfg = UdsClientConfig{ .path = "/tmp/zix.sock" };
    try std.testing.expectEqualStrings("/tmp/zix.sock", cfg.path);
}
