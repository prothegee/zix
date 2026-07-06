//! Integration tests: router dispatch with full Request/Response/Context wiring.
//! Verifies dispatch routes to the correct handler and populates path_params.

const std = @import("std");
const zix = @import("zix");

var last_handler: []const u8 = "";

fn handlerA(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = res;
    _ = ctx;
    last_handler = "A";
}

fn handlerB(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = res;
    _ = ctx;
    last_handler = "B";
}

// --------------------------------------------------------- //

test "zix integration: dispatch, exact match routes to handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var server = zix.Http.Server.init(&[_]zix.Http.Route{
        .{ .path = "/about", .handler = handlerA },
    }, .{ .io = undefined, .ip = "127.0.0.1", .port = 9000, .dispatch_model = .ASYNC });
    defer server.deinit();

    var req = try zix.Http.Request.fromRaw("GET /about HTTP/1.1\r\nHost: localhost\r\n\r\n", al);
    var res = zix.Http.Response.init(undefined, false, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    last_handler = "";
    try std.testing.expect(try server.router.dispatch(&req, &res, &ctx));
    try std.testing.expectEqualStrings("A", last_handler);
}

test "zix integration: dispatch, param populates path_params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var server = zix.Http.Server.init(&[_]zix.Http.Route{
        .{ .path = "/users/:id", .handler = handlerA, .kind = .PARAM },
    }, .{ .io = undefined, .ip = "127.0.0.1", .port = 9000, .dispatch_model = .ASYNC });
    defer server.deinit();

    var req = try zix.Http.Request.fromRaw("GET /users/bob HTTP/1.1\r\nHost: localhost\r\n\r\n", al);
    var res = zix.Http.Response.init(undefined, false, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    try std.testing.expect(try server.router.dispatch(&req, &res, &ctx));
    try std.testing.expectEqual(@as(usize, 1), req.path_params.len);
    try std.testing.expectEqualStrings("id", req.path_params[0].name);
    try std.testing.expectEqualStrings("bob", req.path_params[0].value);
    try std.testing.expectEqualStrings("bob", req.pathParam("id").?);
}

test "zix integration: dispatch, two path params both populated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var server = zix.Http.Server.init(&[_]zix.Http.Route{
        .{ .path = "/orgs/:org/repos/:repo", .handler = handlerA, .kind = .PARAM },
    }, .{ .io = undefined, .ip = "127.0.0.1", .port = 9000, .dispatch_model = .ASYNC });
    defer server.deinit();

    var req = try zix.Http.Request.fromRaw("GET /orgs/zix/repos/core HTTP/1.1\r\nHost: localhost\r\n\r\n", al);
    var res = zix.Http.Response.init(undefined, false, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    try std.testing.expect(try server.router.dispatch(&req, &res, &ctx));
    try std.testing.expectEqual(@as(usize, 2), req.path_params.len);
    try std.testing.expectEqualStrings("zix", req.path_params[0].value);
    try std.testing.expectEqualStrings("core", req.path_params[1].value);
}

test "zix integration: dispatch, prefix routes to handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var server = zix.Http.Server.init(&[_]zix.Http.Route{
        .{ .path = "/static", .handler = handlerA, .kind = .PREFIX },
    }, .{ .io = undefined, .ip = "127.0.0.1", .port = 9000, .dispatch_model = .ASYNC });
    defer server.deinit();

    var req = try zix.Http.Request.fromRaw("GET /static/css/app.css HTTP/1.1\r\nHost: localhost\r\n\r\n", al);
    var res = zix.Http.Response.init(undefined, false, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    last_handler = "";
    try std.testing.expect(try server.router.dispatch(&req, &res, &ctx));
    try std.testing.expectEqualStrings("A", last_handler);
}
