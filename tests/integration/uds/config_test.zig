//! Integration tests: UDS Server.init and HandlerFn wiring.

const std = @import("std");
const zix = @import("zix");

test "zix integration: UdsServer.init, valid path succeeds and deinit is safe" {
    var server = try zix.Uds.Server.init(.{
        .path = "/tmp/zix_integration_test.sock",
        .allocator = std.testing.allocator,
    });
    server.deinit();
}

test "zix integration: UDS HandlerFn, echoHandler satisfies the type" {
    const handler: zix.Uds.HandlerFn = zix.Uds.echoHandler;
    _ = handler;
}
