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

test "zix integration: UDS echoHandler, signature matches expected type" {
    const HandlerType = fn (std.Io.net.Stream, std.Io) void;
    const handler: HandlerType = zix.Uds.echoHandler;
    _ = handler;
}
