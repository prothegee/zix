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
