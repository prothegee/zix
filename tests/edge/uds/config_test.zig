//! Edge tests: zix.Uds boundary conditions.
//! Verifies that empty path is rejected, and frame length encoding at boundaries.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix edge: UdsServer.init, empty path returns error.PathEmpty" {
    const result = zix.Uds.Server.init(.{
        .path = "",
        .allocator = std.testing.allocator,
    });
    try std.testing.expectError(error.PathEmpty, result);
}

test "zix edge: UdsClientConfig, recv_timeout_ms = 0 disables timeout (default)" {
    const cfg = zix.Uds.ClientConfig{ .path = "/tmp/zix.sock" };
    try std.testing.expectEqual(@as(u32, 0), cfg.recv_timeout_ms);
}

test "zix edge: UdsClientConfig, send_timeout_ms = 0 disables timeout (default)" {
    const cfg = zix.Uds.ClientConfig{ .path = "/tmp/zix.sock" };
    try std.testing.expectEqual(@as(u32, 0), cfg.send_timeout_ms);
}

test "zix edge: UdsClientConfig, large recv_timeout_ms value is stored without overflow" {
    const cfg = zix.Uds.ClientConfig{
        .path = "/tmp/zix.sock",
        .recv_timeout_ms = std.math.maxInt(u32),
    };
    try std.testing.expectEqual(std.math.maxInt(u32), cfg.recv_timeout_ms);
}

test "zix edge: HttpClient.requestUds, path too long returns error.InvalidPath" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = std.testing.allocator,
        .io = threaded.io(),
    });
    defer client.deinit();

    // Unix socket paths are limited to 108 bytes on Linux. Build a path that exceeds that.
    const long_path = "/tmp/" ++ ("a" ** 108) ++ ".sock";
    try std.testing.expectError(error.InvalidPath, client.requestUds(.GET, long_path, "/", .{}));
}
