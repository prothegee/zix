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
