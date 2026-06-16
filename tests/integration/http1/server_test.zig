//! Integration tests: zix.Http1.Server.init wiring and dispatch model configuration.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

fn noopHandler(_: *const zix.Http1.ParsedHead, _: []const u8, _: std.posix.fd_t) void {}

test "zix integration: Http1 Server.init valid config, deinit is safe" {
    var server = zix.Http1.Server.init(noopHandler, .{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
    });
    server.deinit();
}

test "zix integration: Http1 Server.init POOL dispatch model" {
    var server = zix.Http1.Server.init(noopHandler, .{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .POOL,
    });
    server.deinit();
}

test "zix integration: Http1 Server.init MIXED dispatch model" {
    var server = zix.Http1.Server.init(noopHandler, .{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .MIXED,
    });
    server.deinit();
}

test "zix integration: Http1 Server.init EPOLL dispatch model" {
    var server = zix.Http1.Server.init(noopHandler, .{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .EPOLL,
    });
    server.deinit();
}

test "zix integration: Http1 Server.init URING dispatch model" {
    var server = zix.Http1.Server.init(noopHandler, .{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .URING,
    });
    server.deinit();
}
